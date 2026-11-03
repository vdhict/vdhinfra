#!/usr/bin/env bash
# Runs INSIDE a throwaway Arch container as root (tests/run-in-pod.sh owner). Exercises
# owner/owner-session.sh for real against a LUKS2 *image file* (no loop device needed for
# luksAddKey / --test-passphrase), real sudo + visudo, real pacman, driven by expect for the
# interactive passphrase prompt; then mini/teamkey-pull.sh with an ssh stub that runs box-side
# commands as agent. Test-only secrets are fixed strings; the generated key is never printed.
# Usage: bash tests/owner-session-container.sh <bundle-dir>
# shellcheck disable=SC2015,SC2016  # ok/bad idiom; bash -c bodies expand in the child
set -uo pipefail
B="${1:?bundle dir}"; cd "$B" || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
OS=owner/owner-session.sh; IMG=/root/disk.img; KF=/home/agent/.vdh-teamkey/team-luks.key
DROPIN=/etc/sudoers.d/50-agent-team; SLOTREC=/etc/vdh-runner/team-keyslot

echo "== setup"
pacman -Sy --noconfirm --needed sudo cryptsetup expect util-linux shadow coreutils >/dev/null 2>&1
useradd -m agent; useradd -m sander
check "setup sudoers has includedir" grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers
truncate -s 64M "$IMG"
printf '%s' 'owner-existing-passphrase-TEST' > /root/ownerpass; chmod 0600 /root/ownerpass
cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$IMG" /root/ownerpass >/dev/null
nslots() { cryptsetup luksDump "$IMG" | awk '/^Keyslots:/{k=1;next} /^[A-Z][a-z]+:/{k=0} k && /^ +[0-9]+: luks2/{n++} END{print n+0}'; }
check "setup image has 1 keyslot" test "$(nslots)" = 1
run_os() { # run_os <log> [args]: SUDO_USER=sander, expect answers consent (ANS1/ANS2) + passphrase
  local log="$1"; shift
  export ANS1="${ANS1:-I UNDERSTAND}" ANS2="${ANS2:-NO CLIENT DATA}"
  expect -c '
    set timeout 600
    log_user 1
    spawn env SUDO_USER=sander LUKS_DEV=/root/disk.img bash '"$OS"' '"$*"'
    expect {
      -re {Type I UNDERSTAND to continue: $} { send -- "$env(ANS1)\r"; exp_continue }
      -re {Type NO CLIENT DATA to confirm.*: $} { send -- "$env(ANS2)\r"; exp_continue }
      -re {Enter any existing passphrase: ?$} { set f [open /root/ownerpass r]; set p [read $f]; close $f; log_user 0; send -- "$p\r"; log_user 1; exp_continue }
      eof
    }
    catch wait r; exit [lindex $r 3]' > "$log" 2>&1
}

echo "== A dry run changes nothing"
SUDO_USER=sander LUKS_DEV="$IMG" bash "$OS" --dry-run > /root/a.log 2>&1; rc=$?
check "A dry-run exit 0" test "$rc" = 0
check "A no drop-in" test ! -e "$DROPIN"
check "A still 1 keyslot" test "$(nslots)" = 1
check "A packages not installed by dry-run" bash -c '! pacman -Q podman >/dev/null 2>&1'
check "A says visudo -cf OK" grep -q 'after visudo -cf: OK' /root/a.log
check "A dry-run ends with DRY RUN OK, never with the real OK line" bash -c 'grep -q "owner-session.sh: DRY RUN OK" /root/a.log && ! grep -qx "owner-session.sh: OK" /root/a.log' 

echo "== B refusals"
SUDO_USER=agent LUKS_DEV="$IMG" bash "$OS" --dry-run > /root/b1.log 2>&1 && bad "B1 SUDO_USER=agent accepted" || ok "B1 refuses to run as agent"
env -u SUDO_USER LUKS_DEV="$IMG" bash "$OS" --dry-run > /root/b2.log 2>&1 && bad "B2 no SUDO_USER accepted" || ok "B2 refuses without SUDO_USER (root login)"
printf 'agent ALL=(ALL) ALL\n' > "$DROPIN"; chmod 0440 "$DROPIN"
SUDO_USER=sander LUKS_DEV="$IMG" bash "$OS" --dry-run > /root/b3.log 2>&1 && bad "B3 foreign drop-in accepted" || ok "B3 refuses a drop-in with other content"
check "B3 foreign drop-in left untouched" grep -qx 'agent ALL=(ALL) ALL' "$DROPIN"
rm -f "$DROPIN"

