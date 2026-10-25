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
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
