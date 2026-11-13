#!/usr/bin/env bash
# chg-2026-11-13-004 C7: run hack/ops/chg-2026-11-13-004-lldap-group.py <mode...> through a short-lived lldap port-forward.
#   chg-2026-11-13-004-lldap-run.sh <owner-email-file> <evidence-file> <mode> [mode...]
# owner-email-file: one line, the owner's own OIDC account email (0600, outside the repo; never printed, never argv).
# The lldap admin credential goes only into the python process env. Evidence must not exist yet (write-once).
set -uo pipefail
EMAIL_FILE="${1:?owner email file}"; EV="${2:?evidence file}"; shift 2
[ ! -e "$EV" ] || { echo "evidence $EV exists" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HOME/Code/pka-wires/_toolchains/open-webui-0.11.4-test/.venv/bin/python3"
PORT=$((20000 + RANDOM % 10000))
kubectl -n security port-forward svc/lldap "$PORT:8080" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 1; done
{
  echo "chg-2026-11-13-004 C7 lldap group owui-profiel-4 $(date -u +%FT%TZ): owner = the owner's own OIDC account (the earlier demo grantee)"
  for MODE in "$@"; do
    echo "-- $MODE"
    LLDAP_URL="http://127.0.0.1:$PORT" \
    LLDAP_ADMIN="$(kubectl -n security get secret lldap-secret -o jsonpath='{.data.LLDAP_USER_DN}' | base64 -d)" \
    LLDAP_ADMIN_PASS="$(kubectl -n security get secret lldap-secret -o jsonpath='{.data.LLDAP_LDAP_USER_PASS}' | base64 -d)" \
    OWNER_EMAIL="$(head -1 "$EMAIL_FILE")" \
      "$PY" -I "$HERE/chg-2026-11-13-004-lldap-group.py" "$MODE" 2>&1 | grep -v -e '^  File' -e '^    ' -e '^Traceback'
  done
} | tee "$EV"
