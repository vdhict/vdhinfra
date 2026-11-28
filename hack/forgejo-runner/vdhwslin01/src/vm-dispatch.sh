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
RUNNER_FILE=/var/lib/forgejo-runner/.runner
# shellcheck disable=SC1091
[[ -r /etc/vdh-runner/vm.env ]] && . /etc/vdh-runner/vm.env

log() { echo "vm-dispatch: $*"; }

vm_ssh() {
  ssh -F /dev/null -i "$VM_KEY" -p "$FWD_PORT" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$VM_KNOWN_HOSTS" -o HostKeyAlias=vdh-job-vm \
    -o ConnectTimeout=5 -o LogLevel=ERROR "$@"
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

# Argus F4: never signal a pid that is not a qemu (a stale pidfile or a reused
# pid). /proc/<pid>/comm of qemu-system-x86_64 reads "qemu-system-x86".
qemu_is_ours() { # qemu_is_ours <pid>
  local c
  c="$(cat "/proc/$1/comm" 2>/dev/null)" || return 1
  [[ "$c" == qemu-system-* ]]
}
# Argus F3: qemu died after it wrote its pidfile (e.g. KVM open failed); say so
# with its exit code and the console tail instead of an ssh timeout.
qemu_died() { # qemu_died <pid> <console log>
  local pid="$1" con="$2" rc=0
  wait "$pid" 2>/dev/null || rc=$?
  echo "qemu (pid $pid) exited rc=${rc} while waiting for ssh; console tail:"
  tail -c 2000 "$con" 2>/dev/null | tr -cd '\11\12\15\40-\176'; echo
}

tunnel_pid=""
qemu_pid=""
cleanup_vm() {
  if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
  fi
  tunnel_pid=""
  if [[ -f "${STATE_DIR}/qemu.pid" ]]; then
    local pid; pid="$(cat "${STATE_DIR}/qemu.pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      if qemu_is_ours "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        qemu_is_ours "$pid" && kill -KILL "$pid" 2>/dev/null
      else
        log "pidfile pid $pid is not a qemu; not signalled"
      fi
    fi
  fi
  # Our own background qemu child: kill it by the pid bash recorded and reap it.
  if [[ -n "$qemu_pid" ]]; then
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      wait "$qemu_pid" 2>/dev/null || true
    elif qemu_is_ours "$qemu_pid"; then
      kill -TERM "$qemu_pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 0.5; done
      qemu_is_ours "$qemu_pid" && kill -KILL "$qemu_pid" 2>/dev/null
      wait "$qemu_pid" 2>/dev/null || true
    else
      log "child pid $qemu_pid is not a qemu; not signalled"
    fi
  fi
  qemu_pid=""
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
  # smm=off: with SMM the guest resets right after GRUB (see vm-golden-build).
  # -no-reboot: a guest reset ends qemu, so wait_vm fails instead of a loop.
  qemu-system-x86_64 \
    -name vdh-job-vm -machine q35,accel=kvm,smm=off -cpu host -no-reboot \
    -smp "$VM_CPUS" -m "$VM_MEM" \
    -nodefaults -no-user-config -display none -vga none \
    -serial "file:${STATE_DIR}/vm-console.log" \
    -drive file=/var/lib/forgejo-runner/vm/job.qcow2,if=virtio,format=qcow2,discard=unmap \
    -netdev "user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:${FWD_PORT}-:22" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -pidfile "${STATE_DIR}/qemu.pid" </dev/null &
  qemu_pid=$!
  # Not in $(...): wait needs qemu to be a child of THIS shell to get its exit code.
  qemu_started "$qemu_pid" "${STATE_DIR}/qemu.pid" "${STATE_DIR}/vm-console.log" || { log "VM did not start"; return 1; }
}

wait_vm() {
  for _ in $(seq 1 90); do
    if vm_ssh fr@127.0.0.1 true 2>/dev/null; then return 0; fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then qemu_died "$qemu_pid" "${STATE_DIR}/vm-console.log"; exit 1; fi
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
    if ! kill -0 "$qemu_pid" 2>/dev/null; then qemu_died "$qemu_pid" "${STATE_DIR}/vm-console.log"; exit 1; fi
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

# The forge as THIS service sees it (hosts pin -> envoy-forge). No VM is
# booted until it answers, so a missing envoy-forge or registration costs no
# CPU on the workstation.
forge_ok() {
  local url
  [[ -s "$RUNNER_FILE" ]] || { log "not registered yet (.runner missing)"; return 1; }
  url="$(sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RUNNER_FILE" | head -n1)"
  [[ -n "$url" ]] || { log "no address in .runner"; return 1; }
  curl -fsS -m 8 -o /dev/null "${url%/}/api/healthz" || { log "forge ${url} not reachable via envoy-forge yet"; return 1; }
}

while true; do
  cleanup_vm
  if ! forge_ok; then sleep 120; continue; fi
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
