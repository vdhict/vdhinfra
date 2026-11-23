#!/usr/bin/env bash
# shellcheck disable=SC2034  # the stub variables are read by the driver lines this harness evals
# chg-2026-11-17-011 local test of the go-live driver's F4 / L1 / L7 / F6 / F7 / F8 snippets (Argus 21-11) with stubbed kubectl and
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
# ---- F7 (Argus 22-11 go RED): G4 3d waits for + requires FamilyCloudMoneyCandidate BEFORE swap-prev; exact alert set; this run's cleared-g4 tag
eval "$(grep -E '^gall\(\) ' "$D")"; G4ISO=2026-11-22T07:00:00Z
al() { local a; for a in "$@"; do printf '{"alert":"%s","severity":"%s"}\n' "${a%%:*}" "$( [ "${a#*:}" = "$a" ] && echo warning || echo "${a#*:}")"; done; }
# shellcheck disable=SC2329  # invoked by the eval'd driver lines
alerts_since() { printf '%s' "$ALERTS"; }
D3LINE=$(grep -A1 -F 'chk "3d alert: billing same_month_200' "$D" | tail -2 | sed 's/ \\$//' | tr '\n' ' ')
TEAMLINE=$(grep -A1 -F 'chk "alert_team_only:' "$D" | tail -2 | sed 's/ \\$//' | tr '\n' ' ')
t "F7 the 3d alert chk and the alert_team_only chk exist in the driver" "[ -n \"\$D3LINE\" ] && [ -n \"\$TEAMLINE\" ]" 0
for c in "Off NotMoney On:1:3d" "Off MoneyCandidate On:0:3d" "Off On:1:3d" "MoneyCandidate MoneyCandidate:1:3d" "Off MoneyCandidate MoneyReopen:1:3d" \
         "Off NotMoney On:1:team" "Off MoneyCandidate On:0:team" "Off On:1:team" "Off MoneyCandidate MoneyCandidate On:1:team" "Off MoneyCandidate On Extra:1:team"; do
  seq=${c%%:*}; rest=${c#*:}; want=${rest%%:*}; which=${rest#*:}; args=()
  for w in $seq; do case $w in Off) args+=(FamilyCloudOff);; On) args+=(FamilyCloudOn);; MoneyCandidate) args+=(FamilyCloudMoneyCandidate);; MoneyReopen) args+=(FamilyCloudMoneyReopen);; NotMoney) args+=(FamilyCloudSameMonth200NotMoney);; Extra) args+=(FamilyCloudSomethingElse);; esac; done
  ALERTS=$(al "${args[@]}"); L=$D3LINE; [ "$which" = team ] && L=$TEAMLINE
  t "F7 $which chk with {$seq} -> RED $want" "[ \"\$(runchk \"\$L\")\" = $want ]" 0; done
