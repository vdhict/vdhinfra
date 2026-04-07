#!/usr/bin/env bash
# Re-enable scheduled backups after a successful recovery.
# Run this AFTER 90-verify.sh passes cleanly.
source "$(dirname "$0")/lib.sh"
require_cluster

log "=== resuming postgres16 ScheduledBackup ==="
# The ScheduledBackup re-runs at its next cron time (02:30); nothing to do
# unless it's been suspended. Show current state:
kubectl -n database get scheduledbackup postgres16-daily -o jsonpath='{"  schedule="}{.spec.schedule}{" suspend="}{.spec.suspend}{"\n"}'

log "=== triggering immediate first post-recovery backup ==="
TS=$(date +%s)
cat <<YAML | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres16-post-recovery-$TS
  namespace: database
spec:
  cluster:
    name: postgres16
  method: barmanObjectStore
YAML
ok "  triggered backup postgres16-post-recovery-$TS"

log "=== triggering immediate VolSync sync for all 7 apps ==="
NOW=$(date -u +%Y-%m-%dT%H-%M-%SZ)
for spec in "${VOLSYNC_APPS[@]}"; do
  IFS=: read -r ns app pvc <<< "$spec"
  kubectl -n "$ns" patch replicationsource "$app" --type merge \
    -p "{\"spec\":{\"trigger\":{\"manual\":\"post-recovery-$NOW\"}}}" >/dev/null && echo "  triggered $ns/$app"
done

ok "all backup tasks triggered. Wait ~5 min then verify with cluster-health daily report."
