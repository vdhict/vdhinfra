#!/usr/bin/env bash
# Suspend all stateful Flux Kustomizations BEFORE Flux can apply them with
# empty data after a fresh bootstrap. Run this within seconds of `just main
# bootstrap` finishing.
#
# Idempotent: re-running on already-suspended KSes is a no-op.
source "$(dirname "$0")/lib.sh"
require_cluster
require_tools flux

STATEFUL_KSES=(
  postgres16
  zwave-js-ui
  zigbee2mqtt
  home-assistant
  node-red
  esphome
  mealie
  radarr
)

log "suspending stateful Flux Kustomizations..."
for ks in "${STATEFUL_KSES[@]}"; do
  if kubectl -n flux-system get kustomization "$ks" >/dev/null 2>&1; then
    if [ "$(kubectl -n flux-system get kustomization "$ks" -o jsonpath='{.spec.suspend}')" = "true" ]; then
      log "  $ks already suspended"
    else
      flux suspend ks "$ks" 2>&1 | sed 's/^/    /'
    fi
  else
    warn "  $ks does not exist yet — Flux hasn't reconciled it. This is fine if bootstrap is still in progress."
  fi
done

# Also scale workloads to 0 if they happen to already exist (covers the race
# where bootstrap was a few seconds ahead of this script).
log "scaling existing stateful workloads to 0 (in case they already started)..."
for spec in "${VOLSYNC_APPS[@]}"; do
  IFS=: read -r ns app pvc <<< "$spec"
  for kind in deployment statefulset; do
    if kubectl -n "$ns" get "$kind" "$app" >/dev/null 2>&1; then
      n=$(kubectl -n "$ns" get "$kind" "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      if [ -n "$n" ] && [ "$n" -gt 0 ]; then
        warn "  $ns/$kind/$app was already at $n replicas — scaling to 0"
        kubectl -n "$ns" scale "$kind" "$app" --replicas=0 2>&1 | sed 's/^/    /'
      fi
    fi
  done
done

# Postgres is special — CNPG manages its own pods via Cluster CR
if kubectl -n database get cluster postgres16 >/dev/null 2>&1; then
  warn "  database/cluster/postgres16 was already created — restore script will handle it"
fi

ok "stateful KSes suspended. You can now run 20-restore-postgres.sh + 30-restore-volsync-all.sh."
