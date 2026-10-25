#!/usr/bin/env bash
# chg-2026-10-20-010 Argus C4 (K4): Open WebUI persisted RAG config. Env says BYPASS_EMBEDDING_AND_RETRIEVAL=false,
# but the DB (PersistentConfig, which wins) holds rag.bypass_embedding_and_retrieval=true. With bypass on, an
# uploaded document is pasted whole into the prompt instead of arriving inside the RAG template's <context>/<source>
# markers that family-cloud treats as private context (Studio). This sets the DB value to false through the admin API
# (so the running app picks it up; a direct DB write would not) and reads it back via the API and the DB (mode=ro).
#
#   OWUI_ADMIN_KEY=... hack/ops/chg-2026-10-20-010-owui-c4.sh --dry-run
#   OWUI_ADMIN_KEY=... hack/ops/chg-2026-10-20-010-owui-c4.sh --apply
#   OWUI_ADMIN_KEY=... hack/ops/chg-2026-10-20-010-owui-c4.sh --rollback <state-file written by --apply>
#
# --apply: requires a fresh pre-change snapshot of open-webui-data (VolumeSnapshot name in $OWUI_SNAPSHOT, readyToUse)
#          records the before-state (bypass bool + template sha256 + marker booleans, never the text) write-once,
#          POSTs only BYPASS_EMBEDDING_AND_RETRIEVAL=false, reads back; any red -> automatic --rollback.
# --rollback: POSTs the recorded before value and reads back.
# The admin key is read from the environment and goes to curl on stdin only (never argv, disk or output).
# Talks to the app container through kubectl port-forward (pod loopback), not via the OIDC edge.
set -euo pipefail
MODE="${1:?--dry-run|--apply|--rollback}"; STATE_IN="${2:-}"
REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
NS=family-ai; TS=$(date -u +%Y%m%dT%H%M%SZ)
EVD="$REPO/ops/evidence/chg-2026-10-20-010"; EV="$EVD/k8s-owui-c4-$TS-${MODE#--}.txt"
[ ! -e "$EV" ] || { echo "evidence exists" >&2; exit 1; }
[ -n "${OWUI_ADMIN_KEY:-}" ] || { echo "OWUI_ADMIN_KEY missing (admin API key; never printed)" >&2; exit 2; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
log() { echo "$*" | tee -a "$EV"; }
# fix 2 (25-10 attempt 3 exited silently under set -e): name the failing step; line + exit code only, never the
# command text (it could carry the admin key). errtrace: also inside $(...) and functions.
STEP=init; set -E
# The trap writes to the evidence file and stderr only, never stdout: stdout of a function may be a pipe (curl's
# config) or a $(...) capture.
trap 'rc=$?; trap - ERR; m="RED owui-c4 stopped at step [$STEP] (line $LINENO, exit $rc)"; echo "$m" >> "$EV"; echo "$m" >&2; exit $rc' ERR
log "chg-2026-10-20-010 C4 $MODE $TS (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"

STEP="find open-webui pod"; POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
PORT=$((20000 + RANDOM % 20000))
kubectl -n $NS port-forward "pod/$POD" "$PORT:8080" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
STEP="port-forward"
for _ in $(seq 1 30); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 1; done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { log "RED owui-c4 stopped at step [port-forward] (no listener on 127.0.0.1:$PORT after 30 s)"; exit 1; }
U="http://127.0.0.1:$PORT"
api() { # METHOD PATH [json]
  { printf 'header = "Authorization: Bearer %s"\n' "$OWUI_ADMIN_KEY"; printf 'header = "Content-Type: application/json"\n'
    # root cause of the 25-10 attempt-3 silent exit: a trailing `[ -n "$3" ] && printf` made this group exit 1 for
    # every GET, so under pipefail `B=$(view)` failed and set -e ended --apply right after a successful GET.
    if [ -n "${3:-}" ]; then printf 'data = "%s"\n' "$(printf '%s' "$3" | sed 's/\\/\\\\/g; s/"/\\"/g')"; fi
  } | curl -sf -K - -X "$1" "$U$2"
}
# API view: booleans and a template digest only
view() {
  api GET /api/v1/retrieval/config | python3 -I 2>>"$EV" -c '
import sys, json, hashlib
raw = sys.stdin.read(); dec = json.JSONDecoder()
# 25-10 attempt 3: the body was not ONE JSON document ("Extra data" at byte 5888). Never guess which part is the
# config: describe the shape (sizes, document count, top-level key NAMES only, never values) and refuse.
docs, i = [], 0
try:
    while True:
        while i < len(raw) and raw[i].isspace(): i += 1
        if i >= len(raw): break
        o, j = dec.raw_decode(raw, i); docs.append((o, i, j)); i = j
except ValueError:
    docs.append((None, i, len(raw)))
if len(docs) != 1 or not isinstance(docs[0][0], dict):
    shape = ["%s@%d-%d keys=%s" % (type(o).__name__, a, b, sorted(o)[:12] if isinstance(o, dict) else "-") for o, a, b in docs]
    sys.stderr.write("view: response is not a single JSON object: %d bytes, %d part(s): %s\n" % (len(raw), len(docs), "; ".join(shape)))
    sys.exit(3)
d = docs[0][0]; t = d.get("RAG_TEMPLATE") or ""
print(json.dumps({"bypass": d.get("BYPASS_EMBEDDING_AND_RETRIEVAL"), "template_sha256": hashlib.sha256(t.encode()).hexdigest(),
                  "template_context": "<context>" in t, "template_source": "<source" in t}, sort_keys=True))'
}
# DB view (mode=ro): the persisted value that wins over env
dbview() {
  kubectl -n $NS exec -i "$POD" -c app -- python3 - <<'PY'
import sqlite3, json, hashlib
c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
# v0.11.4: one row per key (key, value JSON, updated_at)
kv = {k: v for k, v in c.execute("select key, value from config where key in ('rag.bypass_embedding_and_retrieval', 'rag.template')")}
def val(k):
    if k not in kv: return "ABSENT"
    try: return json.loads(kv[k])
    except Exception: return kv[k]
b = val("rag.bypass_embedding_and_retrieval"); t = val("rag.template"); t = t if isinstance(t, str) else ""
print(json.dumps({"db_bypass": b,
                  "db_template_sha256": hashlib.sha256(t.encode()).hexdigest() if t else "ABSENT"}, sort_keys=True))
PY
}
set_bypass() { api POST /api/v1/retrieval/config/update "{\"BYPASS_EMBEDDING_AND_RETRIEVAL\": $1}" >/dev/null; }
readback() { # expected bool, expected template sha
  local v d; v=$(view); d=$(dbview); log "  api $v"; log "  db  $d"
  python3 -I -c '
import json, sys
v, d, want, sha = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3] == "true", sys.argv[4]
ok = v["bypass"] is want and d["db_bypass"] is want and v["template_sha256"] == sha and v["template_context"] and v["template_source"]
sys.exit(0 if ok else 1)' "$v" "$d" "$1" "$2"
}