ALERTS=$(al FamilyCloudOff FamilyCloudMoneyCandidate FamilyCloudOn:critical); t "F7 team chk with a critical alert -> RED 1" "[ \"\$(runchk \"\$TEAMLINE\")\" = 1 ]" 0
ALERTS=$(al FamilyCloudOff FamilyCloudMoneyCandidate:critical FamilyCloudOn); t "F7 team chk with a critical MoneyCandidate -> RED 1" "[ \"\$(runchk \"\$TEAMLINE\")\" = 1 ]" 0
ALERTS=$(al FamilyCloudOff FamilyCloudMoneyCandidate FamilyCloudOn); t "F7 the 3d alert line is not bypassed by a MoneyCandidate arriving with an earlier Off (once)" "[ \"\$(runchk \"\$D3LINE\")\" = 0 ]" 0
# static order: the MoneyCandidate wait precedes swap-prev, the waitfor and the gate sit between probe 1's gate and the swap
WL=$(grep -n 'waitfor 420 "alerts_since .\$G4ISO. | gall FamilyCloudMoneyCandidate"' "$D" | head -1 | cut -d: -f1); SL=$(grep -n 'swap-prev "\$SWTAG"' "$D" | head -1 | cut -d: -f1)
GL=$(grep -n 'gate "G4 3d alert" R4' "$D" | head -1 | cut -d: -f1)
t "F7 static: MoneyCandidate waitfor (l.$WL) precedes swap-prev (l.$SL), its gate (l.$GL) too" "[ -n \"\$WL\" ] && [ -n \"\$SL\" ] && [ \"\$WL\" -lt \"\$SL\" ] && [ \"\$GL\" -gt \"\$WL\" ] && [ \"\$GL\" -lt \"\$SL\" ]" 0
t "F7 static: exactly one swap-prev call, no other date-stamped inline tag" "[ \"\$(grep -c 'g4p \"\$P3\" swap-prev' '$D')\" = 1 ]" 0
# 3e this-run tag: an old archive cleared-g4-<old> next to this run's tag is GREEN; only the old tag (this run's missing) is RED
E3LINE=$(line_of 'chk "3e off state gone, both archives present"'); LB='{}'; SWTAG=20261123T080000Z
LAOK="$(jq -nc --arg t "cloud-off.cleared-g4-$SWTAG.json" '{off:false,off_files:["cloud-off.aborted-g4-20261121T064806Z.json","cloud-off.cleared-1795331125.json","cloud-off.cleared-g4-20261122T070523Z.json",$t]}')"
LAOLD="$(jq -nc '{off:false,off_files:["cloud-off.cleared-1795331125.json","cloud-off.cleared-g4-20261122T070523Z.json"]}')"
LAONLY="$(jq -nc --arg t "cloud-off.cleared-g4-$SWTAG.json" '{off:false,off_files:["cloud-off.cleared-1795331125.json",$t]}')"
LA=$LAOK; t "F7 3e chk: old cleared-g4-<old> + this run's tag -> GREEN" "[ \"\$(runchk \"\$E3LINE\")\" = 0 ]" 0
LA=$LAOLD; t "F7 3e chk: only an old cleared-g4 archive (this run's tag missing) -> RED" "[ \"\$(runchk \"\$E3LINE\")\" = 1 ]" 0
LA=$LAONLY; t "F7 3e chk: this run's tag, no old archive -> GREEN" "[ \"\$(runchk \"\$E3LINE\")\" = 0 ]" 0
# ---- F8 (Argus r3hubble 23-11 Q3): R3 Hubble judged from a live capture; hubble stderr judged; local python pinned
eval "$(sed -n '/^# ---- F8 Hubble live capture (begin)/,/^# ---- F8 Hubble live capture (end)/p' "$D")"
HE=1795417200   # 2026-11-23T07:00:00Z; tcp-test window HE+10..HE+12 (Mac clock), go turn HE+20.5..HE+25 (pod clock)
hts() { printf '%s.%sZ' "$(date -u -r "${1%.*}" +%Y-%m-%dT%H:%M:%S)" "${2:-250000000}"; }
fl() { # $1 verdict $2 workload $3 dst ip $4 epoch $5 dst port $6 destination_names json (default [])
  jq -nc --arg v "$1" --arg w "$2" --arg ip "$3" --arg t "$(hts "$4")" --argjson p "${5:-443}" --argjson n "${6:-[]}" \
    '{flow:{time:$t,verdict:$v,Type:"L3_L4",source:{namespace:"family-ai",pod_name:($w+"-6d9f8b7c5-x2k4q"),workloads:[{name:$w,kind:"Deployment"}]},
      IP:{source:"10.244.5.17",destination:$ip},l4:{TCP:{destination_port:$p}},destination_names:$n},node_name:"vdhclu01node02",time:$t}'; }
dnsfl() { jq -nc --arg t "$(hts "$1")" '{flow:{time:$t,verdict:"FORWARDED",Type:"L7",source:{namespace:"kube-system",pod_name:"coredns-7d8f9c6b5-abcde",workloads:[{name:"coredns"}]},
      IP:{source:"10.244.0.10",destination:"10.244.5.17"},l7:{type:"RESPONSE",dns:{query:"api.anthropic.com.",ips:["160.79.104.10"]}}},time:$t}'; }
