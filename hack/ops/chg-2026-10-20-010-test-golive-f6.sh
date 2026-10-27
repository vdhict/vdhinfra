#!/usr/bin/env bash
# chg-2026-10-20-010 offline test (attempt 10, 27-10): F6 per-turn route records == api_call_count increase, F1 next
# turn Studio-only, F2 no cloud_ok outside the C6/E3 windows, the 000 handling (strictly sequential, never resent when
# anything arrived, at most one resend), the cloud-turn budget (3) and the single __init__.py pin file.
#
#   bash hack/ops/chg-2026-10-20-010-test-golive-f6.sh [<scratch-dir>]
#   C010_GOLIVE=<path> C010_GOSESSION=<path> ...   # run the same cases against another golive/go-session (pre-fix)
#
# Sources the marked `# >>> c010-f6` block (+ C6LOG_PY) of the real golive.sh and `# >>> c010-gs-f2` of go-session.sh.
# SDB_PY runs against a synthetic SQLite file with the Hermes v0.22.5 sessions/messages columns it reads (message text
# is a SENTINEL that must never appear in any output). pturn/f6_settle run against a simulated server (python, clock
# advanced by a stubbed sleep): attempt-9 shapes (000 while Hermes answered; next turn never arrived; tool-call turn).
# No network, no cluster. Deletes nothing (AGR-121). Exit 0 iff all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CHG=chg-2026-10-20-010
GOLIVE="${C010_GOLIVE:-$HERE/$CHG-golive.sh}"; GS="${C010_GOSESSION:-$HERE/$CHG-go-session.sh}"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-golive-f6-XXXXXX")}"; mkdir -p "$B/cache"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
SENT='ZZPRIVATE-c010-sentinel-7f3a'
BLOCK="$B/f6.sh"
{ sed -n "/^C6LOG_PY='/,/^print(json.dumps(out))'/p" "$GOLIVE"; sed -n '/^# >>> c010-f6/,/^# <<< c010-f6/p' "$GOLIVE"; } > "$BLOCK"
t "B0 golive.sh has the c010-f6 block (SDB_PY, F6JUDGE_PY, F2_PY, pf_fresh, send_turn, f6_settle, pturn, c6_settle, f2_check)" bash -c "
  for f in pf_fresh send_turn f6_settle pturn c6_settle f2_check sdb routes_all; do grep -q \"^\$f() \" '$BLOCK' || exit 1; done
  for v in SDB_PY F6JUDGE_PY F2_PY; do grep -q \"^\$v='\" '$BLOCK' || exit 1; done"
pyof() { sed -n "/^$1='/,/'\$/p" "$BLOCK" | sed "1s/^$1='//; \$s/'\$//"; }
SDB=$(pyof SDB_PY); JUDGE=$(pyof F6JUDGE_PY); F2P=$(pyof F2_PY); C6L=$(pyof C6LOG_PY)
t "B1 the F6 code never names agent.log or the logs dir, and SDB_PY never selects content/tool_calls/prompts" bash -c "
  ! grep -v '^#' '$BLOCK' | grep -q 'agent\.log\|/opt/data/logs' && ! printf '%s' \"\$1\" | grep -qi 'content\|tool_calls\|system_prompt\|select \*'" _ "$SDB"
t "B2 SDB_PY opens state.db read-only (mode=ro)" bash -c "printf '%s' \"\$1\" | grep -q 'file:%s?mode=ro'" _ "$SDB"

# ---------------------------------------------------------------- SDB_PY on a synthetic Hermes state.db
DB="$B/state.db"
/usr/bin/python3 -I - "$DB" "$SENT" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); S = sys.argv[2]
c.executescript("""create table sessions (id text primary key, source text not null, started_at real not null,
  last_activity_at real, api_call_count integer default 0, system_prompt text, title text);
create table messages (id integer primary key autoincrement, session_id text not null, role text not null, content text,
  tool_calls text, timestamp real not null, finish_reason text);""")
