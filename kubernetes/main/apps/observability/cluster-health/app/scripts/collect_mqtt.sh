#!/bin/sh
# Probe Mosquitto broker for liveness.
#
# Mosquitto runs with `allow_anonymous false` so an unauthenticated
# subscribe to $SYS/* gets refused at the protocol level — but a
# refusal still proves the broker is reachable, listening on the right
# port, and speaking MQTT. The "broker is unreachable" failure mode is
# DNS resolution failure or TCP connect failure (different exit codes).
set -u

HOST="${MQTT_HOST:-mosquitto.home-automation.svc.cluster.local}"
PORT="${MQTT_PORT:-1883}"

# Capture stderr so we can distinguish "broker up but auth refused"
# (which we still call reachable) from "TCP/DNS failure".
ERR=$(mosquitto_sub -h "$HOST" -p "$PORT" -t '$SYS/broker/version' -C 1 -W 5 2>&1 1>/dev/null)
RC=$?

REACHABLE=false
AUTH_REFUSED=false
case "$RC" in
  0)
    REACHABLE=true
    ;;
  *)
    case "$ERR" in
      *"not authorised"*|*"not authorized"*|*"refused"*|*"Refused"*)
        # Broker is listening + speaking MQTT, just won't let us subscribe
        # to $SYS as an anonymous client. Counts as alive.
        REACHABLE=true
        AUTH_REFUSED=true
        ;;
    esac
    ;;
esac

python3 - "$REACHABLE" "$AUTH_REFUSED" "$ERR" <<'PY'
import json, sys
out = {
    "reachable": sys.argv[1] == "true",
    "auth_refused": sys.argv[2] == "true",
    "raw_stderr": sys.argv[3][:200] if sys.argv[3] else None,
}
json.dump(out, sys.stdout, indent=2)
PY