echo "== B4/B5 consent refusals change nothing"
ANS1="no" run_os /root/b4.log; rc=$?
check "B4 wrong consent answer -> refused, no drop-in, 1 slot" bash -c '[[ "$1" != 0 && ! -e "$2" && "$(grep -c "not confirmed; nothing changed" /root/b4.log)" == 1 ]]' _ "$rc" "$DROPIN"
check "B4 no OK line" bash -c '! grep -q "owner-session.sh: OK" /root/b4.log'
ANS2="client data present" run_os /root/b5.log; rc=$?
check "B5 no client-data confirmation -> refused, nothing changed" bash -c '[[ "$1" != 0 && ! -e "$2" ]] && grep -q "client-data confirmation not given" /root/b5.log' _ "$rc" "$DROPIN"
check "B5 still 1 keyslot, packages untouched" bash -c '[[ "$(cryptsetup luksDump /root/disk.img | grep -c "^  [0-9]*: luks2")" == 1 ]] && ! pacman -Q podman >/dev/null 2>&1'
echo "== C real run"
run_os /root/c.log; rc=$?
sed 's/^/    | /' /root/c.log | grep -v 'Enter any existing' | tail -40
check "C exit 0" test "$rc" = 0
check "C last line is owner-session.sh: OK" bash -c '[[ "$(tr -d "\r" < /root/c.log | grep -v "^$" | tail -n1)" == "owner-session.sh: OK" ]]'
check "C warning shown before any change" bash -c 'awk "/can become root on THIS workstation/{w=NR} /1 packages/{p=NR} END{exit !(w && p && w<p)}" /root/c.log'
check "C consent recorded" grep -q "warning understood; no client data on this box" /root/c.log
check "C podman + tailscale installed" bash -c 'pacman -Q podman tailscale >/dev/null'
check "C drop-in 0440 root:root" test "$(stat -c '%a %U:%G' "$DROPIN")" = "440 root:root"
check "C visudo -c OK" visudo -c
check "C sudo -l -U agent: NOPASSWD: ALL" bash -c 'sudo -l -U agent | grep -q "(ALL : ALL) NOPASSWD: ALL"'
check "C agent: sudo -n works" runuser -u agent -- sudo -n true
runuser -u agent -- sudo -n echo iolog-probe >/dev/null 2>&1
check "C sudo logfile records agent commands" grep -q 'iolog-probe' /var/log/sudo-agent.log
check "C I/O log written under /var/log/sudo-io/agent (root-only)" bash -c '[[ -d /var/log/sudo-io/agent && "$(stat -c %a /var/log/sudo-io)" == 700 ]] && find /var/log/sudo-io/agent -name log -o -name log.json | grep -q .'
check "C sudoreplay lists the agent session" bash -c 'sudoreplay -d /var/log/sudo-io/agent -l 2>/dev/null | grep -q iolog-probe'
check "C 2 keyslots now (owner + team)" test "$(nslots)" = 2
slot="$(head -n1 "$SLOTREC" 2>/dev/null)"
check "C slot recorded ($slot)" bash -c '[[ "$1" =~ ^[0-9]+$ ]]' _ "$slot"
check "C key file 0400 agent 48 bytes" test "$(stat -c '%a %U %s' "$KF")" = "400 agent 48"
check "C key opens exactly the recorded slot" bash -c 'cryptsetup open --test-passphrase -v --key-file "$1" "$2" 2>&1 | grep -q "Key slot $3 unlocked"' _ "$KF" "$IMG" "$slot"
check "C owner passphrase still opens slot 0" bash -c 'cryptsetup open --test-passphrase -v --key-file /root/ownerpass "$1" 2>&1 | grep -q "Key slot 0 unlocked"' _ "$IMG"
check "C no root temp copies left" bash -c '! compgen -G "/root/.vdh-teamkey.*" && ! compgen -G "/root/.vdh-agent-sudoers.*"'
check "C generated key never in the session output" test "$(grep -cF -f "$KF" /root/c.log)" = 0
check "C owner passphrase never in the session output" test "$(grep -cF -f /root/ownerpass /root/c.log)" = 0
check "C tailscaled not enabled" bash -c '! [ -e /etc/systemd/system/multi-user.target.wants/tailscaled.service ]'

