#!/usr/bin/env bash
# Opens the vdhwslin01 provisioning window (chg-2026-10-05-031, Argus
# 2026-10-13T21:52:27Z C1-C3). Sander runs this ONCE, as himself, in a
# directory that holds the downloaded files:
#   provision.sh  vdh-provision-tonight  90-agent-provision  install-window.sh
#
#   bash install-window.sh
#
# It checks agent has no wheel/sudo, verifies every file's sha256, installs
# root:root copies, validates the sudoers drop-in with visudo, and starts a
# 3 h backstop timer that removes the drop-in no matter what.
set -euo pipefail
PROV_SHA256=493920901a796e659b537cb914da57c9c5777ff9d55d56f2cd8673f168de5f37
WRAP_SHA256=6e44004b160c5113d42e443411d412e98b5e5483436c2610e8a2a2dadea9a2b8
DROPIN_SHA256=108c432d900bc4ed877df49877c3407152a4a1bde6fa35c5723eefc1c19b356b
DROPIN=/etc/sudoers.d/90-agent-provision
say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
cd "$(dirname "$0")"

say "agent account"
id agent >/dev/null 2>&1 || die "user agent does not exist"
g=" $(id -nG agent) "
[[ "$g" != *" wheel "* && "$g" != *" sudo "* ]] || die "agent is in wheel/sudo ($g); refusing"
echo "    agent groups:$g(no wheel/sudo)"

say "file hashes"
for pair in "provision.sh:$PROV_SHA256" "vdh-provision-tonight:$WRAP_SHA256" "90-agent-provision:$DROPIN_SHA256"; do
  f="${pair%%:*}"; want="${pair#*:}"
  [[ -f "$f" ]] || die "$f not in $(pwd)"
  have="$(sha256sum "$f" | cut -d' ' -f1)"
  [[ "$have" == "$want" ]] || die "$f sha256 $have != $want"
  echo "    ok $f $have"
done

say "sudoers: includedir present and drop-in valid"
sudo grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers || die "/etc/sudoers has no includedir /etc/sudoers.d"
sudo visudo -cf ./90-agent-provision

say "install root-owned copies"
sudo install -o root -g root -m 0755 provision.sh /usr/local/sbin/vdh-provision.sh
sudo install -o root -g root -m 0755 vdh-provision-tonight /usr/local/sbin/vdh-provision-tonight
for pair in "/usr/local/sbin/vdh-provision.sh:$PROV_SHA256" "/usr/local/sbin/vdh-provision-tonight:$WRAP_SHA256"; do
  f="${pair%%:*}"; want="${pair#*:}"
  [[ "$(sudo sha256sum "$f" | cut -d' ' -f1)" == "$want" ]] || die "installed $f hash mismatch"
  echo "    ok $f $(stat -c '%U:%G %a' "$f")"
done

say "start the 3 h backstop (removes the drop-in even if nobody revokes)"
sudo systemctl stop vdh-agent-provision-revoke.timer 2>/dev/null || true
sudo systemd-run --unit=vdh-agent-provision-revoke --on-active=3h /usr/bin/rm -f /etc/sudoers.d/90-agent-provision
sudo systemctl list-timers vdh-agent-provision-revoke.timer --no-pager | head -3

say "install the drop-in (0440)"
sudo install -o root -g root -m 0440 90-agent-provision "$DROPIN"
sudo visudo -c >/dev/null && echo "    visudo -c: whole sudoers config valid"
sudo -l -U agent | sed 's/^/    /'
say "window OPEN. agent may run: sudo -n /usr/local/sbin/vdh-provision-tonight dry|real|c4|uninstall|revoke"
say "closes by: 'revoke', or the backstop at $(sudo systemctl show vdh-agent-provision-revoke.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
