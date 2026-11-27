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

# Stub pka-alert --for-sander: records the call and behaves per STUB_MODE, writing the ledger and log the way
# pka-alert does (ledger wire = sander-md5(title), title gets a marker prefix). Always exits 0, like the real one.
#   deliver (default) | throttle | fail | refuse | otherwire (a ledger line for a DIFFERENT wire, e.g. another caller)
cat > "$TMP/pka-alert-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
w="sander-$(printf '%s' "$2" | md5 -q 2>/dev/null || printf '%s' "$2" | md5sum | cut -d' ' -f1)"
case "${STUB_MODE:-deliver}" in
  deliver)   printf '{"ts":"x","wire":"%s","id":"stubid%s","priority":4,"quiet":"loud","host":"test","title":"\xe2\x9a\xa0\xef\xb8\x8f %s"}\n' "$w" "$RANDOM" "$2" >> "$PKA_ALERT_LEDGER" ;;
  throttle)  echo "x throttled wire=$w class=needs-sander (10s since last, window 21600s): $2" >> "$PKA_ALERT_LOG" ;;
  fail)      echo "x DELIVERY FAILED wire=$w http=500" >> "$PKA_ALERT_LOG" ;;
  refuse)    echo "x for-sander REFUSED reason=guard(jargon:probe): $2" >> "$PKA_ALERT_LOG" ;;
  otherwire) printf '{"ts":"x","wire":"sander-other","id":"otherid","priority":4,"quiet":"loud","host":"test","title":"x %s"}\n' "$2" >> "$PKA_ALERT_LEDGER" ;;
esac
exit 0
EOF
chmod +x "$TMP/pka-alert-stub"

