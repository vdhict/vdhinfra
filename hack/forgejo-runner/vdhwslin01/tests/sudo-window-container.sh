#!/usr/bin/env bash
# Runs INSIDE a throwaway Arch container as root (chg-2026-10-05-031, Argus
# 2026-10-13T21:52:27Z C1-C4). Tests the sudo-window kit for real with sudo:
#   S1 install-window.sh as a sudo-capable "sander": hashes, agent check,
#      visudo -cf, root-owned copies, 0440 drop-in, backstop timer call
#   S2 the drop-in admits exactly the five wrapper words for agent; everything
#      else is refused by sudo (other words, extra args, no arg, other
#      commands, env assignment / SETENV, -E)
#   S3 `dry` works end to end (provision.sh --dry-run with the fixed args)
#   S4 the wrapper refuses a tampered, symlinked or loosely-moded provision.sh
#   S5 revoke removes the drop-in; verify-revoked.sh (as agent) PASSes
# Not testable here (no systemd/nft/KVM): c4, real, uninstall.
# Usage: bash tests/sudo-window-container.sh <bundle-dir>
# shellcheck disable=SC2015  # ok/bad always return 0
set -uo pipefail
B="${1:?bundle dir}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

echo "== setup"
pacman -Sy --noconfirm --needed sudo mkinitcpio mkinitcpio-dropbear mkinitcpio-utils mkinitcpio-netconf cryptsetup openssh >/dev/null 2>&1
id agent >/dev/null 2>&1 || useradd -m agent
id sander >/dev/null 2>&1 || useradd -m -G wheel sander
echo 'sander ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/00-test-sander; chmod 0440 /etc/sudoers.d/00-test-sander
# stubs for systemd tools (no systemd in a container); they only record calls
for t in systemd-run systemctl; do
  printf '#!/bin/sh\necho "%s $*" >> /var/log/stub-calls\nexit 0\n' "$t" > "/usr/local/bin/$t"; chmod 0755 "/usr/local/bin/$t"
done
# Omarchy-shaped dropbear fixture so the dry-run's initramfs detection runs
install -d -m 0755 /etc/dropbear /etc/mkinitcpio.conf.d
ssh-keygen -q -t ed25519 -N '' -C sander-unlock -f /root/sander_unlock <<<y >/dev/null 2>&1
cp /root/sander_unlock.pub /etc/dropbear/root_key
printf 'HOOKS=(base udev keyboard modconf kms keymap consolefont block netconf dropbear encryptssh filesystems fsck)\n' > /etc/mkinitcpio.conf.d/omarchy_hooks.conf
W=/home/sander/win; install -d -o sander -m 0755 "$W"
cp "$B/provision.sh" "$B/sudo-window/vdh-provision-tonight" "$B/sudo-window/90-agent-provision" "$B/sudo-window/install-window.sh" "$B/sudo-window/verify-revoked.sh" "$W/"
chown -R sander "$W"

echo "== S1 install-window.sh as sander"
if su - sander -c "bash $W/install-window.sh" > /root/s1.log 2>&1; then ok "S1 install-window.sh exits 0"; else bad "S1 install-window"; tail -15 /root/s1.log; fi
sed 's/^/    | /' /root/s1.log | head -40
[[ "$(stat -c '%U:%G %a' /etc/sudoers.d/90-agent-provision 2>/dev/null)" == "root:root 440" ]] && ok "S1 drop-in root:root 0440" || bad "S1 drop-in perms"
[[ "$(stat -c '%U:%G %a' /usr/local/sbin/vdh-provision.sh)" == "root:root 755" ]] && ok "S1 provision copy root:root 0755" || bad "S1 provision perms"
[[ "$(stat -c '%U:%G %a' /usr/local/sbin/vdh-provision-tonight)" == "root:root 755" ]] && ok "S1 wrapper root:root 0755" || bad "S1 wrapper perms"
grep -q 'systemd-run --unit=vdh-agent-provision-revoke --on-active=3h /usr/bin/rm -f /etc/sudoers.d/90-agent-provision' /var/log/stub-calls && ok "S1 3 h backstop timer requested" || bad "S1 no backstop call"
visudo -c >/dev/null && ok "S1 visudo -c whole config valid" || bad "S1 visudo -c"
# agent-in-wheel guard
usermod -aG wheel agent
su - sander -c "bash $W/install-window.sh" > /root/s1b.log 2>&1 && bad "S1 installed although agent is in wheel" || { grep -q 'agent is in wheel' /root/s1b.log && ok "S1 refuses when agent is in wheel" || bad "S1 wheel message"; }
gpasswd -d agent wheel >/dev/null
# tampered sibling refused before anything is installed
cp "$W/90-agent-provision" /root/dropin.keep
echo 'agent ALL=(ALL) NOPASSWD: ALL' >> "$W/90-agent-provision"
su - sander -c "bash $W/install-window.sh" > /root/s1c.log 2>&1 && bad "S1 accepted a tampered drop-in" || { grep -q '90-agent-provision sha256' /root/s1c.log && ok "S1 refuses a tampered drop-in (hash)" || bad "S1 tamper message"; }
cp /root/dropin.keep "$W/90-agent-provision"; chown sander "$W/90-agent-provision"

