#!/usr/bin/env bash
# wq-113 follow-ups (chg-2026-11-28-105): SuccessExitStatus=143, qemu-died detection in the ssh wait loops
# (Argus F3), /proc/<pid>/comm check before any kill (Argus F4), vsock probe by virtio device id 0x0013.
# Offline: fake qemu = bash/sleep, fake /proc and /sys trees; macOS-safe. Includes mutation checks.
# shellcheck disable=SC2015,SC2016  # ok/FAIL idiom; grep patterns hold literal $ on purpose
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
pass=0; fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
D=src/vm-dispatch.sh; G=src/vm-golden-build.sh
t="$(mktemp -d)"

# 1. unit: exit 143 on purpose is a clean stop
grep -qx 'SuccessExitStatus=143' src/forgejo-runner-vm.service && ok "unit has SuccessExitStatus=143" || bad "unit lacks SuccessExitStatus=143"
grep -qE "^trap 'exit 143' TERM INT" "$D" && ok "dispatcher still exits 143 on TERM (script rc stays truthful)" || bad "TERM trap changed"

# 2. shared helpers identical
for fn in qemu_is_ours qemu_died; do
  a="$(sed -n "/^${fn}() {/,/^}/p" "$G")"; b="$(sed -n "/^${fn}() {/,/^}/p" "$D")"
  [[ -n "$a" && "$a" == "$b" ]] && ok "$fn identical in both scripts" || bad "$fn differs or missing"
done

# 3. qemu_is_ours against a fake /proc
fn_is="$(sed -n '/^qemu_is_ours() {/,/^}/p' "$D")"
mkdir -p "$t/proc/100" "$t/proc/200" "$t/proc/300"
printf 'qemu-system-x86\n' > "$t/proc/100/comm"; printf 'bash\n' > "$t/proc/200/comm"; printf 'qemu-img\n' > "$t/proc/300/comm"
chk() { # chk <function text> <pid> -> rc, with /proc redirected to the fixture
  ( eval "${1//\/proc\//$t/proc/}"; qemu_is_ours "$2" ); }
chk "$fn_is" 100 && ok "comm qemu-system-x86 -> ours" || bad "qemu not recognised"
! chk "$fn_is" 200 && ok "comm bash -> not ours" || bad "bash accepted"
! chk "$fn_is" 300 && ok "comm qemu-img -> not ours" || bad "qemu-img accepted"
! chk "$fn_is" 999 && ok "no such pid -> not ours" || bad "missing pid accepted"
# mutation: without the comm test every pid is accepted -> the checks above must notice
mut="${fn_is//\[\[ \"\$c\" == qemu-system-\* \]\]/true}"
if [[ "$mut" != "$fn_is" ]] && chk "$mut" 200; then ok "mutation (comm check removed) is caught by the bash case"; else bad "mutation not caught"; fi

# 4. every kill of a qemu pid sits behind qemu_is_ours
for f in "$D" "$G"; do
  n="$(grep -cE '^[^#]*kill (-TERM |-KILL )?"\$(pid|qemu_pid|vpid)"' "$f")"
  [[ "$n" -ge 1 ]] && ok "$f: $n kill site(s) of a qemu pid" || bad "$f: no kill sites found (pattern stale?)"
done
# stricter: in dispatch each kill line is preceded within 2 lines by a qemu_is_ours guard
awk '/kill -(TERM|KILL)? ?"\$(pid|qemu_pid)"/ && !/kill -0/ {if (!(g1 ~ /qemu_is_ours/ || g2 ~ /qemu_is_ours/ || $0 ~ /qemu_is_ours/)) {print "UNGUARDED: " $0; r=1}} {g2=g1; g1=$0} END{exit r}' "$D" \
  && ok "dispatch: every kill is guarded by qemu_is_ours" || bad "dispatch: unguarded kill"
grep -qE 'kill -0 "\$vpid" 2>/dev/null && qemu_is_ours "\$vpid"; then kill "\$vpid"' "$G" && ok "golden stop_verify guarded" || bad "golden stop_verify unguarded"

# 5. qemu_died reports rc and console tail
fn_died="$(sed -n '/^qemu_died() {/,/^}/p' "$D")"
printf 'kvm: cannot open /dev/kvm\n' > "$t/con.log"
# the wait must run in the shell that forked, so no subshell
eval "$fn_died"; bash -c 'exit 7' & p=$!; sleep 0.3; qemu_died "$p" "$t/con.log" > "$t/died.out"
[[ "$(cat "$t/died.out")" == *"exited rc=7"* && "$(cat "$t/died.out")" == *"cannot open /dev/kvm"* ]] && ok "qemu_died: rc=7 and console tail" || bad "qemu_died output: $(cat "$t/died.out")"

