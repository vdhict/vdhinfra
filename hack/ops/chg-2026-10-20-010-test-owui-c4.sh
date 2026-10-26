#!/usr/bin/env bash
# chg-2026-10-20-010 offline tests of owui-c4.sh fix 2 (named failing step, structured parse refusal, idempotent
# apply/rollback, run id in the state) and golive.sh fix 3 (# >>> c010-c4state: rollback only with a C4 state of
# THIS run). Stub kubectl + stub Open WebUI on 127.0.0.1, fake token, synthetic config. No cluster, no network.
#
#   bash hack/ops/chg-2026-10-20-010-test-owui-c4.sh [<scratch-dir>]
#
# Deletes nothing (AGR-121). Exit 0 iff all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; C4="$HERE/chg-2026-10-20-010-owui-c4.sh"; GL="$HERE/chg-2026-10-20-010-golive.sh"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-owui-c4-XXXXXX")}"; mkdir -p "$B"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
TOK="test-token-not-a-secret-0123456789abcdef"
cat > "$B/server.py" <<'PY'
import json, sys, http.server
port, statef, mode, tok = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ok(self): return self.headers.get("Authorization") == "Bearer " + tok
    def do_GET(self):
        if not self.ok(): self.send_response(401); self.end_headers(); return
        s = json.load(open(statef)); body = json.dumps({"BYPASS_EMBEDDING_AND_RETRIEVAL": s["bypass"], "RAG_TEMPLATE": s["template"], "CHUNK_SIZE": 1000})
        if mode == "extra": body += json.dumps({"status": True})
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body.encode())
    def do_POST(self):
        if not self.ok(): self.send_response(401); self.end_headers(); return
        n = int(self.headers.get("Content-Length") or 0); d = json.loads(self.rfile.read(n) or b"{}")
        s = json.load(open(statef)); s["bypass"] = d["BYPASS_EMBEDDING_AND_RETRIEVAL"]; s["posts"] = s.get("posts", 0) + 1
        json.dump(s, open(statef, "w")); self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
setup() { # $1 name  $2 server mode  $3 initial bypass (true|false)  $4 kubectl mode (ok|dbfail|nopf)
  D="$B/$1"; export D; mkdir -p "$D/bin" "$D/repo/ops/evidence/chg-2026-10-20-010"
  printf '{"bypass": %s, "template": "Use <context> and <source id=1> markers", "posts": 0}' "$3" > "$D/state.json"
  cat > "$D/bin/kubectl" <<EOF
#!/bin/bash
case "\$*" in
  *"get pod"*) echo owui-stub;;
  *port-forward*) [ "$4" = nopf ] && exec sleep 600
     p=\$(echo "\$*" | sed -E 's/.* ([0-9]+):8080.*/\1/'); exec /usr/bin/python3 -I "$B/server.py" \$p "$D/state.json" "$2" "$TOK";;
  *"get volumesnapshot"*) echo true;;
  *"exec -i"*) cat > /dev/null; [ "$4" = dbfail ] && exit 1
     /usr/bin/python3 -I -c 'import json,hashlib,sys; s=json.load(open(sys.argv[1])); print(json.dumps({"db_bypass": s["bypass"], "db_template_sha256": hashlib.sha256(s["template"].encode()).hexdigest()}, sort_keys=True))' "$D/state.json";;
  *) exit 0;;
esac
EOF
  chmod +x "$D/bin/kubectl"; printf '#!/bin/bash\nexit 0\n' > "$D/bin/mise"; chmod +x "$D/bin/mise"
}
c4() { # $1.. args ; sets OUT RC
  OUT=$(cd "$D" && PATH="$D/bin:/usr/bin:/bin:/usr/sbin:/sbin" VDH_REPO="$D/repo" OWUI_ADMIN_KEY="$TOK" OWUI_SNAPSHOT=snap1 C010_RUN_ID="${RUNID:-run-A}" \
        bash "$C4" "$@" 2>&1); RC=$?; export OUT; }
