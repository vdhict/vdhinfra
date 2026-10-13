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
# --- from src/vm-dispatch.sh (sha256 58c5022508ba130b)
payload_vm_dispatch() {
cat <<'VDH_PAYLOAD_EOF'
#!/usr/bin/env bash
# vdhwslin01 runner dispatcher (chg-2026-10-05-031, Argus R5/R7).
# Installed as /usr/local/libexec/vdh-runner/vm-dispatch; runs as user
# `runner` under forgejo-runner-vm.service.
#
# The mechanism, one job per throwaway KVM VM:
#   1. a fresh qcow2 overlay on the read-only golden image (sha256-checked);
#   2. boot it with qemu/KVM, user-mode networking only (no bridge, no tap,
#      no virtiofs/9p/vsock, no USB), ssh forwarded to 127.0.0.1 only;
#   3. forward the VM's docker socket to the host over that ssh link, at the
#      SAME path the VM uses (/run/forgejo-runner/docker.sock), so
#      forgejo-runner talks to the VM's dockerd and the socket it mounts into
#      job containers is the VM's own, never the host's;
#   4. `forgejo-runner one-job --wait` on the HOST: it holds the runner token
#      (/var/lib/forgejo-runner/.runner, 0600, never inside a VM), takes ONE
#      job, runs it in the VM's docker and exits;
#   5. destroy the VM and its overlay; loop.
# The VM is warm while waiting, so a job starts without a boot delay.
set -euo pipefail

STATE_DIR=/run/forgejo-runner
WORK_DIR=/var/lib/forgejo-runner/vm
GOLDEN=/var/lib/vdh-runner-golden/golden.qcow2
GOLDEN_SHA=/etc/vdh-runner/golden.sha256
VM_KEY=/var/lib/forgejo-runner/.ssh/vm_ed25519
VM_KNOWN_HOSTS=/etc/vdh-runner/vm_known_hosts
RUNNER_CFG=/etc/vdh-runner/runner.yaml
SOCK=/run/forgejo-runner/docker.sock
FWD_PORT=40022
VM_CPUS=12
VM_MEM=24G
# shellcheck disable=SC1091
[[ -r /etc/vdh-runner/vm.env ]] && . /etc/vdh-runner/vm.env

log() { echo "vm-dispatch: $*"; }

vm_ssh() {
  ssh -F /dev/null -i "$VM_KEY" -p "$FWD_PORT" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$VM_KNOWN_HOSTS" -o HostKeyAlias=vdh-job-vm \
    -o ConnectTimeout=5 -o LogLevel=ERROR "$@"
}

tunnel_pid=""
cleanup_vm() {
  if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
  fi
  tunnel_pid=""
  if [[ -f "${STATE_DIR}/qemu.pid" ]]; then
    local pid; pid="$(cat "${STATE_DIR}/qemu.pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  # Literal paths only (no rm of variables).
  rm -f -- /run/forgejo-runner/qemu.pid /run/forgejo-runner/docker.sock
  rm -f -- /var/lib/forgejo-runner/vm/job.qcow2
}

on_exit() {
  rm -f -- /run/forgejo-runner/job-active
  cleanup_vm
}
trap on_exit EXIT
trap 'exit 143' TERM INT

golden_ok() {
  [[ -r "$GOLDEN" && -r "$GOLDEN_SHA" ]] || { log "golden image or its pin missing"; return 1; }
  local want have
  want="$(cut -d' ' -f1 "$GOLDEN_SHA")"
  have="$(sha256sum "$GOLDEN" | cut -d' ' -f1)"
  [[ -n "$want" && "$want" == "$have" ]] || { log "golden sha256 mismatch (have ${have}, pinned ${want})"; return 1; }
}

start_vm() {
  mkdir -p "$WORK_DIR"
  qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" /var/lib/forgejo-runner/vm/job.qcow2
  qemu-system-x86_64 \
    -name vdh-job-vm -machine q35,accel=kvm -cpu host \
    -smp "$VM_CPUS" -m "$VM_MEM" \
    -nodefaults -no-user-config -display none -vga none \
    -serial "file:${STATE_DIR}/vm-console.log" \
    -drive file=/var/lib/forgejo-runner/vm/job.qcow2,if=virtio,format=qcow2,discard=unmap \
    -netdev "user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:${FWD_PORT}-:22" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -daemonize -pidfile "${STATE_DIR}/qemu.pid"
}

wait_vm() {
  for _ in $(seq 1 90); do
    if vm_ssh fr@127.0.0.1 true 2>/dev/null; then return 0; fi
    sleep 2
  done
  log "VM ssh did not come up in 180s"; return 1
}

open_docker_tunnel() {
  vm_ssh -N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes \
    -L "${SOCK}:/run/forgejo-runner/docker.sock" fr@127.0.0.1 &
  tunnel_pid=$!
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 --unix-socket "$SOCK" http://vm/_ping >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  log "VM docker did not answer in 60s"; return 1
}

# Reads runner output; marks the job active when a task is taken.
watch_runner() {
  local line
  while IFS= read -r line; do
    echo "$line"
    if [[ ! -e "${STATE_DIR}/job-active" && "$line" =~ task\ [0-9]+\ repo\ is ]]; then
      date +%s > "${STATE_DIR}/job-active"
      log "job started"
    fi
  done
}

while true; do
  cleanup_vm
  if ! golden_ok; then log "not taking jobs; retry in 300s"; sleep 300; continue; fi
  if ! start_vm || ! wait_vm || ! open_docker_tunnel; then
    log "VM start failed; retry in 60s"; cleanup_vm; sleep 60; continue
  fi
  log "VM ready; waiting for one job"
  set +e
  forgejo-runner one-job --wait --config "$RUNNER_CFG" 2>&1 | watch_runner
  rc=${PIPESTATUS[0]}
  set -e
  if [[ -e "${STATE_DIR}/job-active" ]]; then
    date +%s > "${STATE_DIR}/last-job-end"
    rm -f -- /run/forgejo-runner/job-active
    log "job finished rc=${rc}; destroying VM"
  else
    log "runner exited without a job rc=${rc}"
    sleep 30
  fi
done
VDH_PAYLOAD_EOF
}
# --- from src/vm-golden-build.sh (sha256 2a4eef0457a026b3)
payload_vm_golden_build() {
cat <<'VDH_PAYLOAD_EOF'
#!/usr/bin/env bash
# vdhwslin01 golden VM build (chg-2026-10-05-031, Argus R5).
# Installed as /usr/local/libexec/vdh-runner/vm-golden-build; provision.sh
# runs it as user `runner` (same nftables egress limits as jobs).
#
#   vm-golden-build <verified-base.qcow2> <out.qcow2> <known_hosts-out>
#
# Boots the checksum-verified Debian 13 cloud image once with a NoCloud seed:
# installs docker.io, makes dockerd also listen on /run/forgejo-runner/
# docker.sock, adds user `fr` (docker group) with the host's VM key, disables
# cloud-init and powers off. Then boots the result once more WITHOUT a seed to
# prove ssh + docker work and to record the VM host key, and flattens it.
# provision.sh installs the output root-owned 0444 and pins its sha256.
set -euo pipefail
base="${1:?base image}"; out="${2:?output image}"; kh_out="${3:?known_hosts output}"

# A fresh work dir per build: nothing is overwritten or deleted. Old run-*
# dirs (a few GB each) can be cleared by hand after a rebuild.
B="/var/lib/forgejo-runner/golden-build/run-$(date +%Y%m%dT%H%M%S)"
VM_KEY=/var/lib/forgejo-runner/.ssh/vm_ed25519
FWD_PORT=40023
mkdir -p "$B/seed"
log() { echo "vm-golden-build: $*"; }

pubkey="$(cat "${VM_KEY}.pub")"
cat > "$B/seed/meta-data" <<EOF
instance-id: vdh-golden-$(date +%Y%m%d%H%M%S)
local-hostname: vdh-job-vm
EOF
cat > "$B/seed/user-data" <<EOF
#cloud-config
disable_root: true
ssh_pwauth: false
users:
  - name: fr
    groups: [docker]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${pubkey}
package_update: true
package_upgrade: true
packages: [docker.io, ca-certificates, curl]
write_files:
  - path: /etc/systemd/system/docker.service.d/10-vdh.conf
    content: |
      [Service]
      ExecStart=
      ExecStart=/usr/sbin/dockerd -H fd:// -H unix:///run/forgejo-runner/docker.sock --containerd=/run/containerd/containerd.sock
  - path: /etc/tmpfiles.d/forgejo-runner.conf
    content: |
      d /run/forgejo-runner 0755 root root -
  - path: /etc/docker/daemon.json
    content: |
      {"ipv6": false, "log-driver": "local"}
runcmd:
  - [systemd-tmpfiles, --create, /etc/tmpfiles.d/forgejo-runner.conf]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, docker]
  - [docker, pull, node:24-bookworm]
  - [touch, /etc/cloud/cloud-init.disabled]
  - [fstrim, -av]
