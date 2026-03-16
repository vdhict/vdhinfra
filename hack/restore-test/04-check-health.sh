#!/usr/bin/env bash
# Health check for the Docker restore test stack.
# Run ~60-120 seconds after 'docker compose up'.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0
WARN=0

check() {
  local name="$1" result="$2" detail="$3"
  if [ "$result" = "pass" ]; then
    echo "  PASS  $name — $detail"
    PASS=$((PASS + 1))
  elif [ "$result" = "warn" ]; then
    echo "  WARN  $name — $detail"
    WARN=$((WARN + 1))
  else
    echo "  FAIL  $name — $detail"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Restore Test Health Check ==="
echo ""

# --- 1. PostgreSQL ---
echo ">>> PostgreSQL"
if docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
  check "postgres" "pass" "accepting connections"
else
  check "postgres" "fail" "not ready"
fi

# Check databases exist
for db in app authelia grafana home_assistant lldap mealie; do
  exists=$(docker compose exec -T postgres psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null | tr -d '[:space:]')
  if [ "$exists" = "1" ]; then
    # Check table count
    tables=$(docker compose exec -T postgres psql -U postgres -d "$db" -tc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d '[:space:]')
    check "postgres/$db" "pass" "$tables tables"
  else
    check "postgres/$db" "fail" "database does not exist"
  fi
done
echo ""

# --- 2. Home Assistant ---
echo ">>> Home Assistant"
HA_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8123/manifest.json 2>/dev/null || echo "000")
if [ "$HA_STATUS" = "200" ]; then
  check "home-assistant/api" "pass" "frontend serving (HTTP 200)"
else
  # Check if it's still starting
  HA_CONTAINER=$(docker compose ps -q home-assistant 2>/dev/null)
  if [ -n "$HA_CONTAINER" ]; then
    HA_STATE=$(docker inspect --format='{{.State.Status}}' "$HA_CONTAINER" 2>/dev/null)
    check "home-assistant/api" "warn" "container is $HA_STATE (may still be starting — wait and retry)"
  else
    check "home-assistant/api" "fail" "container not running"
  fi
fi

# Check critical config files
DATA_DIR="$SCRIPT_DIR/data/home-assistant"
for f in configuration.yaml .storage/core.entity_registry .storage/core.device_registry .storage/core.config_entries; do
  if [ -f "$DATA_DIR/$f" ]; then
    check "home-assistant/$f" "pass" "exists ($(du -h "$DATA_DIR/$f" | cut -f1))"
  else
    check "home-assistant/$f" "fail" "missing"
  fi
done

# Check HA can talk to postgres
HA_LOG_ERRORS=$(docker compose logs home-assistant 2>/dev/null | grep -ic "error.*recorder\|error.*postgres\|operationalerror" || echo "0")
if [ "$HA_LOG_ERRORS" -gt 0 ]; then
  check "home-assistant/db" "warn" "$HA_LOG_ERRORS database-related log errors (check: docker compose logs home-assistant | grep -i postgres)"
else
  check "home-assistant/db" "pass" "no database errors in logs"
fi

# Count integrations
if [ -f "$DATA_DIR/.storage/core.config_entries" ]; then
  integrations=$(grep -o '"domain"' "$DATA_DIR/.storage/core.config_entries" 2>/dev/null | wc -l | tr -d '[:space:]')
  echo "  INFO  $integrations integrations configured"
fi

# Count automations
if [ -f "$DATA_DIR/automations.yaml" ]; then
  automations=$(grep -c "^- id:" "$DATA_DIR/automations.yaml" 2>/dev/null || echo "0")
  echo "  INFO  $automations automations found"
fi

# Count entities
if [ -f "$DATA_DIR/.storage/core.entity_registry" ]; then
  entities=$(grep -o '"entity_id"' "$DATA_DIR/.storage/core.entity_registry" 2>/dev/null | wc -l | tr -d '[:space:]')
  echo "  INFO  $entities registered entities"
fi
echo ""

# --- 3. Zigbee2MQTT ---
echo ">>> Zigbee2MQTT"
Z2M_DIR="$SCRIPT_DIR/data/zigbee2mqtt"
if [ -f "$Z2M_DIR/configuration.yaml" ]; then
  check "zigbee2mqtt/config" "pass" "configuration.yaml exists"
else
  check "zigbee2mqtt/config" "fail" "configuration.yaml missing"
fi

if [ -f "$Z2M_DIR/database.db" ]; then
  devices=$(grep -c '"type":"' "$Z2M_DIR/database.db" 2>/dev/null || echo "0")
  check "zigbee2mqtt/devices" "pass" "$devices devices in database.db"
