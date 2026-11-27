#!/usr/bin/env bash
# owner-alert-relay-install.sh (wq-161, Argus C2): install the owner-alert-relay on the Mini as a PINNED copy of
# origin/main, so a branch switch in the working tree never changes the code that runs.
#
#   owner-alert-relay-install.sh            dry (default): fetch origin/main, show sha256 and what would be written
#   owner-alert-relay-install.sh --live     copy hack/ops/owner-alert-relay.sh from origin/main to
#                                           ~/.local/libexec/owner-alert-relay.sh (0755), record its sha256 in
#                                           ~/.local/state/owner-alert-relay/installed.sha256, write the plist from
#                                           origin/main to ~/Library/LaunchAgents and launchctl bootstrap it
#   owner-alert-relay-install.sh --check    post-check: sha256 of the libexec copy == installed.sha256 == origin/main,
#                                           plist runs the libexec copy and does not set OWNER_RELAY_TEST. Exit 0/1.
#
# Honest scope (Argus C2 note): uid 501 is shared with myPKA, so the sha check guards against DRIFT (a stale or
# hand-edited copy, a branch switch), not against a same-uid writer. It claims nothing more.
# Nothing is deleted (AGR-121): a previous libexec copy is moved aside to $STATE/prev-<UTC>.sh.
# Env (tests): RELAY_REPO, RELAY_LIBEXEC, RELAY_STATE_DIR, RELAY_LAUNCHAGENTS, LAUNCHCTL, RELAY_NO_FETCH=1.
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
MODE=dry
case "${1:-}" in
  "") ;; --live) MODE=live ;; --check) MODE=check ;;
  *) echo "usage: $0 [--live|--check]" >&2; exit 2 ;;
esac
REPO="${RELAY_REPO:-$HOME/Code/homelab-migration/vdhinfra}"
LIBEXEC="${RELAY_LIBEXEC:-$HOME/.local/libexec}"
STATE="${RELAY_STATE_DIR:-$HOME/.local/state/owner-alert-relay}"
AGENTS="${RELAY_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
LABEL=net.vdhict.owner-alert-relay
DEST="$LIBEXEC/owner-alert-relay.sh"; PLIST="$AGENTS/$LABEL.plist"; SHAFILE="$STATE/installed.sha256"
SRC_PATH=hack/ops/owner-alert-relay.sh; SRC_PLIST=hack/ops/$LABEL.plist
PROD_DEST=/Users/sheijden/.local/libexec/owner-alert-relay.sh   # the literal path in the committed plist
say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

if [ "${RELAY_NO_FETCH:-0}" != 1 ]; then
  git -C "$REPO" fetch -q origin main || { say "FAIL git fetch origin main in $REPO"; exit 1; }
fi
REV=$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null) || { say "FAIL no origin/main in $REPO"; exit 1; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/owner-alert-relay-install.XXXXXX")
git -C "$REPO" show "origin/main:$SRC_PATH" > "$TMPD/relay.sh" 2>/dev/null && [ -s "$TMPD/relay.sh" ] \
  || { say "FAIL $SRC_PATH is not on origin/main@$REV (push and merge first)"; exit 1; }
git -C "$REPO" show "origin/main:$SRC_PLIST" > "$TMPD/plist.src" 2>/dev/null && [ -s "$TMPD/plist.src" ] \
  || { say "FAIL $SRC_PLIST is not on origin/main@$REV"; exit 1; }
# The committed plist names the production path; tests (and only tests) install elsewhere.
sed "s#$PROD_DEST#$DEST#g" "$TMPD/plist.src" > "$TMPD/plist"
MAIN_SHA=$(sha "$TMPD/relay.sh")

if [ "$MODE" = check ]; then
  rc=0
  RUN_SHA=$(sha "$DEST"); REC_SHA=$(cut -d' ' -f1 "$SHAFILE" 2>/dev/null)
  if [ -z "$RUN_SHA" ]; then say "FAIL no installed copy at $DEST"; rc=1
  elif [ "$RUN_SHA" != "$REC_SHA" ]; then say "FAIL running copy sha256 $RUN_SHA != recorded ${REC_SHA:-none} (drift)"; rc=1
  elif [ "$RUN_SHA" != "$MAIN_SHA" ]; then say "FAIL running copy sha256 $RUN_SHA != origin/main@$REV $MAIN_SHA (reinstall)"; rc=1
  else say "OK sha256 $RUN_SHA == recorded == origin/main@$REV"; fi
  if ! grep -qF "<string>$DEST</string>" "$PLIST" 2>/dev/null; then say "FAIL $PLIST does not run $DEST"; rc=1
  elif grep -qE '<key>(EnvironmentVariables|OWNER_RELAY_TEST)</key>' "$PLIST"; then
    say "FAIL $PLIST sets environment variables (OWNER_RELAY_TEST must stay unset, C3)"; rc=1
  else say "OK plist runs the pinned copy, no OWNER_RELAY_TEST"; fi
  [ -x "$DEST" ] || { say "FAIL $DEST not executable"; rc=1; }
  exit "$rc"
fi

if [ "$MODE" = dry ]; then
  say "DRY origin/main@$REV $SRC_PATH sha256 $MAIN_SHA"
  say "DRY would install $DEST (0755), record $SHAFILE, write $PLIST, $LAUNCHCTL bootstrap gui/$(id -u) $PLIST"
  [ -e "$DEST" ] && say "DRY current copy sha256 $(sha "$DEST")"
  exit 0
fi

# --live
mkdir -p "$LIBEXEC" "$STATE" "$AGENTS" || { say "FAIL mkdir"; exit 1; }
if [ -e "$DEST" ]; then mv "$DEST" "$STATE/prev-$(date -u +%Y%m%dT%H%M%SZ).sh" || { say "FAIL move old copy aside"; exit 1; }; fi
cp "$TMPD/relay.sh" "$DEST.new" && chmod 0755 "$DEST.new" && mv "$DEST.new" "$DEST" || { say "FAIL install $DEST"; exit 1; }
GOT=$(sha "$DEST")
[ "$GOT" = "$MAIN_SHA" ] || { say "FAIL installed sha256 $GOT != origin/main $MAIN_SHA"; exit 1; }
printf '%s  origin/main@%s %s\n' "$GOT" "$REV" "$(date -u +%FT%TZ)" > "$SHAFILE"
cp "$TMPD/plist" "$PLIST.new" && mv "$PLIST.new" "$PLIST" || { say "FAIL write $PLIST"; exit 1; }
"$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
"$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST" || { say "FAIL launchctl bootstrap $PLIST"; exit 1; }
say "INSTALLED $DEST sha256 $GOT origin/main@$REV, $LABEL bootstrapped; run --check"
