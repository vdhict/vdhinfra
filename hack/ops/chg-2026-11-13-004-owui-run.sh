#!/usr/bin/env bash
# chg-2026-11-13-004: run hack/ops/chg-2026-11-13-004-owui-in-pod.py in the open-webui pod (Argus C3: the spec is built
# in a pipe; the gateway key and the owner email are never in argv, a file in the repo, or output).
#   chg-2026-11-13-004-owui-run.sh <new-function.py> <rollback-function.py> <owner-email-file> <evidence-file> <mode> [mode...]
# new = c90d5ea1 (Mack 4c6e9d8), rollback = d9870197 (live since chg-2026-11-13-003). Evidence is write-once.
set -uo pipefail
NEW="${1:?new function}"; OLD="${2:?rollback function}"; EMAIL_FILE="${3:?owner email file}"; EV="${4:?evidence}"; shift 4
[ ! -e "$EV" ] || { echo "evidence $EV exists" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(shasum -a 256 "$NEW" | cut -c1-8)" = c90d5ea1 ] || { echo "new function is not c90d5ea1" >&2; exit 1; }
[ "$(shasum -a 256 "$OLD" | cut -c1-8)" = d9870197 ] || { echo "rollback function is not d9870197" >&2; exit 1; }
{
  echo "chg-2026-11-13-004 OWUI records $(date -u +%FT%TZ) (in-pod script, not owui-apply)"
  for MODE in "$@"; do
    echo "-- $MODE"
    kubectl -n family-ai get secret family-ai-hermes-profiel-4-gateway -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d \
    | /usr/bin/python3 -I -c '
import hashlib, json, sys
new, old, mail = open(sys.argv[1]).read(), open(sys.argv[2]).read(), open(sys.argv[3]).readline().strip()
print(json.dumps({"fid": "gezin_voortgang", "content": new, "sha256": hashlib.sha256(new.encode()).hexdigest(),
  "rollback_content": old, "rollback_sha256": hashlib.sha256(old.encode()).hexdigest(),
  "fam": ["hermes-agent-profiel-1", "hermes-agent-profiel-2", "hermes-agent-profiel-3"],
  "model": {"id": "hermes-agent-profiel-4", "naam": "Testprofiel"}, "group": "owui-profiel-4",
  "template_group": "owui-profiel-1", "owner_email": mail, "conn_url": "http://hermes-profiel-4:8642/v1",
  "conn_key": sys.stdin.read().strip(), "demo_id": "voortgang-demo"}))' "$NEW" "$OLD" "$EMAIL_FILE" \
    | kubectl -n family-ai exec -i deploy/open-webui -c app -- python3 -c "$(cat "$HERE/chg-2026-11-13-004-owui-in-pod.py")" "$MODE" 2>&1
  done
} | tee "$EV"