power_state:
  mode: poweroff
  timeout: 60
EOF
xorriso -as mkisofs -quiet -output "$B/seed.iso" -volid cidata -joliet -rock \
  "$B/seed/user-data" "$B/seed/meta-data"

qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$B/build.qcow2" 60G

# shellcheck disable=SC2054  # qemu option values contain commas
common=(-machine q35,accel=kvm -cpu host -smp 4 -m 4G
  -nodefaults -no-user-config -display none -vga none
  -device virtio-rng-pci
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny)

log "pass 1: cloud-init install (up to 30 min)"
timeout 1800 qemu-system-x86_64 "${common[@]}" -name vdh-golden-build \
  -serial "file:$B/build-console.log" \
  -drive "file=$B/build.qcow2,if=virtio,format=qcow2" \
  -drive "file=$B/seed.iso,if=virtio,format=raw,readonly=on" \
  -netdev user,id=n0,ipv6=off -device virtio-net-pci,netdev=n0
log "pass 1 done (VM powered off)"

log "pass 2: verify without seed (-snapshot: this boot writes nothing to the image)"
qemu-system-x86_64 "${common[@]}" -name vdh-golden-verify -snapshot \
  -serial "file:$B/verify-console.log" \
  -drive "file=$B/build.qcow2,if=virtio,format=qcow2" \
  -netdev "user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:${FWD_PORT}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -daemonize -pidfile "$B/verify.pid"
