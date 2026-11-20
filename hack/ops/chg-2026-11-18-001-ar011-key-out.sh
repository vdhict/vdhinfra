#!/usr/bin/env bash
# chg-2026-11-18-001 (tsk-2026-11-19-964, wq-015): ar-011 D1 part 2, the build key out of the cluster while Passkey Point
# sleeps (Argus re-review 20261120T091726Z, A2 + Q3). Run only AFTER the K4 cut readback is green and Argus gave GO.
#
# How the key gets into the cluster today (measured 2026-11-20): ExternalSecret devtenant-build/atlas-devtenant-build-key,
# applied BY HAND with kubectl apply on 2026-10-12T14:49:08Z (chg-2026-10-12-004). It is NOT in Git and NOT owned by Flux
# (no kustomize.toolkit.fluxcd.io labels), so there is nothing to suspend in Git and Flux will not recreate it.
#   store  ClusterSecretStore onepassword-devtenant-build (namespaceSelector devtenant-build only; vault passkey-point-devtenant-build)
#   item   atlas-devtenant-build, properties tls.key + tls.crt; refreshInterval 0; target creationPolicy Owner
# The Secret carries an ownerReference to the ExternalSecret (controller, blockOwnerDeletion), so deleting the
# ExternalSecret garbage-collects the Secret. ESO only READS 1Password (no PushSecret exists in the cluster), so the
# 1Password item is untouched; target.deletionPolicy acts on the Kubernetes Secret only.
#
#   hack/ops/chg-2026-11-18-001-ar011-key-out.sh dry       reads + server-side dry-run delete; writes nothing
#   hack/ops/chg-2026-11-18-001-ar011-key-out.sh remove    delete ES (Secret follows), then readback: both NotFound
#   hack/ops/chg-2026-11-18-001-ar011-key-out.sh restore   wake: re-apply the ES below, readback Ready=True + both keys present
#
# Never prints Secret data: only names, key NAMES, conditions and timestamps.
set -euo pipefail
NS=devtenant-build
NAME=atlas-devtenant-build-key
MODE="${1:?usage: dry | remove | restore}"

es_manifest() {
cat <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: atlas-devtenant-build-key
  namespace: devtenant-build
  labels: {vdhinfra.io/chg: chg-2026-11-18-001}
spec:
  refreshInterval: "0"
  secretStoreRef: {kind: ClusterSecretStore, name: onepassword-devtenant-build}
  target: {name: atlas-devtenant-build-key, creationPolicy: Owner, deletionPolicy: Delete}
  data:
    - {secretKey: tls.key, remoteRef: {key: atlas-devtenant-build, property: tls.key}}
    - {secretKey: tls.crt, remoteRef: {key: atlas-devtenant-build, property: tls.crt}}
YAML
}

state() {
  echo "es:     $(kubectl -n "$NS" get externalsecret "$NAME" -o jsonpath='{.metadata.creationTimestamp} {.status.conditions[?(@.type=="Ready")].reason}' 2>&1 | tail -1)"
  echo "secret: $(kubectl -n "$NS" get secret "$NAME" -o go-template='{{.metadata.creationTimestamp}} keys={{range $k,$v := .data}}{{$k}},{{end}}' 2>&1 | tail -1)"
  echo "users:  $(kubectl -n "$NS" get pods --field-selector=status.phase=Running -o json | python3 -c '
import json,sys
d=json.load(sys.stdin); n=[p["metadata"]["name"] for p in d["items"] if any(v.get("secret",{}).get("secretName")=="atlas-devtenant-build-key" for v in p["spec"].get("volumes",[]))]
print(len(n), " ".join(n))')"
  echo "cronjob devtenant-refresh-contractor-new suspend=$(kubectl -n "$NS" get cronjob devtenant-refresh-contractor-new -o jsonpath='{.spec.suspend}')"
}

case "$MODE" in
  dry)
    date -u +%FT%TZ; state
    kubectl -n "$NS" delete externalsecret "$NAME" --dry-run=server
    es_manifest | kubectl apply --dry-run=server -f - >/dev/null && echo "restore manifest: server dry-run ok"
    ;;
  remove)
    date -u +%FT%TZ; state
    [ "$(kubectl -n "$NS" get cronjob devtenant-refresh-contractor-new -o jsonpath='{.spec.suspend}')" = "true" ] || { echo "refused: the CronJob is not suspended"; exit 2; }
    kubectl -n "$NS" delete externalsecret "$NAME" --wait=true --timeout=60s
    for i in $(seq 1 12); do
      kubectl -n "$NS" get secret "$NAME" >/dev/null 2>&1 || break
      sleep 5
    done
    date -u +%FT%TZ; state
    if kubectl -n "$NS" get externalsecret "$NAME" >/dev/null 2>&1 || kubectl -n "$NS" get secret "$NAME" >/dev/null 2>&1; then
      echo "FAILED: ES or Secret still present"; exit 6
    fi
    echo "OK: ExternalSecret and Secret $NS/$NAME NotFound; the 1Password item is not touched by ESO"
    ;;
  restore)
    date -u +%FT%TZ
    es_manifest | kubectl apply -f -
    kubectl -n "$NS" wait externalsecret "$NAME" --for=condition=Ready --timeout=120s
    state
    keys=$(kubectl -n "$NS" get secret "$NAME" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}')
    [ "$keys" = "tls.crt tls.key " ] || { echo "FAILED: secret keys '$keys'"; exit 6; }
    echo "OK: key back in $NS (Ready, tls.crt + tls.key)"
    ;;
  *) echo "usage: dry | remove | restore"; exit 2 ;;
esac
