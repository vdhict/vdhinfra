#!/usr/bin/env bash
# chg-2026-10-20-010 offline tests of the cloud cut-off (hack/ops/chg-2026-10-20-010-cutoff.sh).
#
#   bash hack/ops/chg-2026-10-20-010-test-cutoff.sh [<scratch-dir>]
#
# Fully offline and hermetic: per scenario a bare "origin", a repo clone, a family-ai repo with land2-cloud-on-live,
# a stub launchctl (bootstrap runs the job once, synchronously, like RunAtLoad), a stub rollback.sh that reverts
# the deploy commit in the scratch origin, a stub ops (events to a file), stub kubectl/flux and a fake token.
# The real cut-off script and the real golive.sh W2 gate are what is tested. Never touches the real repo, change
# log, launchd, cluster or GitHub. Deletes nothing (AGR-121). Exit 0 iff every case passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CUT_SRC="$HERE/chg-2026-10-20-010-cutoff.sh"; GOLIVE_SRC="$HERE/chg-2026-10-20-010-golive.sh"
PLIST_SRC="$HERE/net.vdhict.chg-2026-10-20-010-cutoff.plist"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-cutoff-XXXXXX")}"; mkdir -p "$B"
CHG=chg-2026-10-20-010; CNP=kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
t()   { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
gq()  { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

stubs() { # $1 dir
  mkdir -p "$1/bin"
  printf '#!/bin/bash\n[ "$*" = "get ns family-ai -o name" ] && echo namespace/family-ai\n' > "$1/bin/kubectl"
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/flux"
  printf '#!/bin/bash\necho fake-test-token-not-a-secret-0123456789\n' > "$1/bin/mint"
  printf '#!/bin/bash\necho "$*" >> "%s/events.log"\n' "$1" > "$1/bin/ops"
  cat > "$1/bin/launchctl" <<EOF
#!/bin/bash
D="$1/lc"; mkdir -p "\$D"
case "\$1" in
  bootstrap) l=\$(/usr/bin/plutil -extract Label raw -o - "\$3"); echo "\$3" > "\$D/loaded-\$l"
    args=(); while IFS= read -r a; do args+=("\$a"); done < <(/usr/bin/python3 -I -c 'import json,sys; [print(a) for a in json.load(sys.stdin)]' < <(/usr/bin/plutil -extract ProgramArguments json -o - "\$3"))
    XPC_SERVICE_NAME="\$l" "\${args[@]}" >> "\$D/run-\$l.log" 2>&1; echo \$? > "\$D/exit-\$l"; exit 0;;
  bootout) l="\${2##*/}"; [ -e "\$D/loaded-\$l" ] && mv "\$D/loaded-\$l" "\$D/unloaded-\$l.\$(date +%s%N)"; exit 0;;
  print) l="\${2##*/}"; [ -e "\$D/loaded-\$l" ] || exit 113; echo "path = \$(cat "\$D/loaded-\$l")"; echo "last exit code = \$(cat "\$D/exit-\$l" 2>/dev/null || echo 0)";;
esac
EOF
  chmod +x "$1/bin/"*
}

rollback_stub() { cat <<'EOF'
#!/usr/bin/env bash
# TEST STUB of chg-2026-10-20-010-rollback.sh: records the call; --execute reverts <sha> in the scratch origin
echo "$1 $2 | reason=$3 | FAMILY_AI_REPO=$FAMILY_AI_REPO" >> "$C010_TEST_DIR/rb.log"
[ "$1" = --dry-run ] && { echo "RESULT dry-run GREEN"; exit 0; }
mkdir -p "$VDH_REPO/ops/evidence/chg-2026-10-20-010"; : > "$VDH_REPO/ops/evidence/chg-2026-10-20-010/k8s-rollback-$(date -u +%Y%m%dT%H%M%S)$RANDOM-execute.txt"
case "${C010_STUB_RB:-ok}" in
  fail) exit 1;;
  ok|redafterpush) w="$C010_TEST_DIR/rbwt-$RANDOM$RANDOM"; git clone -q "$C010_TEST_DIR/origin.git" "$w" &&
     git -C "$w" -c user.name=t -c user.email=t@example.invalid revert --no-edit "$2" >/dev/null && git -C "$w" push -q origin HEAD:main
     [ "${C010_STUB_RB:-ok}" = ok ];;