vpid="$(cat "$B/verify.pid")"
stop_verify() { kill "$vpid" 2>/dev/null || true; }
trap stop_verify EXIT

sshv() {
  ssh -F /dev/null -i "$VM_KEY" -p "$FWD_PORT" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$B/known_hosts" \
    -o HostKeyAlias=vdh-job-vm -o ConnectTimeout=5 -o LogLevel=ERROR fr@127.0.0.1 "$@"
}
: > "$B/known_hosts"
ok=0
for _ in $(seq 1 90); do
  if sshv true 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[[ "$ok" == 1 ]] || { log "FAIL: no ssh in the verify boot"; exit 1; }
sshv 'test -e /etc/cloud/cloud-init.disabled' || { log "FAIL: cloud-init still enabled"; exit 1; }
sshv 'docker -H unix:///run/forgejo-runner/docker.sock info --format "{{.ServerVersion}}"' \
  || { log "FAIL: docker not answering on /run/forgejo-runner/docker.sock"; exit 1; }
sshv 'ls /sys/bus/virtio/devices | wc -l; ls /dev/vsock 2>/dev/null || echo no-vsock; findmnt -t virtiofs,9p -n || echo no-host-share'
stop_verify
trap - EXIT

log "flattening"
qemu-img convert -O qcow2 "$B/build.qcow2" "$out"
cp "$B/known_hosts" "$kh_out"
log "golden built: $out"
VDH_PAYLOAD_EOF
}
# --- from src/idle-poweroff.sh (sha256 2756d954205ac7d2)
payload_idle_poweroff() {
cat <<'VDH_PAYLOAD_EOF'
#!/usr/bin/env bash
# vdhwslin01 idle-poweroff (chg-2026-10-05-031, AGR-114 + AGR-115, Argus R10).
#
# Installed as /usr/local/libexec/vdh-runner/idle-poweroff, run as root by
# idle-poweroff.timer every 5 minutes. It powers the box off ONLY when ALL hold:
#   1. /run/team-boot exists, says started_by=team and carries THIS boot's
#      boot_id. It is written in the initramfs by the ssh unlock path
#      (vdh-teamboot); Sander's own boots (console unlock) never have it.
#   2. uptime >= 2 h.
#   3. the runner has no job (/run/forgejo-runner/job-active absent) and the
#      last job ended >= 60 min ago.
#   4. seat0 IdleHint=yes for >= 60 min, and every other user session (not
#      agent/runner) is idle >= 60 min as well.
#   5. no logind block inhibitor (systemctl --check-inhibitors=yes).
# Anything it cannot read means KEEP (fail safe: never power off on doubt).
# Every decision is one line on stdout, which systemd writes to the journal.
set -euo pipefail

# Test seam: tests/idle-poweroff.test.sh points these at fixtures and stubs.
# The systemd unit runs with a clean environment, so production never sets it.
if [[ "${VDH_IDLE_TEST:-0}" == "1" ]]; then
  ROOT="${VDH_IDLE_ROOT:?}"
  LOGINCTL="${VDH_IDLE_LOGINCTL:?}"
  SYSTEMCTL="${VDH_IDLE_SYSTEMCTL:?}"
  NOW="${VDH_IDLE_NOW:?}"
else
  ROOT=""
  LOGINCTL="loginctl"
  SYSTEMCTL="systemctl"
  NOW="$(date +%s)"
fi

SEAT_IDLE_MIN_S=3600
RUNNER_IDLE_MIN_S=3600
UPTIME_MIN_S=7200
# Sessions of these users never block (agent = team ssh, runner = CI service).
EXCLUDED_USERS=" agent runner "

keep() {
  echo "idle-poweroff: KEEP: $*"
  exit 0
}

# --- 1. team-started boot of THIS boot -------------------------------------
marker="${ROOT}/run/team-boot"
[[ -f "$marker" ]] || keep "no /run/team-boot (not a team-started boot)"
boot_id="$(tr -d '[:space:]' < "${ROOT}/proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
[[ -n "$boot_id" ]] || keep "cannot read boot_id"
grep -qx 'started_by=team' "$marker" || keep "marker does not say started_by=team"
grep -qx "boot_id=${boot_id}" "$marker" || keep "marker boot_id does not match this boot"

# --- 2. minimum uptime -------------------------------------------------------
uptime_s="$(cut -d. -f1 < "${ROOT}/proc/uptime" 2>/dev/null || true)"
[[ "$uptime_s" =~ ^[0-9]+$ ]] || keep "cannot read uptime"
(( uptime_s >= UPTIME_MIN_S )) || keep "uptime ${uptime_s}s < ${UPTIME_MIN_S}s"

# --- 3. runner idle ---------------------------------------------------------
# /run/forgejo-runner is runner-owned: never follow a symlink there as root.
[[ ! -L "${ROOT}/run/forgejo-runner/job-active" && ! -L "${ROOT}/run/forgejo-runner/last-job-end" ]] \
  || keep "symlink in /run/forgejo-runner"
[[ ! -e "${ROOT}/run/forgejo-runner/job-active" ]] || keep "runner has a job"
last_end_file="${ROOT}/run/forgejo-runner/last-job-end"
if [[ -f "$last_end_file" ]]; then
  last_end="$(tr -d '[:space:]' < "$last_end_file")"
  [[ "$last_end" =~ ^[0-9]+$ ]] || keep "unreadable last-job-end"
  runner_idle=$(( NOW - last_end ))
  (( runner_idle >= RUNNER_IDLE_MIN_S )) || keep "last job ended ${runner_idle}s ago < ${RUNNER_IDLE_MIN_S}s"
else
  runner_idle="none-this-boot"
fi

# --- 4. interactive idleness (logind) ----------------------------------------
# idle_age <IdleHint> <IdleSinceHint-usec> -> prints seconds idle, or "busy"
idle_age() {
  local hint="$1" since_us="$2"
  if [[ "$hint" != "yes" ]]; then echo busy; return; fi
  [[ "$since_us" =~ ^[0-9]+$ ]] || { echo busy; return; }
  echo $(( NOW - since_us / 1000000 ))
}

prop() { # prop <key> <text>
  sed -n "s/^$1=//p" <<<"$2" | head -n1
}

seat="$("$LOGINCTL" show-seat seat0 -p IdleHint -p IdleSinceHint 2>/dev/null)" \
  || keep "cannot read seat0 from logind"
seat_age="$(idle_age "$(prop IdleHint "$seat")" "$(prop IdleSinceHint "$seat")")"
[[ "$seat_age" != busy ]] || keep "seat0 IdleHint=no (someone is using the desktop)"
(( seat_age >= SEAT_IDLE_MIN_S )) || keep "seat0 idle ${seat_age}s < ${SEAT_IDLE_MIN_S}s"

sessions="$("$LOGINCTL" list-sessions --no-legend 2>/dev/null)" \
  || keep "cannot list logind sessions"
while read -r sid _; do
  [[ -n "${sid:-}" ]] || continue
  info="$("$LOGINCTL" show-session "$sid" -p Name -p Class -p IdleHint -p IdleSinceHint 2>/dev/null)" \
    || keep "cannot read session ${sid}"
  name="$(prop Name "$info")"
  class="$(prop Class "$info")"
  [[ "$class" == "user" ]] || continue
  [[ "$EXCLUDED_USERS" != *" ${name} "* ]] || continue
  age="$(idle_age "$(prop IdleHint "$info")" "$(prop IdleSinceHint "$info")")"
  [[ "$age" != busy ]] || keep "session ${sid} (${name}) is active"
  (( age >= SEAT_IDLE_MIN_S )) || keep "session ${sid} (${name}) idle ${age}s < ${SEAT_IDLE_MIN_S}s"
done <<<"$sessions"

# --- 5. power off ------------------------------------------------------------
echo "idle-poweroff: POWEROFF: started_by=team boot_id=${boot_id} uptime=${uptime_s}s seat0_idle=${seat_age}s runner_idle=${runner_idle}"
if ! "$SYSTEMCTL" poweroff --check-inhibitors=yes; then
  echo "idle-poweroff: KEEP: systemctl poweroff refused (inhibitor?)"
fi
VDH_PAYLOAD_EOF
}
# --- from src/teamboot-record.sh (sha256 9cc8f228738cb47e)
payload_teamboot_record() {
cat <<'VDH_PAYLOAD_EOF'
#!/bin/sh
# vdhwslin01 (chg-2026-10-05-031): one journal line per boot saying who started
# it. Installed as /usr/local/libexec/vdh-runner/teamboot-record.
bid="$(cat /proc/sys/kernel/random/boot_id)"
if grep -qx "boot_id=$bid" /run/team-boot 2>/dev/null && grep -qx 'started_by=team' /run/team-boot; then
  echo "started_by=team boot_id=$bid"
else
  echo "started_by=sander boot_id=$bid"
fi
VDH_PAYLOAD_EOF
}
# --- from src/nft-guard.sh (sha256 ff1bd7d818b1446d)
payload_nft_guard() {
cat <<'VDH_PAYLOAD_EOF'
#!/bin/sh
# vdhwslin01 runner egress guard (chg-2026-10-05-031, Argus F3/C4).
# Installed as /usr/local/libexec/vdh-runner/nft-guard, runs as root.
#   nft-guard check   exit 0 only if table inet vdh_runner is loaded AND
#                     complete (ExecStartPre=+ of forgejo-runner-vm.service)
#   nft-guard guard   every minute (vdh-runner-nft-guard.timer): if the
#                     table is missing/incomplete, STOP forgejo-runner-vm
#                     (KillMode=control-group also kills the job VM).
set -eu
if [ "${VDH_GUARD_TEST:-0}" = 1 ]; then
  NFT="${VDH_GUARD_NFT:?}"; SYSTEMCTL="${VDH_GUARD_SYSTEMCTL:?}"
else
  NFT=nft; SYSTEMCTL=systemctl
fi

table_ok() {
  out="$("$NFT" list table inet vdh_runner 2>/dev/null)" || return 1
  # The rules that make the table worth anything; a half-flushed table fails.
  # nft prints the uid numerically when listing (meta skuid != 969 accept).
  uid="$(id -u runner 2>/dev/null || echo no-runner-user)"
  printf '%s\n' "$out" | grep -qE "meta skuid != (\"runner\"|${uid}) accept" || return 1
  # The output chain's final catch-all drop (policy is accept, so without it
  # everything not matched would pass).
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*counter packets [0-9]+ bytes [0-9]+ drop$' || return 1
  for want in \
    'ip daddr @nonpublic_v4' \
    'meta nfproto ipv6' \
    'tcp dport { 22, 2222 } ip saddr @ssh_allow_v4 accept' \
    'hook output priority' \
    'hook input priority'; do
    printf '%s\n' "$out" | grep -qF -- "$want" || return 1
  done
}

case "${1:-}" in
  check)
    if table_ok; then exit 0; fi
    echo "nft-guard: table inet vdh_runner missing or incomplete: refusing to start the runner"
    exit 1 ;;
  guard)
    if table_ok; then exit 0; fi
    if "$SYSTEMCTL" is-active --quiet forgejo-runner-vm.service; then
      "$SYSTEMCTL" stop forgejo-runner-vm.service
      echo "nft-guard: table inet vdh_runner missing or incomplete: STOPPED forgejo-runner-vm (no jobs until the firewall is back)"
    else
      echo "nft-guard: table inet vdh_runner missing or incomplete (runner already stopped)"
    fi ;;
  *) echo "usage: nft-guard check|guard" >&2; exit 2 ;;
