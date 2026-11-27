#!/usr/bin/env bash
# owner-alert-relay (wq-161, tsk-2026-11-26-907; Larry 080145 option a; decision of 27-10, chg-2026-10-27-005).
# Runs from launchd on the Mini (net.vdhict.owner-alert-relay, every 5 min).
#
# Story: a money or act-on alert for the owner must reach the ntfy.sh topic his phone actually holds. Alertmanager
# today posts critical alerts only to the self-hosted topic "alerts" (0 subscribers since 23-10), and the HA leg is
# off and stays off. This relay closes the gap without a new credential, a new port or an Alertmanager change:
#
#   Alertmanager GET /api/v2/alerts (read-only HTTPRoute alertmanager-heartbeat, envoy-internal, LAN only; the same
#   source host-alert-handoff.sh and the aiops-mac-agent already read, URL in ~/.config/aiops/ntfy.env)
#     -> only alertnames in the TEMPLATE table below (fail closed: no template, no message)
#     -> only active, not silenced, not inhibited
#     -> day only, 07:00-23:00 Europe/Amsterdam (AGR-074). At night it HOLDS: nothing is sent and nothing is recorded,
#        so a still-firing alert goes out on the first run after 07:00. pka-alert's own quiet-hours clamp (priority 2,
#        no sound) stays as the backstop behind this hold.
#     -> pka-alert --for-sander "<title>" "<body>" (the ONLY reviewed way to the owner's phone; its language guard,
#        phone-topic guard and per-title 6 h throttle all apply). The topic lives in ~/.config/pka-alert/alert.env;
#        this script never reads or prints it.
#     -> an episode (alertname|fingerprint|startsAt) is recorded ONLY on a terminal outcome (Argus C1, wq-161):
#          SENT     this call wrote a NEW ledger line whose wire = sander-md5(title) (pka-alert's own throttle key)
#                   -> sent.tsv
#          REFUSED  pka-alert's language guard refused this title ("for-sander REFUSED reason=guard(...): <title>")
#                   -> refused.tsv, never retried: the refusal raises a FORCED team alert, so a retry every 5 min
#                   would spam the team for the alert's whole life
#          PENDING  anything else (throttled, delivery failed, binary missing, no Sander topic): nothing recorded,
#                   retried on the next run. cloud_alert.py keeps its alerts active 11 h, longer than the 6 h throttle.
#        So a repeat is never sent twice, a NEW episode (new startsAt) is, and no episode is lost to a quiet failure.
#   TestOwnerAlertRoute is only relayed with OWNER_RELAY_TEST=1 in the environment (Argus C3). The plist does NOT
#   set it; the live test runs the relay once by hand with the flag. Removing the test route later needs no code.
#
# Texts are fixed Dutch templates per alertname, never the alert's own summary: summaries carry team vocabulary
# that pka-alert's guard refuses (README "Three gates"). A new owner alert = one new line in TEMPLATE, checked with
# `pka-alert --guard-check "<title> <body>"` before it is committed.
#
#   owner-alert-relay.sh [--dry-run] [--input FILE] [--now EPOCH] | --templates
#     --dry-run     print what it would hand to pka-alert; write no state, send nothing
#     --input FILE  read alerts from FILE (Alertmanager /api/v2/alerts JSON) instead of the cluster (tests)
#     --now EPOCH   evaluate day/night at this instant instead of the clock (tests)
#     --templates   print every owner text (for `pka-alert --guard-check` in the test) and exit
#   Env (tests): RELAY_STATE_DIR, PKA_ALERT (path of the pka-alert binary or a stub), PKA_ALERT_LEDGER,
#   PKA_ALERT_LOG (pka-alert's own names), RELAY_ZONEINFO, AIOPS_ENV. OWNER_RELAY_TEST=1 enables the test route.
#   Installed by owner-alert-relay-install.sh as a copy of origin/main in ~/.local/libexec (Argus C2).
#
# Receipt: after a send the log line carries the ntfy message id from pka-alert's own ledger (published.jsonl,
# field id; no topic in that file's fields read here). A successful Alertmanager read touches $STATE/last-ok, the
# stamp a heartbeat watches (follow-up: wires.conf mtime line in pka-wires/alert).
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

