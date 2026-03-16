#!/usr/bin/env bash
# Backup critical home-automation data from the CURRENT running cluster.
# Run this BEFORE migration. Requires kubectl access to the current cluster.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/Users/sheijden/Code/homelab-migration/config/kubeconfig}"
export KUBECONFIG
BACKUP_DIR="$(cd "$(dirname "$0")" && pwd)/backups"
NS="home-automation"
DB_NS="database"

mkdir -p "$BACKUP_DIR"

echo "=== Using kubeconfig: $KUBECONFIG ==="
echo "=== Backup directory: $BACKUP_DIR ==="
echo ""

# --- Helper: find pod by label ---
find_pod() {
  local ns="$1" label="$2"
  kubectl -n "$ns" get pods -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# --- 1. PostgreSQL dump ---
echo ">>> [1/6] Dumping PostgreSQL databases..."
PG_POD=$(kubectl -n "$DB_NS" get pods -l cnpg.io/cluster=postgres16,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
echo "    Primary pod: $PG_POD"
for db in app authelia grafana home_assistant lldap mealie readarr_cache readarr_log; do
  echo "    Dumping $db..."
  kubectl exec -n "$DB_NS" "$PG_POD" -- pg_dump -Fc -d "$db" > "$BACKUP_DIR/${db}.dump" 2>/dev/null || {
    echo "    WARNING: Failed to dump $db (may not exist yet), skipping"
    rm -f "$BACKUP_DIR/${db}.dump"
  }
done
echo "    Done."
echo ""

# --- 2. Home Assistant /config ---
echo ">>> [2/6] Backing up Home Assistant config..."
HA_POD=$(find_pod "$NS" "app.kubernetes.io/name=home-assistant")
echo "    Pod: $HA_POD"
kubectl exec -n "$NS" "$HA_POD" -c app -- tar czf - \
  -C /config \
  --exclude='./home-assistant_v2.db' \
  --exclude='./home-assistant_v2.db-shm' \
  --exclude='./home-assistant_v2.db-wal' \
  --exclude='./.vscode' \
  --exclude='./tts' \
  --exclude='./backups' \
  --exclude='./deps' \
  --exclude='./logs' \
  . > "$BACKUP_DIR/home-assistant-config.tar.gz"
echo "    Done ($(du -h "$BACKUP_DIR/home-assistant-config.tar.gz" | cut -f1))."
echo ""

# --- 3. Zigbee2MQTT /config ---
echo ">>> [3/6] Backing up Zigbee2MQTT config..."
Z2M_POD=$(find_pod "$NS" "app.kubernetes.io/name=zigbee2mqtt")
echo "    Pod: $Z2M_POD"
kubectl exec -n "$NS" "$Z2M_POD" -c app -- tar czf - \
  -C /config \
  --exclude='./log' \
  . > "$BACKUP_DIR/zigbee2mqtt-config.tar.gz"
echo "    Done ($(du -h "$BACKUP_DIR/zigbee2mqtt-config.tar.gz" | cut -f1))."
echo ""

# --- 4. Z-Wave JS UI /usr/src/app/store ---
echo ">>> [4/6] Backing up Z-Wave JS UI store..."
ZW_POD="zwave-js-ui-0"
echo "    Pod: $ZW_POD"
kubectl exec -n "$NS" "$ZW_POD" -c main -- tar czf - \
  -C /usr/src/app/store \
  . > "$BACKUP_DIR/zwave-js-ui-store.tar.gz"
echo "    Done ($(du -h "$BACKUP_DIR/zwave-js-ui-store.tar.gz" | cut -f1))."
echo ""

# --- 5. Node-Red /data ---
echo ">>> [5/6] Backing up Node-Red data..."
NR_POD=$(find_pod "$NS" "app.kubernetes.io/name=node-red")
if [ -n "$NR_POD" ]; then
  echo "    Pod: $NR_POD"
  kubectl exec -n "$NS" "$NR_POD" -c main -- tar czf - \
    -C /data \
    . > "$BACKUP_DIR/node-red-data.tar.gz"
  echo "    Done ($(du -h "$BACKUP_DIR/node-red-data.tar.gz" | cut -f1))."
else
  echo "    SKIP: Node-Red pod not found (not running)"
fi
echo ""

# --- 6. Mosquitto /mosquitto/data ---
echo ">>> [6/6] Backing up Mosquitto data..."
MQ_POD=$(find_pod "$NS" "app.kubernetes.io/name=mosquitto")
echo "    Pod: $MQ_POD"
kubectl exec -n "$NS" "$MQ_POD" -c app -- tar czf - \
  -C /mosquitto/data \
  . > "$BACKUP_DIR/mosquitto-data.tar.gz"
echo "    Done ($(du -h "$BACKUP_DIR/mosquitto-data.tar.gz" | cut -f1))."
echo ""

# --- Summary ---
echo "=== Backup complete ==="
echo ""
ls -lh "$BACKUP_DIR"/
echo ""
echo "Next: run ./02-validate-backups.sh to check backup integrity."
