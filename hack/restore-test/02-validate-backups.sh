#!/usr/bin/env bash
# Validate backup integrity without restoring anything.
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)/backups"
ERRORS=0

echo "=== Validating backups in $BACKUP_DIR ==="
echo ""

# --- Helper ---
check_file_in_tar() {
  local archive="$1" file="$2" label="$3"
  if tar tzf "$archive" 2>/dev/null | grep -q "$file"; then
    echo "    OK: $label found"
  else
    echo "    FAIL: $label NOT found"
    ERRORS=$((ERRORS + 1))
  fi
}

# --- 1. PostgreSQL dumps ---
echo ">>> PostgreSQL dumps"
for db in app authelia grafana home_assistant lldap mealie readarr_cache readarr_log; do
  dump="$BACKUP_DIR/${db}.dump"
  if [ -f "$dump" ]; then
    count=$(pg_restore --list "$dump" 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    size=$(du -h "$dump" | cut -f1)
    echo "    OK: $db ($size, $count objects)"
  else
    echo "    SKIP: $db (not found — may not exist in current cluster)"
  fi
done
echo ""

# --- 2. Home Assistant ---
echo ">>> Home Assistant config"
HA="$BACKUP_DIR/home-assistant-config.tar.gz"
if [ -f "$HA" ]; then
  echo "    Archive size: $(du -h "$HA" | cut -f1)"
  check_file_in_tar "$HA" "configuration.yaml" "configuration.yaml"
  check_file_in_tar "$HA" ".storage/" ".storage/ directory"
  check_file_in_tar "$HA" ".storage/core.entity_registry" "entity registry"
  check_file_in_tar "$HA" ".storage/core.device_registry" "device registry"
  check_file_in_tar "$HA" ".storage/core.area_registry" "area registry"
  check_file_in_tar "$HA" "automations.yaml\|.storage/core.config_entries" "automations or config entries"
  # Count custom_components
  cc=$(tar tzf "$HA" 2>/dev/null | grep -c "^./custom_components/" || echo "0")
  echo "    INFO: $cc files in custom_components/"
else
  echo "    FAIL: archive not found"
  ERRORS=$((ERRORS + 1))
fi
echo ""

# --- 3. Zigbee2MQTT ---
echo ">>> Zigbee2MQTT config"
Z2M="$BACKUP_DIR/zigbee2mqtt-config.tar.gz"
if [ -f "$Z2M" ]; then
  echo "    Archive size: $(du -h "$Z2M" | cut -f1)"
  check_file_in_tar "$Z2M" "configuration.yaml" "configuration.yaml"
  check_file_in_tar "$Z2M" "database.db" "database.db (device pairings)"
  # coordinator_backup is critical for re-pairing
  cb=$(tar tzf "$Z2M" 2>/dev/null | grep -c "coordinator_backup" || echo "0")
  if [ "$cb" -gt 0 ]; then
    echo "    OK: coordinator_backup found ($cb files)"
  else
    echo "    WARN: no coordinator_backup found (will need to re-pair all devices)"
  fi
else
  echo "    FAIL: archive not found"
  ERRORS=$((ERRORS + 1))
fi
echo ""

# --- 4. Z-Wave JS UI ---
echo ">>> Z-Wave JS UI store"
ZW="$BACKUP_DIR/zwave-js-ui-store.tar.gz"
if [ -f "$ZW" ]; then
  echo "    Archive size: $(du -h "$ZW" | cut -f1)"
  # Z-Wave network key is in settings.json
  check_file_in_tar "$ZW" "settings.json" "settings.json (network keys)"
  # node data
  nodes=$(tar tzf "$ZW" 2>/dev/null | grep -c "\.json" || echo "0")
  echo "    INFO: $nodes JSON files in store"
else
  echo "    FAIL: archive not found"
  ERRORS=$((ERRORS + 1))
fi
echo ""

# --- 5. Node-Red ---
echo ">>> Node-Red data"
NR="$BACKUP_DIR/node-red-data.tar.gz"
if [ -f "$NR" ]; then
  echo "    Archive size: $(du -h "$NR" | cut -f1)"
  check_file_in_tar "$NR" "flows.json" "flows.json"
  check_file_in_tar "$NR" "settings.js\|.config.nodes.json" "settings or node config"
else
  echo "    SKIP: archive not found (Node-Red may not be running on current cluster)"
fi
echo ""

# --- 6. Mosquitto ---
echo ">>> Mosquitto data"
MQ="$BACKUP_DIR/mosquitto-data.tar.gz"
if [ -f "$MQ" ]; then
  echo "    Archive size: $(du -h "$MQ" | cut -f1)"
  echo "    OK: archive exists (mosquitto data is ephemeral, content varies)"
else
  echo "    WARN: archive not found (non-critical)"
fi
echo ""

# --- Summary ---
if [ "$ERRORS" -gt 0 ]; then
  echo "=== VALIDATION FAILED: $ERRORS error(s) ==="
  exit 1
else
  echo "=== ALL CHECKS PASSED ==="
  echo "Next: run 'docker compose up' to test a full restore."
fi