c.execute("insert into sessions values ('c6sess', 'api_server', 100, 2000, 14, ?, ?)", (S, S))
c.execute("insert into sessions values ('hwsess', 'api_server', 1000, 1023, 1, ?, null)", (S,))
c.execute("insert into sessions values ('vgsess', 'api_server', 1040, 1063, 2, null, null)")
c.execute("insert into sessions values ('cron1', 'cron', 10, 10, 0, null, null)")
for r in [("c6sess", "user", S, None, 1990, None), ("c6sess", "assistant", S, None, 1999, "stop"),
          ("hwsess", "user", S, None, 1002, None), ("hwsess", "assistant", S, None, 1023, "stop"), ("hwsess", "session_meta", S, None, 1023, None),
          ("vgsess", "user", S, None, 1042, None), ("vgsess", "assistant", S, '[{"x":"%s"}]' % S, 1053, "tool_calls"),
          ("vgsess", "tool", S, None, 1053, None), ("vgsess", "assistant", S, None, 1063, "stop"), ("vgsess", "session_meta", S, None, 1063, None)]:
    c.execute("insert into messages (session_id, role, content, tool_calls, timestamp, finish_reason) values (?,?,?,?,?,?)", r)
c.commit()
PY
SJ=$(/usr/bin/python3 -I -c "$SDB" 1000 "$DB" 2>&1)
t "D1 SDB_PY: 4 sessions, ids hashed (12 hex), never the raw id or any text" bash -c "
  printf '%s' \"\$1\" | /usr/bin/python3 -I -c 'import json,sys,re; d=json.load(sys.stdin)[\"sessions\"]; sys.exit(0 if len(d)==4 and all(re.fullmatch(\"[0-9a-f]{12}\",k) for k in d) else 1)' \
  && ! printf '%s' \"\$1\" | grep -q '$SENT\|hwsess\|vgsess\|c6sess'" _ "$SJ"
hk() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
HW=$(hk hwsess); VG=$(hk vgsess)
t "D2 SDB_PY: last message skips session_meta -> assistant/stop; users since 1000 counted; tool-call turn ends on stop" bash -c "
  printf '%s' \"\$1\" | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin)[\"sessions\"]; h,v=d[sys.argv[1]],d[sys.argv[2]]