else
  check "zigbee2mqtt/devices" "warn" "database.db not found"
fi

cb_count=$(find "$Z2M_DIR" -name "coordinator_backup*" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$cb_count" -gt 0 ]; then
  check "zigbee2mqtt/coordinator" "pass" "$cb_count coordinator backup file(s)"
else
  check "zigbee2mqtt/coordinator" "warn" "no coordinator backup (may need to re-pair devices)"
fi

# Zigbee2MQTT will crash-loop without a coordinator — check if config at least parsed
Z2M_LOG=$(docker compose logs zigbee2mqtt 2>/dev/null | tail -20)
if echo "$Z2M_LOG" | grep -q "MQTT publish\|Connecting to MQTT\|Connected to MQTT\|MQTT connect"; then
  check "zigbee2mqtt/mqtt" "pass" "connected to MQTT broker"
elif echo "$Z2M_LOG" | grep -q "Error:.*connect\|ECONNREFUSED.*9999"; then
  check "zigbee2mqtt/mqtt" "pass" "config loaded, coordinator connection failed (expected in test)"
else
  check "zigbee2mqtt/startup" "warn" "check logs: docker compose logs zigbee2mqtt"
fi
echo ""

# --- 4. Z-Wave JS UI ---
echo ">>> Z-Wave JS UI"
ZW_DIR="$SCRIPT_DIR/data/zwave-js-ui"
if [ -f "$ZW_DIR/settings.json" ]; then
  check "zwave-js-ui/settings" "pass" "settings.json exists"
  # Check for S2 keys (critical for secure device inclusion)
  if grep -q "S2_Unauthenticated\|s2UnauthenticatedKey\|networkKey" "$ZW_DIR/settings.json" 2>/dev/null; then
    check "zwave-js-ui/keys" "pass" "network/security keys present"
  else
    check "zwave-js-ui/keys" "warn" "no security keys found in settings"
  fi
else
  check "zwave-js-ui/settings" "fail" "settings.json missing"
fi

# Check if frontend serves
ZW_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8091/ 2>/dev/null || echo "000")
if [ "$ZW_HTTP" = "200" ] || [ "$ZW_HTTP" = "301" ] || [ "$ZW_HTTP" = "302" ]; then
  check "zwave-js-ui/frontend" "pass" "HTTP $ZW_HTTP"
else
  check "zwave-js-ui/frontend" "warn" "HTTP $ZW_HTTP (may still be starting)"
fi
echo ""

# --- 5. Node-Red ---
echo ">>> Node-Red"
NR_DIR="$SCRIPT_DIR/data/node-red"
if [ -f "$NR_DIR/flows.json" ]; then
  flows=$(grep -c '"type":"tab"' "$NR_DIR/flows.json" 2>/dev/null || echo "0")
  nodes=$(grep -o '"type":"' "$NR_DIR/flows.json" 2>/dev/null | wc -l | tr -d '[:space:]')
  check "node-red/flows" "pass" "$flows tabs, $nodes nodes"
else
  check "node-red/flows" "fail" "flows.json missing"
fi

NR_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:1880/ 2>/dev/null || echo "000")
if [ "$NR_HTTP" = "200" ] || [ "$NR_HTTP" = "302" ]; then
  check "node-red/frontend" "pass" "HTTP $NR_HTTP"
else
  check "node-red/frontend" "warn" "HTTP $NR_HTTP (may still be starting)"
fi
echo ""

# --- 6. Mosquitto ---
echo ">>> Mosquitto"
MQ_TEST=$(docker compose exec -T mosquitto mosquitto_sub -t '$SYS/broker/version' -C 1 -W 3 2>/dev/null || echo "")
if [ -n "$MQ_TEST" ]; then
  check "mosquitto" "pass" "responding ($MQ_TEST)"
else
  check "mosquitto" "warn" "not responding to sub test"
fi
echo ""

# --- Summary ---
echo "========================================"
echo "  PASS: $PASS  |  WARN: $WARN  |  FAIL: $FAIL"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Some checks FAILED. Review logs:"
  echo "  docker compose logs <service>"
  echo ""
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "All critical checks passed with some warnings."
  echo "Review warnings above — most are expected in a test without hardware."
  echo ""
  echo "Manual verification steps:"
  echo "  1. Open http://localhost:8123 — verify HA dashboard loads with entities"
  echo "  2. Open http://localhost:8091 — verify Z-Wave network keys are present"
  echo "  3. Open http://localhost:1880 — verify Node-Red flows are loaded"
  echo "  4. Check HA integrations: Settings > Devices & Services"
  echo ""
else
  echo "All checks PASSED!"
  echo ""
fi

echo "When done testing, run: docker compose down -v"
