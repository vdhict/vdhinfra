#!/usr/bin/env bash
# =============================================================================
# vdhwslin01: Forgejo Actions runner, one throwaway KVM VM per job
# chg-2026-10-05-031 (owner: k8s-engineer / Heph). GENERATED FILE: edit
# provision.in.sh + src/ and run ./build.sh; tests/run-all.sh checks it is
# in sync.
#
# Sander runs this ONCE with sudo on vdhwslin01. It is idempotent: a re-run
# skips what is already in place and prints every action it takes.
#
# Decisions it implements (Larry for the owner, 2026-10-13; AGR-114, AGR-115):
# - The box stays Sander's workstation on CLIENT-VLAN. CI isolation is
#   enforced ON THE HOST (KVM VM per job + nftables), not by LAB-VLAN 60.
#   This is a recorded deviation from Argus R4/R6 for Argus.
# - Only own-team repos (registration scope = the token's scope; first
#   mypka-bot/passkey-point-dotnet), no secrets, no client data on the box.
# - Argus H2 (autologin opens the desktop on a team boot): OWNER RISK
#   ACCEPTANCE, Sander 2026-10-13 (machine is in his own office, low risk).
#   Autologin stays, and there is NO screen-lock hook. /run/team-boot is
#   still written: idle-poweroff needs it to tell team boots from his.
#
# What it sets up:
#   user `runner` (system, nologin, no sudo, groups: kvm)
#   forgejo-runner v13.2.0 vendor binary, sha256-pinned
#   qemu/KVM (qemu-base). libvirt is deliberately NOT used: qemu:///system
#     would make `runner` root-equivalent; qemu runs unprivileged as runner.
#   golden VM: Debian 13 cloud image (sha512-pinned) + docker, built once,
#     root-owned 0444, sha256-pinned; each job gets a fresh qcow2 overlay
#     that is destroyed after the job. No virtiofs/9p/vsock/USB, no host
#     docker socket, user-mode networking only (no bridge/tap).
#   runner mechanism: `forgejo-runner one-job --wait` on the HOST (token
#     stays on the host, 0600) against the VM's dockerd over an ssh-forwarded
#     socket; one job per VM.
#   nftables table inet vdh_runner (on top of the existing firewall):
#     inbound 22/2222 only from the cluster nodes, the Mini and Sander's
#     MacBook (LAN + WireGuard peer, + --allow-ssh-from);
#     everything uid `runner` (qemu/VMs and the runner) sends: only tcp
#     80/443 to public addresses, tcp 443 to envoy-forge, DNS via the host
#     resolver; no RFC1918, no IPv6, no other host port.
#   vdh-runner-nft-guard.timer (every 1 min) + ExecStartPre: the runner stops
#     taking jobs as soon as table inet vdh_runner is missing or incomplete.
#   idle-poweroff.timer (every 5 min): powers off ONLY a team-started boot
#     (/run/team-boot with this boot_id), runner idle, seat0 idle >= 60 min,
#     uptime >= 2 h. Never a boot Sander started.
#   initramfs: controller's dropbear PUBLIC key + the vdh-teamboot wrapper
#     (marks ssh-unlocked boots as team boots); rebuilds the initramfs.
#   LUKS: a separate keyslot for the controller, passphrase read from stdin
#     (or a hidden prompt), never written to disk. Revoke: luksKillSlot.
#
# Usage (as root):
#   <controller passphrase on stdin, see the bundle> | \
#   sudo ./provision.sh --forge-url https://forge.<domain> \
#     --envoy-forge-ip 172.16.2.249 --reg-token - \
#     --controller-pubkey 'ssh-ed25519 AAAA... vdhwslin01-waker'
#   Without a pipe it asks for the passphrase with a hidden prompt.
#   --reg-token -   asks for the one-time registration token (hidden prompt).
#   --dry-run       detect and print the plan, change nothing.
#   --steps a,b     run only these steps (see STEPS below).
#   --uninstall     remove everything this script added (see uninstall()).
# =============================================================================
set -euo pipefail
umask 022

RUNNER_VERSION=13.2.0
RUNNER_URL="https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-amd64"
RUNNER_SHA256=fadaec897f5e6641c363f87ecaf75f866f99c81b7097ec6b433e4c48123fcad1
BASE_NAME=debian-13-genericcloud-amd64-20261001-2618.qcow2
BASE_URL="https://cloud.debian.org/images/cloud/trixie/20261001-2618/${BASE_NAME}"
BASE_SHA512=f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d
RUNNER_NAME=vdhwslin01
RUNNER_LABELS="docker:docker://node:24-bookworm,x86-linux:docker://node:24-bookworm"
KEY_COMMENT=vdhwslin01-waker
# Inbound 22/2222 allow-list (host addresses only, never subnets):
#   cluster worker nodes (controller CronJob egress is SNATed to these) + the Mini
SSH_ALLOW_CLUSTER=(172.16.2.81 172.16.2.82 172.16.2.83 172.16.2.201)
#   Sander's MacBook, where the agent access lives (SOP-023): Wi-Fi + wired,
#   both DHCP-reserved (Larry/Atlas 2026-10-13)
SSH_ALLOW_MACBOOK=(172.16.3.108 172.16.3.23)
#   Sander's MacBook WireGuard peer addresses (Hermod 2026-10-13): the peer
#   IPs only, never the server subnets 192.168.12.0/24 / 192.168.4.0/24.
#   192.168.12.6 = VDHNGFW peer "Macbook", 192.168.4.6 = VDHVPN02 peer "MacBook Sander".
SSH_ALLOW_MACBOOK_WG_PEERS=(192.168.12.6 192.168.4.6)
SSH_ALLOW=("${SSH_ALLOW_CLUSTER[@]}" "${SSH_ALLOW_MACBOOK[@]}" "${SSH_ALLOW_MACBOOK_WG_PEERS[@]}")
BOX_IP=172.16.3.205
UNLOCK_PORT=2222
STEPS_ALL=(preflight packages user binary payload vmkey firewall golden register services initramfs keyslot report)