API=160.79.104.10; NAMES='["api.anthropic.com"]'
cap() { local f; f="$CACHE/f8-$1.json"; shift; : > "$f"; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done; echo "$f"; }
ERR0="$CACHE/f8-err0"; : > "$ERR0"; ERR1="$CACHE/f8-err1"; echo 'rpc error: code = Unavailable desc = connection error: dial tcp 127.0.0.1:14245: connect: connection refused' > "$ERR1"
GOODL=("$(dnsfl $((HE+10)))" "$(fl FORWARDED hermes-profiel-3 $API $((HE+11)) 443 "$NAMES")" "$(fl FORWARDED hermes-profiel-3 $API $((HE+22)))" "$(fl FORWARDED hermes-profiel-1 172.16.2.200 $((HE+15)))")
GOOD=$(cap good "${GOODL[@]}")
J() { hub_judge "$1" "${2:-$ERR0}" "${3:-1}" $((HE+10)) $((HE+12)) "${4:-$((HE+20)).5}" "${5:-$((HE+25))}"; }
JP() { jq -e '.pass == true' <<<"$(J "$@")" >/dev/null; }
# a must-FAIL case needs a real verdict (.pass == false), so a missing judge (old driver) cannot pass it vacuously
JF() { jq -e '.pass == false' <<<"$(J "$@")" >/dev/null; }
t "F8 judge: good capture (p3 named in the tcp test, p3 by DNS IP inside the turn) -> PASS" "JP '$GOOD'" 0
t "F8 judge: good capture reports p3_in_tcp_test 1, p3_in_go_turn 1, api_ips [$API]" "[ \"\$(J '$GOOD' | jq -c '[.p3_in_tcp_test,.p3_in_go_turn,.api_ips]')\" = '[1,1,[\"$API\"]]' ]" 0
t "F8 judge: DROPPED p1/p2/p4 flows to the API are info only -> PASS" "JP '$(cap p1drop "${GOODL[@]}" "$(fl DROPPED hermes-profiel-1 $API $((HE+21)) 443 "$NAMES")" "$(fl DROPPED hermes-profiel-4 $API $((HE+11)))")'" 0
t "F8 judge: DROPPED p1 is reported under p124_dropped_info" "[ \"\$(J '$CACHE/f8-p1drop.json' | jq -c .p124_dropped_info)\" = '{\"hermes-profiel-1\":1,\"hermes-profiel-4\":1}' ]" 0
t "F8 judge: capture died before the stop (alive 0) -> FAIL" "JF '$GOOD' '$ERR0' 0" 0
t "F8 judge: 0 lines -> FAIL" "JF '$(cap empty)'" 0
t "F8 judge: no p3 flow (only DNS + a p1 Studio flow) -> FAIL" "JF '$(cap nop3 "$(dnsfl $((HE+10)))" "$(fl FORWARDED hermes-profiel-1 172.16.2.200 $((HE+15)))")'" 0
t "F8 judge: a FORWARDED p1 flow to the API (named) -> FAIL" "JF '$(cap p1fwd "${GOODL[@]}" "$(fl FORWARDED hermes-profiel-1 $API $((HE+23)) 443 "$NAMES")")'" 0
t "F8 judge: a FORWARDED p2 flow to the API IP from the DNS answer (no name) -> FAIL" "JF '$(cap p2ip "${GOODL[@]}" "$(fl FORWARDED hermes-profiel-2 $API $((HE+40)))")'" 0
t "F8 judge: p3 flows only outside the go turn (tcp test + after the turn) -> FAIL" "JF '$(cap outside "$(dnsfl $((HE+10)))" "$(fl FORWARDED hermes-profiel-3 $API $((HE+11)) 443 "$NAMES")" "$(fl FORWARDED hermes-profiel-3 $API $((HE+26)) 443 "$NAMES")" "$(fl FORWARDED hermes-profiel-3 $API $((HE+20)))")'" 0
t "F8 judge: p3 inside the turn but the tcp test flow missing -> FAIL" "JF '$(cap notcp "$(dnsfl $((HE+18)))" "$(fl FORWARDED hermes-profiel-3 $API $((HE+22)) 443 "$NAMES")")'" 0
t "F8 judge: p3 only DROPPED to the API -> FAIL" "JF '$(cap p3drop "$(fl DROPPED hermes-profiel-3 $API $((HE+11)) 443 "$NAMES")" "$(fl DROPPED hermes-profiel-3 $API $((HE+22)) 443 "$NAMES")")'" 0
t "F8 judge: hubble error output (stderr non-empty) -> FAIL" "JF '$GOOD' '$ERR1'" 0
t "F8 judge: stderr file missing -> FAIL" "JF '$GOOD' '$CACHE/f8-no-such-err'" 0
t "F8 judge: a non-JSON line in the capture -> FAIL (jq error, no verdict)" "declare -F hub_judge >/dev/null && [ -z \"\$(J '$(cap junk "${GOODL[@]}" 'level=error msg="relay gone"')')\" ]" 0
t "F8 judge: no go-turn window (TURNSTART missing) -> FAIL" "JF '$GOOD' '$ERR0' 1 null null" 0
# the driver's own R3 chk line, verbatim
R3LINE=$(line_of 'chk "R3 Hubble live capture:')
t "F8 the R3 live-capture chk line exists in the driver" "[ -n \"\$R3LINE\" ]" 0
for c in good:0 died:1 err:1 p1fwd:1 outside:1 empty:1; do
  case ${c%%:*} in good) HJ=$(J "$GOOD");; died) HJ=$(J "$GOOD" "$ERR0" 0);; err) HJ=$(J "$GOOD" "$ERR1");; p1fwd) HJ=$(J "$CACHE/f8-p1fwd.json");;
    outside) HJ=$(J "$CACHE/f8-outside.json");; empty) HJ=$(J "$CACHE/f8-empty.json");; esac
  t "F8 R3 chk line with capture=${c%%:*} -> RED ${c##*:}" "[ -n \"\$R3LINE\" ] && [ \"\$(runchk \"\$R3LINE\")\" = ${c##*:} ]" 0; done
