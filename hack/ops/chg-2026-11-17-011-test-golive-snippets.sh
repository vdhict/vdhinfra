#!/usr/bin/env bash
# shellcheck disable=SC2034  # the stub variables are read by the driver lines this harness evals
# chg-2026-11-17-011 local test of the go-live driver's F4 / L1 / L7 / F6 snippets (Argus 21-11) with stubbed kubectl and
# g4p: no cluster, no network, no write outside a fresh mktemp dir. The R2/R5 chk lines are eval'd verbatim from the
# driver source. Usage: bash hack/ops/chg-2026-11-17-011-test-golive-snippets.sh [driver]
#   -> "DRIVER SNIPPET TESTS n/n passed", rc 0
set -uo pipefail
D="${1:-$(cd "$(dirname "$0")" && pwd)/chg-2026-11-17-011-golive.sh}"; NS=family-ai; CHG=chg-2026-11-17-011; SVC=10000; PASS=0; FAIL=0; RED=0; WHY=""; EV=/dev/null; CACHE=$(mktemp -d)
eval "$(grep -E '^(own_svc|jget|log|chk|import_ok)\(\) ' "$D")"
eval "$(sed -n '/^root_free() {/,/^  jq -e/p' "$D")"
eval "$(sed -n '/^logs_count() {/,/^  printf/p' "$D")"
t() { if ( eval "$2" ) >/dev/null 2>&1; then r=0; else r=1; fi; if [ "$r" = "$3" ]; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
GOOD='{"files":{"cloud-off.json":{"uid":10000,"gid":10000,"mode":"644","type":"reg"},"cloud-transitions.jsonl":{"uid":10000,"gid":10000,"mode":"600","type":"reg"},"month.json":{"uid":10000,"gid":10000,"mode":"644","type":"reg"}}}'
t "own_svc all 10000 regular -> ok" "own_svc '$GOOD'" 0
t "own_svc one root-owned file -> fail" "own_svc '$(jq -c '.files["cloud-off.json"].uid=0' <<<"$GOOD")'" 1
t "own_svc gid 0 -> fail" "own_svc '$(jq -c '.files["cloud-transitions.jsonl"].gid=0' <<<"$GOOD")'" 1
t "own_svc symlink -> fail" "own_svc '$(jq -c '.files["cloud-off.json"].type="lnk"' <<<"$GOOD")'" 1
t "own_svc lstat error entry -> fail" "own_svc '$(jq -c '.files["cloud-off.json"]={"error":"PermissionError"}' <<<"$GOOD")'" 1
t "own_svc no month.json -> fail" "own_svc '$(jq -c 'del(.files["month.json"])' <<<"$GOOD")'" 1
t "own_svc no files key (old helper) -> fail" "own_svc '{\"off\":false}'" 1
t "own_svc empty input -> fail" "own_svc ''" 1
kubectl() { case "$MOCK" in lines) printf 'a\nTraceback x\nb\n';; clean) printf 'a\nb\n';; empty) :;; fail) return 1;; esac; }
MOCK=clean; t "logs_count clean logs -> rc0 + 0" "[ \"\$(logs_count \"'p' -c app\" 'Traceback')\" = 0 ]" 0
MOCK=lines; t "logs_count one hit -> 1" "[ \"\$(logs_count \"'p' -c app\" 'Traceback')\" = 1 ]" 0
MOCK=empty; t "logs_count empty logs -> rc 1" "logs_count \"'p' -c app\" 'Traceback'" 1
MOCK=fail; t "logs_count kubectl failure -> rc 1" "logs_count \"'p' -c app\" 'Traceback'" 1
MOCK=empty; t "logs_count allow-empty, empty logs -> rc0 + 0 (F5)" "[ \"\$(logs_count \"'p' -c app\" 'Traceback' allow-empty)\" = 0 ]" 0
MOCK=fail; t "logs_count allow-empty, kubectl failure -> rc 1 (F5)" "logs_count \"'p' -c app\" 'Traceback' allow-empty" 1
MOCK=lines; t "logs_count allow-empty, one hit -> 1 (F5)" "[ \"\$(logs_count \"'p' -c app\" 'Traceback' allow-empty)\" = 1 ]" 0
P3=hermes-profiel-3-x
# run the driver's own chk lines verbatim (eval of the exact source line), judge by RED
line_of() { grep -m1 -F "$1" "$D"; }
runchk() { RED=0; eval "$1" >/dev/null 2>&1; echo $RED; }
R2LINE=$(line_of 'chk "R2 no Traceback'); R5LINE=$(line_of "chk \"R5 no 'calls_while_off='")
for m in clean:0 lines:1 empty:1 fail:1; do MOCK=${m%%:*}; t "R2 chk line with logs=$MOCK -> RED ${m##*:}" "[ \"\$(runchk \"\$R2LINE\")\" = ${m##*:} ]" 0; done
pod() { echo "hermes-profiel-$1-x"; }; PUSH_B_ISO=2026-11-22T07:00:00Z
# F5: R5 reads a --since-time window; an idle pod's empty window is 0 hits (GREEN), only a kubectl error is RED
for m in clean:0 empty:0 fail:1; do MOCK=${m%%:*}; t "R5 chk line with logs=$MOCK -> RED ${m##*:}" "[ \"\$(runchk \"\$R5LINE\")\" = ${m##*:} ]" 0; done
# shellcheck disable=SC2329  # invoked by the eval'd driver R5 line
kubectl() { case "$MOCK" in cwo) printf 'x calls_while_off=1\n';; *) printf 'a\n';; esac; }
MOCK=cwo; t "R5 chk line with a calls_while_off line -> RED 1" "[ \"\$(runchk \"\$R5LINE\")\" = 1 ]" 0
# per pod (the args carry the pod name): MOCK=<p2>/<p3>
kubectl() { local w; case "$*" in *profiel-2-x*) w=${MOCK%%/*};; *) w=${MOCK##*/};; esac
  case "$w" in empty) :;; clean) printf 'a\n';; cwo) printf 'x calls_while_off=1\n';; fail) return 1;; esac; }