FORGE_URL=""; FORGE_HOST=""; ENVOY_FORGE_IP=""; REG_TOKEN=""; CTRL_PUBKEY=""
LUKS_DEV=""; DRY=0; UNINSTALL=0; REBUILD_GOLDEN=0; STEPS=()
INITRD_SSHD=""; INITRD_KEYFILE=""; DNS_STUB=0; DNS_SERVERS=()

say()  { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# run <cmd...>: print, then execute (or only print in --dry-run).
run() {
  if (( DRY )); then printf '[dry-run]'; printf ' %q' "$@"; echo; return 0; fi
  printf '+'; printf ' %q' "$@"; echo
  "$@"
}

# write_file <dest> <mode> <owner:group>; content on stdin. Idempotent.
write_file() {
  local dest="$1" mode="$2" owner="$3" content
  content="$(cat; echo x)"; content="${content%x}"
  [[ ! -L "$dest" ]] || die "$dest is a symlink; refusing to write through it"
  if [[ -f "$dest" ]] && cmp -s <(printf '%s' "$content") "$dest" \
     && [[ "$(stat -c '%a %U:%G' "$dest")" == "${mode#0} ${owner}" ]]; then
    info "unchanged: $dest"; return 0
  fi
  if (( DRY )); then
    info "[dry-run] would write $dest ($(printf '%s' "$content" | wc -c) bytes, mode $mode, $owner)"
    return 0
  fi
  install -d -m 0755 "$(dirname "$dest")"
  printf '%s' "$content" > "$dest"
  chmod "$mode" "$dest"; chown "$owner" "$dest"
  info "wrote: $dest"
}

# F1 (Argus): root never creates, chowns, chmods or writes into a path that
# `runner` controls. Runner-owned dirs are created BY runner; an existing one
# is only checked (directory, not a symlink, owned by runner), never changed.
runner_dir() { # runner_dir <path> <mode>
  local p="$1" m="$2"
  [[ ! -L "$p" ]] || die "$p is a symlink; refusing (F1)"
  if [[ -e "$p" ]]; then
    [[ -d "$p" && "$(stat -c %U "$p")" == runner ]] || die "$p exists but is not a runner-owned directory; refusing (F1)"
    info "exists: $p"; return 0
  fi
  run runuser -u runner -- install -d -m "$m" "$p"
}

want_step() { local s; for s in "${STEPS[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
  local steps_csv=""
  while (( $# )); do
    case "$1" in
      --forge-url) FORGE_URL="${2:?}"; shift 2 ;;
      --envoy-forge-ip) ENVOY_FORGE_IP="${2:?}"; shift 2 ;;
      --reg-token) REG_TOKEN="${2:?}"; shift 2 ;;
      --controller-pubkey) CTRL_PUBKEY="${2:?}"; shift 2 ;;
      --allow-ssh-from) SSH_ALLOW+=("${2:?}"); shift 2 ;;
      --luks-device) LUKS_DEV="${2:?}"; shift 2 ;;
      --box-ip) BOX_IP="${2:?}"; shift 2 ;;
      --steps) steps_csv="${2:?}"; shift 2 ;;
      --rebuild-golden) REBUILD_GOLDEN=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      -h|--help) usage 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  if [[ -n "$steps_csv" ]]; then
    IFS=, read -r -a STEPS <<<"$steps_csv"
    local s ok
    for s in "${STEPS[@]}"; do
      ok=0; for a in "${STEPS_ALL[@]}"; do [[ "$s" == "$a" ]] && ok=1; done
      (( ok )) || die "unknown step: $s (valid: ${STEPS_ALL[*]})"
    done
    want_step preflight || STEPS=(preflight "${STEPS[@]}")
  else
    STEPS=("${STEPS_ALL[@]}")
  fi
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# ---------------------------------------------------------------------------
# Embedded payloads (generated from src/ by build.sh; do not edit here)
# ---------------------------------------------------------------------------
# @@PAYLOADS@@