HJ=""; t "F8 R3 chk line with an empty judgement (jq error) -> RED 1" "[ -n \"\$R3LINE\" ] && [ \"\$(runchk \"\$R3LINE\")\" = 1 ]" 0
# dry-run positive control (Q3e)
DS() { hub_seen_p3 "$1" "${2:-$ERR0}" "${3:-1}" $((HE+10)) $((HE+12)); }
DSP() { jq -e '.pass == true' <<<"$(DS "$@")" >/dev/null; }
DSF() { jq -e '.pass == false' <<<"$(DS "$@")" >/dev/null; }
DGOOD=$(cap dgood "$(fl FORWARDED hermes-profiel-3 172.16.2.200 $((HE+11)))" "$(fl FORWARDED hermes-profiel-3 10.96.0.10 $((HE+11)) 53)" "$(fl DROPPED hermes-profiel-3 $API $((HE+12)))")
t "F8 dry-run: p3 -> Studio :443 FORWARDED in the window -> PASS" "DSP '$DGOOD'" 0
t "F8 dry-run: died -> FAIL" "DSF '$DGOOD' '$ERR0' 0" 0
t "F8 dry-run: hubble stderr -> FAIL" "DSF '$DGOOD' '$ERR1'" 0
t "F8 dry-run: 0 lines -> FAIL" "DSF '$CACHE/f8-empty.json'" 0
t "F8 dry-run: Studio flow outside the window -> FAIL" "DSF '$(cap dlate "$(fl FORWARDED hermes-profiel-3 172.16.2.200 $((HE+40)))")'" 0
t "F8 dry-run: only a p1 Studio flow -> FAIL" "DSF '$(cap dp1 "$(fl FORWARDED hermes-profiel-1 172.16.2.200 $((HE+11)))")'" 0
DRYLINE=$(line_of 'chk "R3 Hubble sees p3 live (F8)')
for c in good:0 died:1; do case ${c%%:*} in good) HD=$(DS "$DGOOD");; died) HD=$(DS "$DGOOD" "$ERR0" 0);; esac
  t "F8 dry-run chk line with capture=${c%%:*} -> RED ${c##*:}" "[ -n \"\$DRYLINE\" ] && [ \"\$(runchk \"\$DRYLINE\")\" = ${c##*:} ]" 0; done
# hub_start / hub_stop with stubbed kubectl + hubble: liveness, stderr, 0600, killed by hub_kill
# shellcheck disable=SC2329  # invoked by hub_start
kubectl() { exec sleep 60; }
# shellcheck disable=SC2329
hubble() { case "$HMODE" in alive) cat "$GOOD"; exec sleep 60;; died) cat "$GOOD"; return 1;; err) echo 'rpc error: relay unavailable' >&2; cat "$GOOD"; exec sleep 60;; esac; }
HPID=""; PF=""; HCAP="$CACHE/none"; HERR="$CACHE/none"; HALIVE=x   # an old driver has no F8 block: no crash under set -u
for m in alive died err; do HMODE=$m; hub_start "stub-$m" >/dev/null; sleep 1; P_H=${HPID:-0}; P_F=${PF:-0}
  MODE_CAP=$(stat -f %Lp "$HCAP"); MODE_ERR=$(stat -f %Lp "$HERR"); hub_stop >/dev/null
  eval "ALIVE_$m=$HALIVE; HJ_$m=\$(hub_judge '$HCAP' '$HERR' $HALIVE $((HE+10)) $((HE+12)) $((HE+20)).5 $((HE+25)))"
  eval "GONE_$m=\$( kill -0 $P_H 2>/dev/null || kill -0 $P_F 2>/dev/null; echo \$? )"; eval "MODES_$m=$MODE_CAP/$MODE_ERR"; done