for m in empty/empty:0 empty/clean:0 clean/empty:0 fail/empty:1 empty/fail:1 clean/fail:1 empty/cwo:1 cwo/empty:1; do
  MOCK=${m%%:*}; t "R5 chk line with p2/p3 logs=$MOCK -> RED ${m##*:}" "[ \"\$(runchk \"\$R5LINE\")\" = ${m##*:} ]" 0; done
g4p() { case "$DROP" in ok) echo '{"drop":"ok","uid":10000,"gid":10000,"groups":[10000]}';; root) echo '{"drop":"ok","uid":0,"gid":0}';; err) echo '{"error":"privilege drop failed"}'; return 1;; esac; }
P2=hermes-profiel-2-x
DBODY=$(grep -A1 'chk "F2 in-pod helper drops' "$D" | tail -1 | sed -E 's/^ *"//; s/"; done$//')
n=2; DBODY=$(eval "printf '%s' \"$DBODY\"")
for m in ok:0 root:1 err:1; do DROP=${m%%:*}; t "drop-check chk with helper=$DROP -> rc ${m##*:}" "$DBODY" "${m##*:}"; done
for c in '{"off":true,"triggers":[],"actions":{}}:0' '{"error":"PermissionError","detail":"x"}:1' '{"off":true,"triggers":[{"t":"transitions_unreadable"}]}:1' '{"off":false,"triggers":[]}:1' ':1'; do
  LR1=${c%:*}; t "3a lock-run chk with '${LR1:0:40}' -> rc ${c##*:}" "[ \"\$(jq -c '[.error, .off, .triggers]' <<<'$LR1')\" = '[null,true,[]]' ]" "${c##*:}"; done
# ---- F6 (inc-2026-11-21-001): no root-owned bytecode/temp under the seed-once plugin dirs
RO_OK='{"errors":0,"first":[],"per_root":{"plugins":12,".plugins.old":0},"plugins_present":true,"root_owned":0,"scanned":12}'
# shellcheck disable=SC2329  # invoked by root_free and the eval'd driver lines
g4p() { case "$2" in
    root-owned) case "$RO" in rc1) echo '{"error":"x"}'; return 1;; *) printf '%s\n' "$RO";; esac;;
    import) case "$IMP" in rc1) echo '{"error":"deployed plugin is not the pin"}'; return 1;; *) printf '%s\n' "$IMP";; esac;;
    *) return 1;; esac; }
