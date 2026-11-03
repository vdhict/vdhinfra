#!/usr/bin/env bash
# Team pull of the vdhwslin01 team LUKS key to the Mini waker's fixed path, then shred the box copy
# (chg-2026-10-05-031, B5 = a). Run on vdhmini01 as Atlas, once, after Sander's owner-session.sh.
#
#   teamkey-pull.sh            # pull + verify + shred the box copy + read-back
#
# - box side: ~agent/.vdh-teamkey/team-luks.key (0400 agent, 48 bytes A-Za-z0-9), read as agent over the
#   pinned ssh alias `vdhwslin01` (no sudo, so nothing lands in the sudo I/O log);
# - Mini side: ~/.config/vdhwslin01/team-luks.key, 0400, noclobber; never printed, never on argv;
# - verification compares sha256 values inside this script and prints only match/mismatch;
# - only after a verified copy: `shred -u` of the box copy + rmdir of its dir, read back as absent.
# The key is NOT tested for unlock here (that needs a reboot): C8, the attended first reboot, unlocks
# with exactly this file (PASSFILE=... ~/bin/vdhwslin01-unlock-and-wait.sh) before the waker loads.
# Overrides for tests only: SSH (ssh binary/stub), CONF (Mini dir).
set -euo pipefail
umask 077
SSH="${SSH:-/usr/bin/ssh}"
HOST=vdhwslin01
CONF="${CONF:-$HOME/.config/vdhwslin01}"
DEST="$CONF/team-luks.key"
BOXFILE='.vdh-teamkey/team-luks.key'          # relative to agent's home on the box
die() { echo "teamkey-pull: $*" >&2; exit 2; }
sshb() { "$SSH" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

[[ ! -e "$DEST" && ! -L "$DEST" ]] || die "$DEST already exists (not overwriting); revoke/rotate deliberately"
mkdir -p "$CONF"; chmod 0700 "$CONF"
# Argus 4 (2026-11-03): the key dir must be excluded from Time Machine BEFORE the key lands there.
if command -v tmutil >/dev/null; then
  tmutil isexcluded "$CONF" | grep -q '^\[Excluded\]' \
    || die "$CONF is not excluded from Time Machine; run: tmutil addexclusion \"$CONF\" (then again)"
elif [[ "${TEAMKEY_NO_TMUTIL_OK:-}" != 1 ]]; then
  die "tmutil not found: not on the Mini? (tests: TEAMKEY_NO_TMUTIL_OK=1)"
fi
sshb "test -f ~/$BOXFILE && test ! -L ~/$BOXFILE && test \"\$(stat -c '%a %s' ~/$BOXFILE)\" = '400 48'" \
  || die "box copy missing, a symlink, or not 0400/48 bytes"

tmp="$DEST.new"
[[ ! -e "$tmp" ]] || die "$tmp exists from an earlier attempt; inspect it, then move it away"
( set -o noclobber; sshb "cat ~/$BOXFILE" > "$tmp" )
chmod 0400 "$tmp"
LC_ALL=C grep -qxE '[A-Za-z0-9]{48}' "$tmp" && [[ "$(wc -c < "$tmp" | tr -d ' ')" == 48 ]] \
  || die "pulled copy is not 48 chars A-Za-z0-9 (kept at $tmp for inspection, not printed)"
here="$(sha "$tmp")"
there="$(sshb "sha256sum ~/$BOXFILE" | cut -d' ' -f1)"
[[ "$here" == "$there" ]] || die "sha256 mismatch between the box copy and the pulled copy (kept at $tmp)"
mv -n "$tmp" "$DEST"
[[ -f "$DEST" && ! -e "$tmp" ]] || die "could not move into place"
echo "pulled: $DEST (0400, 48 bytes), sha256 match"

# box copy: shred + remove the dir, then read back (reviewed deletion, AGR-121)
sshb "chmod 0600 ~/$BOXFILE && shred -u ~/$BOXFILE && rmdir ~/.vdh-teamkey"   # shred needs write access
if sshb "test ! -e ~/.vdh-teamkey"; then echo "box copy shredded; ~agent/.vdh-teamkey absent (read back)"
else die "box copy still present after shred"; fi
echo "next: C8 attended reboot unlocking with PASSFILE=$DEST, then point the waker at it (it already reads team-luks.key)"
