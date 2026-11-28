#!/usr/bin/env bash
# chg-2026-11-28-106 A3 teardown: removes the dry-run pod, then its CiliumNetworkPolicy (policy outlives the pod).
# Literal names only; refuses objects that lack the chg label. Called on its own, never inline. No rm.
set -uo pipefail
NS="devtools"; POD="chg-2026-11-28-106-retention-dryrun"; CNP="chg-2026-11-28-106-retention-dryrun"
lbl(){ kubectl -n "${NS:?}" get "$1" "$2" -o jsonpath='{.metadata.labels.vdh\.dryrun/chg}' 2>/dev/null; }
if kubectl -n "$NS" get pod "${POD:?}" >/dev/null 2>&1; then
  [ "$(lbl pod "$POD")" = chg-2026-11-28-106 ] || { echo "refuse: pod $POD lacks chg label"; exit 2; }
  kubectl -n "$NS" delete pod "$POD" --wait=true --timeout=2m
fi
kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 && { echo "STOP: pod still present, CNP kept"; exit 1; }
if kubectl -n "$NS" get ciliumnetworkpolicy "${CNP:?}" >/dev/null 2>&1; then
  [ "$(lbl ciliumnetworkpolicy "$CNP")" = chg-2026-11-28-106 ] || { echo "refuse: CNP $CNP lacks chg label"; exit 2; }
  kubectl -n "$NS" delete ciliumnetworkpolicy "$CNP" --wait=true
fi
left=$(kubectl -n "$NS" get pod,ciliumnetworkpolicy -l vdh.dryrun/chg=chg-2026-11-28-106 --no-headers 2>/dev/null | grep -c .)
echo "objects with chg label left: $left"
echo "TEARDOWN $( [ "$left" -eq 0 ] && echo PASS || echo FAIL )"
[ "$left" -eq 0 ]
