#!/usr/bin/env bash
# vdhwslin01: Sander's ONE sudo session (chg-2026-10-05-031; owner decisions 2026-11-03 via Larry 165632:
# B5 = a, team LUKS keyslot; standing sudo for the team account `agent`).
#
#   sudo bash owner-session.sh --dry-run    # checks + plan, changes nothing
#   sudo bash owner-session.sh              # does it; asks ONCE for your existing disk passphrase
#
# It does exactly four things, each idempotent and read back:
#   1 packages  pacman -S --needed podman tailscale (tailscaled is NOT enabled; the team does
#               that later with a single-use key, chg-2026-11-02-012 S4)
#   2 sudo      /etc/sudoers.d/50-agent-team (fixed name): agent ALL=(ALL:ALL) NOPASSWD: ALL, with
#               output logging (sudo I/O log, /var/log/sudo-io/agent, root 0700) + a sudo logfile
#               + journald (sudo's default syslog). Validated with visudo -cf BEFORE it is installed.
#               Revoke any time:  sudo rm /etc/sudoers.d/50-agent-team
#   3 keyslot   a NEW random team passphrase (48 chars A-Za-z0-9) is generated here as root and
#               added as an extra LUKS keyslot. cryptsetup asks YOU for your existing passphrase
#               (typed at the prompt, never stored, never in a file). Your own keyslot is untouched.
#               The slot number goes to /etc/vdh-runner/team-keyslot.
#               Revoke any time:  sudo cryptsetup luksKillSlot <device> <slot>
#               The team key is handed to agent as ~agent/.vdh-teamkey/team-luks.key (0400). The
#               team pulls it to the Mini and shreds this copy (mini/teamkey-pull.sh). It is never printed.
#   4 report    what to send back (no secrets in it)
# Everything else (runner provisioning, tailscale up) the team does later through agent's sudo.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
DROPIN=/etc/sudoers.d/50-agent-team
IOLOG_ROOT=/var/log/sudo-io
AGENT=agent
KEYDIR=/home/agent/.vdh-teamkey
KEYFILE="$KEYDIR/team-luks.key"
SLOTREC=/etc/vdh-runner/team-keyslot
LUKS_DEV="${LUKS_DEV:-}"          # auto-detected; the override exists for the container test only
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1

