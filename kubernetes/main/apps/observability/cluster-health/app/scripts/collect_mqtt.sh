#!/bin/sh
# Probe Mosquitto broker for liveness + connected client count.
set -u

HOST="${MQTT_HOST:-mosquitto.home-automation.svc.cluster.local}"
PORT="${MQTT_PORT:-1883}"

VERSION=$(mosquitto_sub -h "$HOST" -p "$PORT" -t '$SYS/broker/version' -C 1 -W 5 2>/dev/null || echo "")
CLIENTS=$(mosquitto_sub -h "$HOST" -p "$PORT" -t '$SYS/broker/clients/connected' -C 1 -W 5 2>/dev/null || echo "")
UPTIME=$(mosquitto_sub -h "$HOST" -p "$PORT" -t '$SYS/broker/uptime' -C 1 -W 5 2>/dev/null || echo "")
MSGS=$(mosquitto_sub -h "$HOST" -p "$PORT" -t '$SYS/broker/messages/received' -C 1 -W 5 2>/dev/null || echo "")

OK=false
if [ -n "$VERSION" ]; then OK=true; fi

python3 - "$OK" "$VERSION" "$CLIENTS" "$UPTIME" "$MSGS" <<'PY'
import json, sys
ok = sys.argv[1] == "true"
out = {
    "reachable": ok,
    "version": sys.argv[2] or None,
    "clients_connected": int(sys.argv[3]) if sys.argv[3].isdigit() else None,
    "uptime": sys.argv[4] or None,
    "messages_received": int(sys.argv[5]) if sys.argv[5].isdigit() else None,
}
json.dump(out, sys.stdout, indent=2)
PY