ENV_FILE="${AIOPS_ENV:-$HOME/.config/aiops/ntfy.env}"
STATE="${RELAY_STATE_DIR:-$HOME/.local/state/owner-alert-relay}"
PKA_ALERT="${PKA_ALERT:-$HOME/pka-alert/bin/pka-alert}"
LEDGER="${PKA_ALERT_LEDGER:-$HOME/.local/state/pka-alert/published.jsonl}"
PLOG="${PKA_ALERT_LOG:-$HOME/Library/Logs/pka-alert.log}"
ZONEINFO="${RELAY_ZONEINFO:-/usr/share/zoneinfo/Europe/Amsterdam}"
DRY=0; INPUT=""; NOW=""; TEMPLATES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --input) INPUT="${2:?--input needs a file}"; shift ;;
    --now) NOW="${2:?--now needs an epoch}"; shift ;;
    --templates) TEMPLATES=1 ;;
    *) echo "usage: $0 [--dry-run] [--input FILE] [--now EPOCH]" >&2; exit 2 ;;
  esac
  shift
done
NOW="${NOW:-$(date +%s)}"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# alertname -> owner text. Plain Dutch, an action, no team vocabulary (each line passed `pka-alert --guard-check`).
# FamilyCloudMoneyCandidate is deliberately NOT here: it is the team's check-first item, emitted only while
# MONEY_TO_OWNER=false (chg-2026-11-26-006 set it true), and stays a card.
template() {
  case "$1" in
    FamilyCloudMoneyReopen)
      T="Geld: er is weer betaald voor de AI-dienst"
      B="Er is deze maand toch weer betaald voor de betaalde AI-dienst (met de kaart, gekocht tegoed of automatisch opwaarderen), terwijl die vanwege de rekening was stopgezet. De dienst blijft uit. Wat je kunt doen: kijk bij de aanbieder of deze betaling klopt; klopt hij niet, blokkeer dan de kaart of het opwaarderen daar." ;;
    TestOwnerAlertRoute)
      T="Test: meldingen over geld komen hier binnen"
      B="Dit is een eenmalige test. Voortaan krijg je hier een bericht als er iets met geld is waar jij naar moet kijken. Wat je kunt doen: niets." ;;
    *) return 1 ;;
  esac
}
ALLOW='^(FamilyCloudMoneyReopen|TestOwnerAlertRoute)$'
if [ "$TEMPLATES" = 1 ]; then   # for the test's guard check: one "name<TAB>title body" line per template, sends nothing
  for n in FamilyCloudMoneyReopen TestOwnerAlertRoute; do template "$n" && printf '%s\t%s %s\n' "$n" "$T" "$B"; done
  exit 0
fi

