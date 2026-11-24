#!/usr/bin/env bash
# vm-golden-build pass 1 console markers (chg-2026-11-06-005 run 3): the real 109 s good log passes,
# every broken variant fails, and no duration check is left in the script.
# shellcheck disable=SC2015,SC2016  # ok/FAIL report idiom (echo cannot fail); literal script text in grep
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
G=src/vm-golden-build.sh; F=tests/fixtures; pass=0; fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
out="$(bash "$G" --check-console "$F/golden-console-good-109s.log")" && ok "good 109 s log passes ($out)" || bad "good 109 s log refused ($out)"
for f in "$F"/golden-console-bad-*.log; do
  out="$(bash "$G" --check-console "$f")" && bad "$(basename "$f") accepted ($out)" || ok "$(basename "$f") refused ($out)"
done
bash "$G" --check-console "$F/does-not-exist.log" >/dev/null && bad "missing log accepted" || ok "missing log refused"
! grep -nE '^[^#]*(secs|t0=|date \+%s)' "$G" && ok "no duration check in $G" || bad "a duration check is still in $G"
grep -qE '^if ! res="\$\(console_ok "\$B/build-console.log"\)"; then' "$G" && ok "pass 1 gated on console_ok" || bad "pass 1 not gated on console_ok"
echo "golden console tests: $pass passed, $fail failed"
(( fail == 0 ))
