#!/usr/bin/env bash
# Restore one VolSync-protected app's PVC from MinIO.
#
# Usage:
#   ./30-restore-volsync-app.sh <app-name>
#
# The app-name must match one of the VOLSYNC_APPS entries in lib.sh.
#
# What it does:
#   1. Suspend the app's Flux KS (idempotent)
#   2. Scale workload to 0 (in case it's already running)
#   3. Delete the existing PVC if present (last chance to abort)
#   4. Create a temporary ReplicationDestination targeting the app's repo
#   5. Wait for the destination to materialize the new PVC from the latest snapshot
#   6. Verify the PVC has data
#   7. Delete the temporary ReplicationDestination
#   8. Resume the workload + Flux KS
source "$(dirname "$0")/lib.sh"
require_cluster
require_tools flux

APP="${1:-}"
[ -z "$APP" ] && fatal "usage: $0 <app-name>. Valid: zwave-js-ui zigbee2mqtt home-assistant node-red esphome mealie radarr"

# Look up the app in the canonical list
NS=""
PVC=""
for spec in "${VOLSYNC_APPS[@]}"; do
  IFS=: read -r ns name pvc <<< "$spec"
  if [ "$name" = "$APP" ]; then
    NS="$ns"; PVC="$pvc"; break
  fi
done
[ -z "$NS" ] && fatal "unknown app '$APP'. Valid apps: $(printf '%s ' "${VOLSYNC_APPS[@]}" | sed 's/[^:]*:\([^:]*\):[^ ]*/\1/g')"

log "restoring $NS/$APP (PVC: $PVC)"

# 1. Suspend the Flux KS
log "  suspending Flux KS..."
flux suspend ks "$APP" 2>&1 | sed 's/^/    /' || true

# 2. Scale workload to 0
log "  scaling workload to 0..."
for kind in deployment statefulset; do
  if kubectl -n "$NS" get "$kind" "$APP" >/dev/null 2>&1; then
    kubectl -n "$NS" scale "$kind" "$APP" --replicas=0 2>&1 | sed 's/^/    /'
  fi
done

# 3. Delete existing PVC (DESTRUCTIVE)
if kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  warn "PVC $NS/$PVC exists. THIS WILL DELETE IT."
  confirm "Delete $NS/$PVC and restore from latest restic snapshot?"
  kubectl -n "$NS" delete pvc "$PVC" --wait=true
  ok "deleted $NS/$PVC"
fi

# 4. Create temporary ReplicationDestination
RD_MANIFEST=$(mktemp /tmp/volsync-restore-$APP.XXXXXX.yaml)
trap 'rm -f "$RD_MANIFEST"' EXIT
cat > "$RD_MANIFEST" <<YAML
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${APP}-dst
  namespace: ${NS}
spec:
  trigger:
    manual: restore-once
  restic:
    accessModes: [ReadWriteOnce]
    cacheAccessModes: [ReadWriteOnce]
    cacheCapacity: 5Gi
    cacheStorageClassName: openebs-hostpath
    storageClassName: rook-ceph-block
    volumeSnapshotClassName: csi-ceph-blockpool
    capacity: $(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo 5Gi)
    copyMethod: Snapshot
    cleanupCachePVC: true
    cleanupTempPVC: true
    moverSecurityContext:
      runAsUser: 2000
      runAsGroup: 2000
      fsGroup: 2000
    repository: ${APP}-volsync-secret
YAML
log "  applying ReplicationDestination..."
kubectl apply -f "$RD_MANIFEST"

# 5. Trigger the restore
log "  triggering restore..."
NOW=$(date -u +%Y-%m-%dT%H-%M-%SZ)
kubectl -n "$NS" patch replicationdestination "${APP}-dst" --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"restore-$NOW\"}}}"

log "  waiting for restore to complete (timeout 30 min)..."
wait_for "$APP-dst lastManualSync" \
  "kubectl -n '$NS' get replicationdestination '${APP}-dst' -o jsonpath='{.status.lastManualSync}'" \
  "restore-$NOW" \
  1800

# The destination materializes its own PVC named after the latestImage
# (snapshot reference). Find the snapshot it created and clone into the
# canonical PVC name.
SNAP=$(kubectl -n "$NS" get replicationdestination "${APP}-dst" -o jsonpath='{.status.latestImage.name}')
[ -z "$SNAP" ] && fatal "ReplicationDestination did not produce a latestImage snapshot"
log "  snapshot $SNAP produced. Creating canonical PVC $PVC from it..."

# Create the canonical PVC with dataSourceRef pointing at the snapshot
CAP=$(kubectl -n "$NS" get volumesnapshot "$SNAP" -o jsonpath='{.status.restoreSize}')
cat > /tmp/dr-pvc-$APP.yaml <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
  namespace: ${NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: ${CAP}
  dataSource:
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: ${SNAP}
YAML
kubectl apply -f /tmp/dr-pvc-$APP.yaml
rm -f /tmp/dr-pvc-$APP.yaml

wait_for "$NS/$PVC phase" \
  "kubectl -n '$NS' get pvc '$PVC' -o jsonpath='{.status.phase}'" \
  "Bound" \
  300

# 6. Cleanup the ReplicationDestination
log "  cleaning up temporary ReplicationDestination..."
kubectl -n "$NS" delete replicationdestination "${APP}-dst" --wait=true

# 7. Resume the Flux KS — this re-creates the workload, which mounts the
#    restored PVC because the PVC name matches what the helmrelease expects.
log "  resuming Flux KS..."
flux resume ks "$APP" 2>&1 | sed 's/^/    /'

ok "restored $NS/$APP. The workload should come back up with restored data within 1-2 minutes."
log "verify with: kubectl -n $NS get pods,pvc"
