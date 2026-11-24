#!/usr/bin/env bash
# vdhwslin01 golden VM build (chg-2026-10-05-031, Argus R5).
# Installed as /usr/local/libexec/vdh-runner/vm-golden-build; provision.sh
# runs it as user `runner` (same nftables egress limits as jobs).
#
#   vm-golden-build <verified-base.qcow2> <out.qcow2> <known_hosts-out>
#   vm-golden-build --check-console <console.log>   (pass 1 marker check only; tests)
#
# Boots the checksum-verified Debian 13 cloud image once with a NoCloud seed:
# installs docker.io, makes dockerd also listen on /run/forgejo-runner/
# docker.sock, adds user `fr` (docker group) with the host's VM key, disables
# cloud-init and powers off. Then boots the result once more WITHOUT a seed to
# prove ssh + docker work and to record the VM host key, and flattens it.
# provision.sh installs the output root-owned 0444 and pins its sha256.
set -euo pipefail

# Pass 1 is good only if the serial console shows exactly one of each marker,
# in this order by line number: GRUB "Booting" < kernel banner < cloud-init
# "finished" < "reboot: Power down", the power-down line is the last kernel
# line, and there is no "Kernel panic" or "reboot: Restarting system" anywhere
# (Argus F1, 2026-11-24). qemu exits 0 on a guest reset as well (-no-reboot), so
# the exit code alone proves nothing. Anything else is RED (fail closed). No
# duration check: run 3 (2026-11-24) finished cleanly in 109 s.
console_ok() {
  local f="$1" ng nk nf np lg lk lf lp bad last
  [[ -r "$f" ]] || { echo "no console log"; return 1; }
  ng="$(grep -ac 'Booting `Debian' "$f" || true)"
  nk="$(grep -ac '] Linux version ' "$f" || true)"
  nf="$(grep -acE 'Cloud-init v\. [^ ]+ finished at ' "$f" || true)"
  np="$(grep -ac 'reboot: Power down' "$f" || true)"
  lg="$(grep -an 'Booting `Debian' "$f" | head -n1 | cut -d: -f1 || true)"
  lk="$(grep -an '] Linux version ' "$f" | head -n1 | cut -d: -f1 || true)"
  lf="$(grep -anE 'Cloud-init v\. [^ ]+ finished at ' "$f" | head -n1 | cut -d: -f1 || true)"
  lp="$(grep -an 'reboot: Power down' "$f" | head -n1 | cut -d: -f1 || true)"
  bad="$(grep -acE 'Kernel panic|reboot: Restarting system' "$f" || true)"
  last="$(grep -anE '^\[ *[0-9]+\.[0-9]+\] ' "$f" | tail -n1 | cut -d: -f1 || true)"
  echo "console: ${ng} GRUB boot(s), ${nk} kernel banner(s), cloud-init finished line ${lf:-none}, power down line ${lp:-none}; finished x${nf}, power down x${np}, panic/restart x${bad}, GRUB line ${lg:-none}, banner line ${lk:-none}, last kernel line ${last:-none}"
  [[ "$ng" == 1 && "$nk" == 1 && "$nf" == 1 && "$np" == 1 && "$bad" == 0 ]] || return 1
  (( lg < lk && lk < lf && lf < lp )) && [[ "$last" == "$lp" ]]
}
# qemu runs in the background from bash, NOT with -daemonize: qemu applies
# -sandbox before it daemonizes, and spawn=deny (fork) and elevateprivileges=deny
# (setsid) make -daemonize exit 1 silently before the serial log exists
# (chg-2026-11-06-005 run 4; repro in a pod with qemu 11.1.3). qemu_started
# waits for qemu's own -pidfile to name the pid bash started; if qemu exits
# first it fails with qemu's exit code and the console tail.
# Same function in vm-golden-build and vm-dispatch (tests/qemu-start.test.sh).
qemu_started() { # qemu_started <pid> <pidfile> <console log>
  local pid="$1" pf="$2" con="$3" rc=0
  for _ in $(seq 1 60); do
    if [[ -s "$pf" && "$(cat "$pf" 2>/dev/null)" == "$pid" ]]; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || rc=$?
      echo "qemu (pid $pid) exited rc=${rc} before writing its pidfile; console tail:"
      tail -c 2000 "$con" 2>/dev/null | tr -cd '\11\12\15\40-\176'; echo
      return 1
    fi
    sleep 0.5
  done
  echo "qemu (pid $pid) wrote no pidfile in 30 s"
  return 1
}
if [[ "${1:-}" == --check-console ]]; then
  console_ok "${2:?console log}"; exit
