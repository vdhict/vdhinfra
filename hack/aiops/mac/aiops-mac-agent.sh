#!/bin/bash
# aiops-mac-agent (chg-2026-10-12-009, LAN heartbeat since 2026-10-13).
# Runs every 5 min from launchd (com.vdhict.aiops-mac-agent) on vdhmini01 and
# vdhllmsrv01.
#
#  1. Cluster check, over the LAN only (no ntfy.sh traffic): GET the
#     Alertmanager alerts API through envoy-internal and look for the active
#     Watchdog alert. Watchdog always fires in Prometheus and is re-sent to
#     Alertmanager every minute; Alertmanager drops it ~4 min after the last
#     re-send. So "Watchdog active" proves Prometheus evaluates rules AND
#     Alertmanager receives them. Watchdog's own route is "null" (no ntfy).
#  2. Only a REAL loss goes to ntfy: the cluster has been down for
#     AIOPS_WINDOW_S (default 900 s = 3 consecutive runs) -> ONE "LOST"
#     message; when it comes back -> ONE "BACK" message. No re-sends.
#     07:00-23:00 local: priority 4. 23:00-07:00: priority 1 with a
#     "[night] " title (no sound, no vibration); the 07:00 morning summary in
#     the cluster lists it.
#     The Macs themselves are watched by the cluster (rule MacNodeDown on
#     up{job="mac-node"}), not by each other.
#  3. Writes node_exporter textfile metrics: macOS diagnostic reports
#     (crash / jetsam / panic / resource) in the last 24 h + newest timestamp,
#     and the cluster state seen from here.
#
# Config: ~/.config/aiops/ntfy.env (mode 600, never in Git):
#   NTFY_SERVER, NTFY_ALERT_TOPIC   where LOST/BACK go
#   AIOPS_AM_URL                    https://<alertmanager LAN host>
# NTFY_HB_TOPIC is no longer used. Nothing here prints a topic.
# AIOPS_DRY_NOTIFY=1 logs instead of publishing (tests; costs no quota).
set -u
export TZ=Europe/Amsterdam

ENV_FILE="${AIOPS_ENV:-$HOME/.config/aiops/ntfy.env}"
STATE_DIR="${AIOPS_STATE_DIR:-$HOME/.local/state/aiops}"
TEXTFILE_DIR="${AIOPS_TEXTFILE_DIR:-$HOME/.local/share/aiops/textfile}"
WINDOW_S="${AIOPS_WINDOW_S:-900}"
SELF="$(/bin/hostname -s)"
CURL=(/usr/bin/curl -fsS --max-time 15)

mkdir -p "$STATE_DIR" "$TEXTFILE_DIR"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# shellcheck disable=SC1090
. "$ENV_FILE" || { log "cannot read $ENV_FILE"; exit 2; }
: "${NTFY_SERVER:?}" "${NTFY_ALERT_TOPIC:?}" "${AIOPS_AM_URL:?}"

now=$(date +%s)
hour=$((10#$(date +%H)))
night=0; { [ "$hour" -ge 23 ] || [ "$hour" -lt 7 ]; } && night=1

notify() { # $1 day-priority  $2 title  $3 body
  local prio="$1" title="$2"
  if [ "$night" = 1 ]; then prio=1; title="[night] $title"; fi
  if [ "${AIOPS_DRY_NOTIFY:-0}" = 1 ]; then log "DRY notify p$prio: $title | $3"; return 0; fi
  "${CURL[@]}" -H "Title: $title" -H "Priority: $prio" -H "Tags: heartbeat" \
    --data-binary "$3" "$NTFY_SERVER/$NTFY_ALERT_TOPIC" >/dev/null \
    && log "notified: $title" || { log "notify failed: $title"; return 1; }
}

# 1. cluster check over the LAN
if body=$("${CURL[@]}" -G "$AIOPS_AM_URL/api/v2/alerts" \
            --data-urlencode 'filter=alertname="Watchdog"' \
            --data-urlencode 'active=true' --data-urlencode 'silenced=true' \
            --data-urlencode 'inhibited=true' 2>/dev/null) \
   && printf '%s' "$body" | grep -q '"alertname":"Watchdog"'; then
  st=up; v=1
else
  st=down; v=0
fi
log "cluster $st"

# 2. state machine. State file: "<up|down> <since-epoch> <notified 0|1>"
sf="$STATE_DIR/lan-cluster"
if [ ! -f "$sf" ]; then
  printf '%s %s 0\n' "$st" "$now" > "$sf"     # first observation: never alert
else
  read -r prev since notified < "$sf"
  notified="${notified:-0}"
  if [ "$st" = down ]; then
    [ "$prev" = up ] && { since=$now; notified=0; }
    if [ "$notified" = 0 ] && [ $((now - since)) -ge "$WINDOW_S" ]; then
      notify 4 "heartbeat lost: cluster" \
        "LOST cluster seen-by $SELF: no active Watchdog in Alertmanager over the LAN for $(( (now - since) / 60 )) min" \
        && notified=1
    fi
    printf 'down %s %s\n' "$since" "$notified" > "$sf"
  else
    if [ "$prev" = down ] && [ "$notified" = 1 ]; then
      notify 3 "heartbeat back: cluster" "BACK cluster seen-by $SELF" || { printf 'down %s 1\n' "$since" > "$sf"; st=retry; }
    fi
    [ "$st" = up ] && { [ "$prev" = up ] || printf 'up %s 0\n' "$now" > "$sf"; }
  fi
fi

# 3. textfile metrics (atomic: temp file without .prom, then mv)
tmp=$(mktemp "$TEXTFILE_DIR/.aiops.XXXXXX") || exit 0
{
  echo "# HELP mac_diagnostic_reports_24h macOS diagnostic reports written in the last 24 h, by kind."
  echo "# TYPE mac_diagnostic_reports_24h gauge"
  echo "# HELP mac_diagnostic_report_last_timestamp_seconds Newest macOS diagnostic report of this kind."
  echo "# TYPE mac_diagnostic_report_last_timestamp_seconds gauge"
  find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" -maxdepth 2 -type f \
       \( -name '*.ips' -o -name '*.crash' -o -name '*.panic' -o -name '*.diag' \) \
       -exec stat -f '%m %N' {} + 2>/dev/null |
    awk -v now="$now" '
      { f=$0; sub(/^[0-9]+ /,"",f); n=split(f,a,"/"); b=a[n]
        k="resource"
        if (b ~ /\.panic$/) k="panic"; else if (b ~ /^JetsamEvent/) k="jetsam"; else if (b ~ /\.(ips|crash)$/) k="crash"
        if ($1 > last[k]) last[k]=$1
        if (now - $1 < 86400) c[k]++ }
      END { split("crash jetsam panic resource",K," ")
            for (i=1;i<=4;i++) { k=K[i]
              printf "mac_diagnostic_reports_24h{kind=\"%s\"} %d\n", k, c[k]+0
              if (last[k]) printf "mac_diagnostic_report_last_timestamp_seconds{kind=\"%s\"} %d\n", k, last[k] } }'
  echo "# HELP mac_aiops_peer_heartbeat_up Cluster Watchdog seen in Alertmanager over the LAN (1) or not (0)."
  echo "# TYPE mac_aiops_peer_heartbeat_up gauge"
  echo "mac_aiops_peer_heartbeat_up{peer=\"cluster\"} $v"
  echo "# TYPE mac_aiops_agent_last_run_timestamp_seconds gauge"
  echo "mac_aiops_agent_last_run_timestamp_seconds $now"
} > "$tmp"
mv -f "$tmp" "$TEXTFILE_DIR/aiops.prom"
