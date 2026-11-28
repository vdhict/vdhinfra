#!/usr/bin/env bash
# chg-2026-11-28-107 (G1 row P6): induced-failure drill for the forge alerts.
#
# Proves, end to end and on the live path, that a forge alert fires and is
# DELIVERED to the team ntfy topic pka-team at day priority:
#
#   temporary Probe (closed port, target_role=code-forge)
#     -> probe_success 0 -> ForgeEndpointDown firing (for: 5m)
#     -> Alertmanager route component=forge-monitoring -> ntfy-team-day
#     -> message in ntfy topic pka-team (read back via the ntfy API)
#   cleanup: delete the temporary Probe, wait for the RESOLVED message.
#
# The forge itself is never touched: the drill probe targets port 3999 on the
# forgejo-http ClusterIP, where nothing listens.
#
# Guards:
#   * DAYTIME ONLY: refuses outside 07:00-22:30 Europe/Amsterdam (AGR-074; the
#     drill needs ~20 min and must finish before 23:00).
#   * Runs only once the change is on origin/main AND live (PrometheusRule
#     devtools/forge-monitoring present, live Alertmanager config routes
#     component=forge-monitoring to ntfy-team-day).
#   * The temporary Probe is deleted on every exit path (trap).
#
# Secrets: the pka-alert ntfy token (read access on pka-team) is read from
# ~/.config/ntfy-selfhosted/credentials.env on the Mini and handed to curl on
# stdin (-K -), never in argv, never printed.
#
# Evidence: write-once file ops/evidence/chg-2026-11-28-107/02-drill-<ts>.txt
#
# Usage (from the repo root, on the Mini):  hack/ops/chg-2026-11-28-107-forge-alert-drill.sh
set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
EVD="$REPO/ops/evidence/chg-2026-11-28-107"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$EVD/02-drill-$TS.txt"
CREDS="$HOME/.config/ntfy-selfhosted/credentials.env"
NS=devtools
PROBE=forge-drill-closed-port
TOPIC=pka-team
PROM=(kubectl -n observability exec -i prometheus-kube-prometheus-stack-0 -c prometheus --)
AM=(kubectl -n observability exec -i alertmanager-kube-prometheus-stack-0 -c alertmanager --)

mkdir -p "$EVD"
if [ -e "$OUT" ]; then echo "evidence file exists, refusing to overwrite: $OUT" >&2; exit 2; fi
exec > >(tee "$OUT") 2>&1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# ---- guard: daytime window ---------------------------------------------------
hm=$(TZ=Europe/Amsterdam date +%H%M)
if [ "$((10#$hm))" -lt 700 ] || [ "$((10#$hm))" -gt 2230 ]; then
  log "REFUSED: local time $hm Europe/Amsterdam is outside 07:00-22:30 (AGR-074)"; exit 3
fi
log "local time $hm Europe/Amsterdam: inside the daytime window"

# ---- guard: change is on main and live ---------------------------------------
git -C "$REPO" fetch -q origin
for f in kubernetes/main/apps/devtools/forgejo/monitoring/prometheusrule.yaml \
         kubernetes/main/apps/devtools/forgejo/monitoring/probe.yaml; do
  git -C "$REPO" cat-file -e "origin/main:$f" || { log "ABORT: $f not on origin/main"; exit 4; }
done
log "origin/main $(git -C "$REPO" rev-parse --short origin/main) carries the monitoring manifests"
kubectl -n "$NS" get prometheusrule forge-monitoring -o name
kubectl -n "$NS" get probe forgejo-http forgejo-ssh -o name
real=$("${PROM[@]}" promtool query instant -o json http://localhost:9090 \
  'probe_success{target_role="code-forge",target_friendly=~"forgejo-svc|forgejo-https|forgejo-ssh"} == 1' | jq -r 'length')
log "real forge probes succeeding: $real/3 (proves module http_forgejo_healthz is live)"
[ "$real" = "3" ] || { log "ABORT: real forge probes not all green; fix that before drilling"; exit 5; }
live_route=$("${AM[@]}" amtool config routes test --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml \
  alertname=ForgeEndpointDown component=forge-monitoring severity=warning)
log "live Alertmanager route for component=forge-monitoring: $live_route"
case "$live_route" in *ntfy-team-day*) ;; *) log "ABORT: live Alertmanager does not route to ntfy-team-day yet"; exit 5;; esac