esac
VDH_PAYLOAD_EOF
}
# --- from src/vdh-runner-nft-guard.service (sha256 09eeaceac8a37791)
payload_vdh_runner_nft_guard_service() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031, Argus F3): stop the runner if its egress firewall is gone.
[Unit]
Description=Stop the Forgejo runner when table inet vdh_runner is missing

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/vdh-runner/nft-guard guard
SyslogIdentifier=nft-guard
VDH_PAYLOAD_EOF
}
# --- from src/vdh-runner-nft-guard.timer (sha256 b95040130eff1d09)
payload_vdh_runner_nft_guard_timer() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031, Argus F3): check every minute.
[Unit]
Description=Every minute: runner egress firewall present, else stop the runner

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
VDH_PAYLOAD_EOF
}
# --- from src/teamboot-shell.sh (sha256 d5023e1ecb0cc76f)
payload_teamboot_shell() {
cat <<'VDH_PAYLOAD_EOF'
#!/bin/sh
# vdh-teamboot: wrapper around encryptssh's /bin/cryptsetup_shell inside the
# initramfs (busybox ash, POSIX sh only). chg-2026-10-05-031, AGR-115.
#
# encryptssh makes /bin/cryptsetup_shell the LOGIN SHELL of root for the
# initramfs ssh server, so every ssh unlock (dropbear/tinyssh on 2222) runs
# through here, while a console unlock at the keyboard never does. A disk that
# was locked before and is open after this session therefore means: unlocked
# over ssh = a team-started boot. We record that in /run/team-boot, which
# switch_root carries into the booted system, where idle-poweroff reads it.
# Sander's own boots (console passphrase) never get the marker, so the box
# never powers off a boot he started.
#
# The real shell is delegated to unchanged; this wrapper never sees or stores
# the passphrase (cryptsetup reads it from the ssh session's stdin).
name="$(cat /.cryptname 2>/dev/null)"
was_open=0
if [ -n "$name" ] && [ -b "/dev/mapper/$name" ]; then
  was_open=1
fi

/bin/cryptsetup_shell.vdh-real "$@"
rc=$?

if [ "$was_open" = 0 ] && [ -n "$name" ] && [ -b "/dev/mapper/$name" ]; then
  bid="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  (
    umask 022
    printf 'started_by=team\nboot_id=%s\nvia=initramfs-ssh-unlock\nuptime_at_unlock=%s\n' \
      "$bid" "$up" > /run/team-boot
  )
  echo "vdh-teamboot: started_by=team boot_id=$bid"