esac
EOF
}

scenario() { # $1 name, $2 push-deploy (yes|no) -> sets S, SHA, TSHA, env
  S="$B/$1"; mkdir -p "$S"; stubs "$S"
  gq init --bare "$S/origin.git"; gq clone "$S/origin.git" "$S/repo" 2>/dev/null
  mkdir -p "$S/repo/ops/evidence/$CHG" "$S/repo/hack/ops" "$S/repo/kubernetes/main/apps/observability/cluster-health/app/scripts" "$(dirname "$S/repo/$CNP")"
  echo base > "$S/repo/README"; : > "$S/repo/ops/evidence/$CHG/.keep"; : > "$S/repo/changes.jsonl"
  gq -C "$S/repo" add -A; gq -C "$S/repo" commit -m base; gq -C "$S/repo" push origin HEAD:main
  cp "$CUT_SRC" "$GOLIVE_SRC" "$PLIST_SRC" "$S/repo/hack/ops/"; rollback_stub > "$S/repo/hack/ops/$CHG-rollback.sh"
  echo 'print("stub")' > "$S/repo/kubernetes/main/apps/observability/cluster-health/app/scripts/gh_app_token.py"
  echo '# stub' > "$S/repo/kubernetes/main/apps/observability/cluster-health/app/scripts/git_push.py"
  gq -C "$S/repo" add -A; gq -C "$S/repo" commit -m tooling
  echo 'kind: CiliumNetworkPolicy' > "$S/repo/$CNP"; gq -C "$S/repo" add -A; gq -C "$S/repo" commit -m wiring
  SHA=$(git -C "$S/repo" rev-parse HEAD); TSHA=$(git -C "$S/repo" rev-parse HEAD^)
  [ "$2" = yes ] && gq -C "$S/repo" push origin HEAD:main
  gq init "$S/fai"; mkdir -p "$S/fai/content"; printf '{\n  "price_confirmed": true\n}\n' > "$S/fai/content/cloudmodel.json"
  gq -C "$S/fai" add -A; gq -C "$S/fai" commit -m c; gq -C "$S/fai" branch land2-cloud-on-live; gq -C "$S/fai" checkout -b other
  export VDH_REPO="$S/repo" FAMILY_AI_SRC="$S/fai" C010_FAI_WT="$S/fai-wt" C010_STATE_DIR="$S/state" C010_INST_BASE="$S/inst" \
    C010_AGENTS_DIR="$S/agents" C010_LAUNCHCTL="$S/bin/launchctl" C010_OPS="$S/bin/ops" C010_MINT_CMD="$S/bin/mint" \
    C010_PATH_PREPEND="$S/bin" C010_SELFTEST_WAIT=5 C010_TEST_DIR="$S" C010_CHANGES="$S/repo/changes.jsonl" \
    C010_EVIDENCE_DIR="$S/repo/ops/evidence/$CHG" C010_SETTINGS="$S/settings.json" GH_APP_ID=1 GH_APP_INSTALLATION_ID=2 GH_APP_PRIVATE_KEY_FILE=/nonexistent
  unset C010_NOW C010_STUB_RB; echo '{"budget_usd": 200}' > "$S/settings.json"
}
cut() { (cd "$S/repo" && bash "$S/repo/hack/ops/$CHG-cutoff.sh" "$@"); }
fire() { local a; a=$(/usr/bin/plutil -extract ProgramArguments json -o - "$S/agents/net.vdhict.$CHG-cutoff.plist" |
           /usr/bin/python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)[1:]))'); local IFS=$'\n'; bash $a; }
