#!/usr/bin/env bash
# ha-team-token-macbook.sh: run ON THE MACBOOK (op signs in with Touch ID). Copies the HA team token (account
# mypka-team, AGR-126, chg-2026-11-13-006) from the cluster Secret mypka/ha-team-token, via ssh to the Mini, into
#   1. ~/.config/pka-ha/token (mode 600, outside vault and git) for the Stream Deck, and
#   2. 1Password item `ha-team-token` in vault mypka-cluster (refused if the item exists; check by hand, no overwrite).
# The token goes ssh -> file (umask 077) -> python stdin -> op stdin: never printed, never in argv.
#     bash ha-team-token-macbook.sh            (MINI defaults to sheijden@172.16.2.201)
set -euo pipefail
MINI="${MINI:-sheijden@172.16.2.201}"
VAULT="${VAULT:-mypka-cluster}"; ITEM="${ITEM:-ha-team-token}"
DIR="$HOME/.config/pka-ha"; F="$DIR/token"
umask 077
mkdir -p "$DIR"; chmod 700 "$DIR"
ssh "$MINI" "kubectl -n mypka get secret ha-team-token -o jsonpath='{.data.token}' | base64 -d" > "$F.new"
python3 -c 'import sys; t=open(sys.argv[1]).read().strip(); assert t.count(".")==2 and len(t)>100, "unexpected token shape"' "$F.new"
mv "$F.new" "$F"; chmod 600 "$F"
echo "file: $F ($(stat -f %Lp "$F"), $(wc -c < "$F" | tr -d ' ') bytes)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$F")" https://hass.bluejungle.net/api/ || true)
echo "check https://hass.bluejungle.net/api/ with the token: $code (200 = good)"
op whoami >/dev/null 2>&1 || op signin >/dev/null
if op item get "$ITEM" --vault "$VAULT" >/dev/null 2>&1; then
  echo "1Password: item $ITEM already exists in $VAULT; not overwritten" >&2; exit 3
fi
python3 -c '
import json, sys
tok = open(sys.argv[1]).read().strip()
print(json.dumps({"title": sys.argv[2], "category": "API_CREDENTIAL", "fields": [
  {"id": "username", "type": "STRING", "label": "username", "value": "mypka-team"},
  {"id": "credential", "type": "CONCEALED", "label": "credential", "value": tok},
  {"id": "hostname", "type": "STRING", "label": "hostname", "value": "https://hass.bluejungle.net"},
  {"id": "lan", "type": "STRING", "label": "lan", "value": "http://172.16.2.237:8123"}],
  "urls": [{"primary": True, "href": "https://hass.bluejungle.net"}]}))' "$F" "$ITEM" \
| op item create --vault "$VAULT" - >/dev/null
op item get "$ITEM" --vault "$VAULT" --fields label=username,label=hostname,label=lan
echo "1Password: written $ITEM in $VAULT (token not shown)"
