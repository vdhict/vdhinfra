#!/usr/bin/env bash
# chg-2026-10-20-010 offline test (attempt-7 fix, 27-10): golive A8a (Mini count_tokens before the push) and the A8b
# wiring (in-pod count_tokens after the push, before C4).
#
#   bash hack/ops/chg-2026-10-20-010-test-golive-a8.sh [<scratch-dir>]
#   C010_GOLIVE=<path> ...   # same cases against another golive.sh (pre-fix)
#
# Sources the marked `# >>> c010-a8` block of the real golive.sh. Stubs: a key command printing a FAKE key, and a
# loopback fake count_tokens server that records method, path, headers (the fake key only as a match flag) and body,
# and answers with a chosen status. No network beyond 127.0.0.1, no real key, no 1Password. Deletes nothing (AGR-121).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CHG=chg-2026-10-20-010
GOLIVE="${C010_GOLIVE:-$HERE/$CHG-golive.sh}"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-golive-a8-XXXXXX")}"; mkdir -p "$B"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
FAKEKEY="sk-ant-fake-test-key-not-a-secret-$(printf 'x%.0s' $(seq 1 40))"
WS=wrkspc_synthetic0
BLOCK="$B/a8.sh"; sed -n '/^# >>> c010-a8/,/^# <<< c010-a8/p' "$GOLIVE" > "$BLOCK"
t "B0 golive.sh has the c010-a8 block with a8_mini, A8B_PY and a8_pod" bash -c "grep -q '^a8_mini() ' '$BLOCK' && grep -q '^A8B_PY=' '$BLOCK' && grep -q '^a8_pod() ' '$BLOCK'"