nev()  { [ -e "$S/events.log" ] && wc -l < "$S/events.log" | tr -d ' ' || echo 0; }
nrb()  { if [ -e "$S/rb.log" ]; then grep -c -- '--execute' "$S/rb.log"; else echo 0; fi; }
lastev() { tail -1 "$S/events.log"; }
cnp_main() { git -C "$S/repo" fetch -q origin; git -C "$S/repo" cat-file -e "origin/main:$CNP" 2>/dev/null; }
w2event() { # $1 promo expiry [$2 promo usd]: scratch infra-ops W2 event + fresh prepaid evidence; prints the event ts
  local f="w2a-console-$RANDOM$RANDOM.json" ts; ts="2026-10-25T$(printf '%02d:%02d:%02d' $((RANDOM % 24)) $((RANDOM % 60)) $((RANDOM % 60)))Z"
  /usr/bin/python3 -I -c 'import json,sys,datetime as d; n=d.datetime.now(d.timezone.utc)
json.dump({"captured_utc":(n-d.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),"auto_reload":"off","purchased_balance_usd":0,
"invoicing":"none","org_monthly_limit_usd":200,"key_scope":"organization","key_hint_match":True,"promo_credit_usd":float(sys.argv[3]),
"promo_credit_expires_utc":sys.argv[1]}, open(sys.argv[2],"w"))' "$1" "$S/repo/ops/evidence/$CHG/$f" "${2:-200}"
  echo "{\"actor\":\"infra-ops\",\"chg\":\"$CHG\",\"event\":\"executed\",\"payload\":{\"w2_evidence\":\"ops/evidence/$CHG/$f\",\"w2_readback_by\":\"atlas\",\"w2a\":\"prepaid_autoreload_off_purchased_usd=0_org_limit_usd=200\"},\"ts\":\"$ts\"}" >> "$S/repo/changes.jsonl"
  echo "$ts"
}
# armx <promo expiry> [promo usd] : new capture + new W2 event, then arm through the real gate (sets OUT, rc, ATS)
armx() { sleep 1; ATS=$(w2event "$1" "${2:-200}"); out=$(cut arm "$SHA" --w2-event "$ATS" 2>&1); rc=$?; export OUT="$out"; }
trig() { (cd "$S/repo" && bash hack/ops/$CHG-cutoff.sh readback) | sed -n 's/.*trigger_utc=\([^ ]*\).*/\1/p'; }

