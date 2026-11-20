#!/usr/bin/env bash
# chg-2026-11-20-080 (wq-017) envoy-gateway: run ONE hop end to end with automatic rollback.
# usage: envoy-hop.sh <hopname> <want-tag> <bundle> <rollback: revert|ctrl> [prev-tag prev-bundle prev-chart-regex]
#   The hop commit must be HEAD of the worktree ($WT), not yet on origin/main.
#   revert : rollback = git revert HEAD + push + Flux (step 0, hops 1/2/4/7).
#   ctrl   : rollback = flux suspend hr + helm rollback to the previous chart revision with
#            --force-conflicts (CRDs untouched; Helm never rolls CRDs back). Hops 3/5/6, G2 substitute:
#            the plan's "previous chart + upgrade.crds: Skip" commit cannot work here because the
#            cluster-apps patch forces crds: CreateReplace on every HelmRelease (live: 70/70).
# Env: WT (worktree), MAIN (checkout holding ops/ops), STATE (gate state dir).
set -u
HOP=$1; WANT=$2; BUNDLE=$3; RB=$4; PTAG=${5:-}; PBUNDLE=${6:-}; PRX=${7:-}
WT=${WT:?}; MAIN=${MAIN:?}; STATE=${STATE:?}; export STATE REPO=$WT
E=$WT/ops/evidence/chg-2026-11-20-080; G=$WT/hack/ops/chg-2026-11-20-080-envoy-gate.sh
ts(){ date -u +%Y%m%dT%H%M%SZ; }
log(){ (cd "$MAIN" && ./ops/ops change event chg-2026-11-20-080 "$1" --actor k8s-engineer --payload-json "$2" >/dev/null) && echo "LOG $1"; }
wout(){ set -o noclobber; cat > "$1"; set +o noclobber; }

push(){ # push HEAD of WT to main; rebase on non-ff, never force
  for i in 1 2 3; do
    git -C "$WT" fetch -q origin && git -C "$WT" rebase -q origin/main || return 1
    git -C "$WT" push -q origin HEAD:main && return 0; sleep 3; done; return 1; }

wait_flux(){ # $1 sha ; waits for source + envoy kustomizations + HR new helm revision
  local sha=$1 rev0=$2 i
  flux -n flux-system reconcile source git flux-system >/dev/null 2>&1
  for i in $(seq 1 60); do kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}' | grep -q "$sha" && break; sleep 5; done
  flux -n flux-system reconcile ks cluster-apps >/dev/null 2>&1
  flux -n flux-system reconcile ks envoy-gateway >/dev/null 2>&1 &
  for i in $(seq 1 180); do
    r=$(helm -n network history envoy-gateway -o json 2>/dev/null | jq -r '.[-1] | "\(.revision) \(.status)"')
    hr=$(kubectl -n network get hr envoy-gateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [[ ${r%% *} -gt $rev0 && "${r#* }" == deployed && $hr == True ]] && break; sleep 5; done
  echo "helm rev ${r} hr Ready=$hr"
  flux -n flux-system reconcile ks envoy-gateway-gateways >/dev/null 2>&1
  kubectl -n flux-system get ks envoy-gateway-canary >/dev/null 2>&1 && flux -n flux-system reconcile ks envoy-gateway-canary >/dev/null 2>&1
  for d in $(kubectl -n network get deploy -l app.kubernetes.io/managed-by=envoy-gateway -o name); do kubectl -n network rollout status "$d" --timeout=10m >/dev/null 2>&1 || echo "rollout not complete: $d"; done
}

