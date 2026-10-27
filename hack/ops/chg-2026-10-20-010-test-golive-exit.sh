#!/usr/bin/env bash
# chg-2026-10-20-010 offline test (attempt-5 safety defect, 27-10): after the deploy push golive.sh must never end
# without its rollback unless it reached GREEN.
#
#   bash hack/ops/chg-2026-10-20-010-test-golive-exit.sh [<scratch-dir>]
#   C010_GOLIVE=<path> C010_GOSESSION=<path> ...   # run the same cases against another golive/go-session (pre-fix)
#
# Attempt 5: the C6/(c) check body `for d in $D6; do [ $d -gt 0 ] || exit 1; done` was eval'd by chk() in golive's
# own shell, so its `exit 1` ended golive before gate "C6/W7" -> rollback() never ran, cloud stayed on until a manual
# rollback. Sources the real chk(), the c010-auth block (rollback), gate() and the c010-exitguard block of golive.sh,
# plus the real C6/(c) check line verbatim; stubs rollback.sh, owui-c4.sh and the token minter. Every red after the
# push (each gate after `deploy_push`, an exit inside a check body, a stray exit, set -u, SIGTERM) must invoke
# rollback.sh exactly once; GREEN and pre-push reds must not. Also the c010-gs-fallback block of go-session.sh.
# No network, no cluster, no real token. Deletes nothing (AGR-121). Exit 0 iff all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CHG=chg-2026-10-20-010
GOLIVE="${C010_GOLIVE:-$HERE/$CHG-golive.sh}"; GS="${C010_GOSESSION:-$HERE/$CHG-go-session.sh}"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-golive-exit-XXXXXX")}"; mkdir -p "$B/bin" "$B/hack/ops" "$B/cache"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
SHAX=0123456789abcdef0123456789abcdef01234567

cat > "$B/bin/mint" <<'EOF'
#!/bin/bash
printf 'fake-test-token-exit-not-a-secret-xyz'
EOF
cat > "$B/bin/revoke" <<'EOF'
#!/bin/bash
cat >/dev/null
EOF
cat > "$B/hack/ops/$CHG-rollback.sh" <<EOF
#!/bin/bash
echo "rollback.sh \$1 \$2 reason=\$3" >> "\$C010_RB_LOG"
EOF
cat > "$B/hack/ops/$CHG-owui-c4.sh" <<EOF
#!/bin/bash
echo "owui-c4 \$1" >> "\$C010_RB_LOG"
EOF
chmod +x "$B/bin/"* "$B/hack/ops/"*

# the pieces of the real golive.sh
{ echo 'set -uo pipefail'
  echo 'log() { echo "$*" >> "$EV"; }'
  echo 'RED=0; PUSHED=""; C4STATE=""; CANARY_UID=""; OWUI_ADMIN_KEY=x-not-a-secret'
  echo 'c4_state_ok() { return 1; }'
  grep '^chk() ' "$GOLIVE"
  sed -n '/^# >>> c010-auth/,/^# <<< c010-auth/p' "$GOLIVE"
  grep '^gate() ' "$GOLIVE"
  sed -n '/^# >>> c010-exitguard/,/^# <<< c010-exitguard/p' "$GOLIVE"
} > "$B/prelude.sh"
C6C=$(grep -F 'chk "C6/(c) month.json rose on each of the 3 cloud turns"' "$GOLIVE")