fi
exit $rc
VDH_PAYLOAD_EOF
}
# --- from src/initcpio-install-vdh-teamboot.sh (sha256 09207f8b21b8506a)
payload_initcpio_install_vdh_teamboot() {
cat <<'VDH_PAYLOAD_EOF'
#!/bin/bash
# mkinitcpio install hook "vdh-teamboot" (chg-2026-10-05-031).
# Installed as /etc/initcpio/install/vdh-teamboot and appended to HOOKS by
# /etc/mkinitcpio.conf.d/90-vdh-teamboot.conf, so it builds AFTER encryptssh.
# Build-time only (no runtime hook): it moves encryptssh's cryptsetup_shell to
# cryptsetup_shell.vdh-real and puts the team-boot wrapper in its place.

build() {
    if [[ ! -f "${BUILDROOT}/bin/cryptsetup_shell" ]]; then
        error "vdh-teamboot: /bin/cryptsetup_shell not in image; list vdh-teamboot AFTER encryptssh"
        return 1
    fi
    if [[ ! -f "${BUILDROOT}/bin/cryptsetup_shell.vdh-real" ]]; then
        mv "${BUILDROOT}/bin/cryptsetup_shell" "${BUILDROOT}/bin/cryptsetup_shell.vdh-real"
    fi
    install -m 0755 /usr/local/lib/vdh-runner/teamboot-shell "${BUILDROOT}/bin/cryptsetup_shell"
    # cat/cut/printf come from the busybox that the base hook installs.
    echo "vdh-teamboot: wrapped /bin/cryptsetup_shell"
}

help() {
    cat <<HELPEOF
Marks boots that were unlocked over the initramfs ssh server (encryptssh) as
team-started by writing /run/team-boot (started_by=team + boot_id). Used by
vdhwslin01's idle-poweroff. List it after encryptssh.
HELPEOF
}
VDH_PAYLOAD_EOF
}
# --- from src/forgejo-runner-vm.service (sha256 ae80639fca6b6bbc)
payload_forgejo_runner_vm_service() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031): forgejo-runner, one job per throwaway KVM VM.
[Unit]
Description=Forgejo runner dispatcher: one job per throwaway KVM VM
Wants=network-online.target
After=network-online.target vdh-runner-nft.service
Requires=vdh-runner-nft.service

