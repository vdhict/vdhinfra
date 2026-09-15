#!/bin/bash
# Signed-approval verifier — install as root on the Mini.
# READ THIS BEFORE RUNNING IT. Once installed, Atlas cannot modify any of it;
# that is the whole point, and it means this review is the only one you get.
#
#   sudo bash INSTALL-for-sander.sh
#
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# 1. state directory, root-owned. THIS is where the authority lives: the
#    execution gate reads granted/, never ops/changes.jsonl.
install -d -o root -g wheel -m 0755 /usr/local/var/atlas-approval
install -d -o root -g wheel -m 0755 /usr/local/var/atlas-approval/granted
install -d -o root -g wheel -m 0700 /usr/local/var/atlas-approval/processed
install -d -o root -g wheel -m 0700 /usr/local/var/atlas-approval/rejected
: > /usr/local/var/atlas-approval/replay
chown root:wheel /usr/local/var/atlas-approval/replay
chmod 0600      /usr/local/var/atlas-approval/replay

# 2. the verifier itself, root-owned and not writable by uid 501
install -d -o root -g wheel -m 0755 /usr/local/libexec
install -o root -g wheel -m 0755 "$SRC/atlas-approval-verify.py" \
        /usr/local/libexec/atlas-approval-verify.py

# 3. the daemon
install -o root -g wheel -m 0644 "$SRC/net.vdhict.atlas-approval-verify.plist" \
        /Library/LaunchDaemons/net.vdhict.atlas-approval-verify.plist
launchctl bootout   system/net.vdhict.atlas-approval-verify 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/net.vdhict.atlas-approval-verify.plist
launchctl kickstart -k system/net.vdhict.atlas-approval-verify

echo
echo "installed. verify with:"
echo "  sudo launchctl print system/net.vdhict.atlas-approval-verify | head -20"
echo "  sudo tail -f /usr/local/var/atlas-approval/verify.log"
echo
echo "NOT enabled yet: --require-uv. Atlas reads the flags byte from your first"
echo "real signature; if UV (0x04) is set, add --require-uv to the plist's"
echo "ProgramArguments and reload. Until then a signature proves the key was"
echo "used, not that your fingerprint was checked."