fi

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
  # same digest as JOB_IMAGE in provision.in.sh (tests/run-all.sh checks they match)
  - [docker, pull, "node:24-bookworm@sha256:e7add2a490bb17d97b485b8641bd88455fff7839ade0f5eba493c3508124d413"]
  - [touch, /etc/cloud/cloud-init.disabled]
  - [fstrim, -av]
power_state:
  mode: poweroff
  timeout: 60
EOF
xorriso -as mkisofs -quiet -output "$B/seed.iso" -volid cidata -joliet -rock \
  "$B/seed/user-data" "$B/seed/meta-data"

qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$B/build.qcow2" 60G

# smm=off (chg-2026-11-06-005 run 2, 2026-11-23): with SMM on, the guest reset
# right after GRUB's "Booting" 5946 times in 30 min, no kernel output (the
# image has earlyprintk=ttyS0). Repro on the Mini (TCG, same image, any CPU
# model or q35/pc version): SMM on = vCPU stuck in SMRAM after "Booting";
# smm=off = kernel banner in 4 s. Nothing here needs SMM (no OVMF, no
# secure boot). Same flags in vm-dispatch.
# -no-reboot: a guest reset ends qemu at once instead of looping until the
# timeout (cloud-init here powers off; it never reboots).
# shellcheck disable=SC2054  # qemu option values contain commas
common=(-machine q35,accel=kvm,smm=off -cpu host -smp 4 -m 4G -no-reboot
  -nodefaults -no-user-config -display none -vga none
  -device virtio-rng-pci
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny)

log "host: $(uname -r); $(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'); $(qemu-system-x86_64 --version | head -n1)"
log "pass 1: cloud-init install (up to 30 min)"
timeout 1800 qemu-system-x86_64 "${common[@]}" -name vdh-golden-build \
  -serial "file:$B/build-console.log" \
  -drive "file=$B/build.qcow2,if=virtio,format=qcow2" \
  -drive "file=$B/seed.iso,if=virtio,format=raw,readonly=on" \
  -netdev user,id=n0,ipv6=off -device virtio-net-pci,netdev=n0
if ! res="$(console_ok "$B/build-console.log")"; then
  log "FAIL: pass 1 $res; console tail:"
  tail -c 2000 "$B/build-console.log" | tr -cd '\11\12\15\40-\176'; echo
  exit 1
fi
log "pass 1 $res"
log "pass 1 done (VM powered off)"

log "pass 2: verify without seed (-snapshot: this boot writes nothing to the image)"
qemu-system-x86_64 "${common[@]}" -name vdh-golden-verify -snapshot \
  -serial "file:$B/verify-console.log" \
  -drive "file=$B/build.qcow2,if=virtio,format=qcow2" \
  -netdev "user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:${FWD_PORT}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -pidfile "$B/verify.pid" </dev/null &
vpid=$!
stop_verify() { kill "$vpid" 2>/dev/null || true; wait "$vpid" 2>/dev/null || true; }
trap stop_verify EXIT
# Not in $(...): wait needs qemu to be a child of THIS shell to get its exit code.
qemu_started "$vpid" "$B/verify.pid" "$B/verify-console.log" || { log "FAIL: verify VM did not start"; exit 1; }

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
