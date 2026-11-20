#!/usr/bin/env bash
# usage: inventory.sh <label>  -> counts and names (never values) of PVCs, Secrets, CNPG clusters, CronJob suspend, image refs in Git
set -u
NS="lab-passkey lab-passkey-dotnet lab-passkey-dotnet-maxsession passkey-point-e2e pp-ci devtenant-build devtenant-ops"
echo "# PP inventory $1 at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for ns in $NS; do
  pvc=$(kubectl -n "$ns" get pvc --no-headers 2>/dev/null | awk '{print $1":"$2}' | tr '\n' ' ')
  sec=$(kubectl -n "$ns" get secret --no-headers 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')
  npvc=$(kubectl -n "$ns" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')
  nsec=$(kubectl -n "$ns" get secret --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "ns=$ns pvc_count=$npvc secret_count=$nsec"
  echo "  pvcs: $pvc"
  # secret names deliberately not written to evidence (public repo)
  kubectl -n "$ns" get deploy --no-headers -o custom-columns=N:.metadata.name,R:.spec.replicas,IMG:.spec.template.spec.containers[*].image 2>/dev/null | sed 's/^/  deploy /'
  kubectl -n "$ns" get cronjob --no-headers -o custom-columns=N:.metadata.name,SUSPEND:.spec.suspend 2>/dev/null | sed 's/^/  cronjob /'
  kubectl -n "$ns" get cluster.postgresql.cnpg.io --no-headers -o custom-columns=N:.metadata.name,HIB:.metadata.annotations.cnpg\\.io/hibernation,PHASE:.status.phase,READY:.status.readyInstances 2>/dev/null | sed 's/^/  cnpg /'
  echo "  running_pods=$(kubectl -n "$ns" get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
done
