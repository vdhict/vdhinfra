#!/bin/bash
# Post-deploy check for chg-2026-10-12-009 with automatic rollback.
# Usage: postcheck.sh <commit-sha-to-revert-on-failure>
# Runs from a clean worktree on main. Needs kubectl (KUBECONFIG ~/.kube/config)
# and flux. Prints PASS/FAIL per check; on any FAIL it git-reverts the commit,
# pushes main and reconciles Flux, then exits 1.
set -u
SHA="${1:?usage: postcheck.sh <sha>}"
NS=observability
fail=0
ok()  { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

# Checks retry every 30 s for up to 6 min: the operator + config-reloader
# need tens of seconds to load a new PrometheusRule (the first run of this
# script rolled back a healthy deploy because it checked 5 s too early).
run_checks() {
  fail=0
  # Alertmanager pods Ready and the running config is the new tree.
  for i in 0 1; do
    r=$(kubectl -n $NS get pod "alertmanager-kube-prometheus-stack-$i" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
    [ "$r" = "true true" ] && ok "alertmanager-$i ready" || bad "alertmanager-$i ready=$r"
    cfg=$(kubectl -n $NS exec "alertmanager-kube-prometheus-stack-$i" -c alertmanager -- \
          wget -qO- http://localhost:9093/api/v2/status 2>/dev/null)
    echo "$cfg" | grep -q 'receiver: ntfy-low' && ok "am-$i running config has ntfy-low root" || bad "am-$i running config not reloaded"
    echo "$cfg" | grep -q 'ha-critical' && ok "am-$i keeps ha-critical" || bad "am-$i lost ha-critical"
    kubectl -n $NS exec "alertmanager-kube-prometheus-stack-$i" -c alertmanager -- \
      test -s /etc/alertmanager/secrets/alertmanager-ntfy/day-url && ok "am-$i ntfy secret mounted" || bad "am-$i ntfy secret missing"
  done

  # Prometheus still healthy and the new rule group loaded.
  for i in 0 1; do
    r=$(kubectl -n $NS get pod "prometheus-kube-prometheus-stack-$i" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
    case "$r" in *false*|"") bad "prometheus-$i ready=$r" ;; *) ok "prometheus-$i ready" ;; esac
  done
  rules=$(kubectl -n $NS exec prometheus-kube-prometheus-stack-0 -c prometheus -- \
          wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' 2>/dev/null)
  for g in aiops-certs aiops-tokens aiops-renovate aiops-hosts; do
    echo "$rules" | grep -q "\"name\":\"$g\"" && ok "rule group $g loaded" || bad "rule group $g not loaded"
  done

}
for attempt in $(seq 1 12); do
  echo "--- attempt $attempt $(date -u +%FT%TZ)"
  run_checks
  [ "$fail" = 0 ] && break
  [ "$attempt" -lt 12 ] && sleep 30
done

if [ "$fail" = 0 ]; then echo "POSTCHECK PASS"; exit 0; fi

echo "POSTCHECK FAIL -> rolling back $SHA"
git fetch -q origin main && git checkout -q --detach origin/main \
  && git revert --no-edit "$SHA" \
  && git push origin HEAD:main \
  && flux -n flux-system reconcile source git flux-system \
  && flux -n flux-system reconcile kustomization kube-prometheus-stack --with-source \
  && flux -n $NS reconcile helmrelease kube-prometheus-stack --force
echo "ROLLBACK issued (exit $?)"
exit 1
