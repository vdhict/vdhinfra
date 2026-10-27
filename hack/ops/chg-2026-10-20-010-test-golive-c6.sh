#!/usr/bin/env bash
# chg-2026-10-20-010 offline test (attempt-6 item b, 27-10): C6 canary port-forward liveness + re-open, per-turn
# metadata with the answer unread, and C6 judged on the route p3 took (a Studio-answered turn is RED).
#
#   bash hack/ops/chg-2026-10-20-010-test-golive-c6.sh [<scratch-dir>]
#   C010_GOLIVE=<path> ...   # run the same cases against another golive.sh (pre-fix)
#
# Sources the marked `# >>> c010-c6turn` block of the real golive.sh and runs the real C6 turn loop (extracted
# verbatim between `C6E=$(date +%s)` and `done; unset a m`) against stubs: synthetic OWUI answers carrying a
# SENTINEL, a synthetic p3 agent.log, a fake port-forward process. No network, no cluster. Deletes nothing (AGR-121).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CHG=chg-2026-10-20-010
GOLIVE="${C010_GOLIVE:-$HERE/$CHG-golive.sh}"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-golive-c6-XXXXXX")}"; mkdir -p "$B/bin" "$B/cache"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
SENT='ZZANSWER-c010-sentinel-41b9'
BLOCK="$B/c6turn.sh"; sed -n '/^# >>> c010-c6turn/,/^# <<< c010-c6turn/p' "$GOLIVE" > "$BLOCK"
t "B0 golive.sh has the c010-c6turn block with pf_ensure, resp_meta, p3_turnlog, c6_turn_verdict" bash -c "
  for f in pf_alive pf_up pf_ensure resp_meta p3_turnlog c6_turn_verdict; do grep -q \"^\$f() \" '$BLOCK' || exit 1; done"
H() { bash -c "set -uo pipefail; EV='$B/ev.txt'; CACHE='$B/cache'; NS=family-ai; OW=owui-pod
log() { echo \"\$*\" >> \"\$EV\"; }; . '$BLOCK'; $1"; }

# ---- resp_meta: metadata only, never the answer
R1=$(printf '{"id":"chatcmpl-abc","choices":[{"message":{"role":"assistant","content":"%s"}}],"usage":{}}' "$SENT" | H 'resp_meta')
t "M1 full answer: content=yes, client_id_class=chatcmpl-, byte count, json=yes" bash -c "
  case '$R1' in *'json=yes'*'content=yes'*'client_id_class=chatcmpl-'*) ;; *) exit 1;; esac; echo '$R1' | grep -q 'bytes=[1-9]'"
t "M1 the answer text never appears in the metadata" bash -c "! echo '$R1' | grep -q '$SENT'"
R2=$(printf '' | H 'resp_meta')
t "M2 empty body: bytes=0 json=no content=no client_id_class=none" bash -c "echo '$R2' | grep -q 'bytes=0 json=no keys=- error_key=no content=no client_id_class=none'"
R3=$(printf '{"detail":"%s"}' "$SENT" | H 'resp_meta')
t "M3 error body: error_key=yes content=no, detail text not printed" bash -c "echo '$R3' | grep -q 'error_key=yes' && echo '$R3' | grep -q 'content=no' && ! echo '$R3' | grep -q '$SENT'"
R4=$(printf '{"id":"msg_01x","choices":[{"message":{"content":"  "}}],"%s key":1}' "$SENT" | H 'resp_meta')
t "M4 msg_ class; blank content = no; a key that is not an identifier is not printed" bash -c "
  echo '$R4' | grep -q 'client_id_class=msg_' && echo '$R4' | grep -q 'content=no' && ! echo '$R4' | grep -q '$SENT'"

# ---- C6LOG_PY on a synthetic route record file (Argus 15:21:18Z: never agent.log)
PYSRC=$(sed -n "/^C6LOG_PY='/,/^print(json.dumps(out))'/p" "$BLOCK" | sed "1s/^C6LOG_PY='//; \$s/'\$//")
t "L0 the C6 reader never names agent.log or the logs dir; default files are the route record file + .1" bash -c "
  ! printf '%s' \"\$1\" | grep -q 'agent.log\|/opt/data/logs' && printf '%s' \"\$1\" | grep -q '/opt/data/family-cloud-route.jsonl.1\", \"/opt/data/family-cloud-route.jsonl\"'" _ "$PYSRC"