# ---------------------------------------------------------------- A: arm / readback / idempotent arm / wrong commit
scenario A yes
export C010_NOW=2026-10-25T12:00:00Z; EXP_A=2026-11-13T17:42:09Z   # arbitrary: the trigger must come from the JSON
armx "$EXP_A"; A_TS="$ATS"
t "A1 arm GREEN (rc 0) via the W2 gate" bash -c "[ $rc = 0 ] && grep -q 'W2 gate GREEN: cut-off time from w2a-console-.*json promo_credit_expires_utc = $EXP_A' <<< \"\$OUT\""
t "A1 readback: loaded, trigger = the JSON's expiry $EXP_A, deploy sha, integrity ok" grep -q "loaded=yes trigger_utc=$EXP_A deploy=$SHA interval=300s last_exit=0 integrity=ok" <<< "$out"
t "A1 readback names the W2 event the trigger came from" grep -q "from w2 event $A_TS" <<< "$out"
t "A1 no constant: the script holds no 2026-11-14 date" bash -c "! grep -q '2026-11-14' '$CUT_SRC'"
t "A1 launchd self-test ran under launchd and is ok" grep -q 'selftest .*: ok launchd .*family_ai_worktree=ok .*push_auth=ok' <<< "$out"
t "A1 rendered plist lints, no placeholder left" bash -c "/usr/bin/plutil -lint -s '$S/agents/net.vdhict.$CHG-cutoff.plist' && ! grep -q @@ '$S/agents/net.vdhict.$CHG-cutoff.plist'"
t "A1 family-ai worktree on land2-cloud-on-live (main checkout stays on other)" bash -c "[ \"\$(git -C '$S/fai-wt' rev-parse --abbrev-ref HEAD)\" = land2-cloud-on-live ] && [ \"\$(git -C '$S/fai' rev-parse --abbrev-ref HEAD)\" = other ]"
t "A1 rollback --dry-run ran once with FAMILY_AI_REPO = worktree" bash -c "[ \"\$(grep -c -- '--dry-run' '$S/rb.log')\" = 1 ] && grep -q 'FAMILY_AI_REPO=$S/fai-wt' '$S/rb.log'"
t "A1 one 'cutoff armed' event: readback GREEN, trigger + source logged" bash -c "[ $(nev) = 1 ] && grep -q 'cutoff armed' '$S/events.log' && grep -q 'readback.: .GREEN' '$S/events.log' && grep -q 'trigger_utc.: .$EXP_A' '$S/events.log' && grep -q 'w2_event.: .$A_TS' '$S/events.log'"
t "A1 install pinned: SHA256SUMS covers cutoff, rollback, minter" bash -c "[ \$(wc -l < \$(ls -d '$S'/inst/*/SHA256SUMS | head -1)) = 4 ]"
sleep 1; out=$(cut arm "$SHA" --w2-event "$A_TS" 2>&1); rc=$?; export OUT="$out"
t "A2 second arm, same event: rc 0, 'already armed', no new event, no new install" bash -c "[ $rc = 0 ] && grep -q 'already armed' <<< \"\$OUT\" && [ $(nev) = 1 ] && [ \$(ls '$S/inst' | wc -l) = 1 ]"
out=$(cut arm "$TSHA" --w2-event "$A_TS" 2>&1); rc=$?; export OUT="$out"
t "A3 arm a tooling commit (does not add the CNP): REFUSED rc 2" bash -c "[ $rc = 2 ] && grep -q 'is not the commit that adds' <<< \"\$OUT\""
out=$(cut readback "$TSHA" 2>&1); rc=$?; export OUT="$out"
t "A4 readback for another sha: rc 1" [ $rc = 1 ]
# ---------------------------------------------------------------- F: fire
export C010_NOW=2026-11-13T17:42:08Z; e0=$(nev)
fire; rc=$?
t "F1 1 s before cutoff: rc 0, no rollback, no event, CNP still on main" bash -c "[ $rc = 0 ] && [ $(nrb) = 0 ] && [ $(nev) = $e0 ] && git -C '$S/repo' cat-file -e origin/main:$CNP"
export C010_NOW=$EXP_A
fire; rc=$?
t "F2 exactly at the JSON's expiry: rc 0, rollback --execute once with the armed sha + worktree" bash -c "[ $rc = 0 ] && [ $(nrb) = 1 ] && grep -q -- '--execute $SHA | reason=promo credit expiry cut-off $EXP_A' '$S/rb.log' && grep -- '--execute' '$S/rb.log' | grep -q 'FAMILY_AI_REPO=$S/fai-wt'"
t "F2 cloud CNP gone on origin/main" bash -c "! { git -C '$S/repo' fetch -q origin; git -C '$S/repo' cat-file -e origin/main:$CNP 2>/dev/null; }"
t "F2 exactly one new event: cloud off, GREEN, names rollback evidence" bash -c "[ $(nev) = $((e0+1)) ] && tail -1 '$S/events.log' | grep -q 'cloud off for profiel-3' && tail -1 '$S/events.log' | grep -q '\"result\": \"GREEN\"' && tail -1 '$S/events.log' | grep -q k8s-rollback-"
e1=$(nev); export C010_NOW=2026-11-13T17:47:09Z
fire; rc=$?
t "F3 second run after firing: rc 0, no rollback, no event (idempotent)" bash -c "[ $rc = 0 ] && [ $(nrb) = 1 ] && [ $(nev) = $e1 ]"
fire; t "F3b third run: still nothing" bash -c "[ $(nrb) = 1 ] && [ $(nev) = $e1 ]"
out=$(cut retire 2>&1); rc=$?; export OUT="$out"
t "R2 retire after firing: plist moved to _retired, unloaded, one event" bash -c "[ $rc = 0 ] && [ ! -e '$S/agents/net.vdhict.$CHG-cutoff.plist' ] && ls '$S/agents/_retired/' | grep -q cutoff && [ $(nev) = $((e1+1)) ]"

# ---------------------------------------------------------------- B: already off on main (e.g. rolled back earlier)
scenario B yes; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z
out=$(cut retire 2>&1); rc=$?; export OUT="$out"
t "R1 retire before firing: REFUSED rc 2, still armed" bash -c "[ $rc = 2 ] && [ -e '$S/agents/net.vdhict.$CHG-cutoff.plist' ]"
w="$S/manual"; gq clone "$S/origin.git" "$w"; gq -C "$w" revert --no-edit "$SHA"; gq -C "$w" push origin HEAD:main
e0=$(nev); export C010_NOW=2026-11-15T08:00:00Z
fire; rc=$?
t "B1 cloud already off on main: rc 0, no rollback, one no-op GREEN event" bash -c "[ $rc = 0 ] && [ $(nrb) = 0 ] && [ $(nev) = $((e0+1)) ] && tail -1 '$S/events.log' | grep -q 'already off on main (no-op)'"
fire; t "B2 again: nothing" bash -c "[ $(nrb) = 0 ] && [ $(nev) = $((e0+1)) ]"

