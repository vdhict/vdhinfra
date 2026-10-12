#!/bin/bash
# Install the Mac half of AIOps step 1 (chg-2026-10-12-009) for the current
# user. Idempotent. Usage:  install.sh <lan-ip>
#   vdhmini01:   install.sh 172.16.2.201
#   vdhllmsrv01: install.sh 172.16.2.200
# Needs ~/.config/aiops/ntfy.env (mode 600) to exist already.
# No sudo, no firewall change: the LAN socket is owned by launchd (allowed by
# the application firewall), node_exporter itself only listens on loopback.
set -euo pipefail
LAN_IP="${1:?usage: install.sh <lan-ip>}"
SRC="$(cd "$(dirname "$0")" && pwd)"
BREW=/opt/homebrew/bin/brew
NE=/opt/homebrew/opt/node_exporter/bin/node_exporter
LA="$HOME/Library/LaunchAgents"

[ -f "$HOME/.config/aiops/ntfy.env" ] || { echo "missing ~/.config/aiops/ntfy.env" >&2; exit 2; }
chmod 600 "$HOME/.config/aiops/ntfy.env"
/sbin/ifconfig | grep -q "inet $LAN_IP " || { echo "$LAN_IP is not an address of this Mac" >&2; exit 2; }

[ -x "$NE" ] || HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" install node_exporter
mkdir -p "$HOME/bin" "$HOME/.local/share/aiops/textfile" "$HOME/.local/state/aiops" "$HOME/Library/Logs" "$LA"
install -m 755 "$SRC/aiops-mac-agent.sh" "$HOME/bin/aiops-mac-agent"

for f in "$SRC"/launchd/*.plist; do
  label="$(basename "$f" .plist)"
  sed -e "s#__HOME__#$HOME#g" -e "s#__LAN_IP__#$LAN_IP#g" "$f" > "$LA/$label.plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LA/$label.plist"
  echo "loaded $label"
done
"$NE" --version 2>&1 | head -1