NOW=$(date +%s); T0=$((NOW - 100)); TIN=$((NOW - 50)); TOUT=$((NOW - 500))
rec() { printf '{"ts":%s,"route":"%s","rule":"%s","id_class":"%s"}\n' "$1" "$2" "$3" "$4"; }
RF="$B/route.jsonl"; RF1="$B/route.jsonl.1"
{ rec "$TOUT.5" cloud cloud_ok msg_; } > "$RF1"; { rec "$TIN.25" cloud cloud_ok msg_; } > "$RF"
J1=$(/usr/bin/python3 -I -c "$PYSRC" "$T0" "$NOW" "$RF1" "$RF")
t "L1 one in-window record (across .1 + current; out-of-window ignored) -> count 1 with its fields" bash -c "[ '$J1' = '{\"count\": 1, \"malformed\": 0, \"route\": \"cloud\", \"rule\": \"cloud_ok\", \"id_class\": \"msg_\"}' ]"
{ rec "$TIN" studio private_context chatcmpl-; } > "$B/r2.jsonl"
J2=$(/usr/bin/python3 -I -c "$PYSRC" "$T0" "$NOW" "$B/r2.jsonl")
{ rec "$TIN" cloud cloud_ok msg_; rec "$((TIN+1))" studio private_context chatcmpl-; } > "$B/r3.jsonl"
J3=$(/usr/bin/python3 -I -c "$PYSRC" "$T0" "$NOW" "$B/r3.jsonl")
t "L2 two records in the window (e.g. a concurrent family turn) -> count 2 and NO record fields" bash -c "[ '$J3' = '{\"count\": 2, \"malformed\": 0}' ]"
J4=$(/usr/bin/python3 -I -c "$PYSRC" "$T0" "$NOW" "$B/none.jsonl")
t "L3 no route file / no record -> count 0" bash -c "[ '$J4' = '{\"count\": 0, \"malformed\": 0}' ]"
{ rec "$TIN" cloud cloud_ok msg_; printf '{"ts":%s,"route":"cloud","rule":"cloud_ok","id_class":"msg_","text":"%s"}\n' "$TIN" "$SENT"; printf '%s\n' "$SENT"; } > "$B/r5.jsonl"
J5=$(/usr/bin/python3 -I -c "$PYSRC" "$T0" "$NOW" "$B/r5.jsonl")
t "L4 extra key / non-JSON lines are malformed (counted, never echoed); fields withheld" bash -c "[ '$J5' = '{\"count\": 1, \"malformed\": 2}' ] && ! echo '$J5' | grep -q '$SENT'"
{ printf '{"ts":%s,"route":"cloud","rule":"cloud ok; x","id_class":"msg_"}\n' "$TIN"; printf '{"ts":%s,"route":"cloud","rule":"cloud_ok","id_class":"msg_abc"}\n' "$TIN"; } > "$B/r6.jsonl"
J6=$(/usr/bin/python3 -I -c "$PYSRC" "$T0" "$NOW" "$B/r6.jsonl")
t "L5 out-of-set rule text or id_class value -> malformed" bash -c "[ '$J6' = '{\"count\": 0, \"malformed\": 2}' ]"

# ---- verdict
v() { printf '%s' "$1" | H 'c6_turn_verdict'; }
out=$(v "$J1"); rc=$?
t "V1 exactly one record cloud/cloud_ok/msg_ -> exit 0, 'cloud'" bash -c "[ $rc = 0 ] && echo '$out' | grep -q -- '-> cloud\$'"
out=$(v "$J2"); rc=$?
t "V2 attempt-5 shape (studio/private_context/chatcmpl-) -> RED, names route, rule, class" bash -c "[ $rc = 1 ] && echo '$out' | grep -q 'route=studio rule=private_context id_class=chatcmpl- -> NOT cloud'"
out=$(v "$J3"); rc=$?
t "V3 two records -> RED inconclusive, only the counts" bash -c "[ $rc = 1 ] && [ '$out' = 'p3 route records in window=2 malformed=0 -> inconclusive' ]"
out=$(v "$J4"); rc=$?
t "V4 zero records -> RED inconclusive" bash -c "[ $rc = 1 ] && echo '$out' | grep -q 'window=0 malformed=0 -> inconclusive'"
out=$(v "$J5"); rc=$?
t "V5 malformed lines present -> RED inconclusive even with one good record" bash -c "[ $rc = 1 ] && echo '$out' | grep -q 'window=1 malformed=2 -> inconclusive'"
out=$(v '{"count": 1, "malformed": 0, "route": "cloud", "rule": "cloud_ok", "id_class": "chatcmpl-"}'); rc=$?
t "V6 cloud route but Studio id class -> RED" bash -c "[ $rc = 1 ]"
out=$(v 'not json'); rc=$?
t "V7 unreadable -> RED inconclusive" bash -c "[ $rc = 1 ] && echo '$out' | grep -q inconclusive"

