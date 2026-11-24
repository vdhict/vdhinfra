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
t0="$(date +%s)"
timeout 1800 qemu-system-x86_64 "${common[@]}" -name vdh-golden-build \
  -serial "file:$B/build-console.log" \
  -drive "file=$B/build.qcow2,if=virtio,format=qcow2" \
  -drive "file=$B/seed.iso,if=virtio,format=raw,readonly=on" \
  -netdev user,id=n0,ipv6=off -device virtio-net-pci,netdev=n0
secs=$(( $(date +%s) - t0 ))
log "pass 1 qemu exited after ${secs}s; console: $(grep -ac 'Booting `Debian' "$B/build-console.log") GRUB boot(s), $(grep -ac 'Linux version' "$B/build-console.log") kernel banner(s)"
# qemu exits 0 on a guest reset as well (-no-reboot). package_upgrade plus
# the docker install and image pull cannot finish in under 2 minutes, so a
# short pass 1 is a reset or a crash, not a build.
if (( secs < 120 )); then
  log "FAIL: pass 1 ended after ${secs}s (guest reset or crash); console tail:"
  tail -c 2000 "$B/build-console.log" | tr -cd '\11\12\15\40-\176'; echo
  exit 1
fi
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