# ---------------------------------------------------------------------------
detect_dns() {
  local ns
  while read -r ns; do
    [[ "$ns" == 127.0.0.53 ]] && { DNS_STUB=1; continue; }
    is_ipv4 "$ns" && DNS_SERVERS+=("$ns")
  done < <(awk '$1=="nameserver"{print $2}' /etc/resolv.conf 2>/dev/null)
  (( DNS_STUB )) || (( ${#DNS_SERVERS[@]} )) || die "no usable IPv4 nameserver in /etc/resolv.conf"
}

effective_hooks() {
  # mkinitcpio config is bash; read it the way mkinitcpio does.
  bash -c 'HOOKS=(); . /etc/mkinitcpio.conf 2>/dev/null
    for f in /etc/mkinitcpio.conf.d/*.conf; do [[ -r "$f" ]] && . "$f"; done
    echo "${HOOKS[*]}"'
}

detect_initramfs() {
  command -v mkinitcpio >/dev/null || die "mkinitcpio not found; this script supports mkinitcpio + encryptssh only"
  local hooks; hooks=" $(effective_hooks) "
  info "effective HOOKS:${hooks}"
  if [[ "$hooks" != *" encryptssh "* ]]; then
    if [[ "$hooks" == *" sd-encrypt "* ]]; then
      die "initramfs uses sd-encrypt (systemd). The team-boot marker supports encryptssh (mkinitcpio-utils) only. Re-run with --steps excluding initramfs,keyslot and tell Heph; the runner works, team boots are then never powered off (safe)."
    fi
    die "no encryptssh hook in HOOKS; how is the dropbear unlock on ${UNLOCK_PORT} built? Tell Heph (send the HOOKS line above)."
  fi
  if [[ "$hooks" == *" dropbear "* ]]; then
    INITRD_SSHD=dropbear; INITRD_KEYFILE=/etc/dropbear/root_key
  elif [[ "$hooks" == *" tinyssh "* ]]; then
    INITRD_SSHD=tinyssh; INITRD_KEYFILE=/etc/tinyssh/root_key
  else
    die "encryptssh found but no dropbear/tinyssh hook"
  fi
  [[ -s "$INITRD_KEYFILE" ]] || die "$INITRD_KEYFILE is missing or empty (expected Sander's existing unlock key)"
  info "initramfs ssh: ${INITRD_SSHD}, authorized keys: ${INITRD_KEYFILE}"
}

detect_luks() {
  if (( DRY )) && ! command -v cryptsetup >/dev/null; then warn "cryptsetup missing (dry-run continues)"; return 0; fi
  if [[ -z "$LUKS_DEV" ]]; then
    local src name
    src="$(findmnt -no SOURCE / | sed 's/\[.*\]$//')"
    name="${src#/dev/mapper/}"
    if [[ "$name" == "$src" ]]; then
      (( DRY )) && { warn "/ is not on a /dev/mapper device ($src) (dry-run continues)"; return 0; }
      die "/ is not on a /dev/mapper device ($src); pass --luks-device"
    fi
    LUKS_DEV="$(cryptsetup status "$name" | awk '$1=="device:"{print $2}')"
  fi
  if ! { [[ -b "$LUKS_DEV" ]] && cryptsetup isLuks "$LUKS_DEV"; }; then die "$LUKS_DEV is not a LUKS device"; fi
  info "LUKS device: $LUKS_DEV"
}

step_preflight() {
  say "preflight"
  if (( ! DRY )) && (( EUID != 0 )); then die "run with sudo"; fi
  [[ "$(uname -m)" == x86_64 ]] || die "x86_64 only"
  if ! { [[ -f /etc/arch-release ]] && command -v pacman >/dev/null; }; then die "Arch (pacman) only"; fi
  if { want_step golden || want_step services; } && [[ ! -c /dev/kvm ]]; then
    if (( DRY )); then warn "/dev/kvm missing (dry-run continues)"; else die "/dev/kvm missing (VT-x off in firmware?)"; fi
  fi
  if want_step payload || want_step register || want_step firewall; then
    [[ "$FORGE_URL" =~ ^https://([A-Za-z0-9.-]+)/?$ ]] || die "--forge-url https://<host> required"
    FORGE_HOST="${BASH_REMATCH[1]}"
    is_ipv4 "$ENVOY_FORGE_IP" || die "--envoy-forge-ip <IPv4> required"
  fi
  local ip; for ip in "${SSH_ALLOW[@]}"; do is_ipv4 "$ip" || die "bad --allow-ssh-from $ip"; done
  if want_step initramfs; then
    [[ "$CTRL_PUBKEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "--controller-pubkey 'ssh-ed25519 AAAA...' required"
    detect_initramfs
  fi
  want_step keyslot && detect_luks
  want_step firewall && detect_dns
  info "steps: ${STEPS[*]}"
  info "inbound 22/${UNLOCK_PORT} will be allowed only from: ${SSH_ALLOW[*]}"
  (( ${#SSH_ALLOW_MACBOOK_WG_PEERS[@]} )) || [[ ${#SSH_ALLOW[@]} -gt $(( ${#SSH_ALLOW_CLUSTER[@]} + ${#SSH_ALLOW_MACBOOK[@]} )) ]] \
    || warn "no MacBook WireGuard peer IP set: ssh over WireGuard will be dropped; add --allow-ssh-from <peer-ip>"
  info "ssh from any other machine will be dropped; add --allow-ssh-from <ip> for each one you use"
}

step_packages() {
  say "packages"
  local p missing=()
  for p in qemu-base libisoburn nftables openssh curl cryptsetup; do
    pacman -Q "$p" >/dev/null 2>&1 && info "installed: $p" || missing+=("$p")
  done
  (( ${#missing[@]} )) || return 0
  run pacman -S --needed --noconfirm "${missing[@]}" \
    || die "pacman install failed. Arch does not support partial upgrades: run 'sudo pacman -Syu' yourself, then re-run this script."
}

step_user() {
  say "user runner"
  if id runner >/dev/null 2>&1; then info "user runner exists"
  else run useradd --system --user-group --home-dir /var/lib/forgejo-runner --create-home --shell /usr/bin/nologin runner; fi
  if ! id -nG runner 2>/dev/null | tr ' ' '\n' | grep -qx kvm; then run usermod -aG kvm runner; fi
  run passwd -l runner
  if (( ! DRY )); then
    local g; g=" $(id -nG runner) "
    [[ "$g" != *" wheel "* && "$g" != *" sudo "* ]] || die "runner is in wheel/sudo; refusing"
    if command -v sudo >/dev/null && sudo -l -U runner 2>/dev/null | grep -q 'may run'; then die "runner has sudo rights; refusing"; fi
    info "runner groups:${g}(no wheel/sudo)"
  fi
  # The home dir is created by useradd (fresh, as root, in root-owned /var/lib).
  if (( ! DRY )); then
    [[ ! -L /var/lib/forgejo-runner && -d /var/lib/forgejo-runner ]] || die "/var/lib/forgejo-runner missing or a symlink"
    [[ "$(stat -c %U /var/lib/forgejo-runner)" == runner ]] || die "/var/lib/forgejo-runner is not owned by runner"
    runner_dir /var/lib/forgejo-runner/.ssh 0700
    runner_dir /var/lib/forgejo-runner/vm 0750
  else
    info "[dry-run] would create (as runner) /var/lib/forgejo-runner/.ssh and /vm"
  fi
  run install -d -o root -g root -m 0755 /var/lib/vdh-runner-golden /var/lib/vdh-runner-stage /etc/vdh-runner /usr/local/libexec/vdh-runner /usr/local/lib/vdh-runner
  run install -d -o root -g root -m 0700 /var/cache/vdh-runner
}

step_binary() {
  say "forgejo-runner ${RUNNER_VERSION}"
  local bin=/usr/local/bin/forgejo-runner dl=/var/cache/vdh-runner/forgejo-runner-${RUNNER_VERSION}.download
  if [[ -x "$bin" ]] && [[ "$(sha256sum "$bin" | cut -d' ' -f1)" == "$RUNNER_SHA256" ]]; then
    info "already installed, sha256 ok"; return 0
  fi
  run curl -fsSL --proto '=https' -o "$dl" "$RUNNER_URL"
  if (( ! DRY )); then
    local have; have="$(sha256sum "$dl" | cut -d' ' -f1)"
    [[ "$have" == "$RUNNER_SHA256" ]] || die "forgejo-runner sha256 mismatch: got $have"
    info "sha256 ok: $have"
  fi
  run install -o root -g root -m 0755 "$dl" "$bin"
  (( DRY )) || info "$("$bin" --version)"
}

nsswitch_content() {
  printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n'
}

runner_yaml() {
  cat <<EOF
# vdhwslin01 forgejo-runner config (chg-2026-10-05-031). Written by provision.sh.
log:
  level: info
  job_level: info
runner:
  file: /var/lib/forgejo-runner/.runner
  capacity: 1
  timeout: 3h
  shutdown_timeout: 5m
  insecure: false
  fetch_timeout: 30s
  fetch_interval: 10s
  report_interval: 1s
cache:
  enabled: false
container:
  network: ""
  enable_ipv6: false
  privileged: false
  options: "--add-host=${FORGE_HOST}:${ENVOY_FORGE_IP}"
  valid_volumes: []
  # The VM's dockerd, reached over the ssh-forwarded socket at the same path
  # the VM uses; this is also what job containers get mounted (the VM's own).
  docker_host: "unix:///run/forgejo-runner/docker.sock"
  force_pull: false
host:
  workdir_parent: /var/lib/forgejo-runner/host-workdir
EOF
}

step_payload() {
  say "scripts, units and config"
  payload_vm_dispatch     | write_file /usr/local/libexec/vdh-runner/vm-dispatch 0755 root:root
  payload_vm_golden_build | write_file /usr/local/libexec/vdh-runner/vm-golden-build 0755 root:root
  payload_idle_poweroff   | write_file /usr/local/libexec/vdh-runner/idle-poweroff 0755 root:root
  payload_teamboot_record | write_file /usr/local/libexec/vdh-runner/teamboot-record 0755 root:root
  payload_nft_guard       | write_file /usr/local/libexec/vdh-runner/nft-guard 0755 root:root
  payload_teamboot_shell  | write_file /usr/local/lib/vdh-runner/teamboot-shell 0755 root:root
  payload_forgejo_runner_vm_service   | write_file /etc/systemd/system/forgejo-runner-vm.service 0644 root:root
  payload_idle_poweroff_service       | write_file /etc/systemd/system/idle-poweroff.service 0644 root:root
  payload_idle_poweroff_timer         | write_file /etc/systemd/system/idle-poweroff.timer 0644 root:root
  payload_vdh_teamboot_record_service | write_file /etc/systemd/system/vdh-teamboot-record.service 0644 root:root
  payload_vdh_runner_nft_service      | write_file /etc/systemd/system/vdh-runner-nft.service 0644 root:root
  payload_vdh_runner_nft_guard_service | write_file /etc/systemd/system/vdh-runner-nft-guard.service 0644 root:root
  payload_vdh_runner_nft_guard_timer   | write_file /etc/systemd/system/vdh-runner-nft-guard.timer 0644 root:root
  printf '127.0.0.1 localhost\n::1 localhost\n%s %s\n' "$ENVOY_FORGE_IP" "$FORGE_HOST" \
    | write_file /etc/vdh-runner/hosts 0644 root:root
  nsswitch_content | write_file /etc/vdh-runner/nsswitch.conf 0644 root:root
  runner_yaml | write_file /etc/vdh-runner/runner.yaml 0644 root:root
  [[ -f /etc/vdh-runner/vm.env ]] || printf 'VM_CPUS=12\nVM_MEM=24G\n' | write_file /etc/vdh-runner/vm.env 0644 root:root
  run systemctl daemon-reload
}

step_vmkey() {
  say "host -> VM ssh key (private key stays on the host, 0600 runner)"
  if [[ -f /var/lib/forgejo-runner/.ssh/vm_ed25519 ]]; then info "exists"; return 0; fi
  run runuser -u runner -- ssh-keygen -q -t ed25519 -N '' -C runner@vdhwslin01-vm -f /var/lib/forgejo-runner/.ssh/vm_ed25519
}

nft_ruleset() {
  local allow; allow="$(IFS=,; echo "${SSH_ALLOW[*]}")"; allow="${allow//,/, }"
  local dns_rule
  if (( DNS_STUB )); then
    dns_rule='oifname "lo" ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 accept comment "host resolver stub"'
  else
    local servers; servers="$(IFS=,; echo "${DNS_SERVERS[*]}")"; servers="${servers//,/, }"
    dns_rule="ip daddr { ${servers} } meta l4proto { tcp, udp } th dport 53 accept comment \"host resolver\""
  fi
  cat <<EOF
#!/usr/sbin/nft -f
# vdhwslin01 runner firewall (chg-2026-10-05-031). Written by provision.sh.
# Own table on top of the host's firewall; it never flushes the ruleset.
# A drop here is final; an accept here only ends THIS table's verdict.
table inet vdh_runner
delete table inet vdh_runner
table inet vdh_runner {
	set ssh_allow_v4 {
		type ipv4_addr
		elements = { ${allow} }
	}
	set nonpublic_v4 {
		type ipv4_addr
		flags interval
		elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
			     172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15,
			     224.0.0.0/4, 240.0.0.0/4 }
	}
	chain input {
		type filter hook input priority filter - 10; policy accept;
		iifname "lo" accept
		tcp dport { 22, ${UNLOCK_PORT} } ip saddr @ssh_allow_v4 accept
		tcp dport { 22, ${UNLOCK_PORT} } counter drop comment "22/${UNLOCK_PORT} only from cluster nodes, Mini, Sander's MacBook"
	}
	chain output {
		type filter hook output priority filter - 10; policy accept;
		meta skuid != "runner" accept
		ct state established,related accept
		${dns_rule}
		oifname "lo" ip daddr 127.0.0.1 tcp dport { 40022, 40023 } accept comment "host -> job VM ssh (qemu hostfwd)"
		oifname "lo" counter drop comment "runner/VM -> any other host service"
		meta nfproto ipv6 counter drop
		ip daddr ${ENVOY_FORGE_IP} tcp dport 443 accept comment "envoy-forge"
		ip daddr @nonpublic_v4 counter drop comment "no RFC1918/LAN"
		tcp dport { 80, 443 } accept
		counter drop
	}
}
EOF
}

step_firewall() {
  say "nftables (table inet vdh_runner)"
  nft_ruleset | write_file /etc/vdh-runner/vdh-runner.nft 0644 root:root
  if (( DRY )); then info "[dry-run] would check, load and enable vdh-runner-nft.service"; return 0; fi
  run nft -c -f /etc/vdh-runner/vdh-runner.nft
  run systemctl enable vdh-runner-nft.service
  run systemctl restart vdh-runner-nft.service
  /usr/local/libexec/vdh-runner/nft-guard check || die "table inet vdh_runner not loaded/complete"
  # Post-checks as uid runner (what a job VM gets).
  if runuser -u runner -- curl -s -o /dev/null -m 4 http://172.16.2.1/; then die "post-check: runner reached the LAN gateway; firewall not effective"; fi
  info "post-check ok: runner -> 172.16.2.1:80 blocked"
  if runuser -u runner -- curl -s -o /dev/null -m 4 "http://127.0.0.1:22/"; then die "post-check: runner reached host port 22"; fi
  info "post-check ok: runner -> host 127.0.0.1:22 blocked"
  if runuser -u runner -- curl -s -o /dev/null -m 8 https://deb.debian.org/; then info "post-check ok: runner -> internet 443 allowed"
  else warn "runner cannot reach https://deb.debian.org (DNS or egress?); the golden build will fail"; fi
  if runuser -u runner -- curl -s -o /dev/null -m 6 --resolve "${FORGE_HOST}:443:${ENVOY_FORGE_IP}" "https://${FORGE_HOST}/api/v1/version"; then
    info "post-check ok: runner -> envoy-forge ${ENVOY_FORGE_IP}:443"
  else warn "runner cannot reach envoy-forge ${ENVOY_FORGE_IP}:443 yet (is envoy-forge landed?). Jobs need it (Argus R9)."; fi
}

step_golden() {
  say "golden VM image"
  local golden=/var/lib/vdh-runner-golden/golden.qcow2 pin=/etc/vdh-runner/golden.sha256
  if (( ! REBUILD_GOLDEN )) && [[ -f "$golden" && -f "$pin" && -f /etc/vdh-runner/vm_known_hosts ]] \
     && [[ "$(sha256sum "$golden" | cut -d' ' -f1)" == "$(cut -d' ' -f1 "$pin")" ]]; then
    info "present, sha256 matches pin $(cut -c1-16 "$pin")..."; return 0
  fi
  local base=/var/cache/vdh-runner/${BASE_NAME}
  if [[ -f "$base" ]] && [[ "$(sha512sum "$base" | cut -d' ' -f1)" == "$BASE_SHA512" ]]; then info "base image cached, sha512 ok"
  else
    run curl -fsSL --proto '=https' -o "$base" "$BASE_URL"
    if (( ! DRY )); then
      [[ "$(sha512sum "$base" | cut -d' ' -f1)" == "$BASE_SHA512" ]] || die "base image sha512 mismatch"
      info "base image sha512 ok"
    fi
  fi
  # The base image goes to a ROOT-owned staging dir that runner can only read.
  run install -o root -g root -m 0444 "$base" /var/lib/vdh-runner-stage/base.qcow2
  local b=/var/lib/forgejo-runner/golden-build
  if (( DRY )); then info "[dry-run] would create (as runner) $b"; else runner_dir "$b" 0750; fi
  run runuser -u runner -- /usr/local/libexec/vdh-runner/vm-golden-build /var/lib/vdh-runner-stage/base.qcow2 "$b/golden.qcow2" "$b/known_hosts"
  if (( DRY )); then info "[dry-run] would promote golden + VM host key (read AS runner, written by root into root-owned paths)"; return 0; fi
  # Promotion (F1): the source is opened BY runner (runuser cat), so a symlink
  # there can only reach what runner may read anyway; root only writes into
  # its own directory and renames within it.
  local was_active=0
  if systemctl is-active --quiet forgejo-runner-vm.service 2>/dev/null; then was_active=1; run systemctl stop forgejo-runner-vm.service; fi
  local tmp=/var/lib/vdh-runner-golden/.golden.qcow2.new
  [[ ! -L "$tmp" ]] || die "$tmp is a symlink"
  echo "+ runuser -u runner -- cat $b/golden.qcow2 > $tmp"
  runuser -u runner -- cat "$b/golden.qcow2" > "$tmp"
  chmod 0444 "$tmp"; chown root:root "$tmp"
  run mv -f "$tmp" "$golden"
  local kh; kh="$(runuser -u runner -- cat "$b/known_hosts")"
  grep -qvE '^vdh-job-vm (ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+$' <<<"$kh" \
    && die "VM known_hosts from the build has unexpected lines; refusing"
  [[ -n "$kh" ]] || die "VM known_hosts from the build is empty"
  printf '%s\n' "$kh" | write_file /etc/vdh-runner/vm_known_hosts 0644 root:root
  sha256sum "$golden" | cut -d' ' -f1 | write_file "$pin" 0644 root:root
  info "golden sha256: $(cat "$pin")"
  if (( was_active )); then run systemctl start forgejo-runner-vm.service; fi
  return 0
}

step_register() {
  say "register runner ${RUNNER_NAME} (labels ${RUNNER_LABELS})"
  if [[ -e /var/lib/forgejo-runner/.runner || -L /var/lib/forgejo-runner/.runner ]]; then info "already registered (.runner exists)"; return 0; fi
  local token="$REG_TOKEN"
  if [[ "$token" == "-" ]]; then
    if (( DRY )); then token=dry-run-token
    else read -r -s -p "One-time runner registration token: " token </dev/tty; echo; fi
  fi
  [[ -n "$token" ]] || die "--reg-token required (use - for a hidden prompt)"
  local cmd=(systemd-run --quiet --wait --collect --pipe --uid=runner --gid=runner
    -p WorkingDirectory=/var/lib/forgejo-runner -p UMask=0077
    -p "BindReadOnlyPaths=/etc/vdh-runner/hosts:/etc/hosts /etc/vdh-runner/nsswitch.conf:/etc/nsswitch.conf"
    /usr/local/bin/forgejo-runner register --no-interactive --instance "$FORGE_URL"
    --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --token)
  # Print without the token; never log it.
  printf '%s' "$( (( DRY )) && echo '[dry-run]' || echo '+')"; printf ' %q' "${cmd[@]}"; echo ' <token redacted>'
  if (( ! DRY )); then
    "${cmd[@]}" "$token"
    token=""; REG_TOKEN=""
    local f=/var/lib/forgejo-runner/.runner
    [[ -f "$f" && ! -L "$f" && -s "$f" ]] || die "registration did not write a regular .runner"
    # Created by runner under UMask 0077; root only checks it (F1: no root chown/chmod).
    [[ "$(stat -c '%a %U' "$f")" == "600 runner" ]] || die ".runner is not 0600 runner: $(stat -c '%a %U' "$f")"
    info ".runner written (0600 runner). Regenerate the registration token on the forge now (Argus R7)."
  fi
}

step_services() {
  say "services"
  run systemctl daemon-reload
  run systemctl enable --now vdh-teamboot-record.service
  run systemctl enable --now idle-poweroff.timer
  run systemctl enable --now vdh-runner-nft-guard.timer
  run systemctl enable forgejo-runner-vm.service
  run systemctl restart forgejo-runner-vm.service
  (( DRY )) && return 0
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  info "waiting up to 4 min for the first job VM (boot + ssh + docker)..."
  for _ in $(seq 1 48); do
    if journalctl -u forgejo-runner-vm.service --since "$since" -o cat 2>/dev/null | grep -q 'VM ready; waiting for one job'; then
      info "post-check ok: job VM up, runner waiting for a job"; return 0
    fi
    sleep 5
  done
  warn "no 'VM ready' within 4 min; see: journalctl -u forgejo-runner-vm -b"
}

initramfs_rebuild() {
  local log; log="/var/log/vdh-runner-initramfs-$(date +%Y%m%dT%H%M%S).log"
  local tool=(mkinitcpio -P)
  command -v limine-mkinitcpio >/dev/null && tool=(limine-mkinitcpio)
  if (( DRY )); then run "${tool[@]}"; return 0; fi
  printf '+'; printf ' %q' "${tool[@]}"; echo " (log: $log)"
  set +e; "${tool[@]}" 2>&1 | tee "$log"; local rc=${PIPESTATUS[0]}; set -e
  local n_enc n_ours n_wrap
  n_enc="$(grep -c 'Running build hook: \[encryptssh\]' "$log" || true)"
  n_ours="$(grep -c 'Running build hook: \[vdh-teamboot\]' "$log" || true)"
  n_wrap="$(grep -c 'vdh-teamboot: wrapped /bin/cryptsetup_shell' "$log" || true)"
  info "images with encryptssh: $n_enc, with vdh-teamboot: $n_ours, wrapped: $n_wrap, exit: $rc"
  (( rc == 0 && n_enc > 0 && n_enc == n_ours && n_ours == n_wrap )) \
    || die "initramfs rebuild did not include vdh-teamboot in every image (log $log). Console unlock is unaffected; tell Heph before relying on team boots."
}

print_initrd_hostkeys() {
  echo "    controller known_hosts lines (PUBLIC host keys of the ${INITRD_SSHD} unlock server):"
  local f
  if [[ "$INITRD_SSHD" == dropbear ]]; then
    for f in /etc/dropbear/dropbear_ed25519_host_key /etc/dropbear/dropbear_ecdsa_host_key /etc/dropbear/dropbear_rsa_host_key; do
      [[ -s "$f" ]] || continue
      dropbearkey -y -f "$f" | awk -v h="[${BOX_IP}]:${UNLOCK_PORT}" '/^(ssh-|ecdsa-)/{print "    " h " " $1 " " $2}'
    done
  else
    f=/etc/tinyssh/sshkeydir/ed25519.pk
    [[ -s "$f" ]] && echo "    [${BOX_IP}]:${UNLOCK_PORT} ssh-ed25519 $({ printf '\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20'; cat "$f"; } | base64 -w0)"
  fi
  return 0
}

step_initramfs() {
  say "initramfs: controller unlock key + team-boot marker"
  local blob opts line
  blob="$(awk '{print $2}' <<<"$CTRL_PUBKEY")"
  opts=""; [[ "$INITRD_SSHD" == dropbear ]] && opts="no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty "
  line="${opts}ssh-ed25519 ${blob} ${KEY_COMMENT}"
  if grep -qF "$blob" "$INITRD_KEYFILE"; then info "controller key already in $INITRD_KEYFILE"
  else
    [[ -f "${INITRD_KEYFILE}.vdh-orig" ]] || run cp -a "$INITRD_KEYFILE" "${INITRD_KEYFILE}.vdh-orig"
    { cat "$INITRD_KEYFILE"; echo "$line"; } | write_file "$INITRD_KEYFILE" 0600 root:root
  fi
  payload_initcpio_install_vdh_teamboot | write_file /etc/initcpio/install/vdh-teamboot 0644 root:root
  if [[ " $(effective_hooks) " == *" vdh-teamboot "* ]]; then info "vdh-teamboot already in HOOKS"
  else
    printf '# chg-2026-10-05-031: mark ssh-unlocked boots as team boots. Remove to undo.\nHOOKS+=(vdh-teamboot)\n' \
      | write_file /etc/mkinitcpio.conf.d/zz-vdh-teamboot.conf 0644 root:root
  fi
  if (( ! DRY )); then
    [[ " $(effective_hooks) " == *" encryptssh "*" vdh-teamboot "* ]] || die "vdh-teamboot is not after encryptssh in HOOKS"
  fi
  initramfs_rebuild
  print_initrd_hostkeys
}

read_passphrase() {
  local p
  if [[ -t 0 ]]; then read -r -s -p "Controller LUKS passphrase (paste; it is not shown): " p; echo
  else IFS= read -r p || true; fi
  [[ "$p" =~ ^[A-Za-z0-9]{40,}$ ]] || die "passphrase must be the generated alphanumeric value (40+ chars); nothing changed"
  PASS="$p"
}

slot_of() { # prints the keyslot that the passphrase opens, or nothing
  cryptsetup open --test-passphrase -v --key-file=<(printf '%s' "$PASS") "$LUKS_DEV" 2>/dev/null \
    | sed -n 's/^Key slot \([0-9]*\) unlocked.*/\1/p' | head -n1
}

step_keyslot() {
  say "LUKS: separate controller keyslot on $LUKS_DEV"
  if (( DRY )); then info "[dry-run] would read the passphrase from stdin, test it, and cryptsetup luksAddKey $LUKS_DEV <(passphrase) if absent"; return 0; fi
  PASS=""; read_passphrase
  local slot; slot="$(slot_of)"
  if [[ -n "$slot" ]]; then info "already present in keyslot $slot"
  else
    [[ -r /dev/tty ]] || die "cryptsetup needs your EXISTING passphrase on a terminal"
    echo "+ cryptsetup luksAddKey $LUKS_DEV <(controller passphrase)   (type YOUR existing LUKS passphrase when asked)"
    cryptsetup luksAddKey "$LUKS_DEV" <(printf '%s' "$PASS") </dev/tty
    slot="$(slot_of)"
    [[ -n "$slot" ]] || die "post-check: the controller passphrase does not open $LUKS_DEV"
  fi
  PASS=""
  printf '%s\n' "$slot" | write_file /etc/vdh-runner/luks-keyslot 0644 root:root
  info "controller keyslot: $slot  (revoke: sudo cryptsetup luksKillSlot $LUKS_DEV $slot)"
}

step_report() {
  say "SEND THIS BACK to Atlas (no secrets in it)"
  info "provision.sh sha256: $(sha256sum "$0" | cut -d' ' -f1)"
  info "forgejo-runner: $(/usr/local/bin/forgejo-runner --version 2>/dev/null || echo missing)"
  info "golden sha256: $(cat /etc/vdh-runner/golden.sha256 2>/dev/null || echo missing)"
  info "runner registered: $([[ -s /var/lib/forgejo-runner/.runner ]] && echo yes || echo no)"
  info "luks keyslot: $(cat /etc/vdh-runner/luks-keyslot 2>/dev/null || echo none)"
  local u; for u in vdh-runner-nft.service vdh-runner-nft-guard.timer forgejo-runner-vm.service idle-poweroff.timer vdh-teamboot-record.service; do
    info "$u: $(systemctl is-enabled "$u" 2>/dev/null || true)/$(systemctl is-active "$u" 2>/dev/null || true)"
  done
  info "runner groups: $(id -nG runner 2>/dev/null || echo none)"
  [[ -n "$INITRD_SSHD" ]] && print_initrd_hostkeys
  return 0
}

uninstall() {
  say "uninstall (rollback of everything provision.sh added)"
  (( DRY )) || (( EUID == 0 )) || die "run with sudo"
  run systemctl disable --now vdh-runner-nft-guard.timer forgejo-runner-vm.service idle-poweroff.timer vdh-teamboot-record.service vdh-runner-nft.service || true
  local kf
  for kf in /etc/dropbear/root_key /etc/tinyssh/root_key; do
    if ! { [[ -f "$kf" ]] && grep -q " ${KEY_COMMENT}\$" "$kf"; }; then continue; fi
    grep -v " ${KEY_COMMENT}\$" "$kf" | write_file "$kf" 0600 root:root
  done
  run rm -f -- /etc/mkinitcpio.conf.d/zz-vdh-teamboot.conf /etc/initcpio/install/vdh-teamboot
  if command -v mkinitcpio >/dev/null; then
    if command -v limine-mkinitcpio >/dev/null; then run limine-mkinitcpio; else run mkinitcpio -P; fi
  fi
  run rm -f -- /etc/systemd/system/forgejo-runner-vm.service /etc/systemd/system/idle-poweroff.service \
    /etc/systemd/system/idle-poweroff.timer /etc/systemd/system/vdh-teamboot-record.service \
    /etc/systemd/system/vdh-runner-nft.service
  run systemctl daemon-reload
  run rm -f -- /usr/local/libexec/vdh-runner/vm-dispatch /usr/local/libexec/vdh-runner/vm-golden-build \
    /usr/local/libexec/vdh-runner/idle-poweroff /usr/local/libexec/vdh-runner/teamboot-record \
    /usr/local/lib/vdh-runner/teamboot-shell /usr/local/bin/forgejo-runner \
    /var/lib/vdh-runner-golden/golden.qcow2 /var/lib/vdh-runner-stage/base.qcow2 \
    /usr/local/libexec/vdh-runner/nft-guard /etc/systemd/system/vdh-runner-nft-guard.service \
    /etc/systemd/system/vdh-runner-nft-guard.timer
  local slot=""; [[ -f /etc/vdh-runner/luks-keyslot ]] && slot="$(cat /etc/vdh-runner/luks-keyslot)"
  [[ -d /etc/vdh-runner ]] && run find /etc/vdh-runner -mindepth 1 -delete
  [[ -d /var/cache/vdh-runner ]] && run find /var/cache/vdh-runner -mindepth 1 -delete
  if id runner >/dev/null 2>&1; then run userdel --remove runner; fi
  say "left for you (on purpose, they need you):"
  [[ -n "$slot" ]] && info "LUKS: sudo cryptsetup luksKillSlot <luks-device> $slot   (asks a remaining passphrase)"
  info "forge: Atlas deletes runner '${RUNNER_NAME}' on the forge"
}

main() {
  parse_args "$@"
  if (( UNINSTALL )); then uninstall; exit 0; fi
  local s
  for s in "${STEPS[@]}"; do "step_${s}"; done
  say "done$( (( DRY )) && echo ' (dry-run: nothing changed)')"
}

# Run only when executed (tests/arch-container.sh sources it for unit checks).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
