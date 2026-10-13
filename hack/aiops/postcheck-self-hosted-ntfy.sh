#!/bin/bash
# Post-deploy check: Alertmanager ntfy receivers on the self-hosted ntfy
# (2026-10-13), with automatic rollback.
# Usage: postcheck-self-hosted-ntfy.sh <commit-sha-to-revert-on-failure>
# Sends ONE test warning (alertname SibylSelfHostedNtfyProbe, 10 min) through
# Alertmanager's own API and proves it was delivered to the self-hosted topic
# (Alertmanager webhook success + ntfy published-message counter rising).
# Exit 0 PASS, 1 FAIL + rollback, 3 no verdict.
set -u
SHA="${1:?usage: postcheck-self-hosted-ntfy.sh <sha>}"
NS=observability
for t in kubectl flux git python3; do
  command -v "$t" >/dev/null || { echo "NO VERDICT: $t not on PATH"; exit 3; }
done
kubectl -n "$NS" get pod alertmanager-kube-prometheus-stack-0 >/dev/null 2>&1 \
  || { echo "NO VERDICT: cluster API not reachable"; exit 3; }
fail=0
ok()  { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
amx() { kubectl -n $NS exec "alertmanager-kube-prometheus-stack-$1" -c alertmanager -- "${@:2}"; }
ntfy_pub() { # published-message counter of the ntfy server
  kubectl -n ntfy exec deploy/ntfy -- wget -qO- http://localhost:9090/metrics 2>/dev/null \
    | awk '/^ntfy_messages_published_success/ {s+=$2} END {print s+0}'; }

config_checks() {
  fail=0
  for i in 0 1; do
    r=$(kubectl -n $NS get pod "alertmanager-kube-prometheus-stack-$i" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
    [ "$r" = "true true" ] && ok "alertmanager-$i ready" || bad "alertmanager-$i ready=$r"
    amx $i test -s /etc/alertmanager/secrets/ntfy-alertmanager-token/token 2>/dev/null \
      && ok "am-$i token mounted" || bad "am-$i token not mounted"
    out=$(amx $i wget -qO- http://localhost:9093/api/v2/status 2>/dev/null | python3 -c '
import json, sys
c = json.load(sys.stdin)["config"]["original"]
print("PASS" if "ntfy.ntfy.svc.cluster.local/alerts" in c and "ntfy.sh" not in c and "url_file" not in c else "FAIL",
      "running config: self-hosted ntfy only")' 2>&1)
    echo "am-$i $out"; case "$out" in PASS*) ;; *) fail=1 ;; esac
  done
}

for attempt in $(seq 1 20); do
  echo "--- config attempt $attempt $(date -u +%FT%TZ)"; config_checks
  [ "$fail" = 0 ] && break; [ "$attempt" -lt 20 ] && sleep 30
done

if [ "$fail" = 0 ]; then
  before=$(ntfy_pub); echo "ntfy published before: $before"
  ends=$(date -u -v+10M +%FT%TZ 2>/dev/null || date -u -d '+10 min' +%FT%TZ)
  amx 0 wget -qO- --header 'Content-Type: application/json' --post-data \
    "[{\"labels\":{\"alertname\":\"SibylSelfHostedNtfyProbe\",\"severity\":\"warning\",\"namespace\":\"observability\"},\"annotations\":{\"summary\":\"test warning: Alertmanager -> self-hosted ntfy path (Sibyl, safe to ignore)\"},\"endsAt\":\"$ends\"}]" \
    http://localhost:9093/api/v2/alerts >/dev/null 2>&1 && ok "test warning posted to Alertmanager" || bad "could not post test warning"
  delivered=0
  for i in $(seq 1 16); do
    sleep 15
    after=$(ntfy_pub)
    if [ "${after:-0}" -gt "${before:-0}" ]; then delivered=1; break; fi
  done
  echo "ntfy published after: $after"
  [ "$delivered" = 1 ] && ok "self-hosted ntfy accepted a message after the test warning" || bad "no message reached self-hosted ntfy"
  for i in 0 1; do
    amx $i wget -qO- http://localhost:9093/metrics 2>/dev/null \
      | grep -E '^alertmanager_notifications_failed_total\{integration="webhook"' | sed "s/^/am-$i /"
  done
  kubectl -n $NS logs alertmanager-kube-prometheus-stack-0 -c alertmanager --since=10m 2>/dev/null \
    | grep -iE 'ntfy-(day|night|low|critical).*(error|fail)' | tail -3 | grep . && bad "Alertmanager logged ntfy notify errors" || ok "no ntfy notify errors in am-0 log"
fi

if [ "$fail" = 0 ]; then echo "POSTCHECK PASS"; exit 0; fi
echo "POSTCHECK FAIL -> rolling back $SHA"
wt="$(mktemp -d "${TMPDIR:-/tmp}/self-ntfy-rollback.XXXXXX")"
git fetch -q origin main && git worktree add -q --detach "$wt" origin/main \
  && git -C "$wt" revert --no-edit "$SHA" \
  && git -C "$wt" push origin HEAD:main \
  && flux -n flux-system reconcile source git flux-system \
  && flux -n flux-system reconcile kustomization kube-prometheus-stack \
  && flux -n flux-system reconcile kustomization aiops \
  && flux -n flux-system reconcile kustomization ntfy-network-policies
echo "ROLLBACK issued (exit $?)"
exit 1