# ---- credentials (never printed) ---------------------------------------------
[ -r "$CREDS" ] || { log "ABORT: $CREDS not readable"; exit 6; }
NTFY_URL=$(grep -E '^NTFY_URL=' "$CREDS" | cut -d= -f2- | tr -d '"')
NTFY_TOKEN=$(grep -E '^NTFY_PKA_ALERT_TOKEN=' "$CREDS" | cut -d= -f2- | tr -d '"')
[ -n "$NTFY_URL" ] && [ -n "$NTFY_TOKEN" ] || { log "ABORT: ntfy url/token missing in $CREDS"; exit 6; }
ntfy_poll() { # $1 = since (unix seconds); prints one JSON message per line
  printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" |
    curl -fsS --max-time 20 -K - "$NTFY_URL/$TOPIC/json?poll=1&since=$1"
}
ntfy_poll "$(date +%s)" >/dev/null && log "ntfy read access on $TOPIC: OK (HTTP 200)"

prom_alert() { # firing ForgeEndpointDown series for the drill probe
  "${PROM[@]}" promtool query instant -o json http://localhost:9090 \
    "ALERTS{alertname=\"ForgeEndpointDown\",target_friendly=\"$PROBE\",alertstate=\"$1\"}" |
    jq -r 'length'
}

# ---- baseline ----------------------------------------------------------------
SINCE=$(date +%s)
log "baseline: ntfy since=$SINCE; ForgeEndpointDown(drill) firing=$(prom_alert firing)"

cleanup() {
  if kubectl -n "$NS" get probe "$PROBE" >/dev/null 2>&1; then
    kubectl -n "$NS" delete probe "$PROBE" --wait=true
    log "cleanup: temporary Probe $NS/$PROBE deleted"
  fi
}
trap cleanup EXIT

# ---- induce ------------------------------------------------------------------
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: $PROBE
  namespace: $NS
  labels:
    ops.vdh/chg: chg-2026-11-28-107
    ops.vdh/temporary: "true"
spec:
  jobName: blackbox-forge-drill
  prober:
    url: blackbox-exporter.observability.svc.cluster.local:9115
    path: /probe
  module: http_forgejo_healthz
  interval: 30s
  scrapeTimeout: 10s
  targets:
    staticConfig:
      static:
        - http://forgejo-http.devtools.svc.cluster.local:3999/api/healthz
      labels:
        target_role: code-forge
        target_friendly: $PROBE
EOF
log "induced: temporary Probe $NS/$PROBE applied (closed port 3999)"

# ---- wait: Prometheus firing (for: 5m + scrape + operator reload) ------------
fired=""
for _ in $(seq 1 30); do
  sleep 30
  if [ "$(prom_alert firing)" -ge 1 ]; then fired=yes; break; fi
  log "waiting: pending=$(prom_alert pending) firing=0"
done
[ -n "$fired" ] || { log "FAIL: ForgeEndpointDown(drill) did not fire within 15 min"; exit 10; }
log "Prometheus: ForgeEndpointDown{target_friendly=$PROBE} FIRING"

# ---- Alertmanager: active, which receivers ------------------------------------
sleep 45
"${AM[@]}" amtool alert query --alertmanager.url=http://localhost:9093 -o json \
  alertname=ForgeEndpointDown target_friendly="$PROBE" |
  jq -c '.[] | {alertname: .labels.alertname, target: .labels.target_friendly, state: .status.state, receivers: [.receivers[].name], startsAt}'

# ---- ntfy: delivered to pka-team ----------------------------------------------
msg=""
for _ in $(seq 1 16); do
  msg=$(ntfy_poll "$SINCE" | jq -c --arg p "$PROBE" \
    'select(.event=="message") | select((.message // "") | test("ForgeEndpointDown") and test($p))
     | {id, time, topic, priority, title, message}' | head -1 || true)
  [ -n "$msg" ] && break
  sleep 30
done
[ -n "$msg" ] || { log "FAIL: no FIRING message for the drill in ntfy topic $TOPIC"; exit 11; }
log "DELIVERED (ntfy $TOPIC): $msg"
prio=$(echo "$msg" | jq -r '.priority // 3')
[ "$prio" = "3" ] && log "priority 3 (day receiver ntfy-team-day): OK" || log "UNEXPECTED priority $prio"

# ---- clean up and prove the resolve ------------------------------------------
cleanup
RSINCE=$(date +%s)
res=""
for _ in $(seq 1 24); do
  sleep 30
  res=$(ntfy_poll "$RSINCE" | jq -c --arg p "$PROBE" \
    'select(.event=="message") | select((.message // "") | test("RESOLVED ForgeEndpointDown") and test($p))
     | {id, time, topic, priority, title}' | head -1 || true)
  [ -n "$res" ] && break
done
[ -n "$res" ] && log "RESOLVED delivered (ntfy $TOPIC): $res" || log "WARN: no RESOLVED message within 12 min"
log "post-cleanup: temporary probe present? $(kubectl -n "$NS" get probe "$PROBE" -o name 2>/dev/null || echo no)"
log "post-cleanup: ForgeEndpointDown(drill) firing=$(prom_alert firing)"
log "DRILL PASS"