sys.exit(0 if (h[\"last_role\"],h[\"last_finish\"],h[\"last_ts\"],h[\"users_since\"],h[\"first_user_ts\"],h[\"acc\"])==(\"assistant\",\"stop\",1023,1,1002,1) and (v[\"last_role\"],v[\"last_finish\"],v[\"acc\"])==(\"assistant\",\"stop\",2) else 1)' '$HW' '$VG'" _ "$SJ"

# ---------------------------------------------------------------- C6LOG_PY --all
rec() { printf '{"ts":%s,"route":"%s","rule":"%s","id_class":"%s"}\n' "$1" "$2" "$3" "$4"; }
{ rec 990 cloud cloud_ok msg_; rec 1023 studio private_context chatcmpl-; rec 1053 studio private_context chatcmpl-; rec 1063 studio private_context chatcmpl-; printf '%s\n' "$SENT"; } > "$B/route.jsonl"
RA=$(/usr/bin/python3 -I -c "$C6L" --all 1000 1100 "$B/route.jsonl")
t "R1 --all: in-window records with the four fields, malformed counted, never echoed" bash -c "
  [ '$RA' = '{\"count\": 3, \"malformed\": 1, \"records\": [[1023, \"studio\", \"private_context\", \"chatcmpl-\"], [1053, \"studio\", \"private_context\", \"chatcmpl-\"], [1063, \"studio\", \"private_context\", \"chatcmpl-\"]]}' ]"
R0=$(/usr/bin/python3 -I -c "$C6L" 1000 1030 "$B/route.jsonl")
t "R2 without --all the C6 output shape is unchanged (no records key)" bash -c "[ '$R0' = '{\"count\": 1, \"malformed\": 1}' ]"

# ---------------------------------------------------------------- judge on attempt-9 shapes
mk() { /usr/bin/python3 -I -c 'import json,sys; print(json.dumps({"now": 0, "sessions": json.loads(sys.argv[1])}))' "$1"; }
J() { printf '%s' "$1" > "$B/j0.json"; printf '%s' "$2" > "$B/j1.json"; printf '%s' "$3" > "$B/jr.json"; /usr/bin/python3 -I -c "$JUDGE" "$4" "$B/j0.json" "$B/j1.json" "$B/jr.json"; }
sess() { printf '{"src":"api_server","acc":%s,"last_role":"%s","last_ts":%s,"last_finish":"%s","users_since":%s,"first_user_ts":%s}' "$@"; }
A0=$(mk "{\"$HW\": $(sess 0 assistant 900 stop 0 null)}")
A1=$(mk "{\"$HW\": $(sess 1 assistant 1023 stop 1 1002)}")
RT='{"count":2,"malformed":0,"records":[[1023,"studio","private_context","chatcmpl-"],[1026,"cloud","cloud_ok","msg_"]]}'
JO=$(J "$A0" "$A1" "$RT" 1001)
t "J1 attempt-9 mis-pairing: the next turn's cloud record 3 s after this turn's assistant message is NOT in this turn (n=1, after=1)" bash -c "
  printf '%s' '$JO' | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (d[\"state\"],d[\"n\"],d[\"api_calls\"],d[\"cloud\"],d[\"after\"])==(\"done\",1,1,0,1) else 1)'"
TWO="{\"$HW\": $(sess 1 assistant 1023 stop 1 1002), \"x$HW\": $(sess 1 assistant 1020 stop 1 1005)}"; A2=$(mk "$TWO")
JO=$(J "$A0" "$A2" '{"records":[],"malformed":0}' 1001)
t "J2 two sessions changed (e.g. a real family turn) -> multi" bash -c "printf '%s' '$JO' | grep -q '\"state\": \"multi\"'"
JO=$(J "$A0" "$(mk "{\"$HW\": $(sess 1 assistant 1023 stop 0 null)}")" '{"records":[[1023,"studio","private_context","chatcmpl-"]],"malformed":0}' 1001)
t "J3 session changed but no user message from this turn (not paired) -> pending, never done" bash -c "printf '%s' '$JO' | grep -q '\"state\": \"pending\"'"
JO=$(J "$A0" "$(mk "{\"$HW\": $(sess 1 assistant 1013 tool_calls 1 1002)}")" '{"records":[],"malformed":0}' 1001)
t "J4 last message is an assistant tool call -> pending" bash -c "printf '%s' '$JO' | grep -q '\"state\": \"pending\"'"
JO=$(J "$A0" "$A0" '{"records":[[1010,"studio","private_context","chatcmpl-"]],"malformed":0}' 1001)
t "J5 no session change but a route record -> orphan (never 'none', so never resent)" bash -c "printf '%s' '$JO' | grep -q '\"state\": \"orphan\"'"

# ---------------------------------------------------------------- pturn / f6_settle against a simulated server
cat > "$B/sim.py" <<'PY'
# server model: argv: kind(sdb|routes) dir. Reads dir/scenario, dir/sends ("<clock> <code>" per send), dir/clock.
import json, os, sys, hashlib
kind, d = sys.argv[1], sys.argv[2]
sc = open(d + "/scenario").read().strip(); now = float(open(d + "/clock").read())
sends = [tuple(map(float, l.split())) for l in open(d + "/sends") if l.strip()] if os.path.exists(d + "/sends") else []
h = lambda s: hashlib.sha256(s.encode()).hexdigest()[:12]
S = {h("old"): {"src": "api_server", "acc": 5, "last_role": "assistant", "last_ts": 10.0, "last_finish": "stop", "users_since": 0, "first_user_ts": None}}
R = []
def turn(sid, t0, dur, calls, recs, final=True):
    s = S.setdefault(h(sid), {"src": "api_server", "acc": 0, "last_role": None, "last_ts": None, "last_finish": "none", "users_since": 0, "first_user_ts": None})
    if now < t0 + 0.5: return
    s["users_since"] += 1; s["first_user_ts"] = s["first_user_ts"] or t0 + 0.5; s["last_role"] = "user"; s["last_ts"] = t0 + 0.5
    if now >= t0 + dur:
        s["acc"] += calls
        if final: s.update(last_role="assistant", last_ts=t0 + dur, last_finish="stop")
        for i, (route, rule) in enumerate(recs): R.append([t0 + dur - 1 + i * 0.1, route, rule, "msg_" if route == "cloud" else "chatcmpl-"])
for n, (t0, code) in enumerate(sends, 1):
    P = [("studio", "private_context")]
    if sc == "ok200": turn("old", t0, 10, 1, P)
    elif sc == "tool": turn("old", t0, 20, 2, P * 2)
    elif sc == "arrived000": turn("old", t0, 40, 1, P)                       # pf died, Hermes answered 40 s later
    elif sc == "late000": turn("old", t0, 200, 1, P)                         # answered just before the settle window ends
    elif sc == "lost000" and n == 2: turn("old", t0, 10, 1, P)               # 1st never arrived, 2nd did
    elif sc == "lostall": pass
    elif sc == "cloudleak": turn("old", t0, 10, 1, [("cloud", "cloud_ok")])
    elif sc == "failleak": turn("old", t0, 10, 1, [("studio", "cloud_failed")])
    elif sc == "mismatch": turn("old", t0, 10, 2, P)
    elif sc == "never": turn("old", t0, 10, 1, P, final=False)
    elif sc == "nextlatch": turn("old", t0, 10, 1, [("studio", "private_latch")])
print(json.dumps({"now": now, "sessions": S}) if kind == "sdb" else json.dumps({"count": len(R), "malformed": 0, "records": sorted(R)}))
PY
PT() { # $1 scenario $2 code(s) returned by successive sends (space list) $3 kind ; then $4 extra shell (optional)
  local d="$B/sim-$1-$RANDOM"; mkdir -p "$d"; echo "$1" > "$d/scenario"; echo 1000 > "$d/clock"; : > "$d/sends"; echo "$2" > "$d/codes"
  : > "$d/ev.txt"; mkdir -p "$d/cache"
  bash -c "set -uo pipefail; EV='$d/ev.txt'; CACHE='$d/cache'; NS=family-ai; OUTF='$d/out'
log() { echo \"\$*\" >> \"\$EV\"; }
. '$BLOCK'
C010_F6_WAIT=360; F6_WAIT=360; F6_SETTLE=300; F6_POLL=5
pod() { echo p3; }; xp() { :; }; spend() { echo L; }
sleep() { echo \$(( \$(cat '$d/clock' | cut -d. -f1) + \${1%.*} )) > '$d/clock'; }
pod_now() { cut -d. -f1 '$d/clock'; }
pf_fresh() { [ ! -e '$d/nopf' ]; }
sdb() { /usr/bin/python3 -I '$B/sim.py' sdb '$d'; }
routes_all() { /usr/bin/python3 -I '$B/sim.py' routes '$d'; }
send_turn() { n=\$(( \$(wc -l < '$d/sends') + 1 )); c=\$(awk -v n=\$n '{print (\$n == \"\" ? \$NF : \$n)}' '$d/codes'); echo \"\$(cat '$d/clock') \$c\" >> '$d/sends'; sleep 2; printf '%s' \"\$c\"; }
pturn L1 $3 chat1 '[]'; echo \"rc=\$?\" >> '$d/out'; echo \"abort=\$F6_ABORT\" >> '$d/out'
${4:-}" >/dev/null 2>&1
  PD="$d"; SENDS=$(grep -c . "$d/sends"); PRC=$(grep '^rc=' "$d/out" | head -1); PEV="$d/ev.txt"; }
PT ok200 200 private
t "P1 200 turn: sent once, F6 ok (1 record == 1 api call, 0 cloud), row ok in f6.tsv" bash -c "
  [ $SENDS = 1 ] && [ '$PRC' = rc=0 ] && grep -q 'F6 L1 (private): http=200 tries=1 .*api_calls=+1 route_records=1 cloud=0 .*-> ok\$' '$PEV' && grep -q \$'^L1\tprivate\tok\t' '$PD/cache/f6.tsv'"
PT tool 200 private
t "P2 tool-call turn: 2 records == +2 api calls -> ok" bash -c "[ '$PRC' = rc=0 ] && grep -q 'api_calls=+2 route_records=2' '$PEV'"
PT arrived000 000 private
t "P3 attempt-9 shape: http 000 but Hermes answered 40 s later -> NOT resent, waited, judged on server records: ok" bash -c "
  [ $SENDS = 1 ] && [ '$PRC' = rc=0 ] && grep -q 'http=000 tries=1 .*route_records=1 .*-> ok\$' '$PEV' && ! grep -q 'resent' '$PEV'"
PT late000 000 private
t "P4 000, answer lands at 200 s (inside the 300 s settle): still never resent" bash -c "[ $SENDS = 1 ] && [ '$PRC' = rc=0 ]"
PT lost000 "000 200" private
t "P5 attempt-9 next-turn shape: 000 and nothing arrived for 300 s -> resent exactly once, then ok" bash -c "
  [ $SENDS = 2 ] && [ '$PRC' = rc=0 ] && grep -q 'never reached Hermes -> resent once' '$PEV' && grep -q 'tries=2' '$PEV'"
t "P5b the resend starts only after the full settle window (no overlap with a late original)" bash -c "
  a=\$(head -1 '$PD/sends' | cut -d' ' -f1 | cut -d. -f1); b=\$(sed -n 2p '$PD/sends' | cut -d' ' -f1 | cut -d. -f1); [ \$((b - a)) -ge 300 ]"
PT lostall "000 000" private
t "P6 never arrives twice -> RED inconclusive, exactly 2 sends (one resend max)" bash -c "[ $SENDS = 2 ] && [ '$PRC' = rc=1 ] && grep -q 'RED (inconclusive: none)' '$PEV'"
PT cloudleak 200 private
t "P7 a cloud_ok record on a private turn -> RED (independent of the ledger: spend stub never changes)" bash -c "[ '$PRC' = rc=1 ] && grep -q 'cloud=1 .*RED (cloud record(s) on a private turn)' '$PEV'"
PT failleak 200 private
t "P8 a studio/cloud_failed record (a cloud attempt) on a private turn -> RED" bash -c "[ '$PRC' = rc=1 ] && grep -q 'cloud record(s) on a private turn' '$PEV'"
PT mismatch 200 private
t "P9 api_call_count +2 but 1 route record -> RED" bash -c "[ '$PRC' = rc=1 ] && grep -q 'route records != api_call_count increase' '$PEV'"
PT never 200 private 'pturn L2 next chat1 "[]"; echo "rc2=$?" >> "$OUTF"'
t "P10 turn never settles -> RED timeout, F6_ABORT set, the next turn is skipped and NOT sent" bash -c "
  [ '$PRC' = rc=1 ] && grep -q 'abort=1' '$PD/out' && grep -q 'rc2=1' '$PD/out' && [ $SENDS = 1 ] && grep -q 'F6 L2: skipped' '$PEV' && grep -q \$'^L2\tnext\tred\tskipped' '$PD/cache/f6.tsv'"
PT nextlatch 200 next
t "F1a next turn routed studio with a new latch rule name -> ok, rule name logged" bash -c "[ '$PRC' = rc=0 ] && grep -q 'rules={\"private_latch\":1}' '$PEV'"
t "F1c jf prints JSON booleans as true/false (attempt-10 bug found here: Python True never matched 'true')" bash -c "
  . '$BLOCK' 2>/dev/null; [ \"\$(echo '{\"a\": true}' | jf a)\" = true ] && [ \"\$(echo '{\"a\": false}' | jf a)\" = false ] && [ -z \"\$(echo '{\"a\": null}' | jf a)\" ]"
PT cloudleak 200 next
t "F1b next turn routed to the cloud -> RED (F1)" bash -c "[ '$PRC' = rc=1 ] && grep -q 'F1: next turn not Studio-only' '$PEV'"
PTNOPF() { local d="$B/sim-nopf2"; mkdir -p "$d/cache"; echo ok200 > "$d/scenario"; echo 1000 > "$d/clock"; : > "$d/sends"; echo 200 > "$d/codes"; : > "$d/nopf"; : > "$d/ev.txt"
  bash -c "set -uo pipefail; EV='$d/ev.txt'; CACHE='$d/cache'; log() { echo \"\$*\" >> \"\$EV\"; }; . '$BLOCK'
pod() { echo p3; }; xp() { :; }; spend() { echo L; }; sleep() { echo \$(( \$(cat '$d/clock') + \$1 )) > '$d/clock'; }; pod_now() { cat '$d/clock'; }
pf_fresh() { [ ! -e '$d/nopf' ]; }; sdb() { /usr/bin/python3 -I '$B/sim.py' sdb '$d'; }; routes_all() { /usr/bin/python3 -I '$B/sim.py' routes '$d'; }
send_turn() { echo \"\$(cat '$d/clock') 200\" >> '$d/sends'; printf 200; }
pturn L1 private chat1 '[]'; echo rc=\$? > '$d/out'" >/dev/null 2>&1
  NP_SENDS=$(grep -c . "$d/sends"); NP_RC=$(cat "$d/out"); NP_CLOCK=$(cat "$d/clock"); NP_EV="$d/ev.txt"; }
PTNOPF
t "P11 port-forward never ready: 0 sends, 2 tries, RED inconclusive, no 300 s settle burned" bash -c "
  [ $NP_SENDS = 0 ] && [ '$NP_RC' = rc=1 ] && [ $NP_CLOCK -lt 1100 ] && grep -q 'nothing was sent -> one more try' '$NP_EV' && grep -q 'tries=2' '$NP_EV'"
t "P12 every F6 line holds hashes/counts/rules only (no sentinel, no chat id text beyond the label)" bash -c "! grep -rq '$SENT' '$B'/sim-*/ev.txt"

# ---------------------------------------------------------------- F2
printf '%s' '{"count":4,"malformed":0,"records":[[100,"cloud","cloud_ok","msg_"],[200,"cloud","cloud_ok","msg_"],[300,"cloud","cloud_ok","msg_"],[250,"studio","private_context","chatcmpl-"]]}' > "$B/f2a.json"
o=$(/usr/bin/python3 -I -c "$F2P" "$B/f2a.json" "95:105,195:205,295:305"); rc=$?
t "F2a all cloud_ok inside the C6/E3 windows -> rc 0" bash -c "[ $rc = 0 ] && echo '$o' | grep -q '\"outside\": 0'"
o=$(/usr/bin/python3 -I -c "$F2P" "$B/f2a.json" "95:105,195:205"); rc=$?
t "F2b a cloud_ok outside every window (attempt-9 lesstof shape) -> rc 1, outside 1" bash -c "[ $rc = 1 ] && echo '$o' | grep -q '\"outside\": 1'"
o=$(/usr/bin/python3 -I -c "$F2P" "$B/f2a.json" ""); rc=$?
t "F2c no windows at all -> every cloud_ok is outside -> rc 1" bash -c "[ $rc = 1 ]"
t "F2d golive: PUSH_E taken before deploy_push; F2 chk before gate C7; the 'F2 windows' line is logged for go-session" bash -c "
  p=\$(grep -n '^PUSH_E=' '$GOLIVE' | cut -d: -f1); d=\$(grep -n '^deploy_push ||' '$GOLIVE' | cut -d: -f1); [ -n \"\$p\" ] && [ \"\$p\" -lt \"\$d\" ] \
  && grep -q '^log \"F2 windows from=\$PUSH_E c6=\$F2WIN\"' '$GOLIVE' && grep -B1 '^gate \"C7\"\$' '$GOLIVE' | grep -q '^chk \"F2 '"
# go-session f2_go_session: parses golive's line, adds the E3 window
GSB="$B/gs-f2.sh"; sed -n '/^# >>> c010-gs-f2/,/^# <<< c010-gs-f2/p' "$GS" | grep -v '^eval "\$(sed' > "$GSB"
t "G0 go-session has the c010-gs-f2 block, sources golive's reader + c010-f6 block, and calls f2_go_session before its rollback decision" bash -c "
  grep -q 'f2_go_session() ' '$GSB' && [ \$(sed -n '/^# >>> c010-gs-f2/,/^# <<< c010-gs-f2/p' '$GS' | grep -c '^eval \"\$(sed -n ') = 2 ] \
  && f=\$(grep -n '^  f2_go_session ' '$GS' | cut -d: -f1) && r=\$(grep -n 'rollback_all \"go-time readback' '$GS' | cut -d: -f1) && [ \"\$f\" -lt \"\$r\" ]"
printf 'x\nF2 windows from=1793138000 c6=1793138100:1793138130,1793138150:1793138180\n' > "$B/gev.txt"
GSR() { bash -c "set -uo pipefail; CACHE='$B/cache'; NS=family-ai; log() { echo \"\$*\" >> '$B/gs.out'; }
. '$BLOCK'; . '$GSB'
pod_now() { echo 1793139000; }; routes_all() { echo \"from=\$1\" >> '$B/gs.args'; cat '$B/gs-routes.json'; }
f2_go_session '$B/gev.txt' $1; echo rc=\$? >> '$B/gs.out'" >/dev/null 2>&1; }
printf '%s' '{"count":3,"malformed":0,"records":[[1793138120,"cloud","cloud_ok","msg_"],[1793138170,"cloud","cloud_ok","msg_"],[1793138900,"cloud","cloud_ok","msg_"]]}' > "$B/gs-routes.json"
: > "$B/gs.out"; : > "$B/gs.args"; GSR "1793138890 1793138910"
t "G1 C6 x2 + E3 inside their windows -> rc 0; read from golive's push epoch" bash -c "grep -qx 'rc=0' '$B/gs.out' && grep -qx 'from=1793138000' '$B/gs.args'"
: > "$B/gs.out"; GSR "1793138950 1793138960"
t "G2 E3 window misses the third cloud_ok -> RED rc 1" bash -c "grep -qx 'rc=1' '$B/gs.out'"
: > "$B/gs.out"; printf 'no line\n' > "$B/gev.txt"; GSR "1793138890 1793138910"
t "G3 golive evidence without the F2 windows line -> RED" bash -c "grep -qx 'rc=1' '$B/gs.out' && grep -q \"no 'F2 windows' line\" '$B/gs.out'"

# ---------------------------------------------------------------- C7 + budget (static, on the real files)
C7S=$(sed -n '/^# C7 (attempt 10/,/^gate "C7"$/p' "$GOLIVE")
t "C1 C7 has no lesstof turn (AGR-073; saves a cloud turn): no non-comment line names it" bash -c "! printf '%s\n' \"\$1\" | grep -v '^#' | grep -qi 'lesstof\|fotosynthese'" _ "$C7S"
t "C2 C7 runs exactly 4 private chats via c7 (huiswerk, vergeet, image, document) and gates F6 on 8 rows, F1 on 4" bash -c "
  [ \$(printf '%s\n' \"\$1\" | grep -cE '^(if .*then )?c7 ') = 4 ] && printf '%s' \"\$1\" | grep -q 'wc -l) = 8 \]' && printf '%s' \"\$1\" | grep -q 'wc -l) = 4 \]'" _ "$C7S"
t "C3 C7 keeps the vergeet memory-hash gate (a) and the ledger gate (Argus 23:03:54Z); completions/hubble/failure lines are info only" bash -c "
  printf '%s' \"\$1\" | grep -q '^chk \"(a) vergeet' && printf '%s' \"\$1\" | grep -q '^chk \"C7 ledger (month.json) unchanged' && ! printf '%s' \"\$1\" | grep -q '^chk \"C7 each turn was one p3 completion\|^chk \"W7 no family-cloud failure line during C7'" _ "$C7S"
L5=$(printf '%s\n' "$C7S" | grep '^chk "C7 ledger (month.json) unchanged' | sed -E 's/^chk "[^"]*" //')
L5C=$(SL7=L; eval "printf '%s' $L5")
t "C5 the C7 ledger gate goes RED when month.json changed over C7 (refusal/guard_* after a billed call) and passes when unchanged" bash -c "
  spend() { echo L2; }; ! eval \"\$1\" && spend() { echo L; } && eval \"\$1\"" _ "$L5C"
t "C4 pturn runs outside chk (its F6_ABORT and port-forward state survive between turns)" bash -c "! printf '%s' \"\$1\" | grep -q '^chk .*c7 '" _ "$C7S"
C6TURNS=$(sed -n '/^C6E=\$(date +%s)/,/^done; unset a m/p' "$GOLIVE" | grep -c '^for q in "\$q2" ""; do$')
E3N=$(grep -c 'turn("E3 header-less public first turn"' "$GS")
t "BUD real cloud turns in a GREEN go: C6 loop 2 (q2 + final) + C7 0 + E3 1 = 3 (was 3 + 1 + 1 = 5)" bash -c "[ $C6TURNS = 1 ] && [ $E3N = 1 ] && ! grep -q 'q3=' '$GOLIVE'"

# ---------------------------------------------------------------- the one __init__.py pin
PF="$HERE/$CHG-pin-fc-init.txt"
t "N1 pin file: one non-comment line '<64 hex>  plugins/model-providers/family-cloud/__init__.py'" bash -c "
  [ \$(grep -v '^#' '$PF' | grep -c .) = 1 ] && grep -v '^#' '$PF' | grep -Eqx '[0-9a-f]{64}  plugins/model-providers/family-cloud/__init__.py'"
PINHEX=$(grep -v '^#' "$PF" | awk 'NF{print $1; exit}')
t "N2 golive, derive-p3, finalize-ws hold no hard-coded __init__.py hash; each reads the pin file via fc_init_pin" bash -c "
  for f in golive derive-p3 finalize-ws; do s='$HERE/$CHG-'\$f.sh; ! grep -q '$PINHEX' \"\$s\" || exit 1; grep -q 'FC_INIT_PIN=\$(fc_init_pin ' \"\$s\" || exit 1; done"
printf '# c\nzz  plugins/model-providers/family-cloud/__init__.py\n' > "$B/badpin.txt"
printf '# c\n%s  plugins/model-providers/family-cloud/__init__.py\n' "$PINHEX" > "$B/goodpin.txt"
o1=$(bash -c "$(grep -h -A1 '^fc_init_pin() ' "$HERE/$CHG-golive.sh"); fc_init_pin '$B/goodpin.txt'"); o2=$(bash -c "$(grep -h -A1 '^fc_init_pin() ' "$HERE/$CHG-golive.sh"); fc_init_pin '$B/badpin.txt'")
t "N3 fc_init_pin returns the 64-hex pin, and nothing for a malformed line (golive chk + derive/finalize refuse on empty)" bash -c "[ '$o1' = '$PINHEX' ] && [ -z '$o2' ] \
  && grep -q '^chk \"family-cloud __init__.py pin readable' '$HERE/$CHG-golive.sh' && grep -q 'no valid family-cloud __init__.py pin' '$HERE/$CHG-derive-p3.sh' && grep -q 'no valid family-cloud __init__.py pin' '$HERE/$CHG-finalize-ws.sh'"
t "N4 the three fc_init_pin definitions are identical" bash -c "[ \$(grep -h -A1 '^fc_init_pin() ' '$HERE/$CHG-golive.sh' '$HERE/$CHG-derive-p3.sh' '$HERE/$CHG-finalize-ws.sh' | grep -vx -- '--' | sort -u | wc -l) = 2 ]"
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
