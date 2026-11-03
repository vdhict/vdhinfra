#!/usr/bin/env bash
# Argus C7 live read-back of the HA cap (chg-2026-10-05-031), AFTER Hestia installed
# ha/vdhwslin01_wake.yaml. Run from the Mini ONLY while vdhwslin01 is UP (tcp 22 open):
# then the 4 accepted presses send WoL to a running box (a no-op) instead of waking it.
#   ha-cap-readback.sh            # dry: preconditions only
#   ha-cap-readback.sh --run      # 5 POSTs, read counter + logbook, reset the counter
# Expect: counter goes 0->4, the 5th POST is refused (logbook "team wake refused: daily
# cap 4 reached"), counter stays 4; then counter.reset -> 0. Never prints the webhook id
# or the HA token (both reach curl via -K - on stdin).
set -euo pipefail
HA=http://172.16.2.237:8123
WID_FILE="$HOME/.config/vdhwslin01/ha-webhook-id"
TOK_FILE="${HA_TOKEN_FILE:-/Users/sheijden/Code/homelab-migration/config/hasskey}"
CNT=counter.vdhwslin01_team_boots
die() { echo "ha-cap-readback: $*" >&2; exit 2; }
[[ -r "$WID_FILE" && -r "$TOK_FILE" ]] || die "webhook id or HA token file missing"
/usr/bin/nc -z -G 3 172.16.3.205 22 || die "vdhwslin01 is not up (22 closed): refusing, a POST would really wake it"
api() { # api <METHOD> <path> [json]
  { printf 'url = "%s%s"\n' "$HA" "$2"; printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' < "$TOK_FILE")"; } \
    | /usr/bin/curl -fsS --max-time 15 -X "$1" -H 'Content-Type: application/json' ${3:+--data "$3"} -K -
}
state() { api GET "/api/states/$CNT" | /usr/bin/python3 -I -c 'import json,sys;print(json.load(sys.stdin)["state"])'; }
echo "counter before: $(state)"
[[ "${1:-}" == --run ]] || { echo "dry: preconditions ok (box up, files present). Re-run with --run."; exit 0; }
[[ "$(state)" == 0 ]] || die "counter is not 0 (a real wake happened today?); refusing to test"
t0="$(date -u +%FT%TZ)"
for i in 1 2 3 4 5; do
  code=$(printf 'url = "%s/api/webhook/%s"\n' "$HA" "$(tr -d '\n' < "$WID_FILE")" \
    | /usr/bin/curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H 'Content-Type: application/json' \
      --data '{"source":"cap-readback","jobs":0}' -K -)
  sleep 3; echo "POST $i: http $code, counter $(state)"
done
after="$(state)"
refused=$(api GET "/api/logbook/$t0?entity=$CNT" | /usr/bin/python3 -I -c 'import json,sys;print(sum("refused" in (e.get("message") or "") for e in json.load(sys.stdin)))')
api POST /api/services/counter/reset "{\"entity_id\":\"$CNT\"}" >/dev/null
echo "counter after 5 POSTs: $after (expect 4); refusals in logbook: $refused (expect 1); counter after reset: $(state)"
if [[ "$after" == 4 && "$refused" == 1 ]]; then echo "C7 HA CAP PASS"; else echo "C7 HA CAP FAIL"; exit 1; fi
