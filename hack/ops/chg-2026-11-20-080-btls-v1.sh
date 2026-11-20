#!/usr/bin/env bash
# chg-2026-11-20-080 (wq-017) hop 3: BackendTLSPolicy v1alpha3 -> v1 storage migration, plan section 3.
# usage: btls-v1.sh pre|rewrite|trim     (run in this order; each prints PASS/FAIL, exit 0 = PASS)
#   pre     M1: record objects (no secrets in these objects) + CRD served/storage/storedVersions.
#   rewrite M3+M4: force one write per object (annotation) so the API server re-encodes in storage v1;
#           prove: resourceVersion changed, a managedFields entry for .../v1 exists, GET via /v1 works,
#           Accepted=True. Requires the Git manifests already on gateway.networking.k8s.io/v1 (M2).
#   trim    M5: storedVersions -> ["v1"]; read back. Only after the R6 gate (incl. negative) is green.
set -u
P=${1:?}; fail=0; ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*"; fail=1; }
CRD=backendtlspolicies.gateway.networking.k8s.io
OBJ=$(kubectl get backendtlspolicy -n network -o jsonpath="{.items[*].metadata.name}")   # all objects must be re-encoded before M5
[[ $(kubectl get backendtlspolicy -A --no-headers | grep -v -c "^network ") == 0 ]] || { echo "FAIL BTLS outside network"; exit 1; }
crdline(){ kubectl get crd $CRD -o json | jq -c '{served:[.spec.versions[]|select(.served).name],storage:[.spec.versions[]|select(.storage).name],stored:.status.storedVersions}'; }
case $P in
pre)
  echo "M1 $(date -u +%FT%TZ) crd $(crdline)"
  kubectl -n network get backendtlspolicy $OBJ -o yaml | grep -v -E '^\s+f:|last-applied'
  for o in $OBJ; do echo "rv $o $(kubectl -n network get backendtlspolicy $o -o jsonpath='{.metadata.resourceVersion}')"; done ;;
rewrite)
  t=$(date -u +%Y%m%dT%H%M%SZ); echo "M3 $t crd $(crdline)"
  for o in $OBJ; do
    a=$(kubectl -n network get backendtlspolicy $o -o jsonpath='{.metadata.resourceVersion}')
    kubectl -n network annotate backendtlspolicy $o "chg080/storage=v1-$t" --overwrite >/dev/null
    b=$(kubectl -n network get backendtlspolicy $o -o jsonpath='{.metadata.resourceVersion}')
    [[ $a != "$b" ]] && ok "M4 $o resourceVersion $a -> $b" || bad "M4 $o resourceVersion unchanged"
    mf=$(kubectl get --raw /apis/gateway.networking.k8s.io/v1/namespaces/network/backendtlspolicies/$o | jq -r '[.metadata.managedFields[].apiVersion]|unique|join(",")')
    [[ $mf == *gateway.networking.k8s.io/v1* ]] && ok "M4 $o GET via /v1 ok, managedFields apiVersions [$mf]" || bad "M4 $o managedFields [$mf]"
    s=$(kubectl -n network get backendtlspolicy $o -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}')
    [[ $s == True ]] && ok "M4 $o Accepted" || bad "M4 $o Accepted=$s"
  done ;;
trim)
  kubectl patch crd $CRD --subresource=status --type=merge -p '{"status":{"storedVersions":["v1"]}}' >/dev/null
  l=$(crdline); echo "M5 $(date -u +%FT%TZ) crd $l"
  [[ $l == *'"stored":["v1"]'* ]] && ok "M5 storedVersions [v1]" || bad "M5 $l" ;;
esac
exit $fail
