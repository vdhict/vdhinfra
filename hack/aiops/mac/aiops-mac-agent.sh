#!/bin/bash
# aiops-mac-agent (chg-2026-10-12-009). Runs every 5 min from launchd
# (com.vdhict.aiops-mac-agent) on vdhmini01 and vdhllmsrv01.
#
#  1. Publishes this Mac's heartbeat ("hb <host>") to the ntfy heartbeat topic.
#  2. Reads the heartbeat topic back and checks every peer (the cluster's
#     Alertmanager Watchdog posts "hb cluster", the other Mac posts its own).
#     A peer silent for AIOPS_WINDOW -> LOST notification on the infra alert
#     topic; when it comes back -> BACK. Re-sent every 6 h while lost.
#     07:00-23:00 local: priority 4 (cluster) / 3 (Mac). 23:00-07:00:
#     priority 1 with a "[night] " title, which means no sound and no
#     vibration; the 07:00 morning summary in the cluster lists them.
#     If ntfy itself cannot be reached, nothing is concluded and nothing sent.
#  3. Writes node_exporter textfile metrics: macOS diagnostic reports
#     (crash / jetsam / panic / resource) in the last 24 h + newest timestamp,
#     and the peer heartbeat state seen from here.
#
# Config: ~/.config/aiops/ntfy.env (mode 600, never in Git):
#   NTFY_SERVER, NTFY_ALERT_TOPIC, NTFY_HB_TOPIC
# Nothing here prints a topic.
set -u
export TZ=Europe/Amsterdam

ENV_FILE="${AIOPS_ENV:-$HOME/.config/aiops/ntfy.env}"
STATE_DIR="$HOME/.local/state/aiops"
TEXTFILE_DIR="$HOME/.local/share/aiops/textfile"
PEERS="${AIOPS_PEERS:-cluster vdhmini01 vdhllmsrv01}"
WINDOW="${AIOPS_WINDOW:-15m}"
REALERT_S=21600
SELF="$(/bin/hostname -s)"
CURL=(/usr/bin/curl -fsS --max-time 15)

mkdir -p "$STATE_DIR" "$TEXTFILE_DIR"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# shellcheck disable=SC1090
. "$ENV_FILE" || { log "cannot read $ENV_FILE"; exit 2; }
: "${NTFY_SERVER:?}" "${NTFY_ALERT_TOPIC:?}" "${NTFY_HB_TOPIC:?}"

now=$(date +%s)
hour=$((10#$(date +%H)))
night=0; { [ "$hour" -ge 23 ] || [ "$hour" -lt 7 ]; } && night=1

notify() { # $1 day-priority  $2 title  $3 body
  local prio="$1" title="$2"
  if [ "$night" = 1 ]; then prio=1; title="[night] $title"; fi
  "${CURL[@]}" -H "Title: $title" -H "Priority: $prio" -H "Tags: heartbeat" \
    --data-binary "$3" "$NTFY_SERVER/$NTFY_ALERT_TOPIC" >/dev/null \
    && log "notified: $title" || log "notify failed: $title"
}

# 1. own heartbeat
"${CURL[@]}" -H "Title: hb $SELF" -H "Priority: 1" --data-binary "hb $SELF" \
  "$NTFY_SERVER/$NTFY_HB_TOPIC" >/dev/null || log "heartbeat publish failed"

# 2. peers
peer_metrics=""
if body=$("${CURL[@]}" "$NTFY_SERVER/$NTFY_HB_TOPIC/json?poll=1&since=$WINDOW"); then
  for p in $PEERS; do
    [ "$p" = "$SELF" ] && continue
    if printf '%s' "$body" | grep -q "\"message\":\"hb $p\""; then st=up; v=1; else st=down; v=0; fi
    peer_metrics+="mac_aiops_peer_heartbeat_up{peer=\"$p\"} $v"$'\n'
    sf="$STATE_DIR/peer-$p"
    # state file: "<up|down> <epoch> <notified 0|1> <seen_up 0|1>"
    # A peer never seen up gets a 30 min install grace before LOST.
    if [ ! -f "$sf" ]; then            # first observation: record, never alert
      printf '%s %s 0 %s\n' "$st" "$now" "$v" > "$sf"; continue
    fi
    read -r prev last notified seen_up < "$sf"
    notified="${notified:-0}"; seen_up="${seen_up:-1}"
    prio=3; [ "$p" = cluster ] && prio=4
    if [ "$st" = down ]; then
      if [ "$notified" = 0 ] && [ "$seen_up" = 0 ] && [ $((now - last)) -lt 1800 ]; then
        :                                # install grace
      elif [ "$notified" = 0 ]; then
        notify "$prio" "heartbeat lost: $p" "LOST heartbeat-$p seen-by $SELF: no heartbeat for $WINDOW"
        printf 'down %s 1 %s\n' "$now" "$seen_up" > "$sf"
      elif [ $((now - last)) -ge $REALERT_S ]; then
        notify "$prio" "heartbeat still lost: $p" "LOST heartbeat-$p seen-by $SELF: still no heartbeat"
        printf 'down %s 1 %s\n' "$now" "$seen_up" > "$sf"
      fi
    else
      if [ "$notified" = 1 ]; then
        notify 3 "heartbeat back: $p" "BACK heartbeat-$p seen-by $SELF"
      fi
      [ "$prev" = up ] && [ "$notified" = 0 ] || printf 'up %s 0 1\n' "$now" > "$sf"
    fi
  done
else
  log "heartbeat poll failed: peer state unknown, nothing sent"
  for p in $PEERS; do [ "$p" = "$SELF" ] || peer_metrics+="mac_aiops_peer_heartbeat_up{peer=\"$p\"} -1"$'\n'; done
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
  echo "# HELP mac_aiops_peer_heartbeat_up Peer heartbeat seen on ntfy in the window (1), missing (0), unknown (-1)."
  echo "# TYPE mac_aiops_peer_heartbeat_up gauge"
  printf '%s' "$peer_metrics"
  echo "# TYPE mac_aiops_agent_last_run_timestamp_seconds gauge"
  echo "mac_aiops_agent_last_run_timestamp_seconds $now"
} > "$tmp"
mv -f "$tmp" "$TEXTFILE_DIR/aiops.prom"