# fake count_tokens server: answers $B/status, records the request (key replaced by a flag)
cat > "$B/fake.py" <<PY
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); body = self.rfile.read(n)
        rec = {"path": self.path, "key_is_fake": self.headers.get("x-api-key") == "$FAKEKEY",
               "version": self.headers.get("anthropic-version"), "workspace": self.headers.get("anthropic-workspace-id"),
               "body": json.loads(body or b"{}")}
        open("$B/requests.jsonl", "a").write(json.dumps(rec) + "\n")
        code = int(open("$B/status").read().strip()); self.send_response(code); self.end_headers(); self.wfile.write(b'{"input_tokens": 7}')
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$((41000 + RANDOM % 9000)); python3 "$B/fake.py" "$PORT" & SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 30); do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 0.2; done
printf '#!/bin/bash\nprintf "%%s" "%s"\n' "$FAKEKEY" > "$B/keycmd"; chmod +x "$B/keycmd"
printf '#!/bin/bash\nexit 1\n' > "$B/nokey"; chmod +x "$B/nokey"
settings() { python3 -c 'import json,sys; d={"model":"claude-sonnet-5-5","endpoint":"https://api.anthropic.com/v1"}; w=sys.argv[2]
if w != "-": d["workspace_id"]=w
json.dump(d, open(sys.argv[1],"w"))' "$1" "$2"; }
run() { # $1 settings file  $2 key cmd  [$3 url] -> out + rc; counts requests
  : > "$B/requests.jsonl"
  OUT=$(C010_CLOUD_KEY_CMD="$2" C010_A8_URL="${3:-http://127.0.0.1:$PORT/v1/messages/count_tokens}" bash -c ". '$BLOCK'; a8_mini '$1'" 2>&1); RC=$?
  NREQ=$(grep -c . "$B/requests.jsonl"); }
settings "$B/s-ok.json" "$WS"; echo 200 > "$B/status"; run "$B/s-ok.json" "$B/keycmd"
t "A1 200 -> rc 0, one line 'A8a count_tokens status 200'" bash -c "[ $RC = 0 ] && [ '$OUT' = 'A8a count_tokens status 200 (Mini egress; free, synthetic)' ]"
t "A1 exactly one POST to /v1/messages/count_tokens with the key, version 2023-06-01 and the bundle workspace id" bash -c "
  [ $NREQ = 1 ] && python3 -c 'import json; r=json.loads(open(\"$B/requests.jsonl\").readline()); assert r[\"path\"]==\"/v1/messages/count_tokens\" and r[\"key_is_fake\"] and r[\"version\"]==\"2023-06-01\" and r[\"workspace\"]==\"$WS\"'"
t "A1 body = bundle model + synthetic text only" bash -c "python3 -c 'import json; r=json.loads(open(\"$B/requests.jsonl\").readline()); assert r[\"body\"]=={\"model\":\"claude-sonnet-5-5\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic token count\"}]}'"
for code in 400 401 404 429 529; do
  echo $code > "$B/status"; run "$B/s-ok.json" "$B/keycmd"
  t "A2 status $code -> rc 1 and the number in the line" bash -c "[ $RC = 1 ] && [ '$OUT' = 'A8a count_tokens status $code (Mini egress; free, synthetic)' ]"
done
echo 200 > "$B/status"
for w in - "" wrkspc_ "wrkspc_bad-id" "nope"; do
  settings "$B/s-bad.json" "$w"; run "$B/s-bad.json" "$B/keycmd"
  t "A3 workspace '${w}' -> rc 1, NO request at all" bash -c "[ $RC = 1 ] && [ $NREQ = 0 ] && echo '$OUT' | grep -q 'no valid workspace_id'"
done
run "$B/s-ok.json" "$B/nokey"
t "A4 key not readable (no 1Password session) -> rc 1, no request" bash -c "[ $RC = 1 ] && [ $NREQ = 0 ] && echo '$OUT' | grep -q 'cloud key not readable'"
run "$B/s-ok.json" "$B/keycmd" "https://example.invalid/v1/messages/count_tokens"
t "A5 a test URL override to anything but 127.0.0.1 is refused, no request" bash -c "[ $RC = 1 ] && [ $NREQ = 0 ] && echo '$OUT' | grep -q 'refused test URL'"
# key never in argv: run with a curl wrapper that logs its argv
mkdir -p "$B/bin"; printf '#!/bin/bash\necho "$@" >> "%s/curl-argv.log"\nexec /usr/bin/curl "$@"\n' "$B" > "$B/bin/curl"; chmod +x "$B/bin/curl"
: > "$B/curl-argv.log"; echo 200 > "$B/status"
OUT=$(PATH="$B/bin:$PATH" C010_CLOUD_KEY_CMD="$B/keycmd" C010_A8_URL="http://127.0.0.1:$PORT/v1/messages/count_tokens" bash -c ". '$BLOCK'; a8_mini '$B/s-ok.json'" 2>&1)
t "A6 the key is never in curl argv nor in the output (stdin config only)" bash -c "[ -s '$B/curl-argv.log' ] && ! grep -q 'sk-ant-fake' '$B/curl-argv.log' && ! echo '$OUT' | grep -q 'sk-ant-fake'"
# wiring in golive
t "W1 A8a is a preflight chk on the bundle's settings.json, before any push" bash -c "
  a=\$(grep -n '^chk \"A8a free count_tokens' '$GOLIVE' | cut -d: -f1); p=\$(grep -n '^deploy_push ||' '$GOLIVE' | cut -d: -f1)
  [ -n \"\$a\" ] && [ \"\$a\" -lt \"\$p\" ] && grep -A1 '^chk \"A8a free count_tokens' '$GOLIVE' | grep -q \"a8_mini '\\\$CACHE/new/plugins/model-providers/family-cloud/settings.json'\""
t "W2 A8b runs after gate \"restart checks\" and its own gate comes before C4" bash -c "
  r=\$(grep -n '^gate \"restart checks\"' '$GOLIVE' | cut -d: -f1); b=\$(grep -n '^chk \"A8b in-pod count_tokens' '$GOLIVE' | cut -d: -f1)
  g=\$(grep -n '^gate \"A8 count_tokens\"' '$GOLIVE' | cut -d: -f1); c=\$(grep -n '^log \"== C4 + C5\"' '$GOLIVE' | cut -d: -f1)
  [ -n \"\$b\" ] && [ \"\$r\" -lt \"\$b\" ] && [ \"\$b\" -lt \"\$g\" ] && [ \"\$g\" -lt \"\$c\" ]"
t "W3 A8b uses the deployed plugin's count_tokens_status and prints the status only" bash -c "
  grep -q 'mod.count_tokens_status(settings)' '$BLOCK' && ! grep -q 'response.text\|\.json()' '$BLOCK'"
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