t "F8 stub capture alive until the stop -> HALIVE 1, judge PASS" "[ $ALIVE_alive = 1 ] && jq -e '.pass == true' <<<'$HJ_alive' >/dev/null" 0
t "F8 stub capture that exited early -> HALIVE 0, judge FAIL" "[ $ALIVE_died = 0 ] && jq -e '.pass == false' <<<'$HJ_died' >/dev/null" 0
t "F8 stub capture with hubble stderr -> judge FAIL (stderr_lines 1)" "jq -e '.pass == false and .stderr_lines == 1' <<<'$HJ_err' >/dev/null" 0
t "F8 capture + stderr files are 0600" "[ $MODES_alive = 600/600 ]" 0
t "F8 hub_stop leaves neither the capture nor the port-forward running" "[ $GONE_alive = 1 ] && [ $GONE_err = 1 ]" 0
unset -f kubectl hubble
# static: placement, trap, no stderr discard, python pin
ln_of() { grep -n -F -m1 -- "$1" "$D" | cut -d: -f1; }
LS=$(ln_of 'hub_start go;'); LB=$(ln_of 'push -q origin "$B:refs/heads/main"'); LT=$(ln_of "go-cloud' <"); LSTOP=$(grep -n '^w=.*TURN_E + 30.*hub_stop$' "$D" | cut -d: -f1)
LJ=$(ln_of 'HJ=$(hub_judge'); LH0=$(ln_of 'HT0=$(now_e)'); LGT=$(ln_of 'gate "go turn"')
t "F8 static: capture starts before the push of B, gated (alive + lines) before it" "[ -n \"$LS\" ] && [ \"$LS\" -lt \"$LB\" ] && sed -n '${LS},${LB}p' '$D' | grep -q 'gate \"Hubble capture before B\" R3'" 0
t "F8 static: the p3 tcp test window opens after B; the capture stops 30 s after the turn, before the turn gate" "[ \"$LH0\" -gt \"$LB\" ] && [ \"$LSTOP\" -gt \"$LT\" ] && [ \"$LSTOP\" -lt \"$LGT\" ] && [ \"$LJ\" -gt \"$LSTOP\" ]" 0
t "F8 static: on_exit and rollback_core both kill the capture" "sed -n '/^on_exit() {/,/^}/p' '$D' | grep -q hub_kill && sed -n '/^rollback_core() {/,/^}/p' '$D' | grep -q 'hub_kill'" 0
t "F8 static: every hubble observe keeps stderr (to \$HERR), none discards it" "[ \"\$(grep -c 'hubble observe' '$D')\" -ge 1 ] && ! grep 'hubble observe' '$D' | grep -q '/dev/null' && ! grep -v '^ *#' '$D' | grep 'hubble observe' | grep -v -q '2>> \"\$HERR\"'" 0
t "F8 static: no after-the-fact hubble query (--since) remains" "! grep -v '^ *#' '$D' | grep -q 'hubble observe.*--since'" 0
t "F8 static: the dry-run runs the live capture + the p3 positive control" "sed -n '/^if \\[ \"\$MODE\" = --dry-run \\]; then/,/^fi/p' '$D' | grep -q 'hub_start dry' && sed -n '/^if \\[ \"\$MODE\" = --dry-run \\]; then/,/^fi/p' '$D' | grep -q 'hub_seen_p3'" 0
t "F8 static: local python pinned (PY=/opt/homebrew/bin/python3, refused if missing, logged)" "grep -q '^PY=/opt/homebrew/bin/python3\$' '$D' && grep -q '\\[ -x \"\$PY\" \\] || {' '$D' && grep -q 'command -v python3' '$D'" 0
t "F8 static: no bare local python3 call (only in-pod kubectl exec lines and the log line)" "! grep -v '^ *#' '$D' | grep -E '(^|[^/a-z])python3( |\$)' | grep -v -E 'kubectl[^#]*exec' | grep -v 'command -v python3' | grep -q ." 0
t "L7: --go without --dormant-ack exits 2 before any work" "cd '$CACHE' && bash '$D' --go --commit-a $(printf 'a%.0s' {1..40}) --commit-b $(printf 'b%.0s' {1..40}) 2>&1 | grep -q 'needs --dormant-ack'; [ \${PIPESTATUS[0]} = 2 ]" 0
echo "DRIVER SNIPPET TESTS $PASS/$((PASS+FAIL)) passed"; [ "$FAIL" = 0 ]
