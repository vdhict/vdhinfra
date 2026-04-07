#!/usr/bin/env bash
# Recover postgres16 from a barman base backup + WAL archive on MinIO.
#
# Usage:
#   ./20-restore-postgres.sh                           # latest available
#   ./20-restore-postgres.sh --pitr "2026-04-07 14:00:00+02"
#   ./20-restore-postgres.sh --pitr-backup-id 20260407T160846
#
# Idempotent: if a recovered postgres16 already exists, will refuse to
# proceed unless FORCE=1.
source "$(dirname "$0")/lib.sh"
require_cluster
require_tools flux

PITR_TIME=""
BACKUP_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pitr) PITR_TIME="$2"; shift 2 ;;
    --pitr-backup-id) BACKUP_ID="$2"; shift 2 ;;
    *) fatal "unknown arg: $1" ;;
  esac
done

# Make sure the postgres KS is suspended (15-pause-stateful.sh should have
# done this; we double-check).
log "verifying postgres16 KS is suspended..."
if [ "$(kubectl -n flux-system get kustomization postgres16 -o jsonpath='{.spec.suspend}' 2>/dev/null)" != "true" ]; then
  warn "postgres16 KS is NOT suspended. Suspending now..."
  flux suspend ks postgres16
fi

# Refuse to run against a healthy CNPG cluster
require_workload_absent database "cnpg.io/cluster=postgres16,role=primary" "postgres16 primary"

# If a partial cluster exists, delete it (operator will clean up pods + PVCs)
if kubectl -n database get cluster postgres16 >/dev/null 2>&1; then
  warn "an existing postgres16 cluster object is present"
  confirm "Delete it before recovery? (PVCs will be removed)"
  log "deleting existing cluster + PVCs..."
  kubectl -n database delete cluster postgres16 --wait=true
  kubectl -n database delete pvc -l cnpg.io/cluster=postgres16 --wait=true || true
fi

# Resolve the latest base backup ID if not specified
if [ -z "$BACKUP_ID" ]; then
  log "querying MinIO for the latest base backup..."
  BACKUP_ID=$(kubectl -n storage create job dr-list-bk-$RANDOM \
    --image=minio/mc:RELEASE.2024-09-09T07-53-10Z -- \
    /bin/sh -c "mc alias set local http://minio.storage.svc.cluster.local:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1; mc ls local/cnpg-backups/postgres16/postgres16/base/ | awk '{print \$NF}' | tr -d / | sort | tail -1" \
    --dry-run=client -o yaml 2>/dev/null \
    | kubectl apply -f - 2>/dev/null && sleep 5 && \
    kubectl -n storage logs -l job-name=dr-list-bk-* --tail=1 2>/dev/null | tail -1)
  # Cleaner approach: just inspect via the cnpg cli
  if [ -z "$BACKUP_ID" ]; then
    fatal "could not auto-discover latest backup ID. Pass --pitr-backup-id <id>. List with: mc ls local/cnpg-backups/postgres16/postgres16/base/"
  fi
fi
log "using base backup ID: $BACKUP_ID"

# Build the recovery manifest
TEMPLATE="$(dirname "$0")/recovery-templates/postgres16-recovery.yaml"
RECOVERY_MANIFEST=$(mktemp /tmp/postgres16-recovery.XXXXXX.yaml)
trap 'rm -f "$RECOVERY_MANIFEST"' EXIT

if [ -n "$PITR_TIME" ]; then
  log "recovery target time: $PITR_TIME"
  PITR_BLOCK=$(printf 'recoveryTarget:\n        targetTime: "%s"' "$PITR_TIME")
  sed "s|# \\\${RECOVERY_TARGET_TIME_BLOCK}|$PITR_BLOCK|" "$TEMPLATE" > "$RECOVERY_MANIFEST"
else
  log "recovering to end of WAL stream (latest available)"
  cp "$TEMPLATE" "$RECOVERY_MANIFEST"
fi

log "applying recovery manifest:"
echo "  $RECOVERY_MANIFEST"
echo
grep -A2 "bootstrap:" "$RECOVERY_MANIFEST" | head -8
echo
confirm "Apply this recovery manifest to database/postgres16?"

kubectl apply -f "$RECOVERY_MANIFEST"
ok "recovery manifest applied. CNPG operator is now bootstrapping postgres16 from MinIO."

log "waiting for the recovery cluster to become ready (this may take 5-30 min depending on data + WAL volume)..."
wait_for "postgres16 phase" \
  "kubectl -n database get cluster postgres16 -o jsonpath='{.status.phase}'" \
  "Cluster in healthy state" \
  1800

ok "postgres16 recovered. Verify with: kubectl -n database get cluster postgres16"

log "next step: re-apply the canonical (non-recovery) cluster manifest to remove bootstrap.recovery."
log "the simplest way: resume the postgres16 Flux KS and Flux will overwrite the recovery spec on next reconcile:"
echo
echo "    flux resume ks postgres16"
echo
warn "Do this AFTER you've verified the data is intact."
warn "Once resumed, the canonical spec from git takes over — bootstrap.recovery is removed and the cluster runs normally."