# ---------------------------------------------------------------- C: rollback keeps failing -> 3 attempts, then stop
scenario C yes; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z
export C010_NOW=2026-11-14T00:00:00Z C010_STUB_RB=fail; e0=$(nev)
fire; r1=$?; fire; r2=$?; fire; r3=$?
t "C1 three failing attempts: rc 1 each, 3 rollback calls, 3 RED events" bash -c "[ $r1$r2$r3 = 111 ] && [ $(nrb) = 3 ] && [ $(nev) = $((e0+3)) ] && [ \$(tail -3 '$S/events.log' | grep -c 'attempt RED') = 3 ]"
fire; r4=$?
t "C2 4th run: no rollback call, one FAILED needs_human event" bash -c "[ $r4 = 1 ] && [ $(nrb) = 3 ] && [ $(nev) = $((e0+4)) ] && tail -1 '$S/events.log' | grep -q 'cutoff FAILED after 3 attempts' && tail -1 '$S/events.log' | grep -q needs_human"
fire; t "C3 5th run: silent (no call, no event)" bash -c "[ $(nrb) = 3 ] && [ $(nev) = $((e0+4)) ]"
t "C4 cloud CNP still on main (stub failed before push)" cnp_main

# ---------------------------------------------------------------- D: rollback pushes but its read-back is red
scenario D yes; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z
export C010_NOW=2026-11-14T00:00:00Z C010_STUB_RB=redafterpush; e0=$(nev)
fire; rc=$?
t "D1 pushed but read-back red: done (cloud off on main), event says check evidence" bash -c "[ $rc = 0 ] && [ $(nev) = $((e0+1)) ] && tail -1 '$S/events.log' | grep -q 'rollback readback RED' && [ -e '$S/state/done-$SHA' ]"