echo "== S2 sudo admits exactly the five words"
A() { su -s /bin/bash agent -c "$*" </dev/null; }
l="$(A 'sudo -n -l' 2>&1)"
grep -q 'NOPASSWD: /usr/local/sbin/vdh-provision-tonight dry, /usr/local/sbin/vdh-provision-tonight real, /usr/local/sbin/vdh-provision-tonight c4, /usr/local/sbin/vdh-provision-tonight uninstall, /usr/local/sbin/vdh-provision-tonight revoke' <<<"$(tr -s ' \n' ' ' <<<"$l")" \
  && ok "S2 sudo -l lists exactly the five invocations" || { bad "S2 sudo -l"; echo "$l"; }
! grep -qE '\(ALL\) ALL|NOPASSWD: ALL|SETENV' <<<"$l" && ok "S2 no ALL command, no SETENV" || bad "S2 broad rule present"
for cmd in "sudo -n /usr/local/sbin/vdh-provision-tonight bogus" \
           "sudo -n /usr/local/sbin/vdh-provision-tonight dry --steps keyslot" \
           "sudo -n /usr/local/sbin/vdh-provision-tonight" \
           "sudo -n /usr/local/sbin/vdh-provision.sh --dry-run" \
           "sudo -n /bin/sh -c id" \
           "sudo -n PROV=/tmp/x /usr/local/sbin/vdh-provision-tonight dry" \
           "sudo -n -E /usr/local/sbin/vdh-provision-tonight dry" \
           "sudo -n -u sander /usr/local/sbin/vdh-provision-tonight dry"; do
  if A "$cmd" >/dev/null 2>&1; then bad "S2 sudo ALLOWED: $cmd"; else ok "S2 refused: ${cmd#sudo -n }"; fi
done

echo "== S3 dry runs with the fixed args"
if A 'sudo -n /usr/local/sbin/vdh-provision-tonight dry' > /root/s3.log 2>&1; then ok "S3 dry exits 0"; else bad "S3 dry"; tail -15 /root/s3.log; fi
grep -q 'sha256 ok (ad0304513bbff75f0d6c71bd4afc065e75078660faeb0d0dc53ea1b5eee6de38)' /root/s3.log && ok "S3 hash checked before running" || bad "S3 no hash line"
grep -q 'steps: preflight packages user binary payload vmkey firewall golden register services initramfs report' /root/s3.log && ok "S3 fixed steps, keyslot absent" || bad "S3 steps line: $(grep 'steps:' /root/s3.log)"
! grep -qE 'LUKS: separate controller keyslot|luksAddKey|passphrase' /root/s3.log && ok "S3 keyslot step never runs (no LUKS/passphrase activity)" || bad "S3 keyslot activity"
grep -q 'done (dry-run: nothing changed)' /root/s3.log && ok "S3 provision dry-run completed" || bad "S3 dry-run incomplete"
ls /var/log/vdh-provision-dry-*.log >/dev/null 2>&1 && ok "S3 root log written" || bad "S3 no root log"