case "$MODE" in
  --dry-run)
    log "before (read-only):"; STEP="view (GET /api/v1/retrieval/config)"; V=$(view); log "  api $V"
    STEP="dbview (in-pod sqlite read)"; D=$(dbview); log "  db  $D"
    log "would POST /api/v1/retrieval/config/update {BYPASS_EMBEDDING_AND_RETRIEVAL: false}, then read back API + DB"
    ;;
  --apply)
    STEP="pre-change snapshot check"
    [ -n "${OWUI_SNAPSHOT:-}" ] && [ "$(kubectl -n $NS get volumesnapshot "$OWUI_SNAPSHOT" -o jsonpath='{.status.readyToUse}')" = true ] \
      || { log "RED no ready pre-change VolumeSnapshot of open-webui-data in OWUI_SNAPSHOT"; exit 1; }
    STEP="view (GET /api/v1/retrieval/config)"; B=$(view)
    STEP="dbview (in-pod sqlite read)"; BD=$(dbview); STATE="$EVD/k8s-owui-c4-$TS-before.json"
    STEP="write before-state"
    python3 -I -c 'import json,sys; json.dump({"api": json.loads(sys.argv[1]), "db": json.loads(sys.argv[2]), "snapshot": sys.argv[3], "run_id": sys.argv[5], "noop": json.loads(sys.argv[1])["bypass"] is False}, open(sys.argv[4], "x"), sort_keys=True)' \
      "$B" "$BD" "$OWUI_SNAPSHOT" "$STATE" "${C010_RUN_ID:-none}"
    log "before: api $B; db $BD; state -> ${STATE#$REPO/}"
    SHA=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["template_sha256"])' "$B")
    python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]); sys.exit(0 if v["template_context"] and v["template_source"] else 1)' "$B" \
      || { log "RED RAG template lacks <context>/<source>: not writing (template change is out of scope for C4)"; exit 1; }
    if python3 -I -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["bypass"] is False else 1)' "$B"; then
      STEP="read back (already false)"
      readback false "$SHA" && { log "RESULT C4 GREEN (bypass already false: no POST, idempotent; noop state)"; exit 0; }
      log "RED bypass reported false but the read-back disagrees: not writing"; exit 1
    fi
    STEP="POST bypass=false"; set_bypass false
    STEP="read back after POST"
    if readback false "$SHA"; then log "RESULT C4 GREEN (bypass false in API + DB, template unchanged with markers)"
    else log "RED read-back failed -> automatic rollback"; set_bypass "$(python3 -I -c 'import json,sys; print("true" if json.loads(sys.argv[1])["bypass"] else "false")' "$B")"
         readback "$(python3 -I -c 'import json,sys; print("true" if json.loads(sys.argv[1])["bypass"] else "false")' "$B")" "$SHA" && log "rolled back to before" || log "RED rollback read-back failed"; exit 1; fi
    ;;
  --rollback)
    STEP="read state"; [ -f "$STATE_IN" ] || { log "state file missing"; exit 2; }
    if python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("noop") is True else 1)' "$STATE_IN"; then
      log "RESULT C4 rollback GREEN (noop state: apply changed nothing, nothing to roll back)"; exit 0; fi
    STEP="POST before value"
    WANT=$(python3 -I -c 'import json,sys; print("true" if json.load(open(sys.argv[1]))["api"]["bypass"] else "false")' "$STATE_IN")
    SHA=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["api"]["template_sha256"])' "$STATE_IN")
    set_bypass "$WANT"
    if readback "$WANT" "$SHA"; then log "RESULT C4 rollback GREEN (bypass $WANT)"; else log "RESULT C4 rollback RED"; exit 1; fi
    ;;
  *) echo "mode?" >&2; exit 2 ;;
esac