posts() { /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("posts", 0))' "$D/state.json"; }
evid() { cat "$D"/repo/ops/evidence/chg-2026-10-20-010/k8s-owui-c4-*.txt 2>/dev/null; }
export -f posts evid

setup o1 ok true ok; c4 --dry-run
t "O1 dry-run: before (api + db) logged, rc 0, no POST" bash -c "[ $RC = 0 ] && grep -q '\"bypass\": true' <<< \"\$OUT\" && grep -q 'db_bypass' <<< \"\$OUT\" && [ \$(posts) = 0 ]"
setup o2 extra true ok; c4 --dry-run
t "O2 defensive: a body with extra JSON after the config is refused: RED at step [view ...], rc != 0, no POST" bash -c "[ $RC != 0 ] && grep -q 'RED owui-c4 stopped at step \[view (GET /api/v1/retrieval/config)\]' <<< \"\$OUT\" && [ \$(posts) = 0 ]"
t "O2 the evidence describes the shape (2 parts, key names) and never a value" bash -c "grep -q 'not a single JSON object: .* 2 part(s)' <<< \"\$(evid)\" && grep -q 'RAG_TEMPLATE' <<< \"\$(evid)\" && ! grep -q 'Use <context>' <<< \"\$(evid)\""
setup o3 ok true dbfail; c4 --dry-run
t "O3 in-pod DB read fails: RED at step [dbview ...]" bash -c "[ $RC != 0 ] && grep -q 'stopped at step \[dbview (in-pod sqlite read)\]' <<< \"\$OUT\""
setup o4 ok true nopf; c4 --dry-run
t "O4 port-forward never listens: RED at step [port-forward] (no silent exit)" bash -c "[ $RC != 0 ] && grep -q 'stopped at step \[port-forward\]' <<< \"\$OUT\""
setup o5 ok true ok; RUNID=run-A c4 --apply; ST=$(ls "$D"/repo/ops/evidence/chg-2026-10-20-010/*-before.json 2>/dev/null | head -1)
t "O5 apply (bypass true): one POST, read back false, GREEN; state records run_id run-A and noop false" bash -c "[ $RC = 0 ] && grep -q 'RESULT C4 GREEN (bypass false' <<< \"\$OUT\" && [ \$(posts) = 1 ] && grep -q '\"run_id\": \"run-A\"' '$ST' && grep -q '\"noop\": false' '$ST'"
c4 --rollback "$ST"
t "O7 rollback of that state: one more POST back to true, GREEN" bash -c "[ $RC = 0 ] && grep -q 'RESULT C4 rollback GREEN (bypass true)' <<< \"\$OUT\" && [ \$(posts) = 2 ] && grep -q '\"bypass\": true' '$D/state.json'"
setup o6 ok false ok; sleep 1; c4 --apply; ST6=$(ls "$D"/repo/ops/evidence/chg-2026-10-20-010/*-before.json 2>/dev/null | head -1)
t "O6 apply when bypass is already false: GREEN, idempotent, NO POST, state noop true" bash -c "[ $RC = 0 ] && grep -q 'already false: no POST, idempotent' <<< \"\$OUT\" && [ \$(posts) = 0 ] && grep -q '\"noop\": true' '$ST6'"
c4 --rollback "$ST6"
t "O8 rollback of a noop state: GREEN, NO POST (nothing was changed)" bash -c "[ $RC = 0 ] && grep -q 'noop state' <<< \"\$OUT\" && [ \$(posts) = 0 ]"
# O10 regression: the pre-fix owui-c4.sh (as on main before this commit) reproduces the attempt-3 silent exit
if git -C "$HERE" cat-file -e "${C010_OLD_C4_REV:-origin/main}:hack/ops/chg-2026-10-20-010-owui-c4.sh" 2>/dev/null; then
  git -C "$HERE" show "${C010_OLD_C4_REV:-origin/main}:hack/ops/chg-2026-10-20-010-owui-c4.sh" > "$B/old-c4.sh"
  if ! grep -q 'STEP=init' "$B/old-c4.sh"; then
    setup o10 ok true ok; C4SAVE="$C4"; C4="$B/old-c4.sh"; c4 --apply; C4="$C4SAVE"
    t "O10 old owui-c4 --apply (attempt-3 code) on a healthy OWUI: silent exit after the GET, header only, no state, no POST" bash -c "[ $RC != 0 ] && [ \$(evid | wc -l) = 1 ] && ! ls '$D'/repo/ops/evidence/chg-2026-10-20-010/*-before.json >/dev/null 2>&1 && [ \$(posts) = 0 ]"
  else echo "SKIP  O10 (the reference revision already has the fix)"; fi
fi
t "O9 the test token never appears in any C4 evidence" bash -c "! grep -r -q '$TOK' '$B'/o*/repo/ops/evidence"
# ---------------------------------------------------------------- fix 3: golive c010-c4state
eval "$(sed -n '/^# >>> c010-c4state/,/^# <<< c010-c4state/p' "$GL")"
export -f c4_state_ok c4_state_of_this_run
E="$B/c4state"; mkdir -p "$E"; mk() { printf '{"run_id": "%s"}' "$2" > "$E/k8s-owui-c4-$1-before.json"; }
mk 20261024T000000Z golive-OLD; sleep 1; : > "$E/run-start"; sleep 1
t "S1 only an older state (another run) exists -> nothing selected" bash -c "[ -z \"\$(c4_state_of_this_run '$E' '$E/run-start' golive-NEW)\" ]"
mk 20261025T120000Z golive-NEW
t "S2 one state newer than the run start with this run id -> selected" bash -c "[ \"\$(c4_state_of_this_run '$E' '$E/run-start' golive-NEW)\" = '$E/k8s-owui-c4-20261025T120000Z-before.json' ]"
t "S3 the older state fails c4_state_ok for this run (rollback() would skip it)" bash -c "! c4_state_ok '$E/k8s-owui-c4-20261024T000000Z-before.json' '$E/run-start' golive-NEW"
mk 20261025T120001Z golive-OTHER
t "S4 a newer state with another run id is ignored" bash -c "[ \"\$(c4_state_of_this_run '$E' '$E/run-start' golive-NEW)\" = '$E/k8s-owui-c4-20261025T120000Z-before.json' ]"
mk 20261025T120002Z golive-NEW
t "S5 two states of this run -> ambiguous -> nothing selected" bash -c "[ -z \"\$(c4_state_of_this_run '$E' '$E/run-start' golive-NEW)\" ]"
t "S6 golive passes C010_RUN_ID to owui-c4 and selects C4STATE only via c4_state_of_this_run" bash -c "grep -q 'C010_RUN_ID=\"\$RUN_ID\" \"\$HACK/ops/\$CHG-owui-c4.sh\" --apply' '$GL' && grep -q 'C4STATE=\$(c4_state_of_this_run ' '$GL' && ! grep -q 'C4STATE=\$(ls ' '$GL' && grep -q 'c4_state_ok \"\$C4STATE\"' '$GL'"
# ---------------------------------------------------------------- golive canary api(): same pipefail bug class
setup g1 ok true ok; PORT=$((30000 + RANDOM % 20000)); /usr/bin/python3 -I "$B/server.py" $PORT "$D/state.json" ok "$TOK" & SP=$!
for _ in $(seq 1 30); do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 0.2; done
export U="http://127.0.0.1:$PORT" TOK
eval "$(sed -n '/^# >>> c010-canary-api/,/^# <<< c010-canary-api/p' "$GL")"; export -f api
t "G1 golive api(): body-less GET piped into jq -e is GREEN under pipefail (status 0)" bash -c "set -o pipefail; api \"\$TOK\" GET /api/v1/retrieval/config | /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if \"RAG_TEMPLATE\" in json.load(sys.stdin) else 1)'"
t "G2 golive api(): a body is still sent (POST updates the stub)" bash -c "set -o pipefail; api \"\$TOK\" POST /api/v1/retrieval/config/update '{\"BYPASS_EMBEDDING_AND_RETRIEVAL\": false}' >/dev/null && grep -q '\"bypass\": false' '$D/state.json'"
OLDAPI=$(git -C "$HERE" show "${C010_OLD_C4_REV:-origin/main}:hack/ops/chg-2026-10-20-010-golive.sh" 2>/dev/null | grep -A2 '^api() { t="\$1"' | head -3)
if [ -n "$OLDAPI" ] && ! grep -q 'if \[ -n "\$b" \]' <<< "$OLDAPI"; then
  t "G3 regression: the old api() makes the same healthy GET read RED under pipefail" bash -c "$OLDAPI
set -o pipefail; ! { api \"\$TOK\" GET /api/v1/retrieval/config | /usr/bin/python3 -I -c 'import json,sys; json.load(sys.stdin)'; }"
fi
kill $SP 2>/dev/null; wait $SP 2>/dev/null
# ---------------------------------------------------------------- attempt-4 fixes: golive c010-c4c5 (C4 RESULT, C5 types)
# The REAL golive C4+C5 section (from the owui-c4 --apply line up to `gate "C4/C5"`) runs against a stub owui-c4 (prints a
# fixture as its stdout) and a stub kubectl whose `exec -i` runs the in-pod python locally on a fixture SQLite DB with
# the live schema (key TEXT, value JSON), so SQLite's NUMERIC affinity stores numeric JSON as INTEGER exactly like
# the OWUI DB. The same cases then run against the pre-fix golive.sh, which must fail them.
cat > "$B/mkdb.py" <<'PY'
import json, sqlite3, sys
# argv: db path, JSON overrides {key: ["text", s] | ["int", n] | ["null"] | ["blob", s] | ["pybool", b] | ["drop"]}
base = {k: "false" for k in ("task.autocomplete.enable", "task.follow_up.enable", "task.query.retrieval.enable",
                             "task.query.search.enable", "task.tags.enable")}
base.update({"task.title.enable": "true", "task.voice.prompt.enable": "false", "task.model.external": '"household-chat"',
             "task.model.default": '""', "task.model.params": "{}", "task.autocomplete.input_max_length": "-1"})
for k in ("autocomplete", "follow_up", "image", "query", "tags", "title", "tools"): base[f"task.{k}.prompt_template"] = '""'
base["task.voice.prompt_template"] = '""'
c = sqlite3.connect(sys.argv[1]); c.execute("create table config (key TEXT, value JSON, updated_at BIGINT)")
rows = {k: ("text", v) for k, v in base.items()}
for k, o in json.loads(sys.argv[2] if len(sys.argv) > 2 else "{}").items(): rows[k] = tuple(o)
for k, o in rows.items():
    if o[0] == "drop": continue
    v = {"text": lambda: o[1], "int": lambda: int(o[1]), "null": lambda: None, "blob": lambda: o[1].encode(), "pybool": lambda: bool(o[1])}[o[0]]()
    c.execute("insert into config values (?, ?, 0)", (k, v))
c.commit()
PY
GOOD_C4=$'chg-2026-10-20-010 C4 --apply 20261026T000000Z (k8s-engineer)\nbefore: api {"bypass": true}; db {}; state -> x\nRESULT C4 GREEN (bypass false in API + DB, template unchanged with markers)'
wire() { # $1 golive file  $2 case dir  $3 owui-c4 stdout fixture  $4 db overrides JSON ; sets WEV (the evidence)
  local W="$B/wire/$2"; mkdir -p "$W/bin" "$W/hack/ops" "$W/repo/ops/evidence/chg-2026-10-20-010" "$W/cache"
  /usr/bin/python3 -I "$B/mkdb.py" "$W/webui.db" "$4"; printf '%s\n' "$3" > "$W/c4.out"
  printf '#!/bin/bash\ncat %q\n' "$W/c4.out" > "$W/hack/ops/chg-2026-10-20-010-owui-c4.sh"; chmod +x "$W/hack/ops/chg-2026-10-20-010-owui-c4.sh"
  cat > "$W/bin/kubectl" <<EOF
#!/bin/bash
case "\$*" in
  *"get pod"*) echo owui-stub;;
  *"exec -i"*) sed 's#/app/backend/data/webui.db#$W/webui.db#' | /usr/bin/python3 -I -;;
  *) exit 0;;
