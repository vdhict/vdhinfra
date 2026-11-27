#!/usr/bin/env bash
# Tests for hack/ops/owner-alert-relay.sh (wq-161). Synthetic Alertmanager JSON, a STUB pka-alert, temp state:
# nothing reaches ntfy, the real pka-alert is only asked --guard-check (publishes nothing, by its own contract).
# Nothing is deleted; the temp dir stays under $TMPDIR (AGR-121).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HERE/../owner-alert-relay.sh"
FX="$HERE/owner-alert-relay"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/owner-alert-relay-test.XXXXXX")
fail=0; n=0
ok()   { n=$((n+1)); echo "ok $n - $1"; }
bad()  { n=$((n+1)); fail=$((fail+1)); echo "not ok $n - $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Stub: records the call, writes a ledger line like pka-alert does (title gets a marker prefix).
cat > "$TMP/pka-alert-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
printf '{"ts":"x","wire":"sander-x","host":"test","title":"\xe2\x9a\xa0\xef\xb8\x8f %s","priority":4,"quiet":"loud","id":"stubid%s"}\n' "$2" "$RANDOM" >> "$PKA_ALERT_LEDGER"
exit 0
EOF
chmod +x "$TMP/pka-alert-stub"

run() { # run <case> <epoch> <fixture> [extra args]
  local c="$1" e="$2" f="$3"; shift 3
  STUB_CALLS="$TMP/$c.calls" PKA_ALERT_LEDGER="$TMP/$c.ledger" RELAY_STATE_DIR="$TMP/$c.state" \
    PKA_ALERT="$TMP/pka-alert-stub" AIOPS_ENV=/nonexistent \
    bash "$RELAY" --input "$f" --now "$e" "$@" > "$TMP/$c.out" 2>&1
}
calls() { [ -e "$TMP/$1.calls" ] && grep -c . "$TMP/$1.calls" || echo 0; }

# Epochs (Europe/Amsterdam local time in brackets)
DAY=1795773600        # 2026-11-27 11:00 CET
CET_2259=1795816740   CET_2300=1795816800   CET_0659=1795759140   CET_0700=1795759200
CEST_2259=1784149140  CEST_2300=1784149200  CEST_0659=1784091540  CEST_0700=1784091600

# 1 day: exactly one send, only the allowlisted active alert, owner text not the alert summary
run day "$DAY" "$FX/alerts.json"
check "day: one hand-off" '[ "$(calls day)" = 1 ]'
check "day: --for-sander with the Dutch money title" 'grep -q "^--for-sander Geld: er is weer betaald voor de AI-dienst" "$TMP/day.calls"'
check "day: alert summary never forwarded" '! grep -q "family-cloud\|SAME month" "$TMP/day.calls"'
check "day: Candidate (warning, team item) not sent" '! grep -q Candidate "$TMP/day.calls"'
check "day: non-owner critical not sent" '! grep -q KubePod "$TMP/day.calls"'
check "day: suppressed copy not sent" '[ "$(grep -c aaaa000000000004 "$TMP/day.state/sent.tsv")" = 0 ]'
check "day: ledger id in the log" 'grep -q "SENT FamilyCloudMoneyReopen .*pka_alert_ledger_id=stubid" "$TMP/day.out"'
# 2 repeat: same identity is never sent twice
run day "$DAY" "$FX/alerts.json"
check "repeat: still one hand-off" '[ "$(calls day)" = 1 ]'
check "repeat: counted as already-sent" 'grep -q "already-sent=1" "$TMP/day.out"'
# 3 new episode (same fingerprint, new startsAt) is sent
run day "$DAY" "$FX/alerts-new-episode.json"
check "new episode: second hand-off" '[ "$(calls day)" = 2 ]'

# 4 night hold at both edges, CET and CEST; held = nothing sent AND nothing recorded
for c in CET_2300 CET_0659 CEST_2300 CEST_0659; do
  run "n_$c" "${!c}" "$FX/alerts.json"
  check "night $c: nothing sent" '[ "$(calls n_$c)" = 0 ]'
  check "night $c: not recorded (so it goes out after 07:00)" '[ ! -s "$TMP/n_$c.state/sent.tsv" ]'
  check "night $c: logged HELD" 'grep -q "HELD (night) FamilyCloudMoneyReopen" "$TMP/n_$c.out"'
done
# 5 day edges send
for c in CET_2259 CET_0700 CEST_2259 CEST_0700; do
  run "d_$c" "${!c}" "$FX/alerts.json"
  check "day edge $c: sent" '[ "$(calls d_$c)" = 1 ]'
done
# 6 held at 23:00, then the first run after 07:00 sends it (same state dir)
run hold "$CET_2300" "$FX/alerts.json"
check "hold->morning: held at 23:00" '[ "$(calls hold)" = 0 ]'
run hold "$CET_0700" "$FX/alerts.json"
check "hold->morning: sent at 07:00" '[ "$(calls hold)" = 1 ]'
# 7 no zoneinfo: fail closed (hold) even by day
STUB_CALLS="$TMP/nz.calls" PKA_ALERT_LEDGER="$TMP/nz.ledger" RELAY_STATE_DIR="$TMP/nz.state" PKA_ALERT="$TMP/pka-alert-stub" \
  RELAY_ZONEINFO=/nonexistent/zone bash "$RELAY" --input "$FX/alerts.json" --now "$DAY" > "$TMP/nz.out" 2>&1
check "no zoneinfo: held by day" '[ "$(calls nz)" = 0 ] && grep -q "unreadable: holding" "$TMP/nz.out"'
# 8 dry-run: prints, sends and records nothing
run dry "$DAY" "$FX/alerts.json" --dry-run
check "dry-run: no hand-off" '[ "$(calls dry)" = 0 ]'
check "dry-run: no state" '[ ! -e "$TMP/dry.state" ]'
check "dry-run: says what it would send" 'grep -q "DRY would send FamilyCloudMoneyReopen" "$TMP/dry.out"'
# 9 every owner text passes the real pka-alert language guard (--guard-check publishes nothing)
REAL="${PKA_ALERT_REAL:-$HOME/pka-alert/bin/pka-alert}"
if [ -x "$REAL" ]; then
  while IFS=$'\t' read -r name text; do
    v=$("$REAL" --guard-check "$text" 2>/dev/null | tail -1)
    check "guard: $name text is plain language ($v)" '[ "$v" = ok ]'
  done < <(bash "$RELAY" --templates)
else
  echo "# skip guard check: no pka-alert at $REAL"
fi

echo "1..$n  failed=$fail  (tmp $TMP)"
[ "$fail" = 0 ]