rollback(){
  local t; t=$(ts)
  if [[ $RB == revert ]]; then
    git -C "$WT" revert --no-edit HEAD >/dev/null && push || { echo "ROLLBACK PUSH FAILED"; return 1; }
    local r0; r0=$(helm -n network history envoy-gateway -o json | jq -r '.[-1].revision')
    wait_flux "$(git -C "$WT" rev-parse HEAD)" "$r0"
  else
    local prev; prev=$(helm -n network history envoy-gateway -o json | jq -r --arg v "$PRX" '[.[]|select(.chart|test($v))][-1].revision')
    echo "controller-only rollback to helm rev $prev ($PTAG)"
    flux -n network suspend hr envoy-gateway
    helm -n network rollback envoy-gateway "$prev" --force-conflicts --wait --timeout 8m
    for d in $(kubectl -n network get deploy -l app.kubernetes.io/managed-by=envoy-gateway -o name); do kubectl -n network rollout status "$d" --timeout=10m >/dev/null 2>&1; done
  fi
  sleep 60
  { echo "chg-2026-11-20-080 wq-017 $HOP ROLLBACK readback ($RB) at $t"; "$G" gate "$HOP-rollback" "$PTAG" "$PBUNDLE"; echo "exit=$?"; } 2>&1 | wout "$E/envoy-$HOP-$t-rollback-readback.txt"
  grep -E 'GATE|exit=' "$E/envoy-$HOP-$t-rollback-readback.txt"
  log rolled_back "{\"wq\":\"wq-017\",\"step\":\"envoy $HOP\",\"mode\":\"$RB\",\"evidence\":\"ops/evidence/chg-2026-11-20-080/envoy-$HOP-$t-rollback-readback.txt\",\"summary\":\"gate failed, automatic rollback ($RB); readback $(grep -o 'GATE [A-Z]*' "$E/envoy-$HOP-$t-rollback-readback.txt")\",\"decision\":\"AGR-109: tests are the gate\"}"
}

# ---- pre-gate
t0=$(ts); git -C "$WT" fetch -q origin
"$G" guard | wout "$E/envoy-$HOP-$t0-p1-guard.txt"; grep -q 'GUARD PASS' "$E/envoy-$HOP-$t0-p1-guard.txt" || { echo "P1 FAILED, not pushing"; cat "$E/envoy-$HOP-$t0-p1-guard.txt"; exit 2; }
"$G" snapshot "$E/envoy-$HOP-$t0-p3-snapshot.yaml"
{ echo "# P3 $t0 helm history + CRDs + proxy names/UIDs/LB IPs"; helm -n network history envoy-gateway; cat "$STATE/svc-base"; kubectl get crd -o json | jq -r '.items[] | select(.spec.group=="gateway.networking.k8s.io" or .spec.group=="gateway.envoyproxy.io") | "\(.metadata.name) \(.metadata.annotations["gateway.networking.k8s.io/bundle-version"]//"-") \(.status.storedVersions|join(","))"'; } | wout "$E/envoy-$HOP-$t0-p3-state.txt"
rev0=$(helm -n network history envoy-gateway -o json | jq -r '.[-1].revision')
date -u +%FT%TZ > "$STATE/hop-start-iso"
# ---- execute
push || { echo "PUSH FAILED"; exit 3; }
sha=$(git -C "$WT" rev-parse HEAD); echo "pushed $sha $(date -u +%FT%TZ)"
log executed "{\"wq\":\"wq-017\",\"step\":\"envoy $HOP\",\"commit\":\"${sha:0:8}\",\"summary\":\"pushed hop $HOP -> $WANT (bundle $BUNDLE); rollback mode $RB\",\"decision\":\"AGR-109: tests are the gate\"}"
wait_flux "$sha" "$rev0"
sleep 120   # soak: proxies drain (180s drainTimeout runs in the old pods) and xDS settles
t1=$(ts)
{ echo "chg-2026-11-20-080 wq-017 $HOP gate, main ${sha:0:8}"; "$G" gate "$HOP" "$WANT" "$BUNDLE"; echo "exit=$?"; } 2>&1 | wout "$E/envoy-$HOP-$t1-gate.txt"
if grep -q '^exit=0' "$E/envoy-$HOP-$t1-gate.txt"; then
  echo "GATE PASS $HOP"; grep -c '^PASS' "$E/envoy-$HOP-$t1-gate.txt"
  log validated "{\"wq\":\"wq-017\",\"step\":\"envoy $HOP\",\"commit\":\"${sha:0:8}\",\"evidence\":\"ops/evidence/chg-2026-11-20-080/envoy-$HOP-$t1-gate.txt\",\"summary\":\"$HOP $WANT gate PASS ($(grep -c '^PASS' "$E/envoy-$HOP-$t1-gate.txt") checks)\",\"decision\":\"AGR-109: tests are the gate\"}"
  exit 0
fi
echo "GATE FAIL $HOP"; grep '^FAIL' "$E/envoy-$HOP-$t1-gate.txt"
rollback; exit 1