esac
EOF
  chmod +x "$W/bin/kubectl"
  { sed -n '/^log() {/p; /^chk() {/p' "$1"
    sed -n '/^# >>> c010-c4state/,/^# <<< c010-c4state/p; /^# >>> c010-c4c5/,/^# <<< c010-c4c5/p' "$1"
    sed -n '/--apply | tee -a "\$EV"/,/^gate "C4\/C5"/p' "$1" | sed '$d'; echo 'echo "RED=$RED"'; } > "$W/section.sh"
  (cd "$W" && PATH="$W/bin:/usr/bin:/bin:/usr/sbin:/sbin" REPO="$W/repo" HACK="$W/hack" CHG=chg-2026-10-20-010 NS=family-ai \
     CACHE="$W/cache" EV="$W/ev.txt" RUN_ID=golive-T OWUI_ADMIN_KEY="$TOK" OWUI_SNAPSHOT=snap1 RED=0 \
     bash -c 'set -uo pipefail; : > "$CACHE/run-start"; source ./section.sh' > "$W/run.out" 2>&1)
  WEV=$(cat "$W/ev.txt" 2>/dev/null); export WEV; }
c4v() { grep -E '^  (ok|RED) +C4 green' <<< "$WEV" | awk '{print $1}'; }   # verdict of the C4 chk line
c5v() { grep -E '^  (ok|RED) +C5 task model' <<< "$WEV" | awk '{print $1}'; }
export -f c4v c5v
# case table: name | C4 fixture | DB overrides | expected C4 verdict | expected C5 verdict | reason that must be in the evidence
CASES=(
  "K1 C4 GREEN, golive info lines after it (attempt 4)|$GOOD_C4|{}|ok|ok|C4 GREEN: one owui-c4 RESULT line"
  "K2 C4 GREEN followed by trailing info lines in owui-c4's own output|$GOOD_C4"$'\n  info a\n  info b'"|{}|ok|ok|C4 GREEN: one owui-c4 RESULT line"
  "K3 C4 no RESULT line (owui-c4 stopped at a step)|chg-2026-10-20-010 C4 --apply 20261026T000000Z (k8s-engineer)|{}|RED|ok|C4 RED: 0 owui-c4 RESULT lines"
  "K4 C4 two RESULT lines (both GREEN, the last one GREEN)|$GOOD_C4"$'\n'"RESULT C4 GREEN (again)|{}|RED|ok|C4 RED: 2 owui-c4 RESULT lines"
  "K5 C4 one RESULT line that is RED|chg-2026-10-20-010 C4 --apply x"$'\n'"RESULT C4 RED (read-back failed)|{}|RED|ok|C4 RED: owui-c4 RESULT is not GREEN"
  "P1 C5 live shape: input_max_length stored as INTEGER (the attempt-3/4 crash)|$GOOD_C4|{}|ok|ok|C5 GREEN: 19 task.% keys decoded"
  "P2 C5 int stored in a checked flag (task.tags.enable = 0) is RED, named|$GOOD_C4|{\"task.tags.enable\":[\"int\",0]}|ok|RED|C5 RED: task.tags.enable: expected JSON false, got int"
  "P3 C5 bool written by a Python driver (False -> SQLite stores INTEGER 0) is RED, named|$GOOD_C4|{\"task.follow_up.enable\":[\"pybool\",false]}|ok|RED|C5 RED: task.follow_up.enable: expected JSON false, got int"
  "P4 C5 SQL NULL in task.model.default is allowed|$GOOD_C4|{\"task.model.default\":[\"null\"]}|ok|ok|C5 GREEN"
  "P5 C5 JSON null text in task.model.default is allowed|$GOOD_C4|{\"task.model.default\":[\"text\",\"null\"]}|ok|ok|C5 GREEN"
  "P6 C5 SQL NULL in a checked flag is RED, named|$GOOD_C4|{\"task.query.search.enable\":[\"null\"]}|ok|RED|C5 RED: task.query.search.enable: expected JSON false, got NoneType"
  "P7 C5 JSON-string external = a profiel model is RED|$GOOD_C4|{\"task.model.external\":[\"text\",\"\\\"hermes-agent-profiel-3\\\"\"]}|ok|RED|C5 RED: task.model.external: not household-chat"
  "P8 C5 JSON-string default naming profiel-N is RED|$GOOD_C4|{\"task.model.default\":[\"text\",\"\\\"hermes-agent-profiel-3\\\"\"]}|ok|RED|C5 RED: task.model.default: names a profiel-N model"
  "P9 C5 garbage text in a checked flag is RED with a reason, no crash|$GOOD_C4|{\"task.tags.enable\":[\"text\",\"GARBAGE-c5{\"]}|ok|RED|C5 RED: task.tags.enable: stored text is not JSON"
  "P10 C5 garbage text in any other task.% key is RED with a reason|$GOOD_C4|{\"task.title.prompt_template\":[\"text\",\"GARBAGE-c5{\"]}|ok|RED|C5 RED: task.title.prompt_template: stored text is not JSON"
  "P11 C5 a BLOB value is RED, unsupported type named|$GOOD_C4|{\"task.model.params\":[\"blob\",\"GARBAGE-c5\"]}|ok|RED|C5 RED: task.model.params: unsupported stored type bytes"
  "P12 C5 a missing flag is RED, named|$GOOD_C4|{\"task.query.retrieval.enable\":[\"drop\"]}|ok|RED|C5 RED: task.query.retrieval.enable: missing"
  "P13 C5 a flag that is JSON true is RED, named|$GOOD_C4|{\"task.autocomplete.enable\":[\"text\",\"true\"]}|ok|RED|C5 RED: task.autocomplete.enable: expected JSON false, got bool true"
)
run_cases() { # $1 golive file  $2 tag ; prints "<name>\t<PASS|FAIL>"
  local c n fx db e4 e5 why i=0
  for c in "${CASES[@]}"; do
    i=$((i + 1)); IFS='|' read -r n fx db e4 e5 why <<< "$(printf '%s' "$c" | tr '\n' '\036')"; fx=$(printf '%s' "$fx" | tr '\036' '\n')
    wire "$1" "$2-$i" "$fx" "$db"
    if [ "$(c4v)" = "$e4" ] && [ "$(c5v)" = "$e5" ] && grep -qF "$why" <<< "$WEV" && ! grep -q 'GARBAGE-c5\|Traceback' <<< "$WEV"
    then printf '%s\tPASS\n' "$n"; else printf '%s\tFAIL\t(C4 %s, C5 %s)\n' "$n" "$(c4v)" "$(c5v)"; fi
  done; }
