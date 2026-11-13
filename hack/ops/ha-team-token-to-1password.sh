#!/usr/bin/env bash
# ha-team-token-to-1password.sh: copy the HA team token (mypka-team, AGR-126) into 1Password
# item `ha-team-token` (vault mypka-cluster), straight from the cluster Secret
# mypka/ha-team-token. Run in a session where op can write mypka-cluster (Touch ID, e.g. the MacBook):
#     hack/ops/ha-team-token-to-1password.sh
# The token goes kubectl -> python (stdin) -> op (stdin). It is never printed,
# never in argv and never in a file, so it never reaches a model session or a
# handoff file (that is how inc-2026-10-13-002 leaked the previous token).
# Why not the PushSecret: the Connect token gets 403 on writes (chg-2026-10-13-005).
# Refuses if the item already exists (check it by hand, do not overwrite).
set -euo pipefail
VAULT="${VAULT:-mypka-cluster}"
ITEM="${ITEM:-ha-team-token}"

op whoami >/dev/null 2>&1 || op signin >/dev/null
if op item get "$ITEM" --vault "$VAULT" >/dev/null 2>&1; then
  echo "item $ITEM already exists in $VAULT; not overwritten" >&2; exit 3
fi

kubectl -n mypka get secret ha-team-token -o jsonpath='{.data.token}' | base64 -d \
| /usr/bin/python3 -I -c '
import json, sys
tok = sys.stdin.read().strip()
assert tok.count(".") == 2 and len(tok) > 100, "unexpected token shape"
print(json.dumps({
  "title": sys.argv[1],
  "category": "API_CREDENTIAL",
  "fields": [
    {"id": "username", "type": "STRING", "label": "username", "value": "mypka-team"},
    {"id": "credential", "type": "CONCEALED", "label": "credential", "value": tok},
    {"id": "hostname", "type": "STRING", "label": "hostname", "value": "https://hass.bluejungle.net"},
    {"id": "lan", "type": "STRING", "label": "lan", "value": "http://172.16.2.237:8123"},
  ],
  "urls": [{"primary": True, "href": "https://hass.bluejungle.net"}],
}))' "$ITEM" \
| op item create --vault "$VAULT" - >/dev/null

op item get "$ITEM" --vault "$VAULT" --fields label=username,label=hostname,label=lan
echo "written: $ITEM in $VAULT (token not shown)"
