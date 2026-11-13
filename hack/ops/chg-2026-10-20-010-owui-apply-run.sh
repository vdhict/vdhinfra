#!/usr/bin/env bash
# chg-2026-10-20-010 land 3: run family-ai-cluster bin/owui-apply against the live Open WebUI through a port-forward
# (macOS local-network privacy blocks python to the LAN), with a 20-minute admin token minted inside the pod (never
# printed, never argv). Arguments after the checkout go to owui-apply unchanged, e.g.
#   chg-2026-10-20-010-owui-apply-run.sh <family-ai-cluster checkout> --attachments-only --attachment-group owui-profiel-3 --dry-run
set -uo pipefail
FAI="${1:?family-ai-cluster checkout}"; shift
PY="$HOME/Code/pka-wires/_toolchains/open-webui-0.11.4-test/.venv/bin/python3"
PORT=$((20000 + $$ % 10000))
kubectl -n family-ai port-forward svc/open-webui "$PORT:8080" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 1; done
T=$(kubectl -n family-ai exec -i deploy/open-webui -c app -- sh -c 'cd /app/backend && python3 - 2>/dev/null' <<'PY' | grep '^L3TOKEN ' | tail -1
import os, sqlite3
from datetime import timedelta
c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
rows = c.execute("select id, role from user where email = ?", (os.environ.get("WEBUI_ADMIN_EMAIL", "").strip(),)).fetchall()
if len(rows) == 1 and rows[0][1] == "admin":
    from open_webui.utils.auth import create_token
    print("L3TOKEN " + create_token({"id": rows[0][0]}, expires_delta=timedelta(minutes=20)))
PY
)
MODEL=$(kubectl -n family-ai get configmap family-ai-runtime -o jsonpath='{.data.FAMILY_LLM_MODEL}')
OWUI_ADMIN_KEY="${T#L3TOKEN }" "$PY" -I "$FAI/bin/owui-apply" --bundle "$FAI/dist" --url "http://127.0.0.1:$PORT" --studio-model "$MODEL" "$@" 2>&1
RC=$?
T=""
exit $RC
