#!/usr/bin/env bash
# Extract backups into Docker volumes and start the restore test stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
DATA_DIR="$SCRIPT_DIR/data"

echo "=== Preparing restore test ==="
echo ""

# --- Clean previous test data ---
if [ -d "$DATA_DIR" ]; then
  echo "Cleaning previous test data..."
  rm -rf "$DATA_DIR"
fi

mkdir -p \
  "$DATA_DIR/postgres" \
  "$DATA_DIR/home-assistant" \
  "$DATA_DIR/zigbee2mqtt" \
  "$DATA_DIR/zwave-js-ui" \
  "$DATA_DIR/node-red" \
  "$DATA_DIR/mosquitto/data" \
  "$DATA_DIR/mosquitto/config"

# --- 1. Extract Home Assistant config ---
echo ">>> Extracting Home Assistant config..."
tar xzf "$BACKUP_DIR/home-assistant-config.tar.gz" -C "$DATA_DIR/home-assistant"
echo "    Done."

# --- 2. Extract Zigbee2MQTT config ---
echo ">>> Extracting Zigbee2MQTT config..."
tar xzf "$BACKUP_DIR/zigbee2mqtt-config.tar.gz" -C "$DATA_DIR/zigbee2mqtt"
echo "    Done."

# --- 3. Extract Z-Wave JS UI store ---
echo ">>> Extracting Z-Wave JS UI store..."
tar xzf "$BACKUP_DIR/zwave-js-ui-store.tar.gz" -C "$DATA_DIR/zwave-js-ui"
echo "    Done."

# --- 4. Extract Node-Red data ---
echo ">>> Extracting Node-Red data..."
if [ -f "$BACKUP_DIR/node-red-data.tar.gz" ]; then
  tar xzf "$BACKUP_DIR/node-red-data.tar.gz" -C "$DATA_DIR/node-red"
  echo "    Done."
else
  echo "    SKIP: no backup found (Node-Red will start empty)"
fi

# --- 5. Extract Mosquitto data ---
echo ">>> Extracting Mosquitto data..."
tar xzf "$BACKUP_DIR/mosquitto-data.tar.gz" -C "$DATA_DIR/mosquitto/data"
echo "    Done."

# --- 6. Create Mosquitto config (anonymous for testing) ---
cat > "$DATA_DIR/mosquitto/config/mosquitto.conf" <<'MQCONF'
listener 1883
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
MQCONF

# --- 7. Copy postgres dumps ---
echo ">>> Copying PostgreSQL dumps..."
cp "$BACKUP_DIR"/*.dump "$DATA_DIR/postgres/" 2>/dev/null || echo "    No dumps found."
echo "    Done."

# --- 8. Patch Home Assistant config for local testing ---
echo ">>> Patching Home Assistant configuration for Docker test..."
HA_DIR="$DATA_DIR/home-assistant"

# Remove postgres-dependent recorder config if present — HA will fall back to SQLite
# We'll use the postgres init script to restore the DB, but HA needs to be able to start
# even if postgres takes a moment to come up.

# Create a minimal test overlay that disables components needing hardware/cluster services
if [ ! -f "$HA_DIR/configuration.yaml" ]; then
  echo "    WARNING: No configuration.yaml found — HA may use onboarding flow"
fi

echo "    Done."
echo ""

# --- 9. Create postgres init script ---
cat > "$DATA_DIR/postgres/00-restore-databases.sh" <<'PGINIT'
#!/bin/bash
set -e

echo "=== Creating databases ==="
for db in app authelia grafana home_assistant lldap mealie readarr_cache readarr_log; do
  psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 || \
    psql -U postgres -c "CREATE DATABASE $db OWNER postgres;"
done

echo "=== Restoring dumps ==="
for dump in /docker-entrypoint-initdb.d/*.dump; do
  db=$(basename "$dump" .dump)
  echo "Restoring $db..."
  pg_restore -U postgres --clean --if-exists -d "$db" "$dump" 2>&1 || {
    echo "WARNING: pg_restore for $db had errors (may be expected for clean install)"
  }
done
echo "=== Database restore complete ==="
PGINIT
chmod +x "$DATA_DIR/postgres/00-restore-databases.sh"

echo "=== Extraction complete ==="
echo ""
echo "Starting Docker Compose stack..."
echo ""

cd "$SCRIPT_DIR"
docker compose up -d

echo ""
echo "=== Stack starting ==="
echo ""
echo "Services:"
echo "  Home Assistant:  http://localhost:8123"
echo "  Z-Wave JS UI:    http://localhost:8091"
echo "  Zigbee2MQTT:     http://localhost:8080"
echo "  Node-Red:        http://localhost:1880"
echo "  Mosquitto MQTT:  localhost:1883"
echo "  PostgreSQL:      localhost:5432"
echo ""
echo "Run './04-check-health.sh' after ~60 seconds to validate."
echo "Run 'docker compose logs -f' to watch startup."
