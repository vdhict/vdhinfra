#!/usr/bin/env bash
# chg-2026-10-20-010 offline tests of the `# >>> c010-owui-auth` block of hack/ops/chg-2026-10-20-010-go-session.sh
# (Argus 25-10 11:58:52Z admin_access: in-pod create_token, <= 120 min, no signin, no API key), against a stub
# Open WebUI on 127.0.0.1. owui_mint is replaced by a fake that returns a JWT-shaped test token.
#
#   bash hack/ops/chg-2026-10-20-010-test-owui-auth.sh [<scratch-dir>]
#
# The stub logs method, path and whether the presented credential was the registered token (never values).
# Deletes nothing (AGR-121). Exit 0 iff all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; GS="$HERE/chg-2026-10-20-010-go-session.sh"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-owui-auth-XXXXXX")}"; mkdir -p "$B"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
cat > "$B/stub.py" <<'PY'
import sys, http.server
port, mode, logf, tokf = int(sys.argv[1]), set(sys.argv[2].split(",")), sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def who(self):
        a = self.headers.get("Authorization", "")
        return "token" if a == "Bearer " + open(tokf).read().strip() else ("other" if a else "none")
    def send(self, c): self.send_response(c); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b'{"users": []}')
    def rec(self): open(logf, "a").write("%s %s auth=%s\n" % (self.command, self.path.split("?")[0], self.who()))
    def do_POST(self): self.rec(); self.send(401)
    def do_DELETE(self): self.rec(); self.send(401)
    def do_GET(self):
        self.rec()
        if "reject_bearer" in mode: return self.send(401)
        self.send(200 if self.who() == "token" and (self.path.startswith("/api/v1/users/") or self.path.startswith("/api/v1/groups/")) else 401)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
fake() { # $1 lifetime seconds  $2 extra claims json fragment -> JWT-shaped token
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  /usr/bin/python3 -I -c 'import base64,json,sys,time,uuid
b=lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
now=int(time.time()); p={"id":"svc-admin-test","iat":now,"exp":now+int(sys.argv[1]),"jti":"jti-"+uuid.uuid4().hex}; p.update(json.loads(sys.argv[2]))
print("%s.%s.c2lnbmF0dXJl" % (b({"alg":"HS256","typ":"JWT"}), b(p)))' "$1" "$extra"; }
case_run() { # $1 name  $2 stub mode  $3 token (or "") -> D
  D="$B/$1"; mkdir -p "$D"; printf '%s' "$3" > "$D/token"; local port=$((30000 + RANDOM % 20000))
  /usr/bin/python3 -I "$B/stub.py" $port "$2" "$D/stub.log" "$D/token" & local sp=$!
  for _ in $(seq 1 30); do nc -z 127.0.0.1 $port 2>/dev/null && break; sleep 0.2; done
  bash -c '
    U="http://127.0.0.1:'"$port"'"; NS=x; OW=x; RED=0
    log() { echo "$(date -u +%FT%TZ) $*" >> "'"$D"'/out.log"; }; okl() { log "  ok   $*"; }; red() { log "  RED  $*"; RED=1; }
    '"$(sed -n '/^# >>> c010-owui-auth/,/^# <<< c010-owui-auth/p' "$GS")"'
    owui_mint() { [ -s "'"$D"'/token" ] && printf "C010TOKEN %s\n" "$(cat "'"$D"'/token")"; }
    owui_auth_begin; rc=$?; echo "begin=$rc exp=${EXP:-none}" >> "'"$D"'/out.log"
    [ $rc = 0 ] && { [ -n "$ADMIN" ] && echo "admin=set" >> "'"$D"'/out.log"; owui_auth_end; }
    echo "admin_after=${ADMIN:-empty}" >> "'"$D"'/out.log"'
  kill $sp 2>/dev/null; wait $sp 2>/dev/null
}
T120=$(fake 7200)
case_run t1 ok "$T120"
t "T1 minted token (120 min): admin GETs with it, exp recorded, NO signin / api_key request at all" bash -c "grep -q 'begin=0 exp=20' '$D/out.log' && grep -q 'admin=set' '$D/out.log' && grep -q 'GET /api/v1/users/ auth=token' '$D/stub.log' && grep -q 'GET /api/v1/groups/ auth=token' '$D/stub.log' && ! grep -q -E 'signin|api_key|POST|DELETE' '$D/stub.log'"
t "T1 end: admin token dropped, only exp logged" bash -c "grep -q 'admin_after=empty' '$D/out.log' && grep -q 'expires by itself at' '$D/out.log'"
case_run t2 ok "$(fake 10800)"
t "T2 token lifetime 3 h (> 120 min) -> STOP, not used" bash -c "grep -q 'STOP: minted token refused: lifetime 10800 s' '$D/out.log' && [ ! -s '$D/stub.log' ]"
case_run t3 ok "$(fake 7200 '{"role": "admin"}')"
t "T3 token with an extra claim -> STOP" bash -c "grep -q 'STOP: minted token refused: claims' '$D/out.log' && [ ! -s '$D/stub.log' ]"
case_run t4 ok ""
t "T4 mint returns nothing (service admin not found) -> STOP" bash -c "grep -q 'STOP: in-pod create_token gave no admin token' '$D/out.log' && grep -q 'begin=2' '$D/out.log'"
case_run t5 reject_bearer "$T120"
t "T5 OWUI refuses the minted token on admin GETs -> STOP, token dropped" bash -c "grep -q 'STOP: OWUI does not accept the minted token' '$D/out.log' && grep -q 'admin_after=empty' '$D/out.log'"
case_run t6 ok "not-a-jwt-header.not-base64-json!!.sig"
t "T6 unreadable token -> STOP" bash -c "grep -q 'STOP: minted token refused: unreadable' '$D/out.log'"
t "T7 no token, jti or signature in any output" bash -c "! grep -r -q -E 'jti-|c2lnbmF0dXJl|eyJ' '$B'/t*/out.log"
export BLK="$(sed -n '/^# >>> c010-owui-auth/,/^# <<< c010-owui-auth/p' "$GS")"
t "T8 static: block has no signin / api_key / signout call, mints with create_token(expires_delta=timedelta(minutes=120))" bash -c "! grep -q -E '/auths/(signin|api_key|signout)' <<< \"\$BLK\" && grep -q 'create_token({\"id\": rows\[0\]\[0\]}, expires_delta=timedelta(minutes=120))' <<< \"\$BLK\""
t "T9 static: the token never reaches argv or a log line (headers via curl -K -, no echo/log of ADMIN)" bash -c "grep -q \"printf 'header = .Authorization: Bearer %s.\" <<< \"\$BLK\" && ! grep -E '(log|okl|echo)[^#]*\\\$ADMIN' <<< \"\$BLK\""
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