say()  { echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

dropin_content() {
cat <<'EOF'
# chg-2026-10-05-031: owner decision 2026-11-03 (via Larry 165632): standing sudo for the team
# account `agent` on vdhwslin01 (AGR-099: visible and logged). Installed by owner-session.sh.
# Revoke:  sudo rm /etc/sudoers.d/50-agent-team   (check: sudo -l -U agent shows no rules)
# Logging: every command -> journald (sudo default syslog) + /var/log/sudo-agent.log;
#          terminal OUTPUT of every agent sudo session -> /var/log/sudo-io/agent (root 0700).
#          Input is NOT logged on purpose (a secret typed or piped into a command must not land
#          in a log); replay with: sudo sudoreplay -d /var/log/sudo-io/agent -l
Defaults:agent log_output
Defaults:agent !log_input
Defaults:agent iolog_dir=/var/log/sudo-io/%{user}
Defaults:agent logfile=/var/log/sudo-agent.log
agent ALL=(ALL:ALL) NOPASSWD: ALL
EOF
}

# ---------------------------------------------------------------------------
say "preflight"
(( EUID == 0 )) || die "run it with sudo: sudo bash $0"
[[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root && "${SUDO_USER}" != "$AGENT" ]] \
  || die "run it as YOURSELF with sudo (SUDO_USER is '${SUDO_USER:-}'), not as root or agent"
id "$AGENT" >/dev/null 2>&1 || die "user $AGENT does not exist"
g=" $(id -nG "$AGENT") "
[[ "$g" != *" wheel "* && "$g" != *" sudo "* ]] || die "$AGENT is already in wheel/sudo ($g): stop and tell the team"
grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers || die "/etc/sudoers has no includedir /etc/sudoers.d"
for c in visudo cryptsetup shred blkid runuser sha256sum; do command -v "$c" >/dev/null || die "$c missing"; done
if [[ -z "$LUKS_DEV" ]]; then
  mapfile -t devs < <(blkid -t TYPE=crypto_LUKS -o device)
  (( ${#devs[@]} == 1 )) || die "expected exactly one LUKS device, found ${#devs[@]}: ${devs[*]:-none}"
  LUKS_DEV="${devs[0]}"
fi
cryptsetup isLuks "$LUKS_DEV" || die "$LUKS_DEV is not LUKS"
info "you: ${SUDO_USER}; team account: $AGENT (groups:${g}); disk: $LUKS_DEV"
(( DRY )) && info "DRY RUN: nothing will change"

# ---------------------------------------------------------------------------
say "1 packages: podman tailscale (tailscaled stays disabled)"
missing=()
for p in podman tailscale; do
  if pacman -Q "$p" >/dev/null 2>&1; then info "installed: $(pacman -Q "$p")"; else missing+=("$p"); fi
done
if (( ${#missing[@]} )); then
  if (( DRY )); then info "[dry-run] would: pacman -S --needed --noconfirm ${missing[*]}"
  else
    pacman -S --needed --noconfirm "${missing[@]}" \
      || die "pacman failed. Arch does not do partial upgrades: run 'sudo pacman -Syu' first, then this script again."
  fi
fi

# ---------------------------------------------------------------------------
say "2 sudo for $AGENT: $DROPIN"
tmp="$(mktemp /root/.vdh-agent-sudoers.XXXXXX)"
dropin_content > "$tmp"
visudo -cf "$tmp" >/dev/null || { shred -u "$tmp"; die "visudo rejects the drop-in; nothing installed"; }
if [[ -e "$DROPIN" || -L "$DROPIN" ]]; then
  if [[ ! -L "$DROPIN" && "$(sha256sum < "$tmp")" == "$(sha256sum < "$DROPIN")" ]]; then info "already installed, identical"
  else shred -u "$tmp"; die "$DROPIN exists with OTHER content (or is a symlink); not touching it. Tell the team."; fi
elif (( DRY )); then info "[dry-run] would install $DROPIN (0440 root:root) after visudo -cf: OK"
else
  install -d -o root -g root -m 0700 "$IOLOG_ROOT"
  install -o root -g root -m 0440 "$tmp" "$DROPIN"
  if ! visudo -c >/dev/null; then
    mv -f "$DROPIN" "/root/50-agent-team.rejected.$(date +%s)"
    shred -u "$tmp"; die "visudo -c failed after install; drop-in moved away, sudo unchanged"
  fi
  info "installed $DROPIN; visudo -c OK"
fi
shred -u "$tmp"
if (( ! DRY )); then
  sudo -l -U "$AGENT" | grep -q 'NOPASSWD: ALL' || die "read-back: sudo -l -U $AGENT shows no NOPASSWD: ALL"
  info "read-back: $(sudo -l -U "$AGENT" | grep 'NOPASSWD: ALL' | sed 's/^ *//')"
fi

# ---------------------------------------------------------------------------
say "3 team LUKS keyslot on $LUKS_DEV"
slot_of_file() { cryptsetup open --test-passphrase -v --key-file "$1" "$LUKS_DEV" 2>/dev/null | sed -n 's/^Key slot \([0-9]*\) unlocked.*/\1/p' | head -n1; }
nslots() { cryptsetup luksDump "$LUKS_DEV" | awk '/^Keyslots:/{k=1;next} /^[A-Z][a-z]+:/{k=0} k && /^ +[0-9]+: luks2/{n++} END{print n+0}'; }
if [[ -s "$SLOTREC" ]]; then
  info "a team keyslot is already recorded: $(head -n1 "$SLOTREC"); nothing to add (revoke first to replace it)"
elif (( DRY )); then
  info "keyslots now: $(nslots)"
  info "[dry-run] would: generate a 48-char random team passphrase (root-only temp file), cryptsetup luksAddKey $LUKS_DEV (asks YOUR passphrase), test it, record the slot, hand the key to $AGENT as $KEYFILE (0400), shred the temp file"
else
  [[ ! -e "$KEYFILE" && ! -L "$KEYFILE" ]] || die "$KEYFILE already exists; the team has not pulled the previous key. Stop."
  # agent's home: everything there is created BY agent (no root write into an agent-controlled path).
  [[ ! -L "$KEYDIR" ]] || die "$KEYDIR is a symlink; refusing"
  if [[ ! -e "$KEYDIR" ]]; then runuser -u "$AGENT" -- install -d -m 0700 "$KEYDIR"; fi
  [[ -d "$KEYDIR" && ! -L "$KEYDIR" && "$(stat -c %U "$KEYDIR")" == "$AGENT" ]] || die "$KEYDIR is not an $AGENT-owned directory; refusing"
  k="$(mktemp /root/.vdh-teamkey.XXXXXX)"
  set +o pipefail
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 > "$k"
  set -o pipefail
  if [[ "$(wc -c < "$k")" -ne 48 ]] || ! LC_ALL=C grep -qxE '[A-Za-z0-9]{48}' "$k"; then shred -u "$k"; die "key generation failed"; fi
  before="$(nslots)"
  echo
  echo "    >>> cryptsetup will now ask for YOUR EXISTING disk passphrase (the one you type at boot)."
  echo "    >>> It is used once to authorise the new team slot and is not stored anywhere."
  if ! cryptsetup luksAddKey "$LUKS_DEV" "$k" </dev/tty; then shred -u "$k"; die "luksAddKey failed (wrong passphrase?); nothing changed"; fi
  slot="$(slot_of_file "$k")"
  after="$(nslots)"
  if [[ -z "$slot" ]] || (( after != before + 1 )); then shred -u "$k"; die "read-back failed: slot='${slot}' keyslots ${before}->${after}"; fi
  install -d -o root -g root -m 0755 "$(dirname "$SLOTREC")"
  printf '%s\n# chg-2026-10-05-031 team keyslot, added %s by %s; revoke: cryptsetup luksKillSlot %s %s\n' \
    "$slot" "$(date -u +%FT%TZ)" "$SUDO_USER" "$LUKS_DEV" "$slot" > "$SLOTREC"
  chmod 0644 "$SLOTREC"
  # hand-over: agent writes its own file (umask 377 -> 0400, noclobber); root only supplies stdin
  runuser -u "$AGENT" -- sh -c "umask 377; set -C; cat > '$KEYFILE'" < "$k" || { shred -u "$k"; die "could not hand the key to $AGENT"; }
  shred -u "$k"
  [[ -f "$KEYFILE" && ! -L "$KEYFILE" && "$(stat -c '%a %U %s' "$KEYFILE")" == "400 $AGENT 48" ]] || die "read-back: $KEYFILE is not 0400 $AGENT 48 bytes"
  info "team keyslot $slot added and tested (keyslots ${before} -> ${after}); your own slot is untouched"
  info "key handed to $AGENT: $KEYFILE (0400, 48 bytes); the root temp copy is shredded"
fi

# ---------------------------------------------------------------------------
say "4 SEND THIS BACK to the team (no secrets in it)"
info "owner-session.sh sha256: $(sha256sum "$0" | cut -d' ' -f1)"
info "packages: $(pacman -Q podman 2>/dev/null || echo 'podman missing'); $(pacman -Q tailscale 2>/dev/null || echo 'tailscale missing')"
info "tailscaled: $(systemctl is-enabled tailscaled 2>/dev/null || true) (expected: disabled or empty)"
info "sudo drop-in: $(stat -c '%a %U:%G' "$DROPIN" 2>/dev/null || echo absent) $DROPIN"
info "agent sudo: $(sudo -l -U "$AGENT" 2>/dev/null | grep -c 'NOPASSWD: ALL') NOPASSWD rule(s)"
info "team keyslot: $(head -n1 "$SLOTREC" 2>/dev/null || echo none)"
info "team key for pull: $(stat -c '%a %U %s bytes' "$KEYFILE" 2>/dev/null || echo absent)"
say "done$( (( DRY )) && echo ' (dry run: nothing changed)')"
