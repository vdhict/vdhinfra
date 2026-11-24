#!/usr/bin/env bash
# qemu start without -daemonize (chg-2026-11-06-005 run 4): -sandbox ...,spawn=deny stays, -daemonize is gone,
# both scripts share one qemu_started(), and qemu_started passes a live process that writes its pidfile and
# fails (with the exit code and console tail) on one that exits first. Fake "qemu" = bash; no VM is started.
# shellcheck disable=SC2015  # ok/FAIL report idiom (echo cannot fail)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
pass=0; fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
for f in src/vm-golden-build.sh src/vm-dispatch.sh; do
  ! grep -nE '^[^#]*-daemonize' "$f" && ok "$f: no -daemonize" || bad "$f: -daemonize is back"
  grep -qE '^[^#]*-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny' "$f" && ok "$f: sandbox with spawn=deny kept" || bad "$f: sandbox flags changed"
  grep -qE '^[^#]*-pidfile "[^"]+" </dev/null &$' "$f" && ok "$f: qemu backgrounded by bash with -pidfile" || bad "$f: qemu not started with & + -pidfile"
  grep -qE '^[^#]*qemu_started "\$[a-z_]+pid" ' "$f" && ok "$f: start gated on qemu_started" || bad "$f: qemu_started not called"
  ! grep -nE 'res="\$\(qemu_started' "$f" && ok "$f: qemu_started not in a subshell" || bad "$f: qemu_started in \$(...) cannot wait for qemu"
done
a="$(sed -n '/^qemu_started() {/,/^}/p' src/vm-golden-build.sh)"; b="$(sed -n '/^qemu_started() {/,/^}/p' src/vm-dispatch.sh)"
[[ -n "$a" && "$a" == "$b" ]] && ok "qemu_started identical in both scripts" || bad "qemu_started differs"
eval "$a"
t="$(mktemp -d)"
# a: live process that writes its own pid to the pidfile (like qemu -pidfile)
bash -c 'echo $$ > "$1"; exec sleep 30' _ "$t/a.pid" & p=$!
qemu_started "$p" "$t/a.pid" "$t/a.log" >/dev/null && ok "live process with matching pidfile -> started" || bad "live process refused"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
# b: exits 1 at once without a pidfile, like qemu -daemonize under the sandbox
printf 'console line before death\n' > "$t/b.log"
bash -c 'exit 1' & p=$!
qemu_started "$p" "$t/b.pid" "$t/b.log" > "$t/b.out"; r=$?; out="$(cat "$t/b.out") rc=$r"
[[ "$out" == *"exited rc=1 before writing its pidfile"* && "$out" == *"console line before death"* && "$out" == *"rc=1" ]] \
  && ok "early exit -> fails with qemu's rc=1 and the console tail" || bad "early exit not reported: $out"
# c: pidfile naming another pid is not accepted
echo 1 > "$t/c.pid"; bash -c 'exit 3' & p=$!
qemu_started "$p" "$t/c.pid" "$t/c.log" > "$t/c.out"; r=$?; out="$(cat "$t/c.out") rc=$r"
[[ "$out" == *"exited rc=3"* && "$out" == *"rc=1" ]] && ok "foreign pid in pidfile is not success (rc=3 reported)" || bad "foreign pidfile accepted: $out"
mkdir -p "$t/../vdh-qemu-start-test-trash" 2>/dev/null; mv "$t" "$t/../vdh-qemu-start-test-trash/" 2>/dev/null
echo "qemu start tests: $pass passed, $fail failed"
(( fail == 0 ))
