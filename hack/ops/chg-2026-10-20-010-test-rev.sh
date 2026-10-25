#!/usr/bin/env bash
# chg-2026-10-20-010 offline test of the Flux lastAppliedRevision check (rev_is) in golive.sh and rollback.sh.
#
#   bash hack/ops/chg-2026-10-20-010-test-rev.sh
#
# Background: the 25-10 11:36Z go went RED (and rolled back) because both scripts compared against
# 'main@sha1:<sha>' while Flux reports 'refs/heads/main@sha1:<sha>'. rev_is accepts exactly those two forms
# with the FULL sha and nothing looser. Sources the marked `# >>> c010-rev` block of each real script.
# No cluster, no network, no writes. Exit 0 iff all cases pass for both scripts.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
SHA=97996d3af149735d17cc391bb55369db8a469dab
OTHER=4a557455a4ac07f6aaee00a2791ac130d3bb2768
blk() { sed -n '/^# >>> c010-rev/,/^# <<< c010-rev/p' "$1"; }
G="$HERE/chg-2026-10-20-010-golive.sh"; R="$HERE/chg-2026-10-20-010-rollback.sh"
t "the c010-rev block exists in golive.sh and rollback.sh and is byte-identical" bash -c "[ -n \"\$(sed -n '/^# >>> c010-rev/,/^# <<< c010-rev/p' '$G')\" ] && [ \"\$(sed -n '/^# >>> c010-rev/,/^# <<< c010-rev/p' '$G')\" = \"\$(sed -n '/^# >>> c010-rev/,/^# <<< c010-rev/p' '$R')\" ]"
t "golive.sh: the ks Ready check uses rev_is and no literal main@sha1 comparison is left" bash -c "grep -q 'chk \"ks \$ks Ready at \$SHA\" \"rev_is ' '$G' && ! grep -q \"= 'main@sha1:\" '$G'"
t "rollback.sh: the ks Ready check uses rev_is and no literal main@sha1 comparison is left" bash -c "grep -q 'chk \"ks \$ks Ready at \$PUSHED\" \"rev_is ' '$R' && ! grep -q \"= 'main@sha1:\" '$R'"
for f in "$G" "$R"; do
  n=$(basename "$f" .sh | sed 's/chg-2026-10-20-010-//')
  eval "$(blk "$f")"
  t "$n accepts main@sha1:<full sha>"            rev_is "main@sha1:$SHA" "$SHA"
  t "$n accepts refs/heads/main@sha1:<full sha>" rev_is "refs/heads/main@sha1:$SHA" "$SHA"
  t "$n refuses main@sha1:<other sha>"            bash -c "$(blk "$f"); ! rev_is 'main@sha1:$OTHER' '$SHA'"
  t "$n refuses refs/heads/main@sha1:<other sha>" bash -c "$(blk "$f"); ! rev_is 'refs/heads/main@sha1:$OTHER' '$SHA'"
  t "$n refuses a short sha in the revision"      bash -c "$(blk "$f"); ! rev_is 'refs/heads/main@sha1:${SHA:0:12}' '$SHA'"
  t "$n refuses a short expected sha"             bash -c "$(blk "$f"); ! rev_is 'main@sha1:${SHA:0:12}' '${SHA:0:12}'"
  t "$n refuses another branch"                   bash -c "$(blk "$f"); ! rev_is 'refs/heads/feat/x@sha1:$SHA' '$SHA'"
  t "$n refuses a prefix / suffix / whitespace"   bash -c "$(blk "$f"); ! rev_is 'xmain@sha1:$SHA' '$SHA' && ! rev_is 'refs/heads/main@sha1:${SHA}0' '$SHA' && ! rev_is 'main@sha1:$SHA ' '$SHA'"
  t "$n refuses an empty revision"                bash -c "$(blk "$f"); ! rev_is '' '$SHA'"
done
echo "RESULT $PASS/$((PASS+FAIL)) PASS"; [ $FAIL = 0 ]
