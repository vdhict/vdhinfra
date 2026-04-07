#!/usr/bin/env bash
# Sanity check after a full or partial recovery.
source "$(dirname "$0")/lib.sh"
require_cluster

PASS=0
FAIL=0
WARN=0

check() {
  local name="$1" cmd="$2" want="$3"
  local got
  got=$(eval "$cmd" 2>/dev/null || echo "")
  if [ "$got" = "$want" ]; then
    ok "  $name: $got"
    PASS=$((PASS+1))
  else
    err "  $name: got '$got', want '$want'"
    FAIL=$((FAIL+1))
  fi
}

warn_check() {
  local name="$1" cmd="$2"
  local out
  out=$(eval "$cmd" 2>/dev/null || echo "")
  if [ -n "$out" ]; then
    warn "  $name: $out"
    WARN=$((WARN+1))
  else
    ok "  $name: clean"
    PASS=$((PASS+1))
  fi
}

log "=== nodes ==="
check "nodes ready" \
  "kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | tr ' ' '\n' | sort -u" \
  "True"

log "=== Flux ==="
check "GitRepository ready" \
  "kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" \
  "True"
warn_check "failing Kustomizations" \
  "kubectl -n flux-system get kustomization -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); fails=[k[\"metadata\"][\"name\"] for k in d[\"items\"] if not any(c[\"type\"]==\"Ready\" and c[\"status\"]==\"True\" for c in k.get(\"status\",{}).get(\"conditions\",[]))]; print(\" \".join(fails))'"
warn_check "failing HelmReleases" \
  "kubectl get hr -A -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); fails=[f\"{k[\\\"metadata\\\"][\\\"namespace\\\"]}/{k[\\\"metadata\\\"][\\\"name\\\"]}\" for k in d[\"items\"] if not any(c[\"type\"]==\"Ready\" and c[\"status\"]==\"True\" for c in k.get(\"status\",{}).get(\"conditions\",[]))]; print(\" \".join(fails))'"

log "=== Postgres ==="
check "postgres16 cluster phase" \
  "kubectl -n database get cluster postgres16 -o jsonpath='{.status.phase}'" \
  "Cluster in healthy state"
check "postgres16 ready instances" \
  "kubectl -n database get cluster postgres16 -o jsonpath='{.status.readyInstances}'" \
  "3"

log "=== VolSync apps ==="
for spec in "${VOLSYNC_APPS[@]}"; do
  IFS=: read -r ns app pvc <<< "$spec"
  check "$ns/$pvc bound" \
    "kubectl -n '$ns' get pvc '$pvc' -o jsonpath='{.status.phase}'" \
    "Bound"
done

log "=== Pods ==="
warn_check "CrashLoopBackOff pods" \
  "kubectl get pod -A -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); clbo=[]; [clbo.append(f\"{p[\\\"metadata\\\"][\\\"namespace\\\"]}/{p[\\\"metadata\\\"][\\\"name\\\"]}\") for p in d[\"items\"] for cs in (p[\"status\"].get(\"containerStatuses\") or []) if (cs.get(\"state\",{}).get(\"waiting\") or {}).get(\"reason\")==\"CrashLoopBackOff\"]; print(\" \".join(clbo[:5]))'"
warn_check "Pending pods >5min" \
  "kubectl get pod -A --field-selector=status.phase=Pending -o name | head -5"

log "=== Home Assistant API ==="
if curl -sk --max-time 5 https://hass.bluejungle.net/api/ >/dev/null 2>&1; then
  ok "  HA API reachable"
  PASS=$((PASS+1))
else
  warn "  HA API not yet reachable (may need a moment to start after restore)"
  WARN=$((WARN+1))
fi

echo
log "==========================="
log "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
log "==========================="

if [ $FAIL -gt 0 ]; then
  err "verification FAILED. Investigate above issues before resuming backups."
  exit 1
elif [ $WARN -gt 0 ]; then
  warn "verification PASSED with warnings. Review warnings above."
  exit 0
else
  ok "verification PASSED cleanly. Recovery complete."
fi