while IFS=$'\t' read -r n r x; do t "$n" [ "$r" = PASS ]; [ "$r" = PASS ] || echo "      $x"; done < <(run_cases "$GL" new)
t "K6 the C4 state info line names the state once (attempt 4 printed rel + abs path)" bash -c "grep -q '^  info C4 state of this run: none\$' '$B/wire/new-1/ev.txt'"
t "K7 golive keeps owui-c4's own stdout per run and judges C4 only on it; no tail of the evidence left" bash -c "grep -q -- '--apply | tee -a \"\$EV\" \"\$CACHE/c4-apply.out\"' '$GL' && grep -q \"c4_result_green '\\\$CACHE/c4-apply.out'\" '$GL' && ! grep -q \"tail -1 '\\\$EV'\" '$GL'"
t "P14 the fixture reproduces the live type table: input_max_length INTEGER, the 18 others TEXT" bash -c "[ \"\$(/usr/bin/python3 -I -c 'import sqlite3,sys; print(sorted(set((t, k == \"task.autocomplete.input_max_length\") for k, t in sqlite3.connect(sys.argv[1]).execute(\"select key, typeof(value) from config\"))))' '$B/wire/new-6/webui.db')\" = \"[('integer', True), ('text', False)]\" ]"
eval "$(sed -n '/^# >>> c010-c4c5/,/^# <<< c010-c4c5/p' "$GL")"; export C5_PY
t "P15 C5 decode() of a real Python bool keeps it: False passes the flag check, True is RED, named (no driver can store a bool)" \
  /usr/bin/python3 -I -c 'import os; exec(os.environ["C5_PY"].split("# --- main")[0])