# Day = 07:00 <= local < 23:00 Europe/Amsterdam (start inclusive, end exclusive, as pka-alert). Without the compiled
# zone file there is no trustworthy local time: hold (fail closed), never guess an offset.
is_day() {
  [ -r "$ZONEINFO" ] || { log "zoneinfo $ZONEINFO unreadable: holding everything"; return 1; }
  local hm
  hm=$(TZ=":$ZONEINFO" date -r "$NOW" +%H%M 2>/dev/null || TZ=":$ZONEINFO" date -d "@$NOW" +%H%M 2>/dev/null) || return 1
  [ -n "$hm" ] || return 1
  hm=$((10#$hm))
  [ "$hm" -ge 700 ] && [ "$hm" -lt 2300 ]
}

# One TSV line per relevant alert: alertname fingerprint startsAt
select_alerts() {
  /usr/bin/jq -r --arg re "$ALLOW" '
    .[] | select(.labels.alertname | test($re))
        | select((.status.state // "active") == "active")
        | [.labels.alertname, (.fingerprint // "nofp"), (.startsAt // "")] | @tsv'
}

if [ -n "$INPUT" ]; then
  alerts=$(select_alerts < "$INPUT") || { log "cannot parse $INPUT"; exit 2; }
  src="input"
else
  AIOPS_AM_URL=$(sed -n 's/^AIOPS_AM_URL=//p' "$ENV_FILE" 2>/dev/null | tr -d '"' | tail -1)
  [ -n "$AIOPS_AM_URL" ] || { log "no AIOPS_AM_URL in $ENV_FILE"; exit 1; }
  body=$(/usr/bin/curl -fsS --max-time 15 -G "$AIOPS_AM_URL/api/v2/alerts" \
           --data-urlencode active=true --data-urlencode silenced=false --data-urlencode inhibited=false 2>/dev/null) \
    || { log "alertmanager read failed (nothing sent, nothing recorded; retried next run)"; exit 1; }
  alerts=$(printf '%s' "$body" | select_alerts) || { log "alertmanager answer unparseable"; exit 1; }
  src=alertmanager-lan
fi

[ "$DRY" = 1 ] || mkdir -p "$STATE" || { log "cannot create $STATE"; exit 1; }
[ "$DRY" = 1 ] || [ -n "$INPUT" ] || touch "$STATE/last-ok"
SENT="$STATE/sent.tsv"; REFUSED="$STATE/refused.tsv"

# pka-alert's throttle key for --for-sander, which is also the ledger "wire" of what it published.
wire_of() { printf 'sander-%s' "$(printf '%s' "$1" | md5 -q 2>/dev/null || printf '%s' "$1" | md5sum | cut -d' ' -f1)"; }
recorded() { { [ -e "$SENT" ] && grep -qxF -- "$1" "$SENT"; } || { [ -e "$REFUSED" ] && grep -qxF -- "$1" "$REFUSED"; }; }
lines_of() { local c; c=$(wc -l < "$1" 2>/dev/null) || c=0; echo $((c+0)); }

day=0; is_day && day=1
n_sent=0; n_held=0; n_seen=0; n_pend=0; n_ref=0
while IFS=$'\t' read -r name fp since; do
  [ -n "$name" ] || continue
  key="$name|$fp|$since"
  if recorded "$key"; then n_seen=$((n_seen+1)); continue; fi
  if [ "$name" = TestOwnerAlertRoute ] && [ "${OWNER_RELAY_TEST:-0}" != 1 ]; then
    log "SKIP $name: test route disabled (OWNER_RELAY_TEST not 1)"; continue
  fi
  if [ "$day" = 0 ]; then n_held=$((n_held+1)); log "HELD (night) $name fp=$fp since=$since"; continue; fi
  template "$name" || { log "no template for $name (not sent)"; continue; }
  if [ "$DRY" = 1 ]; then echo "DRY would send $name: $T"; n_sent=$((n_sent+1)); continue; fi
  if [ ! -x "$PKA_ALERT" ]; then
    n_pend=$((n_pend+1)); log "PENDING $name fp=$fp since=$since reason=pka-alert-missing (retry next run)"; continue
  fi
  w=$(wire_of "$T")
  l0=$(lines_of "$LEDGER"); g0=$(lines_of "$PLOG")
  "$PKA_ALERT" --for-sander "$T" "$B" || true      # pka-alert always exits 0; the ledger and its log are the verdict
  # Only lines written during THIS call count, so an older id for the same title is never borrowed.
  id=$(tail -n +"$((l0+1))" "$LEDGER" 2>/dev/null | /usr/bin/jq -r --arg w "$w" 'select(.wire == $w) | .id // empty' 2>/dev/null | tail -1)
  if [ -n "$id" ]; then
    printf '%s\n' "$key" >> "$SENT"; n_sent=$((n_sent+1))
    log "SENT $name fp=$fp since=$since wire=$w pka_alert_ledger_id=$id"
  elif tail -n +"$((g0+1))" "$PLOG" 2>/dev/null | grep -F "for-sander REFUSED reason=guard" | grep -qF -- ": $T"; then
    printf '%s\n' "$key" >> "$REFUSED"; n_ref=$((n_ref+1))
    log "REFUSED $name fp=$fp since=$since wire=$w: language guard refused the text (final, not retried; fix the template)"
  else
    n_pend=$((n_pend+1))
    log "PENDING $name fp=$fp since=$since wire=$w: no new ledger id (throttled or not delivered; see pka-alert.log), retry next run"
  fi
done <<< "$alerts"
log "source=$src day=$day sent=$n_sent pending=$n_pend refused=$n_ref held=$n_held already-recorded=$n_seen dry=$DRY"
