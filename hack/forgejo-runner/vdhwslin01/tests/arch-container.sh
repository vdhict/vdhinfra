#!/usr/bin/env bash
# Runs INSIDE a throwaway Arch Linux container as root (no KVM, no systemd,
# no LUKS, no netfilter rights). Exercises everything provision.sh does that
# a container can do for real, plus a full --dry-run:
#   A  full --dry-run (detection paths on a real Arch userland)
#   B  REAL steps: packages user binary payload vmkey initramfs (mkinitcpio
#      with dropbear + encryptssh, the Omarchy-shaped HOOKS), then a re-run
#      to prove idempotency
#   C  the built initramfs: wrapper in place, real shell kept, controller key
#      present with its restrictions
#   D  the team-boot wrapper itself, chroot'ed into the extracted initramfs
#      with its busybox: ssh unlock -> marker; already open -> no marker;
#      failed unlock -> no marker
#   E  nftables ruleset renders and (if a user+net namespace is allowed)
#      passes `nft -c`
#   F  idle-poweroff unit tests under Arch bash
# Usage: bash tests/arch-container.sh <bundle-dir>
# Test-harness idioms, on purpose: ok/bad always return 0 (SC2015); bash -c
# bodies are meant to expand in the child (SC2016); E sets globals that the
# sourced provision.sh reads (SC2034, SC1091).
# shellcheck disable=SC2015,SC2016,SC2034,SC1091
set -euo pipefail
B="${1:?bundle dir}"
cd "$B"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   $*"; }
bad()  { fail=$((fail+1)); echo "FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

echo "== setup: packages a real Omarchy-with-dropbear box has"
pacman -Sy --noconfirm --needed mkinitcpio mkinitcpio-dropbear mkinitcpio-utils mkinitcpio-netconf \
  linux cryptsetup openssh nftables util-linux shadow >/dev/null
getent group kvm >/dev/null || groupadd -r kvm
# No systemd in a container: a stub that records calls.
printf '#!/bin/sh\necho "systemctl $*" >> /var/log/systemctl-stub.calls\n' > /usr/local/sbin/systemctl
chmod +x /usr/local/sbin/systemctl
# Fixture: Sander's dropbear unlock as the Arch wiki/Omarchy shape.
install -d -m 0755 /etc/dropbear /etc/mkinitcpio.conf.d
ssh-keygen -q -t ed25519 -N '' -C sander-unlock -f /root/sander_unlock
cp /root/sander_unlock.pub /etc/dropbear/root_key
printf 'HOOKS=(base udev keyboard modconf kms keymap consolefont block netconf dropbear encryptssh filesystems fsck)\n' \
  > /etc/mkinitcpio.conf.d/omarchy_hooks.conf
ssh-keygen -q -t ed25519 -N '' -C test-controller -f /root/ctrl
CTRL_PUB="$(cat /root/ctrl.pub)"
ARGS=(--forge-url https://forge.example.invalid --envoy-forge-ip 172.16.2.251 --reg-token -
      --controller-pubkey "$CTRL_PUB")

echo "== A: full dry-run"
if out="$(bash ./provision.sh --dry-run "${ARGS[@]}" 2>&1)"; then ok "A dry-run exits 0"; else bad "A dry-run exit"; fi
echo "$out" | sed 's/^/    | /' | head -120 || true
grep -q 'effective HOOKS: base udev keyboard modconf kms keymap consolefont block netconf dropbear encryptssh filesystems fsck' <<<"$out" \
  && ok "A HOOKS detected" || bad "A HOOKS detection"
grep -q 'initramfs ssh: dropbear, authorized keys: /etc/dropbear/root_key' <<<"$out" && ok "A dropbear detected" || bad "A dropbear detection"
grep -q 'token redacted' <<<"$out" && ok "A registration token never printed" || bad "A token redaction"
[[ ! -e /usr/local/bin/forgejo-runner && ! -e /etc/vdh-runner/runner.yaml ]] && ok "A dry-run changed nothing" || bad "A dry-run wrote files"
id runner >/dev/null 2>&1 && bad "A dry-run created user" || ok "A dry-run created no user"

echo "== B: real steps (container-capable subset)"
STEPS=packages,user,binary,payload,vmkey,initramfs
if bash ./provision.sh --steps "$STEPS" "${ARGS[@]}" > /root/real1.log 2>&1; then ok "B real run exits 0"; else bad "B real run"; tail -40 /root/real1.log; fi
sed 's/^/    | /' /root/real1.log | grep -v '^    | +' | head -60 || true
check "B runner: system user, nologin, locked" bash -c '[[ "$(getent passwd runner | cut -d: -f7)" == /usr/bin/nologin ]] && passwd -S runner | grep -q " L "'
check "B runner: in kvm, not wheel" bash -c 'g=" $(id -nG runner) "; [[ "$g" == *" kvm "* && "$g" != *" wheel "* ]]'
check "B forgejo-runner binary sha256 pinned" bash -c '[[ "$(sha256sum /usr/local/bin/forgejo-runner | cut -d" " -f1)" == fadaec897f5e6641c363f87ecaf75f866f99c81b7097ec6b433e4c48123fcad1 ]]'
check "B forgejo-runner reports 13.2.0" bash -c '/usr/local/bin/forgejo-runner --version | grep -q 13.2.0'
check "B runner.yaml: docker_host = VM socket, cache off, no privileged" bash -c 'grep -q "docker_host: \"unix:///run/forgejo-runner/docker.sock\"" /etc/vdh-runner/runner.yaml && grep -A1 "^cache:" /etc/vdh-runner/runner.yaml | grep -q "enabled: false" && grep -q "privileged: false" /etc/vdh-runner/runner.yaml'
check "B hosts override maps forge to envoy-forge" grep -qx '172.16.2.251 forge.example.invalid' /etc/vdh-runner/hosts
check "B VM key 0600 runner, private key never printed" bash -c '[[ "$(stat -c "%a %U" /var/lib/forgejo-runner/.ssh/vm_ed25519)" == "600 runner" ]] && ! grep -q "PRIVATE KEY" /root/real1.log'
check "B controller key appended once with restrictions" bash -c '[[ "$(grep -c "vdhwslin01-waker" /etc/dropbear/root_key)" == 1 ]] && grep -q "^no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 " /etc/dropbear/root_key'
check "B Sander's key untouched" grep -qF "$(cut -d' ' -f2 /root/sander_unlock.pub)" /etc/dropbear/root_key
check "B original root_key kept" test -s /etc/dropbear/root_key.vdh-orig
check "B hook drop-in sorts after omarchy_hooks.conf" bash -c 'ls /etc/mkinitcpio.conf.d | tail -n1 | grep -qx zz-vdh-teamboot.conf'
check "B every image got encryptssh AND vdh-teamboot" grep -qE 'images with encryptssh: ([1-9]), with vdh-teamboot: \1, wrapped: \1, exit: 0' /root/real1.log
check "B dropbear host keys printed as known_hosts lines" grep -qE '^\s+\[172\.16\.3\.205\]:2222 (ssh-|ecdsa-)' /root/real1.log

echo "== B2: idempotent re-run"
if bash ./provision.sh --steps "$STEPS" "${ARGS[@]}" > /root/real2.log 2>&1; then ok "B2 re-run exits 0"; else bad "B2 re-run"; tail -30 /root/real2.log; fi
check "B2 key still present exactly once" bash -c '[[ "$(grep -c "vdhwslin01-waker" /etc/dropbear/root_key)" == 1 ]]'
check "B2 binary not re-downloaded" grep -q 'already installed, sha256 ok' /root/real2.log
check "B2 files unchanged" bash -c '[[ "$(grep -c "unchanged:" /root/real2.log)" -ge 12 ]]'
check "B2 user step idempotent" grep -q 'user runner exists' /root/real2.log

echo "== C: inspect the built initramfs"
img=/boot/initramfs-linux.img
X=/root/initrd-x; install -d "$X"
(cd "$X" && lsinitcpio -x "$img")
check "C /bin/cryptsetup_shell is the vdh wrapper" grep -q 'vdh-teamboot: wrapper' "$X/usr/bin/cryptsetup_shell"
check "C real encryptssh shell kept as .vdh-real" grep -q 'cryptsetup open' "$X/usr/bin/cryptsetup_shell.vdh-real"
check "C passwd: root login shell is the wrapper path" grep -q '^root:x:0:0:root:/root:/bin/cryptsetup_shell$' "$X/etc/passwd"
check "C controller key in initramfs authorized_keys" grep -q 'no-pty ssh-ed25519 .* vdhwslin01-waker$' "$X/root/.ssh/authorized_keys"

echo "== D: wrapper behaviour in the initramfs busybox (chroot)"
install -d "$X/dev/mapper" "$X/proc/sys/kernel/random" "$X/run"
echo 11111111-2222-3333-4444-555555555555 > "$X/proc/sys/kernel/random/boot_id"
echo "12.34 5.00" > "$X/proc/uptime"
echo testvol > "$X/.cryptname"
cp "$X/usr/bin/cryptsetup_shell.vdh-real" /root/real-shell.keep
# D1: the real shell "unlocks" (creates the mapper node) -> marker
printf '#!/bin/sh\nmknod /dev/mapper/testvol b 7 0\n' > "$X/usr/bin/cryptsetup_shell.vdh-real"; chmod +x "$X/usr/bin/cryptsetup_shell.vdh-real"
chroot "$X" /bin/sh /bin/cryptsetup_shell > /root/d1.out 2>&1 || true
check "D1 ssh unlock writes /run/team-boot" grep -qx 'started_by=team' "$X/run/team-boot"
check "D1 marker carries this boot_id" grep -qx 'boot_id=11111111-2222-3333-4444-555555555555' "$X/run/team-boot"
check "D1 marker world-readable, root-owned" bash -c '[[ "$(stat -c "%a %U" '"$X"'/run/team-boot)" == "644 root" ]]'
# D2: disk already open (console won the race) -> no new marker
find "$X/run/team-boot" -delete
chroot "$X" /bin/sh /bin/cryptsetup_shell > /root/d2.out 2>&1 || true
check "D2 already-open disk -> no marker" test ! -e "$X/run/team-boot"
# D3: failed unlock (no mapper appears) -> no marker
find "$X/dev/mapper/testvol" -delete
printf '#!/bin/sh\nexit 2\n' > "$X/usr/bin/cryptsetup_shell.vdh-real"
rc=0; chroot "$X" /bin/sh /bin/cryptsetup_shell > /root/d3.out 2>&1 || rc=$?
check "D3 failed unlock -> no marker" test ! -e "$X/run/team-boot"
check "D3 wrapper passes the real exit code through" test "$rc" = 2
cp /root/real-shell.keep "$X/usr/bin/cryptsetup_shell.vdh-real"

echo "== E: nftables ruleset"
# shellcheck disable=SC1091
( . ./provision.sh; FORGE_HOST=forge.example.invalid; ENVOY_FORGE_IP=172.16.2.251; DNS_STUB=1; nft_ruleset ) > /root/vdh.nft
( . ./provision.sh; FORGE_HOST=forge.example.invalid; ENVOY_FORGE_IP=172.16.2.251; DNS_STUB=0; DNS_SERVERS=(172.16.3.1); nft_ruleset ) > /root/vdh-nostub.nft
sed 's/^/    | /' /root/vdh.nft
check "E ruleset never flushes the host ruleset" bash -c '! grep -q "flush ruleset" /root/vdh.nft'
check "E ssh allow-list = nodes + Mini + MacBook" grep -q 'elements = { 172.16.2.81, 172.16.2.82, 172.16.2.83, 172.16.2.201, 172.16.3.108, 172.16.3.23, 192.168.12.6, 192.168.4.6 }' /root/vdh.nft
check "E non-stub DNS rule renders" grep -q 'ip daddr { 172.16.3.1 } meta l4proto { tcp, udp } th dport 53 accept' /root/vdh-nostub.nft
for f in /root/vdh.nft /root/vdh-nostub.nft; do
  if unshare -rn true 2>/dev/null; then
    if unshare -rn nft -c -f "$f"; then ok "E nft -c accepts $(basename "$f") (user+net namespace)"; else bad "E nft -c rejects $(basename "$f")"; fi
  else
    echo "SKIP E nft -c: no user namespaces in this container (provision.sh runs nft -c before loading on the box)"
  fi
done

echo "== F: idle-poweroff unit tests (Arch bash $BASH_VERSION)"
if bash tests/idle-poweroff.test.sh > /root/f.out 2>&1; then ok "F $(tail -n1 /root/f.out)"; else bad "F"; cat /root/f.out; fi

echo "== G: F1 (Argus) a re-run never lets runner steer root"
ARGS_NOKEY=(--forge-url https://forge.example.invalid --envoy-forge-ip 172.16.2.251 --reg-token -)
# G1: runner swaps its own subdir for a symlink to /etc -> the user step must refuse
runuser -u runner -- mv /var/lib/forgejo-runner/vm /var/lib/forgejo-runner/vm.orig
runuser -u runner -- ln -s /etc /var/lib/forgejo-runner/vm
before="$(stat -c '%U:%G %a' /etc)"
if bash ./provision.sh --steps user "${ARGS_NOKEY[@]}" > /root/g1.log 2>&1; then bad "G1 user step followed a runner symlink"; else ok "G1 user step refuses a runner-planted symlink"; fi
grep -q 'is a symlink; refusing (F1)' /root/g1.log && ok "G1 says why" || bad "G1 message: $(tail -2 /root/g1.log)"
[[ "$(stat -c '%U:%G %a' /etc)" == "$before" ]] && ok "G1 /etc untouched ($before)" || bad "G1 /etc changed"
runuser -u runner -- rm /var/lib/forgejo-runner/vm
runuser -u runner -- mv /var/lib/forgejo-runner/vm.orig /var/lib/forgejo-runner/vm
# G2: .runner as a symlink to /etc/passwd -> register must not chown/chmod it
runuser -u runner -- ln -s /etc/passwd /var/lib/forgejo-runner/.runner
before="$(stat -c '%U:%G %a' /etc/passwd)"
bash ./provision.sh --steps register "${ARGS_NOKEY[@]}" > /root/g2.log 2>&1 || true
[[ "$(stat -c '%U:%G %a' /etc/passwd)" == "$before" ]] && ok "G2 /etc/passwd untouched via .runner symlink ($before)" || bad "G2 /etc/passwd changed"
runuser -u runner -- rm /var/lib/forgejo-runner/.runner
# G3: golden promotion with a stub build (no KVM here). The stub runs AS runner.
[[ -c /dev/kvm ]] || mknod /dev/kvm c 10 232
cp /usr/local/libexec/vdh-runner/vm-golden-build /root/vm-golden-build.real
cat > /usr/local/libexec/vdh-runner/vm-golden-build <<'STUB'
#!/bin/bash
# test stub: behaviour chosen by /root/stub-mode (root-owned, readable)
mode="$(cat /root/stub-mode)"; out="$2"; kh="$3"
case "$mode" in
  shadow)  ln -sfn /etc/shadow "$out"; echo "vdh-job-vm ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST" > "$kh" ;;
  inject)  echo golden > "$out"; printf 'vdh-job-vm ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST\n@cert-authority * ssh-ed25519 AAAAEVIL\n' > "$kh" ;;
  good)    rm -f "$out"; head -c 1048576 /dev/urandom > "$out"; echo "vdh-job-vm ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST" > "$kh" ;;