rows = [(k, False) for k in ("task.tags.enable","task.follow_up.enable","task.autocomplete.enable","task.query.search.enable","task.query.retrieval.enable")]
assert decode("x", False) is False and decode("x", True) is True and decode("x", 5) == 5 and decode("x", None) is None and decode("x", "\"s\"") == "s"
assert check(rows + [("task.model.external", "\"household-chat\"")]) == 6
try: check(rows[1:] + [("task.tags.enable", True), ("task.model.external", "\"household-chat\"")]); raise SystemExit(1)
except Bad as e: assert str(e) == "task.tags.enable: expected JSON false, got bool true", e'
t "P16 C5 an unreadable DB is RED with a named reason, no traceback" bash -c "o=\$(/usr/bin/python3 -I - '$B/no-such.db' <<< \"\$C5_PY\" 2>&1); [ \$? = 1 ] && [ \"\$o\" = 'C5 RED: sqlite read failed (OperationalError)' ]"
t "P17 C5 has no broad except (no bare except / except Exception)" bash -c "! grep -Eq 'except *:|except +(Base)?Exception' <<< \"\$C5_PY\""
# R: the pre-fix golive.sh (reference revision) fails the new C4 and C5 cases
if git -C "$HERE" show "${C010_OLD_C4_REV:-origin/main}:hack/ops/chg-2026-10-20-010-golive.sh" > "$B/old-golive.sh" 2>/dev/null \
   && ! grep -q '^# >>> c010-c4c5' "$B/old-golive.sh"; then
  OLDR=$(run_cases "$B/old-golive.sh" old); printf '%s\n' "$OLDR" | sed 's/^/  pre-fix: /'
  oldfail() { grep -F "$1" <<< "$OLDR" | grep -q $'\tFAIL'; }
  r1() { local k; for k in K1 K2 K3 K4 K5; do oldfail "$k " || return 1; done; }
  r2() { local k; for k in P1 P9 P10; do oldfail "$k " || return 1; done
         grep -q 'TypeError: the JSON object must be str, bytes or bytearray, not int' "$B/wire/old-6/cache/chk.log"; }
  t "R1 pre-fix C4 fails K1+K2 (GREEN read RED after trailing lines) and K3-K5 (no named reason)" r1
  t "R2 pre-fix C5 fails P1 (the int TypeError crash, as in attempts 3+4) and P9/P10 (garbage: traceback, no reason)" r2
  echo "  pre-fix: $(grep -c $'\tFAIL' <<< "$OLDR")/${#CASES[@]} of the new C4/C5 cases FAIL on the pre-fix golive.sh"
else echo "SKIP  R1/R2 (the reference revision already has the c010-c4c5 fix)"; fi
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
