#!/usr/bin/env bash
# chg-2026-10-20-010 go session (Atlas 25-10): one script that holds a short-lived Open WebUI admin SESSION (no API
# key is minted) for golive.sh --go, then runs the extra canary turns and the go-time readbacks.
#
#   hack/ops/chg-2026-10-20-010-go-session.sh <deploy-sha> <w2-event-ts>
#
#  0. admin access (Argus 11:58:52Z): an in-pod create_token() for the service admin, <= 120 min, no signin, no API key.
#  1. (superseded by 0) formerly: sign in as the team-provisioned service admin: email + password went
#     from the Secret straight into the request body on stdin (never argv, never a file, never printed); the
#     returned session JWT lives in this process only; its exp claim is recorded (timestamp only).
#  2. harmless admin GET (/api/v1/users/?query=..., body discarded) must be 200 with the JWT as Bearer, else stop.
#  3. golive.sh --go <sha> --w2-event <ts> with OWUI_ADMIN_KEY = the JWT in its environment only.
#  4. after a GREEN go: extra synthetic canary turns INSIDE the hermes-profiel-3 pod (API_SERVER_KEY read there,
#     never leaves the pod; responses discarded unread; numbers only):
#       E1 X-Hermes-Session-Id <fresh synthetic id>  -> Studio (month.json unchanged)
#       E2 POST /v1/runs, session-shaped wake path      -> Studio (month.json unchanged)
#       E3 header-less public first turn               -> cloud (input tokens up, 0 < usd delta <= 0.2048)
#          + replay post: that session's Hermes system text == cloud SOUL + date only
#     F2 (attempt 10): no rule cloud_ok route record from golive's push to the end outside golive's C6 windows and E3.
#     Cloud budget of a GREEN go (attempt 10): golive C6 2 + E3 1 = 3 real cloud turns (was C6 3 + C7 lesstof 1 + E3 1 = 5).
#     plus go-time readbacks: runtime_pinned() True, HERMES_INSTALL_ROOT / HERMES_PLUGIN_HOST_PROCESS unset, every
#     PINNED_SOURCES hash, OWUI connection to hermes-profiel-3 = chat completions (type only), profiel-1/2 W3/W4.
#     ANY red -> automatic rollback: owui-c4 --rollback (state from the go) + rollback.sh --execute with a fresh
#     scoped token, read back cloud off.
#  5. the temporary canary account is gone (read back), then sign out and prove the JWT is refused (401) or
#     record that OWUI keeps it valid until exp.
# Evidence: ops/evidence/chg-2026-10-20-010/k8s-go-session-<ts>.txt (write-once; codes, counts, deltas only).
# No rm (AGR-121). Never prints the JWT, the password, the API key or any response content.
set -uo pipefail
SHA="${1:?deploy sha}"; W2TS="${2:?w2 event ts}"
CHG=chg-2026-10-20-010; NS=family-ai
REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
SRC="$(git rev-parse --show-toplevel)"; HACK="$SRC/hack"
TS=$(date -u +%Y%m%dT%H%M%SZ); CACHE="$HOME/.cache/$CHG/go-session-$TS"; mkdir -p "$CACHE"; chmod 700 "$CACHE"
EV="$REPO/ops/evidence/$CHG/k8s-go-session-$TS.txt"; [ ! -e "$EV" ] || { echo "evidence exists" >&2; exit 1; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
export FAMILY_AI_REPO="${FAMILY_AI_REPO:-$HOME/.cache/$CHG/fai-cutoff-wt-v0225}"
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$EV"; }
RED=0; red() { log "  RED  $*"; RED=1; }
okl() { log "  ok   $*"; }
log "$CHG go session $TS deploy=$SHA w2=$W2TS (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"

# ---------------------------------------------------------------- OWUI port-forward + session
OW=$(kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
PF=""; trap 'kill $PF 2>/dev/null || true' EXIT
pf_up() { # (re)open the port-forward to the OWUI pod; the 11:36Z run lost it during the go
  [ -n "$PF" ] && kill $PF 2>/dev/null; PORT=$((20000 + RANDOM % 20000))
  kubectl -n $NS port-forward "pod/$OW" "$PORT:8080" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 30); do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 1; done
  U="http://127.0.0.1:$PORT"; nc -z 127.0.0.1 $PORT 2>/dev/null; }
pf_up || { log "STOP: no port-forward to OWUI"; exit 2; }
: > "$CACHE/session-start"
# >>> c010-owui-auth (Argus 25-10 11:58:52Z admin_access; sourced as-is by hack/ops/chg-2026-10-20-010-test-owui-auth.sh)
# No signin, no API key: the open-webui pod mints a short-lived admin token with OWUI's own create_token() for the
# team service admin (id looked up read-only by WEBUI_ADMIN_EMAIL, role must be admin), expires_delta 120 min. The
# token travels only over the kubectl exec stdout into a shell variable; headers go to curl on stdin; it is never
# printed, logged or stored, nor is its jti. Recorded: exp and the id class (service admin). Overridable: owui_mint.
ADMIN=""; EXP=""
owui_mint() { # stdout: "C010TOKEN <token>" (one line) or nothing
  kubectl -n $NS exec -i "$OW" -c app -- sh -c 'cd /app/backend && python3 - 2>/dev/null' <<'PY' | grep '^C010TOKEN ' | tail -1
import os, sqlite3
from datetime import timedelta
c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
rows = c.execute("select id, role from user where email = ?", (os.environ.get("WEBUI_ADMIN_EMAIL", "").strip(),)).fetchall()
if len(rows) == 1 and rows[0][1] == "admin":
    from open_webui.utils.auth import create_token
    print("C010TOKEN " + create_token({"id": rows[0][0]}, expires_delta=timedelta(minutes=120)))
PY
}
token_check() { # stdin: token -> prints "<exp ISO>" when claims are exactly id/iat/exp/jti and exp-iat <= 120 min, else "BAD <why>"
  /usr/bin/python3 -I -c 'import sys,json,base64,datetime as d
t=sys.stdin.read().strip().split(".")
try:
    p=json.loads(base64.urlsafe_b64decode(t[1]+"="*(-len(t[1])%4)))
except Exception: print("BAD unreadable"); sys.exit()
if set(p) != {"id","iat","exp","jti"}: print("BAD claims %s" % sorted(k for k in p if k != "jti")); sys.exit()
if not (0 < p["exp"] - p["iat"] <= 7200 + 5): print("BAD lifetime %d s" % (p["exp"] - p["iat"])); sys.exit()
print(d.datetime.fromtimestamp(p["exp"], d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
breq_with() { # $1 token $2 method $3 path : prints body then the HTTP code on the last line
  { printf 'header = "Authorization: Bearer %s"\n' "$1"; printf 'header = "Content-Type: application/json"\n'; } \
    | /usr/bin/curl -s -K - -X "$2" -w '\n%{http_code}' --max-time 30 "$U$3"; }
breq() { breq_with "$ADMIN" "$@"; }
code_of() { tail -1; }
owui_auth_begin() { # -> ADMIN set, or returns 2 with a STOP line
  local r; r="$(owui_mint)"; ADMIN="${r#C010TOKEN }"; r=""
  if [ "${#ADMIN}" -lt 20 ]; then ADMIN=""; log "STOP: in-pod create_token gave no admin token (service admin not found or not admin)"; return 2; fi
  EXP=$(printf '%s' "$ADMIN" | token_check)
  case "$EXP" in BAD*) log "STOP: minted token refused: ${EXP#BAD }"; ADMIN=""; return 2;; esac
  okl "OWUI admin token minted in the open-webui pod via create_token (service admin, <= 120 min, no signin): exp $EXP"
  local c1 c2; c1=$(breq GET "/api/v1/users/?query=c010-canary" | code_of); c2=$(breq GET "/api/v1/groups/" | code_of)
  if [ "$c1" != 200 ] || [ "$c2" != 200 ]; then log "STOP: OWUI does not accept the minted token as Bearer for admin GETs (users=$c1 groups=$c2)"; owui_auth_end; return 2; fi
  okl "harmless admin GETs accept the minted token: users=$c1 groups=$c2 (bodies discarded)"
}
owui_auth_end() { [ -n "$ADMIN" ] && log "  info admin token dropped from memory; it expires by itself at $EXP (no signin session exists)"; ADMIN=""; }
# <<< c010-owui-auth
owui_auth_begin || exit 2
canary_count() { BODY=1 breq GET "/api/v1/users/?query=c010-canary" | sed '$d' | /usr/bin/python3 -I -c 'import json,sys
d=json.load(sys.stdin); us=d.get("users", d) if isinstance(d, dict) else d
print(sum(1 for u in us if isinstance(u, dict) and u.get("email")=="c010-canary@acceptatie.invalid"))'; }
canary_db() { kubectl -n $NS exec -i "$OW" -c app -- python3 -c "import sqlite3; c=sqlite3.connect('file:/app/backend/data/webui.db?mode=ro', uri=True); print(c.execute(\"select count(*) from user where email = 'c010-canary@acceptatie.invalid'\").fetchone()[0])" 2>/dev/null; }
log "  info canary account before go: api=$(canary_count) db=$(canary_db)"

# ---------------------------------------------------------------- golive --go (the reviewed runbook)
OWUI_ADMIN_KEY="$ADMIN" bash "$HACK/ops/$CHG-golive.sh" --go "$SHA" --w2-event "$W2TS" > "$CACHE/golive.out" 2>&1; GRC=$?
GEV=$(ls -t "$REPO/ops/evidence/$CHG/"k8s-golive-*-go.txt 2>/dev/null | head -1)
log "golive --go rc=$GRC evidence ${GEV#$REPO/}: $(grep -E '^RESULT' "$GEV" 2>/dev/null | tail -1)"
grep -E 'RED|ROLLBACK' "$GEV" 2>/dev/null | head -10 | sed 's/^/    /' | tee -a "$EV"
SNAP=$(kubectl -n $NS get volumesnapshot -l change=$CHG -o jsonpath='{range .items[*]}{.metadata.name} {.status.readyToUse}{"\n"}{end}' 2>/dev/null | grep "$(grep -o 'golive [0-9TZ]*' "$GEV" | head -1 | awk '{print $2}' | tr 'TZ' 'tz')" )
log "  info snapshots of this go: $(echo $SNAP)"
# only a C4 state written during THIS session (never an older dry-run's)
C4STATE=$(find "$REPO/ops/evidence/$CHG" -maxdepth 1 -name 'k8s-owui-c4-*-before.json' -newer "$CACHE/session-start" 2>/dev/null | sort | tail -1)
log "  info C4 state of this go: ${C4STATE:+${C4STATE#$REPO/}}${C4STATE:-none (C4 not applied)}"

# >>> c010-gs-f2 (attempt 10; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-f6.sh)
# golive's route reader + F2 helpers, taken verbatim from the golive.sh of this checkout (reviewed together)
eval "$(sed -n "/^C6LOG_PY='/,/^print(json.dumps(out))'/p" "$HACK/ops/$CHG-golive.sh")"
eval "$(sed -n '/^# >>> c010-f6/,/^# <<< c010-f6/p' "$HACK/ops/$CHG-golive.sh")"
pod() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
xp() { kubectl -n $NS exec "$1" -c app -- "${@:2}"; }
f2_go_session() { # $1 golive evidence $2 E3 start-1 $3 E3 end+2 (pod epoch) ; rc 0 iff F2 holds
  local l from c6 o rc
  l=$(grep -o 'F2 windows from=[0-9]\{10\} c6=[0-9:,]*' "$1" 2>/dev/null | tail -1)
  [ -n "$l" ] || { log "  RED  F2: golive evidence has no 'F2 windows' line"; return 1; }
  [[ "$2" =~ ^[0-9]{10}$ ]] && [[ "$3" =~ ^[0-9]{10}$ ]] || { log "  RED  F2: no E3 window"; return 1; }
  from=${l#*from=}; from=${from%% *}; c6=${l#*c6=}
  o=$(f2_check "$from" "${c6:+$c6,}$2:$3"); rc=$?
  log "  $o (windows C6 ${c6:-none} + E3 $2:$3)"; return $rc; }
# <<< c010-gs-f2
rollback_all() { # $1 reason
  log "ROLLBACK (go session): $1"
  [ -n "$C4STATE" ] && OWUI_ADMIN_KEY="$ADMIN" "$HACK/ops/$CHG-owui-c4.sh" --rollback "$C4STATE" >> "$CACHE/rollback.out" 2>&1 \
    && okl "owui-c4 --rollback" || log "  info owui-c4 rollback rc!=0 or no state"
  local t; t="$(/usr/bin/python3 -I "$HACK/ops/$CHG-mint.py" mint 2>>"$CACHE/mint.log")"
  if [ "${#t}" -ge 20 ]; then
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$t" | base64 | tr -d '\n')" \
      bash "$HACK/ops/$CHG-rollback.sh" --execute "$SHA" "go session red: $1" > "$CACHE/rollback-exec.out" 2>&1; local rc=$?
    printf '%s' "$t" | /usr/bin/python3 -I "$HACK/ops/$CHG-mint.py" revoke 2>>"$CACHE/mint.log" || true; t=""
  else rc=9; log "  RED  token mint failed for the rollback push"; fi
  log "  rollback.sh --execute rc=$rc: $(grep -E '^RESULT' "$CACHE/rollback-exec.out" | tail -1)"
  ! kubectl -n $NS get cnp hermes-profiel-3-cloud >/dev/null 2>&1 && okl "cloud off: CNP hermes-profiel-3-cloud gone" || red "CNP still present after rollback"
}

if [ $GRC = 0 ]; then
  P3=$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-3 --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  # ---------------------------------------------------------- step 5: go-time readbacks in the pod
  R5=$(kubectl -n $NS exec "$P3" -c app -- env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c "$(cat "$HACK/ops/$CHG-pin-probe.py")" 2>/dev/null)
  log "  step5 profiel-3 $P3 pin-probe: $R5"
  echo "$R5" | /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") and d.get("pins_ok")==d.get("pins_total")>=24 else 1)' \
    && okl "step5 runtime_pinned True (exactly the plugin's PINNED_MODULES), all PINNED_SOURCES match, HERMES_INSTALL_ROOT + HERMES_PLUGIN_HOST_PROCESS unset" || red "step5 in-pod readback"
  CT=$(kubectl -n $NS exec -i "$OW" -c app -- python3 - <<'PY'
import sqlite3, json
c = sqlite3.connect('file:/app/backend/data/webui.db?mode=ro', uri=True)
kv = dict(c.execute("select key, value from config where key in ('openai.api_base_urls','openai.api_configs')"))
urls = json.loads(kv.get('openai.api_base_urls', '[]')); cfg = json.loads(kv.get('openai.api_configs', '{}'))
idx = [i for i, u in enumerate(urls) if u.rstrip('/').startswith('http://hermes-profiel-3:8642')]
out = []
for i in idx:
    t = (cfg.get(str(i)) or {}).get('api_type')
    out.append("idx %d api_type=%s -> %s" % (i, t or 'unset', 'responses' if t == 'responses' else 'chat-completions'))
print("; ".join(out) or "no hermes-profiel-3 connection")
PY
)
  log "  step5 OWUI connection to hermes-profiel-3 (type only): $CT"
  echo "$CT" | grep -q 'chat-completions' && ! echo "$CT" | grep -q -- '-> responses' && okl "OWUI connection is chat completions" || red "OWUI connection type"

  # ---------------------------------------------------------- step 6: extra canary turns (numbers only)
  E=$(kubectl -n $NS exec -i "$P3" -c app -- env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python - <<'PY'
import json, os, time, urllib.request, secrets
K = os.environ["API_SERVER_KEY"]; B = "http://127.0.0.1:%s" % os.environ.get("API_SERVER_PORT", "8642")
def ledger():
    d = json.load(open("/cloud-spend/month.json")); return d["usd"], d["input_tokens"]
def fails():
    try: return open("/opt/data/logs/agent.log", errors="replace").read().count("family-cloud: cloud call failed")
    except Exception: return -1
def post(path, body, extra=None):
    h = {"Authorization": "Bearer " + K, "Content-Type": "application/json"}; h.update(extra or {})
    r = urllib.request.Request(B + path, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(r, timeout=240) as resp: return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e: return e.code, {}
def get(path):
    r = urllib.request.Request(B + path, headers={"Authorization": "Bearer " + K})
    with urllib.request.urlopen(r, timeout=30) as resp: return json.loads(resp.read() or b"{}")
model = os.environ.get("API_SERVER_MODEL_NAME", "hermes-agent")
out = []
def turn(name, fn):
    u0, t0 = ledger(); f0 = fails(); st = time.time(); code = fn(); en = time.time(); time.sleep(5); u1, t1 = ledger()
    out.append({"turn": name, "http": code, "usd_delta": round(u1 - u0, 6), "input_tokens_delta": t1 - t0,
                "fail_lines_delta": fails() - f0, "start": st, "end": en})
sid = "c010-canary-" + secrets.token_hex(6)
turn("E1 X-Hermes-Session-Id (synthetic id)", lambda: post("/v1/chat/completions",
     {"model": model, "stream": False, "messages": [{"role": "user", "content": "Hoeveel dagen heeft een week? Kort."}]},
     {"X-Hermes-Session-Id": sid})[0])
def runs():
    c, d = post("/v1/runs", {"model": model, "input": "Hoeveel maanden heeft een jaar? Kort.", "session_id": "c010-canary-run-" + secrets.token_hex(6)})
    rid = d.get("run_id") or d.get("id")
    if c not in (200, 201, 202) or not rid: return c
    for _ in range(80):
        s = get("/v1/runs/" + rid).get("status", "")
        if s in ("completed", "failed", "cancelled", "error"): return 200 if s == "completed" else ("run " + s)
        time.sleep(3)
    return "run timeout"
turn("E2 /v1/runs session-shaped (wake path)", runs)
turn("E3 header-less public first turn", lambda: post("/v1/chat/completions",
     {"model": model, "stream": False, "messages": [{"role": "user", "content": "Noem drie kleuren van de regenboog. Kort. " + secrets.token_hex(3)}]})[0])
print(json.dumps(out))
PY
)
  printf '%s' "$E" | /usr/bin/python3 -I -c 'import json,sys
for t in json.load(sys.stdin): print("  canary %-42s http=%s usd_delta=%s input_tokens_delta=%s fail_lines_delta=%s" % (t["turn"], t["http"], t["usd_delta"], t["input_tokens_delta"], t["fail_lines_delta"]))' | tee -a "$EV"
  E3START=$(printf '%s' "$E" | /usr/bin/python3 -I -c 'import json,sys; print(int(json.load(sys.stdin)[2]["start"]) - 1)' 2>/dev/null)
  E3END=$(printf '%s' "$E" | /usr/bin/python3 -I -c 'import json,sys; print(int(json.load(sys.stdin)[2]["end"]) + 2)' 2>/dev/null)
  printf '%s' "$E" | /usr/bin/python3 -I -c 'import json,sys
t = json.load(sys.stdin); e1, e2, e3 = t
studio = lambda x: x["http"] == 200 and x["usd_delta"] == 0 and x["input_tokens_delta"] == 0 and x["fail_lines_delta"] == 0
cloud = e3["http"] == 200 and e3["input_tokens_delta"] > 0 and 0 < e3["usd_delta"] <= 0.2048 and e3["fail_lines_delta"] == 0
sys.exit(0 if studio(e1) and studio(e2) and cloud else 1)' \
    && okl "step6 E1 -> Studio, E2 -> Studio, E3 -> cloud (0 < usd delta <= 0.2048)" || red "step6 extra canary routing"
  # E3 system text: the reviewed replay (post mode) on that session, pins from the deployed bundle
  mkdir -p "$CACHE/b"; sops -d --extract '["data"]["bundle.tar.gz"]' "$SRC/kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml" | base64 -d | tar -xzf - -C "$CACHE/b"
  /usr/bin/python3 -I - "$CACHE/b/plugins" "${E3START:-0}" > "$CACHE/replay-in.json" <<'PY'
import base64, hashlib, json, sys
d, since = sys.argv[1] + "/", float(sys.argv[2])
rels = ["model-providers/family-cloud/__init__.py", "model-providers/family-cloud/settings.json", "model-providers/family-cloud/cloud-SOUL.md", "gezin/__init__.py"]
json.dump({"mode": "post", "since": since, "pins": {r: hashlib.sha256(open(d + r, "rb").read()).hexdigest() for r in rels}, "files": {}}, sys.stdout)
PY
  kubectl -n $NS exec -i "$P3" -c app -- env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c "$(cat "$HACK/ops/$CHG-replay.py")" < "$CACHE/replay-in.json" > "$CACHE/replay-e3.json"; RRC=$?
  log "  step6 E3 replay post (system text): rc=$RRC $(jq -c '{mode, result, system_sha, want_sha}' "$CACHE/replay-e3.json" 2>/dev/null)"
  [ $RRC = 0 ] && okl "step6 E3 Hermes system text == cloud SOUL + date only" || red "step6 E3 system text"
  # ---------------------------------------------------------- F2 over the whole go (attempt 10, owner 27-10)
  # No rule cloud_ok route record from golive's push to now outside golive's C6 windows and this E3 window.
  # golive logs "F2 windows from=<pod epoch> c6=<a:b,...>"; the reader is golive's own c010-f6 block (C6LOG_PY).
  f2_go_session "$GEV" "${E3START:-}" "${E3END:-}" || red "F2 cloud_ok outside the C6/E3 windows (or unreadable)"
  # ---------------------------------------------------------- step 8: profiel-1/2 unchanged (W3/W4)
  for n in 1 2; do
    Pn=$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-$n --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
    k=$(kubectl -n $NS get secret family-ai-hermes-profiel-$n -o json | jq '.data | has("CLOUD_API_KEY")')
    envk=$(kubectl -n $NS exec "$Pn" -c app -- sh -c 'env | cut -d= -f1' | grep -c '^CLOUD_')
    eg=$(kubectl -n $NS exec "$Pn" -c app -- /opt/hermes/.venv/bin/python -c 'import socket
try: socket.create_connection(("api.anthropic.com", 443), timeout=6).close(); print("CONNECTED")
except Exception: print("blocked")' 2>/dev/null)
    fc=$(kubectl -n $NS exec "$Pn" -c app -- sh -c 'test -e /opt/data/plugins/model-providers/family-cloud && echo present || echo absent')
    log "  step8 profiel-$n: secret CLOUD_API_KEY=$k env CLOUD_*=$envk egress api.anthropic.com:443=$eg family-cloud=$fc"
    [ "$k" = false ] && [ "$envk" = 0 ] && [ "$eg" = blocked ] && [ "$fc" = absent ] && okl "step8 profiel-$n no key, no cloud egress" || red "step8 profiel-$n"
  done
  [ $RED = 0 ] || rollback_all "go-time readback or extra canary red"
else
  log "golive was not GREEN (rc=$GRC): its own rollback/stop applies; no extra canary"
  RED=1
  # >>> c010-gs-fallback (attempt-5 fix, 27-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-exit.sh)
  # Never trust that golive rolled back (attempt 5: it exited after C6 without its rollback and cloud stayed on).
  # Source of truth = origin/main: if the deploy is on main and the cloud CNP file is still there, roll back here.
  git -C "$SRC" fetch -q origin main 2>/dev/null || log "  info git fetch failed; using the local origin/main ref"
  if git -C "$SRC" merge-base --is-ancestor "$SHA" origin/main 2>/dev/null \
     && git -C "$SRC" cat-file -e "origin/main:kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml" 2>/dev/null; then
    log "  RED  golive red but the deploy $SHA is on main with the cloud CNP file: go session rolls back"
    rollback_all "golive rc=$GRC left the deploy on main"
  else
    okl "after golive red: the cloud wiring is not on origin/main (not pushed, or reverted)"
    ! kubectl -n $NS get cnp hermes-profiel-3-cloud >/dev/null 2>&1 && okl "cloud off: CNP hermes-profiel-3-cloud absent" || red "CNP hermes-profiel-3-cloud still present although not on main"
  fi
  # <<< c010-gs-fallback
fi

# ---------------------------------------------------------------- canary account gone, then end the session
pf_up || log "  info port-forward could not be re-opened (DB readback still runs)"
na=$(canary_count 2>/dev/null); nd=$(canary_db); log "  canary account after go: db=$nd api=${na:-n/a} (expect 0)"
[ "$nd" = 0 ] && okl "temporary canary account deleted (read back from the OWUI database)" || red "canary account still present (db=$nd)"
owui_auth_end
log "RESULT go-session $([ $RED = 0 ] && echo GREEN || echo RED)"
"$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$SHA" --arg ev "${EV#$REPO/}" --arg g "${GEV#$REPO/}" \
  --arg r "$([ $RED = 0 ] && echo GREEN || echo RED)" --arg exp "$EXP" \
  '{step:"go session: in-pod OWUI admin token + golive --go (C2 posthash AND keys, pin-probe) + extra canary E1-E3 + step 5/8 readbacks", deploy:$s, result:$r, evidence:$ev, golive_evidence:$g,
    owui_admin:("in-pod create_token for the service admin, no signin, no API key, env only, never printed or logged (incl jti); exp " + $exp),
    authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
exit $RED