echo "== D idempotent re-run"
run_os /root/d.log; rc=$?
check "D exit 0" test "$rc" = 0
(( rc == 0 )) || sed 's/^/    d| /' /root/d.log | tail -25
check "D still 2 keyslots" test "$(nslots)" = 2
check "D drop-in unchanged" grep -q 'already installed, identical' /root/d.log
check "D keyslot not re-added" grep -q 'a team keyslot is already recorded' /root/d.log

echo "== E F1: agent plants a symlink for the key dir (fresh slot request)"
mv "$SLOTREC" /root/slotrec.keep
KEYSHA="$(sha256sum "$KF" | cut -d' ' -f1)"
mv /home/agent/.vdh-teamkey /root/teamkey.keep
runuser -u agent -- ln -s /etc /home/agent/.vdh-teamkey
before="$(stat -c '%U:%G %a' /etc)"
run_os /root/e.log; rc=$?
check "E refused" test "$rc" != 0
grep -q 'is a symlink; refusing' /root/e.log || sed 's/^/    e| /' /root/e.log | tail -15
check "E says symlink" grep -q 'is a symlink; refusing' /root/e.log
check "E /etc untouched and no key written there" bash -c '[[ "$(stat -c "%U:%G %a" /etc)" == "$1" && ! -e /etc/team-luks.key ]]' _ "$before"
check "E no extra keyslot" test "$(nslots)" = 2
rm -f /home/agent/.vdh-teamkey; mv /root/teamkey.keep /home/agent/.vdh-teamkey; mv /root/slotrec.keep "$SLOTREC"

echo "== F team pull (Mini side) with an ssh stub that runs box commands as agent"
cat > /root/ssh-stub <<'STUB'
#!/bin/bash
while [[ "$1" == -o ]]; do shift 2; done
shift   # host alias
exec runuser -l agent -c "$*"
STUB
chmod 0755 /root/ssh-stub
TEAMKEY_NO_TMUTIL_OK=1 SSH=/root/ssh-stub CONF=/root/miniconf bash mini/teamkey-pull.sh > /root/f.log 2>&1; rc=$?
sed 's/^/    | /' /root/f.log
check "F pull exit 0" test "$rc" = 0
check "F Mini copy 0400, 48 bytes, same sha256" bash -c '[[ "$(stat -c "%a %s" /root/miniconf/team-luks.key)" == "400 48" && "$(sha256sum /root/miniconf/team-luks.key | cut -d" " -f1)" == "$1" ]]' _ "$KEYSHA"
check "F box copy shredded, dir gone" test ! -e /home/agent/.vdh-teamkey
check "F pulled key opens the team slot" bash -c 'cryptsetup open --test-passphrase -v --key-file /root/miniconf/team-luks.key "$1" 2>&1 | grep -q "Key slot $2 unlocked"' _ "$IMG" "$slot"
check "F key never in the pull output" test "$(grep -cF -f /root/miniconf/team-luks.key /root/f.log)" = 0
TEAMKEY_NO_TMUTIL_OK=1 SSH=/root/ssh-stub CONF=/root/miniconf bash mini/teamkey-pull.sh > /root/f2.log 2>&1 && bad "F2 second pull overwrote" || ok "F2 second pull refuses (Mini copy exists)"

SSH=/root/ssh-stub CONF=/root/miniconf2 bash mini/teamkey-pull.sh > /root/f3.log 2>&1 && bad "F3 pull ran without tmutil and without the test override" || ok "F3 pull refuses without a Time Machine exclusion check"
echo "== G revoke paths work"
rm -f "$DROPIN"
check "G after removing the drop-in agent has no sudo" bash -c '! runuser -u agent -- sudo -n true 2>/dev/null'
cryptsetup luksKillSlot -q --key-file /root/ownerpass "$IMG" "$slot" >/dev/null 2>&1
check "G luksKillSlot removes the team slot; owner slot stays" bash -c '[[ "$(cryptsetup luksDump "$1" | awk "/^Keyslots:/{k=1;next} /^[A-Z][a-z]+:/{k=0} k && /^ +[0-9]+: luks2/{n++} END{print n+0}")" == 1 ]] && cryptsetup open --test-passphrase --key-file /root/ownerpass "$1"' _ "$IMG"

echo "RESULT: ${pass} passed, ${fail} failed"
(( fail == 0 ))
