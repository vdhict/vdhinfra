#!/bin/bash
# Post-deploy check for the LAN dead man's switch (2026-10-13, Mack AGR-078),
# with automatic rollback. Run on a Mac on the LAN (it tests the LAN path).
# Usage: postcheck-lan-heartbeat.sh <commit-sha-to-revert-on-failure>
# Needs kubectl, flux, git, python3, curl and AIOPS_AM_URL in
# ~/.config/aiops/ntfy.env. Exit 0 PASS, 1 FAIL + rollback, 3 no verdict.
set -u
SHA="${1:?usage: postcheck-lan-heartbeat.sh <sha>}"
NS=observability
for t in kubectl flux git python3 curl; do
  command -v "$t" >/dev/null || { echo "NO VERDICT: $t not on PATH"; exit 3; }
done
AM_URL=$(sed -n 's/^AIOPS_AM_URL=//p' "$HOME/.config/aiops/ntfy.env" | tr -d '"')
[ -n "$AM_URL" ] || { echo "NO VERDICT: AIOPS_AM_URL missing in ntfy.env"; exit 3; }
kubectl -n "$NS" get pod alertmanager-kube-prometheus-stack-0 >/dev/null 2>&1 \
  || { echo "NO VERDICT: cluster API not reachable"; exit 3; }

fail=0
ok()  { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

run_checks() {
  fail=0
  for i in 0 1; do
    r=$(kubectl -n $NS get pod "alertmanager-kube-prometheus-stack-$i" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
    [ "$r" = "true true" ] && ok "alertmanager-$i ready" || bad "alertmanager-$i ready=$r"
    cfg=$(kubectl -n $NS exec "alertmanager-kube-prometheus-stack-$i" -c alertmanager -- \
          wget -qO- http://localhost:9093/api/v2/status 2>/dev/null)
    printf '%s' "$cfg" | python3 -c '
import json, sys
c = json.load(sys.stdin)["config"]["original"]
ok = "name: heartbeat" not in c and "heartbeat-url" not in c and ("repeat_interval: 1d" in c or "repeat_interval: 24h" in c)
print("PASS" if ok else "FAIL", "running config: heartbeat receiver gone, 24h repeat")' 2>/dev/null \
      | sed "s/^/am-$i /" | tee /dev/stderr | grep -q '^am-[01] PASS' || fail=1
  done
  # LAN path: the one routed call works and finds Watchdog.
  body=$(curl -fsS -m 10 -G "$AM_URL/api/v2/alerts" --data-urlencode 'filter=alertname="Watchdog"' 2>/dev/null)
  printf '%s' "$body" | grep -q '"alertname":"Watchdog"' && ok "LAN GET /api/v2/alerts finds Watchdog" \
    || bad "LAN GET /api/v2/alerts did not return Watchdog"
  # Nothing else is routed.
  c=$(code -X POST -H 'Content-Type: application/json' -d '{}' "$AM_URL/api/v2/silences"); [ "$c" = 404 ] && ok "POST silences -> 404" || bad "POST silences -> $c"
  c=$(code "$AM_URL/api/v2/silences"); [ "$c" = 404 ] && ok "GET silences -> 404" || bad "GET silences -> $c"
  c=$(code "$AM_URL/"); [ "$c" = 404 ] && ok "GET / -> 404" || bad "GET / -> $c"
  c=$(code -X POST -H 'Content-Type: application/json' -d '[]' "$AM_URL/api/v2/alerts"); [ "$c" = 404 ] && ok "POST alerts -> 404" || bad "POST alerts -> $c"
  # Rules loaded and healthy.
  rules=$(kubectl -n $NS exec prometheus-kube-prometheus-stack-0 -c prometheus -- \
          wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' 2>/dev/null)
  out=$(printf '%s' "$rules" | python3 -c '
import json, sys
rs = {r["name"]: r for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"]}
for n in ("MacNodeDown", "MacAgentStale"):
    r = rs.get(n)
    print(("PASS" if r and r.get("health") == "ok" else "FAIL"), "rule", n, "health", r and r.get("health"))
print(("FAIL" if "MacHostDown" in rs else "PASS"), "old MacHostDown gone")' 2>&1)
  echo "$out"; echo "$out" | grep -q '^FAIL' && fail=1
}

for attempt in $(seq 1 20); do
  echo "--- attempt $attempt $(date -u +%FT%TZ)"
  run_checks
  [ "$fail" = 0 ] && break
  [ "$attempt" -lt 20 ] && sleep 30
done
if [ "$fail" = 0 ]; then echo "POSTCHECK PASS"; exit 0; fi

echo "POSTCHECK FAIL -> rolling back $SHA"
wt="$(mktemp -d "${TMPDIR:-/tmp}/lan-hb-rollback.XXXXXX")"
git fetch -q origin main && git worktree add -q --detach "$wt" origin/main \
  && git -C "$wt" revert --no-edit "$SHA" \
  && git -C "$wt" push origin HEAD:main \
  && flux -n flux-system reconcile source git flux-system \
  && flux -n flux-system reconcile kustomization kube-prometheus-stack \
  && flux -n flux-system reconcile kustomization aiops
echo "ROLLBACK issued (exit $?)"
exit 1
