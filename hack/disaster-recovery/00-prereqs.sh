#!/usr/bin/env bash
# Pre-flight check for disaster recovery. Run this BEFORE any of the other
# scripts to verify your environment has everything it needs.
source "$(dirname "$0")/lib.sh"

log "verifying tools..."
require_tools kubectl flux sops age mc git

log "verifying age key..."
KEY="${SOPS_AGE_KEY_FILE:-$HOME/Code/homelab-migration/config/age.key}"
if [ ! -f "$KEY" ]; then
  fatal "age key not found at $KEY. Set SOPS_AGE_KEY_FILE or restore the key from offline backup."
fi
ok "age key present at $KEY"

log "testing sops decryption..."
if ! SOPS_AGE_KEY_FILE="$KEY" sops -d kubernetes/main/cluster/cluster-secrets.sops.yaml >/dev/null 2>&1; then
  fatal "sops decryption failed. The age key cannot decrypt cluster-secrets.sops.yaml. Wrong key or corrupt file."
fi
ok "sops decryption works"

log "verifying cluster reachability..."
require_cluster
ok "$(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("server",d["serverVersion"]["gitVersion"])')"

log "verifying MinIO reachability (in-cluster)..."
if ! kubectl -n storage get svc minio >/dev/null 2>&1; then
  warn "minio service not found in storage namespace — this may be expected during early bootstrap"
else
  ok "minio service present"
fi

log "verifying postgres barman bucket..."
if kubectl -n storage get secret minio-secret >/dev/null 2>&1; then
  cat > /tmp/dr-mc-check.json <<'JSON'
{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"dr-mc-check","namespace":"storage"},
 "spec":{"ttlSecondsAfterFinished":120,"backoffLimit":0,
  "template":{"spec":{"restartPolicy":"Never",
   "containers":[{"name":"mc","image":"minio/mc:RELEASE.2024-09-09T07-53-10Z",
     "command":["/bin/sh","-c","mc alias set local http://minio.storage.svc.cluster.local:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1; echo BASE_BACKUPS:; mc ls local/cnpg-backups/postgres16/postgres16/base/ 2>/dev/null | tail -3; echo VOLSYNC_REPOS:; mc ls local/volsync/ 2>/dev/null"],
     "envFrom":[{"secretRef":{"name":"minio-secret"}}]}]}}}}
JSON
  kubectl delete job -n storage dr-mc-check --ignore-not-found >/dev/null 2>&1
  kubectl apply -f /tmp/dr-mc-check.json >/dev/null
  sleep 10
  kubectl -n storage logs job/dr-mc-check 2>/dev/null || warn "dr-mc-check job log not yet available"
  kubectl delete job -n storage dr-mc-check --ignore-not-found >/dev/null 2>&1
  rm -f /tmp/dr-mc-check.json
fi

ok "pre-flight passed. You may now proceed with the recovery scripts."