echo "== S4 wrapper refuses a bad provision.sh"
cp -a /usr/local/sbin/vdh-provision.sh /root/prov.keep
echo '# tampered' >> /usr/local/sbin/vdh-provision.sh
A 'sudo -n /usr/local/sbin/vdh-provision-tonight dry' > /root/s4a.log 2>&1 && bad "S4 ran a tampered provision.sh" || { grep -q 'sha256 mismatch' /root/s4a.log && ok "S4 tampered content refused" || bad "S4 tamper msg"; }
cp -a /root/prov.keep /usr/local/sbin/vdh-provision.sh
chmod 0777 /usr/local/sbin/vdh-provision.sh
A 'sudo -n /usr/local/sbin/vdh-provision-tonight dry' > /root/s4b.log 2>&1 && bad "S4 ran a world-writable provision.sh" || ok "S4 world-writable refused ($(grep -o 'mode [0-9]*' /root/s4b.log))"
cp -a /root/prov.keep /usr/local/sbin/vdh-provision.sh
mv /usr/local/sbin/vdh-provision.sh /usr/local/sbin/vdh-provision.real; ln -s /usr/local/sbin/vdh-provision.real /usr/local/sbin/vdh-provision.sh
A 'sudo -n /usr/local/sbin/vdh-provision-tonight dry' > /root/s4c.log 2>&1 && bad "S4 ran through a symlink" || ok "S4 symlink refused"
unlink /usr/local/sbin/vdh-provision.sh; mv /usr/local/sbin/vdh-provision.real /usr/local/sbin/vdh-provision.sh
chown agent /usr/local/sbin/vdh-provision.sh
A 'sudo -n /usr/local/sbin/vdh-provision-tonight dry' > /root/s4d.log 2>&1 && bad "S4 ran an agent-owned provision.sh" || ok "S4 non-root owner refused"
chown root:root /usr/local/sbin/vdh-provision.sh
/usr/local/sbin/vdh-provision-tonight dry extra >/dev/null 2>&1; [[ $? == 2 ]] && ok "S4 wrapper itself rejects two words (root direct)" || bad "S4 two words"
/usr/local/sbin/vdh-provision-tonight 'dry;id' >/dev/null 2>&1; [[ $? == 2 ]] && ok "S4 wrapper rejects 'dry;id'" || bad "S4 injection word"
[[ "$(sha256sum /usr/local/sbin/vdh-provision.sh | cut -d' ' -f1)" == ad0304513bbff75f0d6c71bd4afc065e75078660faeb0d0dc53ea1b5eee6de38 ]] && ok "S4 original restored" || bad "S4 restore"

echo "== S5 revoke + verify-revoked"
install -o agent -m 0755 "$W/verify-revoked.sh" /home/agent/verify-revoked.sh
if A "cd ~ && bash ./verify-revoked.sh" > /root/s5pre.log 2>&1; then bad "S5 verify-revoked PASSED while the drop-in is still installed"; else grep -q 'RESULT: FAIL' /root/s5pre.log && ok "S5 verify-revoked FAILs (exit != 0) while the window is open" || bad "S5 pre message"; fi
if A 'sudo -n /usr/local/sbin/vdh-provision-tonight revoke' > /root/s5.log 2>&1; then ok "S5 revoke exits 0"; else bad "S5 revoke"; cat /root/s5.log; fi
sed 's/^/    | /' /root/s5.log
[[ ! -e /etc/sudoers.d/90-agent-provision ]] && ok "S5 drop-in gone" || bad "S5 drop-in still there"
A 'sudo -n /usr/local/sbin/vdh-provision-tonight dry' >/dev/null 2>&1 && bad "S5 wrapper still runnable" || ok "S5 wrapper no longer runnable for agent"
install -o agent -m 0755 "$W/verify-revoked.sh" /home/agent/verify-revoked.sh
if A "cd ~ && bash ./verify-revoked.sh" > /root/s5b.log 2>&1; then ok "S5 verify-revoked.sh PASS"; else bad "S5 verify-revoked"; fi
sed 's/^/    | /' /root/s5b.log
ls /home/agent/vdhwslin01-sudo-revoked-*.txt >/dev/null 2>&1 && [[ "$(stat -c %a /home/agent/vdhwslin01-sudo-revoked-*.txt | head -1)" == 444 ]] && ok "S5 write-once evidence file 0444" || bad "S5 evidence file"

echo "RESULT: ${pass} passed, ${fail} failed"
(( fail == 0 ))