esac
STUB
chmod 0755 /usr/local/libexec/vdh-runner/vm-golden-build
echo shadow > /root/stub-mode; chmod 0755 /root; chmod 0644 /root/stub-mode   # runner reads the mode only
if bash ./provision.sh --steps golden "${ARGS_NOKEY[@]}" > /root/g3a.log 2>&1; then bad "G3a promotion succeeded through a symlink to /etc/shadow"; else ok "G3a promotion via symlink -> /etc/shadow fails"; fi
if [[ -e /var/lib/vdh-runner-golden/golden.qcow2 ]] && cmp -s /etc/shadow /var/lib/vdh-runner-golden/golden.qcow2; then bad "G3a shadow copied to golden"; else ok "G3a /etc/shadow not copied into a 0444 path"; fi
echo inject > /root/stub-mode
if bash ./provision.sh --steps golden "${ARGS_NOKEY[@]}" > /root/g3b.log 2>&1; then bad "G3b injected known_hosts line accepted"; else ok "G3b injected known_hosts line refused"; fi
! grep -q 'cert-authority' /etc/vdh-runner/vm_known_hosts 2>/dev/null && ok "G3b no injected line in /etc/vdh-runner/vm_known_hosts" || bad "G3b injected line landed"
echo good > /root/stub-mode
if bash ./provision.sh --steps golden "${ARGS_NOKEY[@]}" > /root/g3c.log 2>&1; then ok "G3c benign build promotes"; else bad "G3c benign promotion failed"; tail -5 /root/g3c.log; fi
[[ "$(stat -c '%U:%G %a' /var/lib/vdh-runner-golden/golden.qcow2)" == "root:root 444" ]] && ok "G3c golden root:root 0444" || bad "G3c golden perms"
[[ "$(sha256sum /var/lib/vdh-runner-golden/golden.qcow2 | cut -d' ' -f1)" == "$(cat /etc/vdh-runner/golden.sha256)" ]] && ok "G3c pin matches the promoted image" || bad "G3c pin mismatch"
[[ "$(stat -c '%U %a' /var/lib/vdh-runner-stage/base.qcow2)" == "root 444" ]] && ok "G3c base staged root-owned 0444 outside runner's tree" || bad "G3c stage perms"
cp /root/vm-golden-build.real /usr/local/libexec/vdh-runner/vm-golden-build
# G5: registration as root over the LAN, handed to runner (stub runner binary: no forge here)
cp /usr/local/bin/forgejo-runner /root/forgejo-runner.real
cat > /usr/local/bin/forgejo-runner <<'STUB'
#!/bin/sh
# test stub for `register`: writes .runner in cwd like the real one
[ "$1" = register ] || exit 0
printf '{"uuid":"00000000-0000-0000-0000-000000000000","token":"stub-runner-token","address":"https://forge.example.invalid","labels":["docker"]}\n' > .runner
STUB
chmod 0755 /usr/local/bin/forgejo-runner
if bash ./provision.sh --steps register --forge-url https://forge.example.invalid --envoy-forge-ip 172.16.2.251 --reg-token STUBREGTOKEN0123456789 > /root/g5.log 2>&1; then ok "G5 register step exits 0"; else bad "G5 register"; tail -5 /root/g5.log; fi
[[ "$(stat -c '%a %U' /var/lib/forgejo-runner/.runner 2>/dev/null)" == "600 runner" ]] && ok "G5 .runner 0600 owned by runner (written by runner)" || bad "G5 .runner perms"
[[ ! -e /var/lib/vdh-runner-stage/reg/.runner ]] && ok "G5 staged copy removed" || bad "G5 staged .runner left behind"
[[ "$(stat -c '%a %U' /var/lib/vdh-runner-stage/reg)" == "700 root" ]] && ok "G5 staging dir root 0700" || bad "G5 stage perms"
! grep -q STUBREGTOKEN /root/g5.log && ok "G5 registration token not in output" || bad "G5 token printed"
bash ./provision.sh --steps register --forge-url https://forge.example.invalid --envoy-forge-ip 172.16.2.251 --reg-token X > /root/g5b.log 2>&1
grep -q 'already registered' /root/g5b.log && ok "G5 re-run skips (already registered)" || bad "G5 re-run"
runuser -u runner -- rm /var/lib/forgejo-runner/.runner
cp /root/forgejo-runner.real /usr/local/bin/forgejo-runner

# G4: after everything, nothing outside runner's own trees is owned by runner
stray="$(find / -xdev -user runner -not -path '/var/lib/forgejo-runner*' -not -path '/proc/*' 2>/dev/null | head -5)"
[[ -z "$stray" ]] && ok "G4 no runner-owned path outside /var/lib/forgejo-runner" || bad "G4 runner owns: $stray"
grep -q 'Running build hook' /root/real1.log && ok "G (B ran before G)" || true

echo "RESULT: ${pass} passed, ${fail} failed"
(( fail == 0 ))