for c in "$RO_OK:0" \
  "$(jq -c '.root_owned=1 | .per_root.plugins=1 | .first=["plugins/model-providers/family-cloud/__pycache__/__init__.cpython-311.pyc"]' <<<"$RO_OK"):1" \
  "$(jq -c '.root_owned=2 | .per_root[".plugins.old"]=2' <<<"$RO_OK"):1" \
  "$(jq -c '.errors=1' <<<"$RO_OK"):1" "$(jq -c '.plugins_present=false' <<<"$RO_OK"):1" "$(jq -c '.scanned=0' <<<"$RO_OK"):1" \
  '{"state":"old helper, no fields"}:1' ':1' 'rc1:1'; do
  RO=${c%:*}; t "F6 root_free with root-owned=${RO:0:60} -> rc ${c##*:}" "root_free hermes-profiel-3-x" "${c##*:}"; done
IOK='{"import":"ok","as_uid":10000,"bytecode":"off","has":["trip_cloud_off"]}'
for c in "$IOK:0" "$(jq -c '.as_uid=0' <<<"$IOK"):1" "$(jq -c '.bytecode="on"' <<<"$IOK"):1" '{"import":"ok","has":[]}:1' \
  '{"error":"deployed plugin is not the pin"}:1' ':1'; do
  IMP=${c%:*}; t "F6 import_ok with '${IMP:0:50}' -> rc ${c##*:}" "import_ok '$IMP'" "${c##*:}"; done
# the driver's own chk lines, verbatim
R2IMP=$(line_of 'chk "R2 family-cloud module imports'); R2F6=$(line_of 'chk "R2 F6 p3: 0 uid-0'); PREF6=$(line_of 'chk "F6 p3: 0 uid-0')
RBF6=$(line_of 'chk "rollback read-back (F6)'); RBHINT=$(line_of 'case "$WHY" in *"rollback read-back (F6)"')
t "F6 the four new chk lines exist in the driver" "[ -n \"\$R2IMP\" ] && [ -n \"\$R2F6\" ] && [ -n \"\$PREF6\" ] && [ -n \"\$RBF6\" ] && [ -n \"\$RBHINT\" ]" 0
for m in ok:0 root:1 bc:1 old:1 rc1:1; do
  case ${m%%:*} in ok) IMP=$IOK;; root) IMP=$(jq -c '.as_uid=0' <<<"$IOK");; bc) IMP=$(jq -c '.bytecode="on"' <<<"$IOK");; old) IMP='{"import":"ok"}';; rc1) IMP=rc1;; esac
  t "F6 R2 import chk line with helper=${m%%:*} -> RED ${m##*:}" "[ \"\$(runchk \"\$R2IMP\")\" = ${m##*:} ]" 0; done
RO_ROOT=$(jq -c '.root_owned=1' <<<"$RO_OK")
for L in R2F6 PREF6 RBF6; do
  for m in ok:0 root:1 rc1:1; do case ${m%%:*} in ok) RO=$RO_OK;; root) RO=$RO_ROOT;; rc1) RO=rc1;; esac
    t "F6 $L chk line with root-owned=${m%%:*} -> RED ${m##*:}" "[ \"\$(runchk \"\$$L\")\" = ${m##*:} ]" 0; done; done
hint() { RED=0; WHY=""; eval "$RBF6" >/dev/null 2>&1; eval "$RBHINT"; }
RO=$RO_ROOT; t "F6 rollback: a uid-0 name -> the chown hint is logged" "hint | grep -q 'chown it to 10000'" 0
RO=$RO_OK; t "F6 rollback: clean -> no hint" "hint | grep -q 'chown'" 1
# static: every in-pod python the driver runs (kubectl exec ... python) carries -I -B; at least the 4 known sites
EXECPY=$(grep -E 'kubectl[^#]*exec[^#]*python' "$D")
t "F6 in-pod python exec sites found (g4p, tcp, 2x OWUI turn)" "[ \"\$(printf '%s\n' \"\$EXECPY\" | grep -c .)\" -ge 4 ]" 0
t "F6 every in-pod python exec runs with -I -B" "! printf '%s\n' \"\$EXECPY\" | grep -v -E 'python3? -I -B ' | grep -q ." 0
t "F6 g4p pipes the helper into python -I -B -" "grep -E '^g4p\(\) ' '$D' | grep -q -- 'python -I -B - '" 0
t "L7: --go without --dormant-ack exits 2 before any work" "cd '$CACHE' && bash '$D' --go --commit-a $(printf 'a%.0s' {1..40}) --commit-b $(printf 'b%.0s' {1..40}) 2>&1 | grep -q 'needs --dormant-ack'; [ \${PIPESTATUS[0]} = 2 ]" 0
echo "DRIVER SNIPPET TESTS $PASS/$((PASS+FAIL)) passed"; [ "$FAIL" = 0 ]