# ---------------------------------------------------------------- E: integrity
scenario E yes; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z
INST=$(ls -d "$S"/inst/*/ | head -1); echo '# tampered' >> "$INST/chg-2026-10-20-010-rollback.sh"
export C010_NOW=2026-11-14T00:00:00Z; e0=$(nev)
fire; r1=$?; fire; r2=$?
t "E1 install changed after arm: rc 1, no rollback, one integrity RED event (once per day)" bash -c "[ $r1$r2 = 11 ] && [ $(nrb) = 0 ] && [ $(nev) = $((e0+1)) ] && tail -1 '$S/events.log' | grep -q 'integrity RED'"
t "E2 readback reports integrity=fail, rc 1" bash -c "! (cd '$S/repo' && bash hack/ops/$CHG-cutoff.sh readback '$SHA' | grep -q integrity=ok)"

# ---------------------------------------------------------------- G: go-live never happened / re-deployed with another sha
scenario G no; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z
export C010_NOW=2026-11-14T00:00:00Z; e0=$(nev)
fire; rc=$?
t "G1 armed but never pushed (no CNP on main): rc 0, no rollback, no-op GREEN" bash -c "[ $rc = 0 ] && [ $(nrb) = 0 ] && tail -1 '$S/events.log' | grep -q 'already off'"
scenario G2 no; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z
w="$S/redeploy"; gq clone "$S/origin.git" "$w"; mkdir -p "$(dirname "$w/$CNP")"; echo 'kind: CiliumNetworkPolicy # v2' > "$w/$CNP"
gq -C "$w" add -A; gq -C "$w" commit -m redeploy; gq -C "$w" push origin HEAD:main
export C010_NOW=2026-11-14T00:00:00Z; e0=$(nev)
fire; rc=$?
t "G2 CNP on main from another sha: rc 1, no rollback, RED re-arm event" bash -c "[ $rc = 1 ] && [ $(nrb) = 0 ] && tail -1 '$S/events.log' | grep -q 'armed deploy is not in main'"

# ---------------------------------------------------------------- X: re-arm = new capture + new W2 event + gate GREEN
scenario X yes; export C010_NOW=2026-10-25T12:00:00Z; armx 2026-11-14T00:00:00Z; e0=$(nev)
sleep 1; out=$(cut arm "$SHA" --w2-event 2026-10-25T23:59:59Z 2>&1); rc=$?; export OUT="$out"
t "X1 re-arm with no such W2 event: REFUSED by the gate, trigger unchanged" bash -c "[ $rc = 2 ] && grep -q 'REFUSED: W2 gate' <<< \"\$OUT\" && [ \"$(trig)\" = 2026-11-14T00:00:00Z ]"
armx 2026-11-14T00:00:00Z
t "X2 new capture, same grant (monthly check): re-armed at the same time, one 're-armed' line" bash -c "[ $rc = 0 ] && [ \"$(trig)\" = 2026-11-14T00:00:00Z ] && [ $(nev) = $((e0+1)) ] && tail -1 '$S/events.log' | grep -q 'cutoff re-armed'"
armx 2026-12-14T00:00:00Z
t "X3 new grant, later expiry: trigger moves to 2026-12-14T00:00:00Z, old plist in _retired" bash -c "[ $rc = 0 ] && [ \"$(trig)\" = 2026-12-14T00:00:00Z ] && ls '$S/agents/_retired/' | grep -q cutoff"
echo '{"budget_usd": 100}' > "$S/settings.json"; armx 2026-11-10T08:00:00Z 100
t "X4 budget_usd 100 against a USD 100 grant passes; earlier expiry moves the trigger EARLIER (2026-11-10T08:00:00Z)" bash -c "[ $rc = 0 ] && [ \"$(trig)\" = 2026-11-10T08:00:00Z ]"
echo '{"budget_usd": 200}' > "$S/settings.json"; armx 2026-12-10T00:00:00Z 100
t "X5 budget_usd 200 against a USD 100 grant: REFUSED, trigger unchanged" bash -c "[ $rc = 2 ] && grep -q 'budget_usd 200 > promo_credit_usd 100' <<< \"\$OUT\" && [ \"$(trig)\" = 2026-11-10T08:00:00Z ]"
armx "$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ)"
t "X6 expired JSON (expiry 1 min ago, real clock): REFUSED by the gate, trigger unchanged" bash -c "[ $rc = 2 ] && grep -q 'promotional credit expired' <<< \"\$OUT\" && [ \"$(trig)\" = 2026-11-10T08:00:00Z ]"
t "X7 one change-log line per re-arm (X2, X3, X4), none for refusals" bash -c "[ \$(grep -c 'cutoff re-armed' '$S/events.log') = 3 ] && [ $(nev) = $((e0+3)) ]"
export C010_NOW=2026-11-10T07:59:59Z; fire
t "X8 1 s before the re-armed trigger: no rollback" bash -c "[ $(nrb) = 0 ]"
export C010_NOW=2026-11-10T08:00:00Z; fire
t "X9 at the re-armed trigger: rollback --execute once" bash -c "[ $(nrb) = 1 ] && grep -q 'cut-off 2026-11-10T08:00:00Z' '$S/rb.log'"

# ---------------------------------------------------------------- P: arming after the cutoff is refused
scenario P yes; export C010_NOW=2026-11-14T00:00:01Z
armx 2026-11-14T00:00:00Z
t "P1 arm after the cutoff: REFUSED rc 2, nothing loaded" bash -c "[ $rc = 2 ] && grep -q 'is not in the future' <<< \"\$OUT\" && [ ! -e '$S/agents/net.vdhict.$CHG-cutoff.plist' ]"

# ---------------------------------------------------------------- L: launchd-selftest (test label, loaded then unloaded)
scenario L yes; export C010_NOW=2026-10-25T12:00:00Z
out=$(cut launchd-selftest "$SHA" 2>&1); rc=$?; export OUT="$out"
t "L1 launchd-selftest GREEN, test label unloaded + moved to _retired, real label untouched" bash -c "[ $rc = 0 ] && grep -q 'launchd-selftest GREEN' <<< \"\$OUT\" && [ ! -e '$S/agents/net.vdhict.$CHG-cutoff-test.plist' ] && [ ! -e '$S/agents/net.vdhict.$CHG-cutoff.plist' ] && [ ! -e '$S/lc/loaded-net.vdhict.$CHG-cutoff-test' ]"
t "L2 launchd-selftest ran no rollback and logged no event" bash -c "[ $(nrb) = 0 ] && [ $(nev) = 0 ]"

echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"
[ $FAIL = 0 ]