# ---- fails(): counted inside the pod, only the number leaves (Argus 15:21:18Z)
t "F1 fails() runs in the pod (xp ... sh -c '... | grep -c ...') and nothing in golive copies agent.log or app pod logs to the Mini" bash -c "
  grep -q \"^fails() { xp \\\"\\\$(pod 3)\\\" sh -c 'cat /opt/data/logs/agent.log\\* 2>/dev/null | grep -c \\\"family-cloud: cloud call failed\\\" || true'; }\$\" '$GOLIVE' \
  && ! grep -nE 'kubectl -n [^ ]+ logs [^|]*-c app' '$GOLIVE' \
  && [ \"\$(grep -n 'agent\.log' '$GOLIVE' | grep -v '^[0-9]*:#' | grep -vc \"sh -c 'cat /opt/data/logs/agent.log[*]\\? \\(2>/dev/null \\)\\?| grep\")\" = 0 ]"
# ---- pf_ensure: liveness, re-open, failure
cat > "$B/bin/nc" <<EOF
#!/bin/bash
[ -e "$B/nc-ok" ]
EOF
chmod +x "$B/bin/nc"; : > "$B/nc-ok"
sleep 60 & LIVE=$!; disown $LIVE 2>/dev/null
PFH() { PATH="$B/bin:/usr/bin:/bin" bash -c "set -uo pipefail; EV='$B/ev-pf.txt'; CACHE='$B/cache'; NS=family-ai; OW=owui-pod
log() { echo \"\$*\" >> \"\$EV\"; }; . '$BLOCK'; pf_up() { echo pf_up >> '$B/pf-calls'; [ -e '$B/pfup-ok' ]; }; $1"; }
: > "$B/ev-pf.txt"; : > "$B/pf-calls"
PFH "PF=$LIVE; PORT=1; pf_ensure t1; echo rc=\$? reopen=\$PF_REOPEN >> '$B/pf-calls'"
t "P1 live port-forward: no re-open, nothing logged" bash -c "grep -qx 'rc=0 reopen=0' '$B/pf-calls' && ! grep -q pf_up '$B/pf-calls' && [ ! -s '$B/ev-pf.txt' ]"
kill $LIVE 2>/dev/null; while kill -0 $LIVE 2>/dev/null; do sleep 0.1; done; : > "$B/pf-calls"; : > "$B/pfup-ok"
PFH "PF=$LIVE; PORT=1; pf_ensure 'before C6 turn 2'; echo rc=\$? reopen=\$PF_REOPEN >> '$B/pf-calls'"
t "P2 dead port-forward process: re-opened via pf_up, logged with where + count, rc 0" bash -c "
  grep -q pf_up '$B/pf-calls' && grep -qx 'rc=0 reopen=1' '$B/pf-calls' && grep -q 'port-forward to OWUI lost (before C6 turn 2): re-opening (#1)' '$B/ev-pf.txt' && grep -q 're-opened (before C6 turn 2)' '$B/ev-pf.txt'"
sleep 60 & LIVE2=$!; disown $LIVE2 2>/dev/null; mv "$B/nc-ok" "$B/nc-ok.off"; : > "$B/pf-calls"; mv "$B/pfup-ok" "$B/pfup-ok.off"; : > "$B/ev-pf.txt"
PFH "PF=$LIVE2; PORT=1; pf_ensure cleanup; echo rc=\$? >> '$B/pf-calls'"
t "P3 process alive but port closed + re-open fails: RED line, rc 1" bash -c "grep -qx 'rc=1' '$B/pf-calls' && grep -q 'RED  port-forward could not be re-opened (cleanup)' '$B/ev-pf.txt'"
kill $LIVE2 2>/dev/null

# ---- the real C6 loop, verbatim, with stubs: turn 1 cloud, turn 2 Studio (attempt-5 shape), turn 3 inconclusive (2 records)
sed -n '/^C6E=\$(date +%s)/,/^done; unset a m/p' "$GOLIVE" > "$B/loop.sh"
t "W0 the C6 loop was found in golive.sh" bash -c "[ \$(wc -l < '$B/loop.sh') -gt 5 ]"
cat > "$B/stubs.sh" <<EOF
N=0
pf_ensure() { echo "pf_ensure \$1" >> '$B/loop-calls'; }
pf_alive() { return 0; }
tokens() { echo 0; }
xp() { date +%s; }
sleep() { :; }
ask() { n=\$(( \$(cat '$B/turn-n' 2>/dev/null || echo 0) + 1 )); echo "\$n" > '$B/turn-n'; printf '{"id":"chatcmpl-hermes","choices":[{"message":{"role":"assistant","content":"$SENT"}}]}\n200'; }
p3_turnlog() { n=\$(cat '$B/turn-n'); if [ "\$n" = 2 ]; then echo '{"count": 1, "malformed": 0, "route": "studio", "rule": "private_context", "id_class": "chatcmpl-"}'; elif [ "\$n" = 3 ]; then echo '{"count": 2, "malformed": 0}'; else echo '{"count": 1, "malformed": 0, "route": "cloud", "rule": "cloud_ok", "id_class": "msg_"}'; fi; }
EOF
: > "$B/loop-calls"; : > "$B/ev-loop.txt"
bash -c "set -uo pipefail; EV='$B/ev-loop.txt'; CACHE='$B/cache'; log() { echo \"\$*\" >> \"\$EV\"; }
. '$BLOCK'; . '$B/stubs.sh'
CID=c; H=''; q1=a; q2=b; q3=c; m='[{\"role\":\"user\",\"content\":\"q\"}]'
. '$B/loop.sh'
echo \"C6NOTCLOUD=[\$C6NOTCLOUD] H=[\$H]\" >> '$B/loop-calls'" >/dev/null 2>&1
t "W1 pf_ensure runs before each of the 3 turns" bash -c "[ \$(grep -c '^pf_ensure before C6 turn [123]\$' '$B/loop-calls') = 3 ]"
t "W2 per-turn metadata line: curl_rc, http, bytes, content, client id class, pf_after and the p3 verdict" bash -c "
  [ \$(grep -cE 'C6 turn [123]: curl_rc=0 http=200 bytes=[0-9]+ json=yes .*content=yes client_id_class=chatcmpl- pf_after=up; p3 route' '$B/ev-loop.txt') = 3 ]"
t "W3 Studio turn 2 NOT cloud, turn 3 (2 records) inconclusive with counts only: C6NOTCLOUD = 2 3; HTTP alone still reads 200" bash -c "
  grep -qx 'C6NOTCLOUD=\[ 2 3\] H=\[ 200 200 200\]' '$B/loop-calls' && grep -q 'C6 turn 2: .*p3 route=studio rule=private_context id_class=chatcmpl- -> NOT cloud' '$B/ev-loop.txt' \
  && grep -q 'C6 turn 3: .*; p3 route records in window=2 malformed=0 -> inconclusive\$' '$B/ev-loop.txt' && grep -q 'C6 turn 1: .*-> cloud\$' '$B/ev-loop.txt'"
t "W4 no answer text in the evidence" bash -c "! grep -q '$SENT' '$B/ev-loop.txt'"
t "W5 golive judges C6 on C6NOTCLOUD in a chk (a Studio answer is RED)" bash -c "grep -q '^chk \"C6 every turn answered by the cloud.*\" \"\[ -z .\$C6NOTCLOUD. \]\"' '$GOLIVE'"
t "W6 cleanup and C7 re-check the port-forward first; pf_up records every pid; cleanup kills them all" bash -c "
  grep -A1 '^cleanup() {' '$GOLIVE' | grep -q 'pf_ensure cleanup' && grep -q '^c7() { local cid s0 s1 s2; pf_ensure' '$GOLIVE' \
  && grep -q '^pf_ensure \"before C7\"' '$GOLIVE' && grep -q 'echo \"\$PF\" >> \"\$CACHE/pf.pids\"' '$BLOCK' && grep -q 'pf_kill_all; }' '$GOLIVE'"
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