N=0
run() { # $1 = scenario snippet; sets RC, RBN (rollback.sh calls), EVF (evidence file)
  N=$((N+1)); EVF="$B/ev-$N.txt"; RB="$B/rb-$N.log"; : > "$RB"; : > "$EVF"
  ( cd "$B" && env -i PATH="/usr/bin:/bin" HOME="$B" C010_RB_LOG="$RB" C010_MINT_CMD="$B/bin/mint" C010_REVOKE_CMD="$B/bin/revoke" \
      bash -c "CACHE='$B/cache'; EV='$EVF'; HACK='$B/hack'; CHG=$CHG; SHA=$SHAX; SRC='$B'; MODE=--go
. '$B/prelude.sh'
cleanup() { echo cleanup >> \"\$C010_RB_LOG\"; }; CLEANUP_HOOK=cleanup   # as registered at C6
$1" ) >/dev/null 2>&1
  RC=$?; RBN=$(grep -c '^rollback.sh --execute' "$RB"); CLN=$(grep -c '^cleanup' "$RB")
}

# ---- static
t "S1 chk() runs the check body in a subshell" bash -c "grep -q '^chk() { if ( eval \"\$2\" )' '$GOLIVE'"
t "S2 the exit guard block exists and is installed before the deploy push" bash -c "
  g=\$(grep -n '^trap on_exit EXIT' '$GOLIVE' | cut -d: -f1); p=\$(grep -n '^deploy_push ||' '$GOLIVE' | cut -d: -f1)
  [ -n \"\$g\" ] && [ -n \"\$p\" ] && [ \"\$g\" -lt \"\$p\" ]"
t "S3 exactly one EXIT trap in golive.sh (nothing replaces the guard, e.g. no 'trap cleanup EXIT')" bash -c "[ \"\$(grep -cE '^[[:space:]]*trap .*EXIT' '$GOLIVE')\" = 1 ]"
t "S4 GO_FINISHED=1 set exactly once, on the line after gate \"C7\"" bash -c "
  [ \"\$(grep -c '^GO_FINISHED=1' '$GOLIVE')\" = 1 ] && grep -A1 '^gate \"C7\"' '$GOLIVE' | tail -1 | grep -q '^GO_FINISHED=1'"
t "S5 go-session.sh has the c010-gs-fallback block (rolls back when the deploy is still on main)" bash -c "
  sed -n '/# >>> c010-gs-fallback/,/# <<< c010-gs-fallback/p' '$GS' | grep -q 'rollback_all'"

# ---- the attempt-5 failure, verbatim
run "PUSHED=$SHAX; D6=' 0 0 0'
$C6C
echo alive >> \"\$C010_RB_LOG\"
gate \"C6/W7\""
t "E1 real C6/(c) check with deltas 0 0 0 after the push: golive survives the check (did not exit inside chk)" grep -q '^alive' "$RB"
t "E1 ... and gate \"C6/W7\" runs rollback.sh exactly once, rc 1" bash -c "[ $RBN = 1 ] && [ $RC = 1 ] && grep -q 'ROLLBACK: C6/W7' '$EVF'"
t "E1 ... and the canary cleanup still ran" bash -c "[ $CLN = 1 ]"

run "PUSHED=$SHAX
chk 'a check body that exits' 'exit 1'
echo alive >> \"\$C010_RB_LOG\"; echo \"RED=\$RED\" >> \"\$C010_RB_LOG\""
t "E2 a check body with 'exit 1' marks RED and returns (golive continues)" bash -c "grep -q '^alive' '$RB' && grep -q '^RED=1' '$RB'"
t "E2 ... and the script end without a gate still rolls back (exit guard), exactly once" bash -c "[ $RBN = 1 ] && [ $RC != 0 ] && grep -q 'exit guard' '$EVF'"

# ---- a red at every gate after the push
GATES=$(awk '/^deploy_push \|\|/{p=1} p && /^gate "/{sub(/^gate "/,""); sub(/".*/,""); print}' "$GOLIVE")
t "E3 golive.sh has gates after the push (incl. C6/W7 and C7)" bash -c "printf '%s\n' \"$GATES\" | grep -qx 'C6/W7' && printf '%s\n' \"$GATES\" | grep -qx 'C7'"
while IFS= read -r g; do
  [ -n "$g" ] || continue
  run "PUSHED=$SHAX
chk 'injected red' 'false'
gate \"$g\"
echo after-gate >> \"\$C010_RB_LOG\""
  t "E3 red at gate \"$g\": rollback.sh exactly once, rc 1, golive stops there, cleanup ran" \
    bash -c "[ $RBN = 1 ] && [ $RC = 1 ] && ! grep -q '^after-gate' '$RB' && [ $CLN = 1 ] && grep -qF 'ROLLBACK: $g' '$EVF'"
done <<< "$GATES"

# ---- other ways to end after the push
run "PUSHED=$SHAX; exit 3"
t "E4 stray 'exit 3' after the push: exit guard runs rollback.sh once, rc stays 3, cleanup ran" bash -c "[ $RBN = 1 ] && [ $RC = 3 ] && [ $CLN = 1 ]"
run "PUSHED=$SHAX; echo \"\$C010_UNBOUND_VAR\""
t "E5 set -u unbound variable after the push: exit guard rolls back once, rc != 0" bash -c "[ $RBN = 1 ] && [ $RC != 0 ]"
run "PUSHED=$SHAX; kill -TERM \$\$; sleep 5; echo not-reached >> \"\$C010_RB_LOG\""
t "E6 SIGTERM after the push: exit guard rolls back once, rc 143" bash -c "[ $RBN = 1 ] && [ $RC = 143 ] && ! grep -q not-reached '$RB'"
run "PUSHED=$SHAX; exit 0"
t "E7 exit 0 after the push WITHOUT GREEN: still rolled back, rc forced to 1" bash -c "[ $RBN = 1 ] && [ $RC = 1 ]"

# ---- must NOT roll back
run "PUSHED=$SHAX; gate C7; GO_FINISHED=1; exit 0"
t "N1 GREEN (GO_FINISHED after gate C7): no rollback, rc 0, cleanup ran" bash -c "[ $RBN = 0 ] && [ $RC = 0 ] && [ $CLN = 1 ]"
run "chk 'injected red' 'false'; gate preflight"
t "N2 red before the push: no rollback, rc 1, 'nothing pushed'" bash -c "[ $RBN = 0 ] && [ $RC = 1 ] && grep -q 'nothing pushed' '$EVF'"
run "exit 2"
t "N3 any exit before the push: no rollback, rc kept" bash -c "[ $RBN = 0 ] && [ $RC = 2 ]"
run "PUSHED=$SHAX; chk 'injected red' 'false'; gate C7"
t "N4 gate rollback then exit: the exit guard does NOT roll back a second time" bash -c "[ $RBN = 1 ]"

# ---- go-session fallback block
mkdir -p "$B/gs"; /usr/bin/git init -q --bare "$B/gs/origin.git"; /usr/bin/git clone -q "$B/gs/origin.git" "$B/gs/src" 2>/dev/null
G() { /usr/bin/git -C "$B/gs/src" -c user.name=t -c user.email=t@example.invalid "$@"; }
G commit -q --allow-empty -m base; G push -q origin HEAD:refs/heads/main
CNPF=kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml
mkdir -p "$B/gs/src/$(dirname $CNPF)"; echo 'kind: CiliumNetworkPolicy' > "$B/gs/src/$CNPF"; G add -A; G commit -q -m deploy
DSHA=$(G rev-parse HEAD)
sed -n '/# >>> c010-gs-fallback/,/# <<< c010-gs-fallback/p' "$GS" > "$B/gs/block.sh"
cat > "$B/bin/kubectl" <<EOF
#!/bin/bash
[ -e "$B/gs/cnp-live" ]
EOF
chmod +x "$B/bin/kubectl"
gsrun() { : > "$B/gs/out"; PATH="$B/bin:/usr/bin:/bin" bash -c "SRC='$B/gs/src'; SHA=$DSHA; NS=family-ai; GRC=1; RED=1
log() { echo \"\$*\" >> '$B/gs/out'; }; okl() { log \"  ok   \$*\"; }; red() { log \"  RED  \$*\"; }
rollback_all() { echo \"rollback_all \$1\" >> '$B/gs/out'; }
. '$B/gs/block.sh'" >/dev/null 2>&1; }
G push -q origin HEAD:refs/heads/main; : > "$B/gs/cnp-live"; gsrun
t "F1 golive red, deploy on origin/main with the CNP file: go session calls rollback_all" grep -q '^rollback_all ' "$B/gs/out"
G revert --no-edit HEAD >/dev/null; G push -q origin HEAD:refs/heads/main; mv "$B/gs/cnp-live" "$B/gs/cnp-live.was"; gsrun
t "F2 deploy reverted on main and CNP absent: no rollback_all, cloud-off ok line" bash -c "! grep -q '^rollback_all' '$B/gs/out' && grep -q 'ok   cloud off' '$B/gs/out'"
mv "$B/gs/cnp-live.was" "$B/gs/cnp-live"; gsrun
t "F3 reverted on main but CNP still live: no second rollback, RED line" bash -c "! grep -q '^rollback_all' '$B/gs/out' && grep -q 'RED  CNP hermes-profiel-3-cloud still present' '$B/gs/out'"

t "T1 no token value in any evidence file" bash -c "! grep -rq 'fake-test-token' '$B'/ev-*.txt"
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