run() { # run <case> <epoch> <fixture> [extra args]
  local c="$1" e="$2" f="$3"; shift 3
  STUB_CALLS="$TMP/$c.calls" PKA_ALERT_LEDGER="$TMP/$c.ledger" PKA_ALERT_LOG="$TMP/$c.plog" RELAY_STATE_DIR="$TMP/$c.state" \
    PKA_ALERT="${PKA_ALERT_STUB:-$TMP/pka-alert-stub}" AIOPS_ENV=/nonexistent \
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
check "repeat: counted as already-recorded" 'grep -q "already-recorded=1" "$TMP/day.out"'
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
STUB_CALLS="$TMP/nz.calls" PKA_ALERT_LEDGER="$TMP/nz.ledger" PKA_ALERT_LOG="$TMP/nz.plog" RELAY_STATE_DIR="$TMP/nz.state" PKA_ALERT="$TMP/pka-alert-stub" \
  RELAY_ZONEINFO=/nonexistent/zone bash "$RELAY" --input "$FX/alerts.json" --now "$DAY" > "$TMP/nz.out" 2>&1
check "no zoneinfo: held by day" '[ "$(calls nz)" = 0 ] && grep -q "unreadable: holding" "$TMP/nz.out"'
# 8 dry-run: prints, sends and records nothing
run dry "$DAY" "$FX/alerts.json" --dry-run
check "dry-run: no hand-off" '[ "$(calls dry)" = 0 ]'
check "dry-run: no state" '[ ! -e "$TMP/dry.state" ]'
check "dry-run: says what it would send" 'grep -q "DRY would send FamilyCloudMoneyReopen" "$TMP/dry.out"'
# 10 C1: throttled -> PENDING, not recorded; the next run delivers -> SENT; then nothing more
STUB_MODE=throttle run thr "$DAY" "$FX/alerts.json"
check "throttled: called once" '[ "$(calls thr)" = 1 ]'
check "throttled: PENDING logged" 'grep -q "PENDING FamilyCloudMoneyReopen" "$TMP/thr.out"'
check "throttled: not recorded" '[ ! -s "$TMP/thr.state/sent.tsv" ] && [ ! -s "$TMP/thr.state/refused.tsv" ]'
STUB_MODE=deliver run thr "$DAY" "$FX/alerts.json"
check "throttled->later run: retried and SENT" '[ "$(calls thr)" = 2 ] && grep -q "SENT FamilyCloudMoneyReopen .*pka_alert_ledger_id=stubid" "$TMP/thr.out"'
run thr "$DAY" "$FX/alerts.json"
check "throttled->sent: no third call" '[ "$(calls thr)" = 2 ]'
# 11 C1: delivery failure -> PENDING, not recorded
STUB_MODE=fail run fl "$DAY" "$FX/alerts.json"
check "delivery fail: PENDING, not recorded" 'grep -q "PENDING FamilyCloudMoneyReopen" "$TMP/fl.out" && [ ! -s "$TMP/fl.state/sent.tsv" ]'
STUB_MODE=fail run fl "$DAY" "$FX/alerts.json"
check "delivery fail: retried next run" '[ "$(calls fl)" = 2 ]'
# 12 C1: a ledger line for ANOTHER wire is not a receipt
STUB_MODE=otherwire run ow "$DAY" "$FX/alerts.json"
check "other wire in ledger: PENDING, not SENT" 'grep -q "PENDING FamilyCloudMoneyReopen" "$TMP/ow.out" && [ ! -s "$TMP/ow.state/sent.tsv" ]'
# 13 C1: binary missing -> PENDING, not recorded
PKA_ALERT_STUB=/nonexistent/pka-alert run nb "$DAY" "$FX/alerts.json"
check "binary missing: PENDING pka-alert-missing, not recorded" 'grep -q "PENDING FamilyCloudMoneyReopen .*pka-alert-missing" "$TMP/nb.out" && [ ! -e "$TMP/nb.state/sent.tsv" ]'
# 14 C1: guard refusal is final -> REFUSED recorded once, never called again
STUB_MODE=refuse run rf "$DAY" "$FX/alerts.json"
check "refused: REFUSED logged" 'grep -q "REFUSED FamilyCloudMoneyReopen" "$TMP/rf.out"'
check "refused: recorded in refused.tsv only" '[ "$(grep -c . "$TMP/rf.state/refused.tsv")" = 1 ] && [ ! -s "$TMP/rf.state/sent.tsv" ]'
STUB_MODE=refuse run rf "$DAY" "$FX/alerts.json"
check "refused: no second call" '[ "$(calls rf)" = 1 ]'
# 15 C3: TestOwnerAlertRoute only with OWNER_RELAY_TEST=1
run tr0 "$DAY" "$FX/alerts-test-route.json"
check "test route without flag: not sent, SKIP logged, not recorded" '[ "$(calls tr0)" = 0 ] && grep -q "SKIP TestOwnerAlertRoute" "$TMP/tr0.out" && [ ! -s "$TMP/tr0.state/sent.tsv" ]'
OWNER_RELAY_TEST=1 run tr1 "$DAY" "$FX/alerts-test-route.json"
check "test route with OWNER_RELAY_TEST=1: sent" '[ "$(calls tr1)" = 1 ] && grep -q "^--for-sander Test: meldingen over geld" "$TMP/tr1.calls"'
OWNER_RELAY_TEST=1 run tr2 "$CET_2300" "$FX/alerts-test-route.json"
check "test route with flag at night: held" '[ "$(calls tr2)" = 0 ]'

# 16 C2: install script against a throwaway origin (stub launchctl; nothing touches ~/Library or ~/.local)
INST="$HERE/../owner-alert-relay-install.sh"
G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
O="$TMP/origin"; C="$TMP/clone"; mkdir -p "$O/hack/ops"
cp "$RELAY" "$O/hack/ops/owner-alert-relay.sh"; cp "$HERE/../net.vdhict.owner-alert-relay.plist" "$O/hack/ops/"
( cd "$O" && G init -q -b main && G add -A && G commit -qm init ) && G clone -q "$O" "$C"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$TMP/launchctl.calls" > "$TMP/launchctl-stub"; chmod +x "$TMP/launchctl-stub"
IE() { RELAY_REPO="$C" RELAY_LIBEXEC="$TMP/i/libexec" RELAY_STATE_DIR="$TMP/i/state" RELAY_LAUNCHAGENTS="$TMP/i/agents" \
       LAUNCHCTL="$TMP/launchctl-stub" bash "$INST" "$@" > "$TMP/inst.out" 2>&1; }
IE; check "install dry: exit 0, writes nothing, no launchctl" '[ $? = 0 ] && [ ! -e "$TMP/i" ] && [ ! -e "$TMP/launchctl.calls" ] && grep -q "DRY would install" "$TMP/inst.out"'
IE --check; check "install check before install: FAIL" '[ $? = 1 ]'
IE --live; check "install live: exit 0" '[ $? = 0 ]'
check "install live: copy == origin/main, mode 0755" 'cmp -s "$TMP/i/libexec/owner-alert-relay.sh" "$O/hack/ops/owner-alert-relay.sh" && [ "$(stat -f %Lp "$TMP/i/libexec/owner-alert-relay.sh" 2>/dev/null || stat -c %a "$TMP/i/libexec/owner-alert-relay.sh")" = 755 ]'
check "install live: sha256 recorded" '[ "$(cut -d" " -f1 "$TMP/i/state/installed.sha256")" = "$(shasum -a 256 "$O/hack/ops/owner-alert-relay.sh" | cut -d" " -f1)" ]'
check "install live: plist runs the libexec copy, bootstrapped" 'grep -qF "<string>$TMP/i/libexec/owner-alert-relay.sh</string>" "$TMP/i/agents/net.vdhict.owner-alert-relay.plist" && grep -q "^bootstrap gui/" "$TMP/launchctl.calls"'
IE --check; check "install check after install: OK" '[ $? = 0 ]'
echo "# tamper" >> "$TMP/i/libexec/owner-alert-relay.sh"
IE --check; check "install check: drifted copy FAILs" '[ $? = 1 ] && grep -q "drift" "$TMP/inst.out"'
IE --live; check "reinstall: old copy moved aside, check OK" '[ -n "$(ls "$TMP/i/state" | grep "^prev-")" ] && IE --check'
sed -i.bak 's#<key>RunAtLoad</key>#<key>EnvironmentVariables</key><dict><key>OWNER_RELAY_TEST</key><string>1</string></dict><key>RunAtLoad</key>#' "$TMP/i/agents/net.vdhict.owner-alert-relay.plist"
IE --check; check "install check: plist with OWNER_RELAY_TEST FAILs (C3)" '[ $? = 1 ] && grep -q "C3" "$TMP/inst.out"'
IE --live; IE --check; check "reinstall restores the clean plist" '[ $? = 0 ]'
( cd "$O" && echo "# newer" >> hack/ops/owner-alert-relay.sh && G commit -qam newer )
IE --check; check "install check: origin/main moved -> FAIL (reinstall)" '[ $? = 1 ] && grep -q "reinstall" "$TMP/inst.out"'

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
