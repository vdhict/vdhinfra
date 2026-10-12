#!/bin/bash
# Post-deploy check for chg-2026-10-07-007 step f (mypka wires alerts, ntfy
# route) + the RenovateNoContainerCommit14d signal, with automatic rollback.
# Usage: mypka-wires-postcheck.sh <commit-sha-to-revert-on-failure>
# Needs kubectl, flux, git, python3 (eval "$(mise env -s bash)").
# Exit 0 = PASS, 1 = FAIL + rollback issued, 3 = no verdict (tooling/API).
set -u
SHA="${1:?usage: mypka-wires-postcheck.sh <sha>}"
NS=observability
for t in kubectl flux git python3; do
  command -v "$t" >/dev/null || { echo "NO VERDICT: $t not on PATH"; exit 3; }
done
kubectl -n "$NS" get pod prometheus-kube-prometheus-stack-0 >/dev/null 2>&1 \
  || { echo "NO VERDICT: cluster API not reachable"; exit 3; }

fail=0
ok()  { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

run_checks() {
  fail=0
  # Flux applied the new Kustomization.
  r=$(kubectl -n flux-system get kustomization mypka-wires-alerts -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$r" = "True" ] && ok "ks mypka-wires-alerts Ready" || bad "ks mypka-wires-alerts Ready=$r"

  # Alertmanager: both pods ready, running config has the new route and the
  # pre-existing tree (root ntfy-low, ha-critical) intact.
  for i in 0 1; do
    r=$(kubectl -n $NS get pod "alertmanager-kube-prometheus-stack-$i" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
    [ "$r" = "true true" ] && ok "alertmanager-$i ready" || bad "alertmanager-$i ready=$r"
    cfg=$(kubectl -n $NS exec "alertmanager-kube-prometheus-stack-$i" -c alertmanager -- \
          wget -qO- http://localhost:9093/api/v2/status 2>/dev/null)
    echo "$cfg" | grep -q 'component=\\"mypka-wires\\"\|component = mypka-wires\|mypka-wires' \
      && ok "am-$i running config has mypka-wires route" || bad "am-$i running config lacks mypka-wires route"
    echo "$cfg" | grep -q 'receiver: ntfy-low' && ok "am-$i root ntfy-low" || bad "am-$i root changed"
    echo "$cfg" | grep -q 'ha-critical' && ok "am-$i keeps ha-critical" || bad "am-$i lost ha-critical"
  done

  # Prometheus: every rule in the new groups (and the renovate group) loaded
  # with health=ok.
  rules=$(kubectl -n $NS exec prometheus-kube-prometheus-stack-0 -c prometheus -- \
          wget -qO- 'http://localhost:9090/api/v1/rules' 2>/dev/null)
  out=$(printf '%s' "$rules" | python3 -c '
import json, sys
want = {"mypka-wires-records": 1, "mypka-wires-wave1": 1, "mypka-wires-tennis": 1, "mypka-jobs": 1, "aiops-renovate": 4}
try:
    groups = {g["name"]: g for g in json.load(sys.stdin)["data"]["groups"]}
except Exception as e:
    print("FAIL rules API unreadable", e); sys.exit()
for name, n in want.items():
    g = groups.get(name)
    if not g:
        print("FAIL group", name, "not loaded"); continue
    bad = [(r.get("name"), r.get("health"), r.get("lastError")) for r in g["rules"] if r.get("health") != "ok"]
    if len(g["rules"]) < n or bad:
        print("FAIL group", name, "rules", len(g["rules"]), "unhealthy", bad)
    else:
        print("PASS group", name, "rules", len(g["rules"]), "health=ok")
' 2>&1)
  echo "$out"
  echo "$out" | grep -q '^FAIL' && fail=1

  # aiops-exporter serves the new metric (proves the new poll code runs).
  m=$(kubectl -n $NS exec prometheus-kube-prometheus-stack-0 -c prometheus -- \
      wget -qO- 'http://localhost:9090/api/v1/query?query=renovate_last_main_container_commit_timestamp_seconds' 2>/dev/null)
  echo "$m" | grep -q '"result":\[{' && ok "renovate_last_main_container_commit_timestamp_seconds scraped" \
    || bad "renovate_last_main_container_commit_timestamp_seconds not in Prometheus"
  up=$(kubectl -n $NS exec prometheus-kube-prometheus-stack-0 -c prometheus -- \
      wget -qO- 'http://localhost:9090/api/v1/query?query=aiops_github_up' 2>/dev/null)
  echo "$up" | grep -q '"1"\]' && ok "aiops_github_up 1" || bad "aiops_github_up not 1"
}

for attempt in $(seq 1 20); do
  echo "--- attempt $attempt $(date -u +%FT%TZ)"
  run_checks
  [ "$fail" = 0 ] && break
  [ "$attempt" -lt 20 ] && sleep 30
done

if [ "$fail" = 0 ]; then echo "POSTCHECK PASS"; exit 0; fi

echo "POSTCHECK FAIL -> rolling back $SHA"
wt="$(mktemp -d "${TMPDIR:-/tmp}/mypka-wires-rollback.XXXXXX")"
git fetch -q origin main && git worktree add -q --detach "$wt" origin/main \
  && git -C "$wt" revert --no-edit "$SHA" \
  && git -C "$wt" push origin HEAD:main \
  && flux -n flux-system reconcile source git flux-system \
  && flux -n flux-system reconcile kustomization cluster-apps \
  && flux -n flux-system reconcile kustomization kube-prometheus-stack \
  && flux -n flux-system reconcile kustomization aiops
echo "ROLLBACK issued (exit $?)"
exit 1
