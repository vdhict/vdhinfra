#!/usr/bin/env bash
# Red mutations for the regrant mode (tsk-2026-11-17-110): each guard is broken in a scratch copy and the unit test must fail.
# Usage: hack/ops/chg-2026-11-18-001-ar011-k4-regrant-mutation.sh   (exit 0 only when the real script is green and every mutant is red)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/chg-2026-11-18-001-ar011-k4.mjs"
test_file="$here/chg-2026-11-18-001-ar011-k4-regrant.test.mjs"
scratch="$(mktemp -d)"
node --test "$test_file" >/dev/null 2>&1 || { echo "BASELINE RED"; exit 1; }
bad=0
mutate() { # name, python-style exact old string, new string
  local name="$1" old="$2" new="$3" out="$scratch/$1.mjs"
  OLD="$old" NEW="$new" python3 -I -c '
import os,sys
s=open(sys.argv[1]).read(); o=os.environ["OLD"]; n=os.environ["NEW"]
assert s.count(o)==1, "mutation target not unique: "+o
open(sys.argv[2],"w").write(s.replace(o,n))' "$src" "$out" || { echo "MUTANT $name: target missing"; bad=1; return; }
  if K4_MODULE="$out" node --test "$test_file" >/dev/null 2>&1; then echo "MUTANT $name: SURVIVED (test still green)"; bad=1; else echo "MUTANT $name: killed"; fi
}
mutate no-expect-check "if (expect !== p.regrantSha256)" "if (false)"
mutate no-env-gate "if (process.env.K4_REGRANT !== '1')" "if (false)"
mutate fresh-token-not-fatal "if (!fresh) { out({ failed: 'fresh token did not show FULL24" "if (false) { out({ failed: 'fresh token did not show FULL24"
mutate fresh-token-any-kind "fresh = await signIn(lib, ['FULL24'])" "fresh = await signIn(lib, ['K4', 'FULL24'])"
mutate post-403-counts "if (st === 201) done = true;" "if (st === 201 || st === 403) done = true;"
mutate principal-unchecked "body.principalId === BUILD_SP_ID && grantOk" "grantOk"
mutate extra-fields-ok " && Object.keys(body).length === 3" ""
mutate no-pin "if (regrantSha256 !== REGRANT_SHA256)" "if (false)"
mutate no-readback "good = nonGraph === 0 && sameSet(roles, [...FULL24]) ? good + 1 : 0;" "good = 3;"
mutate state-ignored "(state ? p.stateSha256 === state : p.stateIsFull)" "true"
echo "scratch: $scratch"
exit $bad
