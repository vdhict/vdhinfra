#!/usr/bin/env bash
# shellcheck disable=SC2034  # the stub variables are read by the driver lines this harness evals
# chg-2026-11-17-011 local test of the go-live driver's F4 / L1 / L7 snippets (Argus 21-11) with stubbed kubectl and
# g4p: no cluster, no network, no write outside a fresh mktemp dir. The R2/R5 chk lines are eval'd verbatim from the
# driver source. Usage: bash hack/ops/chg-2026-11-17-011-test-golive-snippets.sh [driver]
#   -> "DRIVER SNIPPET TESTS n/n passed", rc 0
set -uo pipefail
D="${1:-$(cd "$(dirname "$0")" && pwd)/chg-2026-11-17-011-golive.sh}"; NS=family-ai; SVC=10000; PASS=0; FAIL=0; RED=0; WHY=""; EV=/dev/null; CACHE=$(mktemp -d)
eval "$(grep -E '^(own_svc|jget|log|chk)\(\) ' "$D")"
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
P3=hermes-profiel-3-x
# run the driver's own chk lines verbatim (eval of the exact source line), judge by RED
line_of() { grep -m1 -F "$1" "$D"; }
runchk() { RED=0; eval "$1" >/dev/null 2>&1; echo $RED; }
R2LINE=$(line_of 'chk "R2 no Traceback'); R5LINE=$(line_of "chk \"R5 no 'calls_while_off='")
for m in clean:0 lines:1 empty:1 fail:1; do MOCK=${m%%:*}; t "R2 chk line with logs=$MOCK -> RED ${m##*:}" "[ \"\$(runchk \"\$R2LINE\")\" = ${m##*:} ]" 0; done
pod() { echo "hermes-profiel-$1-x"; }; PUSH_B_ISO=2026-11-22T07:00:00Z
for m in clean:0 empty:1 fail:1; do MOCK=${m%%:*}; t "R5 chk line with logs=$MOCK -> RED ${m##*:}" "[ \"\$(runchk \"\$R5LINE\")\" = ${m##*:} ]" 0; done
kubectl() { case "$MOCK" in cwo) printf 'x calls_while_off=1\n';; *) printf 'a\n';; esac; }
MOCK=cwo; t "R5 chk line with a calls_while_off line -> RED 1" "[ \"\$(runchk \"\$R5LINE\")\" = 1 ]" 0
g4p() { case "$DROP" in ok) echo '{"drop":"ok","uid":10000,"gid":10000,"groups":[10000]}';; root) echo '{"drop":"ok","uid":0,"gid":0}';; err) echo '{"error":"privilege drop failed"}'; return 1;; esac; }
P2=hermes-profiel-2-x
DBODY=$(grep -A1 'chk "F2 in-pod helper drops' "$D" | tail -1 | sed -E 's/^ *"//; s/"; done$//')
n=2; DBODY=$(eval "printf '%s' \"$DBODY\"")
for m in ok:0 root:1 err:1; do DROP=${m%%:*}; t "drop-check chk with helper=$DROP -> rc ${m##*:}" "$DBODY" "${m##*:}"; done
for c in '{"off":true,"triggers":[],"actions":{}}:0' '{"error":"PermissionError","detail":"x"}:1' '{"off":true,"triggers":[{"t":"transitions_unreadable"}]}:1' '{"off":false,"triggers":[]}:1' ':1'; do
  LR1=${c%:*}; t "3a lock-run chk with '${LR1:0:40}' -> rc ${c##*:}" "[ \"\$(jq -c '[.error, .off, .triggers]' <<<'$LR1')\" = '[null,true,[]]' ]" "${c##*:}"; done
t "L7: --go without --dormant-ack exits 2 before any work" "cd '$CACHE' && bash '$D' --go --commit-a $(printf 'a%.0s' {1..40}) --commit-b $(printf 'b%.0s' {1..40}) 2>&1 | grep -q 'needs --dormant-ack'; [ \${PIPESTATUS[0]} = 2 ]" 0
echo "DRIVER SNIPPET TESTS $PASS/$((PASS+FAIL)) passed"; [ "$FAIL" = 0 ]