[Service]
User=runner
Group=runner
SupplementaryGroups=kvm
WorkingDirectory=/var/lib/forgejo-runner
# F3: never start without the egress firewall ("+" = runs as root).
ExecStartPre=+/usr/local/libexec/vdh-runner/nft-guard check
ExecStart=/usr/local/libexec/vdh-runner/vm-dispatch
Restart=always
RestartSec=30
KillMode=control-group
TimeoutStopSec=60
RuntimeDirectory=forgejo-runner
RuntimeDirectoryMode=0755
# The forge name must resolve to envoy-forge for this service only; Sander's
# own /etc/hosts and resolver order stay untouched.
BindReadOnlyPaths=/etc/vdh-runner/hosts:/etc/hosts /etc/vdh-runner/nsswitch.conf:/etc/nsswitch.conf
# Sandbox: no access to /home, /root, /run/user (Sander's session and files).
ProtectHome=yes
# F4: Sander's processes (and their command lines) are invisible.
ProtectProc=invisible
ProcSubset=pid
ProtectSystem=strict
ReadWritePaths=/var/lib/forgejo-runner
PrivateTmp=yes
NoNewPrivileges=yes
DevicePolicy=closed
DeviceAllow=/dev/kvm rw
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=
MemoryMax=30G

[Install]
WantedBy=multi-user.target
VDH_PAYLOAD_EOF
}
# --- from src/idle-poweroff.service (sha256 6d3d4061c1b7af52)
payload_idle_poweroff_service() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031): AGR-114/115 idle power-off of team boots only.
[Unit]
Description=Power off an idle team-started boot (never a boot Sander started)

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/vdh-runner/idle-poweroff
SyslogIdentifier=idle-poweroff
VDH_PAYLOAD_EOF
}
# --- from src/idle-poweroff.timer (sha256 8b3ff63648d336ac)
payload_idle_poweroff_timer() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031): check every 5 minutes.
[Unit]
Description=Check every 5 min whether a team-started boot may power off

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
VDH_PAYLOAD_EOF
}
# --- from src/vdh-teamboot-record.service (sha256 bf835a22d18b8ae4)
payload_vdh_teamboot_record_service() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031): one journal line per boot: who started it.
[Unit]
Description=Record whether this boot was started by the team or by Sander
After=local-fs.target

[Service]
Type=oneshot
SyslogIdentifier=vdh-teamboot
ExecStart=/usr/local/libexec/vdh-runner/teamboot-record

[Install]
WantedBy=multi-user.target
VDH_PAYLOAD_EOF
}
# --- from src/vdh-runner-nft.service (sha256 31236061a1ba7048)
payload_vdh_runner_nft_service() {
cat <<'VDH_PAYLOAD_EOF'
# vdhwslin01 (chg-2026-10-05-031): own nftables table, added ON TOP of the
# host's existing firewall (ufw/nftables). It never flushes the ruleset.
[Unit]
Description=vdh runner host firewall (table inet vdh_runner)
Wants=network-pre.target
Before=network-pre.target
After=nftables.service ufw.service firewalld.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nft -f /etc/vdh-runner/vdh-runner.nft
ExecStop=/usr/bin/nft delete table inet vdh_runner

[Install]
WantedBy=multi-user.target
VDH_PAYLOAD_EOF
}

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
