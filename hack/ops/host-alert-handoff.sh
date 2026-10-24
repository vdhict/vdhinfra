#!/usr/bin/env bash
# chg-2026-10-24-003 host-alert handoff (Larry 24-10, inc-2026-10-23-002 option c).
# Runs from launchd on the Mini (net.vdhict.host-alert-handoff, every 5 min).
#
# For every FIRING severity=critical alert about one of the two always-on Macs
# (label host, or target_friendly for the blackbox probes, in HOSTS below) it
# appends ONE line per alertname+host+day to
#   ~/mypka-handoff/<date>/<date>-atlas-to-larry-host-alert-<host>.md
# (file created with a heading if absent). Silenced or inhibited alerts are
# skipped: someone already owns them. Nothing is ever deleted; the script
# only appends. Silent by design (AGR-074): no push, no sound.
#
# Source: Alertmanager GET /api/v2/alerts over the LAN (AIOPS_AM_URL from
# ~/.config/aiops/ntfy.env, the read-only HTTPRoute alertmanager-heartbeat the
# aiops-mac-agent already uses). Fallback when the LAN read fails: Prometheus
# ALERTS{alertstate="firing",severity="critical"} via kubectl exec.
#
#   host-alert-handoff.sh [--dry-run] [--input FILE]
#     --dry-run     print the lines it would write, write nothing
#     --input FILE  read alerts from FILE (Alertmanager /api/v2/alerts JSON)
#                   instead of the cluster; for synthetic tests
#   HANDOFF_DIR overrides ~/mypka-handoff (tests).
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
HOSTS='^(vdhmini01|vdhllmsrv01)$'
ENV_FILE="${AIOPS_ENV:-$HOME/.config/aiops/ntfy.env}"
OUT="${HANDOFF_DIR:-$HOME/mypka-handoff}"
DRY=0; INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --input) INPUT="${2:?--input needs a file}"; shift ;;
    *) echo "usage: $0 [--dry-run] [--input FILE]" >&2; exit 2 ;;
  esac
  shift
done
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Normalised alert list on stdout: one TSV line per alert: alertname host startsAt summary
from_am() { # Alertmanager v2 JSON on stdin
  /usr/bin/jq -r --arg re "$HOSTS" '
    .[] | select(.labels.severity == "critical")
        | select((.status.state // "active") == "active")
        | (.labels.host // .labels.target_friendly // "") as $h
        | select($h | test($re))
        | [.labels.alertname, $h, (.startsAt // ""),
           ((.annotations.summary // .annotations.description // "(no summary)") | gsub("[\t\n]"; " "))]
        | @tsv'
}
from_prom() { # Prometheus /api/v1/query JSON on stdin (ALERTS has no annotations)
  /usr/bin/jq -r --arg re "$HOSTS" '
    .data.result[] | .metric
        | (.host // .target_friendly // "") as $h
        | select($h | test($re))
        | [.alertname, $h, "", "(from Prometheus ALERTS; see Alertmanager for the summary)"]
        | @tsv'
}

if [ -n "$INPUT" ]; then
  alerts=$(from_am < "$INPUT") || { log "cannot parse $INPUT"; exit 2; }
  src="input:$INPUT"
else
  AIOPS_AM_URL=$(sed -n 's/^AIOPS_AM_URL=//p' "$ENV_FILE" 2>/dev/null | tr -d '"' | tail -1)
  if [ -n "$AIOPS_AM_URL" ] && body=$(/usr/bin/curl -fsS --max-time 15 -G "$AIOPS_AM_URL/api/v2/alerts" \
        --data-urlencode 'filter=severity="critical"' --data-urlencode active=true \
        --data-urlencode silenced=false --data-urlencode inhibited=false 2>/dev/null) \
     && alerts=$(printf '%s' "$body" | from_am); then
    src=alertmanager-lan
  else
    log "alertmanager LAN read failed; falling back to Prometheus via kubectl"
    KUBECTL=$(command -v kubectl || ls "$HOME"/.local/share/mise/installs/*kubectl*/*/kubectl 2>/dev/null | head -1)
    q='ALERTS%7Balertstate%3D%22firing%22%2Cseverity%3D%22critical%22%7D'
    if [ -n "$KUBECTL" ] && body=$("$KUBECTL" -n observability exec prometheus-kube-prometheus-stack-0 -c prometheus -- \
          wget -qO- "http://localhost:9090/api/v1/query?query=$q" 2>/dev/null) \
       && alerts=$(printf '%s' "$body" | from_prom); then
      src=prometheus-kubectl
    else
      log "no source reachable (Alertmanager LAN and Prometheus via kubectl both failed)"; exit 1
    fi
  fi
fi

n_new=0; n_seen=0
d=$(date +%F); t=$(date +%H:%M)
while IFS=$'\t' read -r name host since summary; do
  [ -n "$name" ] || continue
  f="$OUT/$d/$d-atlas-to-larry-host-alert-$host.md"
  key="[$name@$host]"
  if [ -e "$f" ] && grep -qF -- "$key" "$f"; then n_seen=$((n_seen+1)); continue; fi
  since=${since%%.*}; since=${since%Z}   # 2026-10-24T05:12:30.123Z -> 2026-10-24T05:12:30
  line="- $t $key critical alert firing${since:+ since ${since}Z}: $summary. Needs a person on $host; Prometheus/ntfy pka-team carry the detail. (chg-2026-10-24-003) — Atlas"
  if [ "$DRY" = 1 ]; then echo "DRY would append to $f: $line"; n_new=$((n_new+1)); continue; fi
  mkdir -p "$OUT/$d" || { log "cannot create $OUT/$d"; exit 1; }
  [ -e "$f" ] || printf '# Atlas -> Larry: critical host alerts on %s, %s\n\n' "$host" "$d" > "$f"
  printf '%s\n' "$line" >> "$f" && n_new=$((n_new+1))
done <<< "$alerts"
log "source=$src new=$n_new already-told=$n_seen dry=$DRY"