# 6. behaviour: wait_vm / open_docker_tunnel exit 1 at once when qemu is gone (not after 180 s)
run_wait() { # run_wait <function name> <script> -> sets out, rc
  local body; body="$(sed -n "/^$1() {/,/^}/p" "$2")"
  out="$( bash -c '
    log() { echo "vm-dispatch: $*"; }; vm_ssh() { return 1; }; sleep() { :; }; curl() { return 1; }
    STATE_DIR=$1; SOCK=/nonexistent
    eval "$2"; eval "$3"
    bash -c "exit 7" & qemu_pid=$!; while kill -0 $qemu_pid 2>/dev/null; do :; done
    '"$1"'; echo "RETURNED rc=$?"' _ "$t" "$(sed -n '/^qemu_died() {/,/^}/p' "$D")" "$body" 2>&1 )"; rc=$?
}
for w in wait_vm open_docker_tunnel; do
  run_wait "$w" "$D"
  [[ "$out" == *"exited rc=7"* && "$out" != *RETURNED* && "$rc" == 1 ]] && ok "$w: qemu gone -> logs rc=7 and exits 1" || bad "$w: rc=$rc out=$out"
  # mutation: drop the kill -0 line -> the loop runs to its end and returns 1 with no qemu rc
  mutbody="$(sed -n "/^$w() {/,/^}/p" "$D" | grep -v 'qemu_died')"
  out2="$( bash -c '
    log() { echo "vm-dispatch: $*"; }; vm_ssh() { return 1; }; sleep() { :; }; curl() { return 1; }; STATE_DIR=$1; SOCK=/x
    eval "$2"; '"$w"'; echo "RETURNED rc=$?"' _ "$t" "$mutbody" 2>&1 )"
  [[ "$out2" != *"exited rc=7"* ]] && ok "$w: mutation (qemu_died check removed) is caught" || bad "$w: mutation not caught"
done
# also: wait_vm with qemu alive and ssh never up still gives up with its own message
out="$( bash -c '
  log() { echo "vm-dispatch: $*"; }; vm_ssh() { return 1; }; sleep() { :; }
  STATE_DIR=$1; eval "$2"; eval "$3"; command sleep 30 & qemu_pid=$!
  wait_vm; echo "RETURNED rc=$?"; kill $qemu_pid' _ "$t" "$(sed -n '/^qemu_died() {/,/^}/p' "$D")" "$(sed -n '/^wait_vm() {/,/^}/p' "$D")" 2>&1 )"
[[ "$out" == *"did not come up"* && "$out" == *"RETURNED rc=1"* ]] && ok "wait_vm: qemu alive, no ssh -> timeout message, rc 1" || bad "wait_vm timeout path: $out"
grep -qE 'if ! kill -0 "\$vpid" 2>/dev/null; then qemu_died "\$vpid"' "$G" && ok "golden ssh wait loop checks qemu" || bad "golden ssh wait loop does not check qemu"

# 7. vsock probe = virtio device id 0x0013, not the /dev/vsock node
! grep -nE '^[^#]*ls /dev/vsock' "$G" provision.sh && ok "no /dev/vsock node probe left" || bad "node probe still present"
probe="$(grep -E "^nvs=\"\\\$\(sshv '" "$G" | sed -e "s/^nvs=\"\\\$(sshv '//" -e "s/')\" *\\\\\$//")"
[[ -n "$probe" ]] && ok "probe command extracted" || bad "probe not found"
mkdir -p "$t/sys1/v0" "$t/sys1/v1" "$t/sys2/v0" "$t/sys2/v1" "$t/sys3"
printf '0x0001\n' > "$t/sys1/v0/device"; printf '0x0004\n' > "$t/sys1/v1/device"      # net, rng: no vsock
printf '0x0002\n' > "$t/sys2/v0/device"; printf '0x0013\n' > "$t/sys2/v1/device"      # blk + vsock
for c in 1:0 2:1 3:0; do
  d="${c%%:*}"; want="${c##*:}"
  got="$(bash -c "${probe//\/sys\/bus\/virtio\/devices/$t/sys$d}")"
  [[ "$got" == "$want" ]] && ok "probe on fixture $d -> $got vsock device(s)" || bad "probe on fixture $d -> '$got', want $want"
done
grep -q '"\$nvs" == 0' "$G" && ok "golden build fails on a vsock device" || bad "golden build does not gate on the count"

mkdir -p "$t/../vdh-wq113-test-trash" 2>/dev/null; mv "$t" "$t/../vdh-wq113-test-trash/" 2>/dev/null
echo "wq113 tests: $pass passed, $fail failed"
(( fail == 0 ))
