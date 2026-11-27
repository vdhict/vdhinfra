#!/usr/bin/env bash
# vdhwslin01 idle-poweroff (chg-2026-10-05-031, AGR-114 + AGR-115, Argus R10).
#
# Installed as /usr/local/libexec/vdh-runner/idle-poweroff, run as root by
# idle-poweroff.timer every 5 minutes. It powers the box off ONLY when ALL hold:
#   1. /run/team-boot exists, says started_by=team and carries THIS boot's
#      boot_id. It is written in the initramfs by the ssh unlock path
#      (vdh-teamboot); Sander's own boots (console unlock) never have it.
#   2. uptime >= 2 h.
#   3. the runner has no job (/run/forgejo-runner/job-active absent) and the
#      last job ended >= 60 min ago.
#   4. nobody else is using the box (rules shared with the estate, pka-run
#      guard_blocks/input_guard_blocks, AGR-114):
#      - ignore up to one local seat0 user session that began within 180 s
#        of boot (the Hyprland autologin); other user sessions mean KEEP;
#      - no audio is playing according to ALSA PCM status;
#      - no input for >= 60 min, read from the xhci_hcd interrupt counts that
#        vdh-input-sampler (src/input-sampler.sh) writes to /run/vdh-input/state.
#        No state, stale state or another boot's state: KEEP.
#   5. no logind block (or block-weak) inhibitor on shutdown, checked by this
#      script from `systemd-inhibit --list` (wq-157). Delay locks stay honoured
#      by logind itself.
# Power-off is then `systemctl poweroff --check-inhibitors=no`: systemctl's own
# client-side check (=yes) also refuses on ANY other logged-in user, and the
# tty1 autologin plus agent ssh exist on every team boot, so =yes could never
# succeed (inc 2026-11-27T01:11:40Z). Rule 4a is the session check instead.
# Known gap: a block lock taken between check 5 and the poweroff call (ms).
# Anything it cannot read means KEEP (fail safe: never power off on doubt).
# Every decision is one line on stdout, which systemd writes to the journal.
set -euo pipefail

# Test seam: tests/idle-poweroff.test.sh points these at fixtures and stubs.
# The systemd unit runs with a clean environment, so production never sets it.
if [[ "${VDH_IDLE_TEST:-0}" == "1" ]]; then
  ROOT="${VDH_IDLE_ROOT:?}"
  LOGINCTL="${VDH_IDLE_LOGINCTL:?}"
  SYSTEMCTL="${VDH_IDLE_SYSTEMCTL:?}"
  INHIBIT="${VDH_IDLE_INHIBIT:?}"
  NOW="${VDH_IDLE_NOW:?}"
else
  ROOT=""
  LOGINCTL="loginctl"
  SYSTEMCTL="systemctl"
  INHIBIT="systemd-inhibit"
  NOW="$(date +%s)"
fi

AUTOLOGIN_WINDOW_US=180000000
INPUT_QUIET_MIN_S=3600
INPUT_HEARTBEAT_MAX_S=30
RUNNER_IDLE_MIN_S=3600
UPTIME_MIN_S=7200
# Sessions of these users never block (agent = team ssh, runner = CI service).
EXCLUDED_USERS=" agent runner "

keep() {
  echo "idle-poweroff: KEEP: $*"
  exit 0
}

# --- 1. team-started boot of THIS boot -------------------------------------
marker="${ROOT}/run/team-boot"
[[ -f "$marker" ]] || keep "no /run/team-boot (not a team-started boot)"
boot_id="$(tr -d '[:space:]' < "${ROOT}/proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
[[ -n "$boot_id" ]] || keep "cannot read boot_id"
grep -qx 'started_by=team' "$marker" || keep "marker does not say started_by=team"
grep -qx "boot_id=${boot_id}" "$marker" || keep "marker boot_id does not match this boot"

# --- 2. minimum uptime -------------------------------------------------------
uptime_s="$(cut -d. -f1 < "${ROOT}/proc/uptime" 2>/dev/null || true)"
[[ "$uptime_s" =~ ^[0-9]+$ ]] || keep "cannot read uptime"
(( uptime_s >= UPTIME_MIN_S )) || keep "uptime ${uptime_s}s < ${UPTIME_MIN_S}s"

# --- 3. runner idle ---------------------------------------------------------
# /run/forgejo-runner is runner-owned: never follow a symlink there as root.
[[ ! -L "${ROOT}/run/forgejo-runner/job-active" && ! -L "${ROOT}/run/forgejo-runner/last-job-end" ]] \
  || keep "symlink in /run/forgejo-runner"
[[ ! -e "${ROOT}/run/forgejo-runner/job-active" ]] || keep "runner has a job"
last_end_file="${ROOT}/run/forgejo-runner/last-job-end"
if [[ -f "$last_end_file" ]]; then
  last_end="$(tr -d '[:space:]' < "$last_end_file")"
  [[ "$last_end" =~ ^[0-9]+$ ]] || keep "unreadable last-job-end"
  runner_idle=$(( NOW - last_end ))
  (( runner_idle >= RUNNER_IDLE_MIN_S )) || keep "last job ended ${runner_idle}s ago < ${RUNNER_IDLE_MIN_S}s"
else
  runner_idle="none-this-boot"
fi

# --- 4. is anybody else using the box? ---------------------------------------
prop() { # prop <key> <text>
  sed -n "s/^$1=//p" <<<"$2" | head -n1
}

# 4a. sessions: ignore at most one early local seat0 session.
sessions="$("$LOGINCTL" list-sessions --no-legend 2>/dev/null)" \
  || keep "cannot list logind sessions"
autologin_seen=0
while read -r sid _; do
  [[ -n "${sid:-}" ]] || continue
  info="$("$LOGINCTL" show-session "$sid" -p Name -p Class -p Remote -p Seat -p TimestampMonotonic 2>/dev/null)" \
    || keep "cannot read session ${sid}"
  name="$(prop Name "$info")"
  class="$(prop Class "$info")"
  [[ -n "$class" && -n "$name" ]] || keep "session ${sid} has no readable Name/Class"
  [[ "$class" == user* ]] || continue
  [[ "$EXCLUDED_USERS" != *" ${name} "* ]] || continue
  remote="$(prop Remote "$info")"
  [[ "$remote" != "yes" ]] || keep "remote session ${sid} (${name})"
  [[ "$remote" == "no" ]] || keep "session ${sid} (${name}) Remote unreadable: treated as remote"
  [[ "$(prop Seat "$info")" == "seat0" ]] || keep "session ${sid} (${name}) is not on seat0"
  started_us="$(prop TimestampMonotonic "$info")"
  [[ "$started_us" =~ ^[0-9]+$ ]] || keep "session ${sid} (${name}) has no readable start time"
  (( started_us <= AUTOLOGIN_WINDOW_US )) \
    || keep "session ${sid} (${name}) began $(( started_us / 1000000 )) s after boot (a login, not the autologin)"
  (( autologin_seen == 0 )) || keep "additional early seat0 session ${sid} (${name})"
  autologin_seen=1
done <<<"$sessions"

# 4b. audio: ALSA reports RUNNING for active PCM streams.
shopt -s nullglob
for status in "${ROOT}"/proc/asound/card*/pcm*/sub*/status; do
  if grep -Ex '[[:space:]]*(state:[[:space:]]*)?RUNNING[[:space:]]*' "$status" >/dev/null 2>&1; then
    keep "audio is playing"
  elif (( $? != 1 )); then
    keep "cannot read audio status ${status#"$ROOT"}"
  fi
done

# 4c. input: the sampler's state. Missing, stale or foreign state means KEEP.
state="${ROOT}/run/vdh-input/state"
[[ -f "$state" && ! -L "$state" ]] || keep "input activity unknown (no ${state#"$ROOT"})"
snap="$(cat "$state" 2>/dev/null)" || keep "input activity unknown (state unreadable)"   # one read: no mixed snapshots
for k in boot_id heartbeat since last_input; do
  grep -q "^${k}=" <<<"$snap" || keep "input activity unknown (state lacks ${k})"
done
st_boot="$(prop boot_id "$snap")"
st_beat="$(prop heartbeat "$snap")"
st_since="$(prop since "$snap")"
st_last="$(prop last_input "$snap")"
[[ "$st_boot" == "$boot_id" ]] || keep "input activity unknown (state is from another boot)"
[[ "$st_beat" =~ ^[0-9]+$ && "$st_since" =~ ^[0-9]+$ ]] || keep "input activity unknown (state unreadable)"
[[ -z "$st_last" || "$st_last" =~ ^[0-9]+$ ]] || keep "input activity unknown (last_input unreadable)"
beat_age=$(( uptime_s - st_beat ))
(( beat_age >= 0 && beat_age <= INPUT_HEARTBEAT_MAX_S )) || keep "input activity unknown (sampler heartbeat ${beat_age}s old)"
# Quiet time counts from the later of: last input seen, sampler start (it cannot vouch for earlier).
quiet_from="$st_since"
if [[ -n "$st_last" ]] && (( st_last > quiet_from )); then quiet_from="$st_last"; fi
quiet_s=$(( uptime_s - quiet_from ))
(( quiet_s >= 0 )) || keep "input activity unknown (input time in the future)"
(( quiet_s >= INPUT_QUIET_MIN_S )) || keep "local input ${quiet_s}s ago < ${INPUT_QUIET_MIN_S}s (AGR-114)"

# --- 5. no block inhibitor on shutdown ---------------------------------------
# Columns: WHO UID USER PID COMM WHAT WHY MODE. WHO and WHY may hold spaces, so
# MODE is the last field and WHAT is matched as any field naming "shutdown" in
# its colon list (a WHY word "shutdown" also matches: fail safe). An unknown
# layout or an unknown mode means KEEP. No block lock is known-harmless: the box
# holds only delay locks (NetworkManager, UPower, Omarchy; evidence 101).
inhibitors="$("$INHIBIT" --list --mode=block --no-pager 2>/dev/null)" \
  || keep "cannot list logind inhibitors"
header_seen=0
while read -r -a f; do
  (( ${#f[@]} > 0 )) || continue
  if [[ "${f[*]}" == "No inhibitors." ]]; then header_seen=1; continue; fi   # systemd's empty-table line
  if (( header_seen == 0 )); then
    [[ "${f[0]}" == WHO && "${f[${#f[@]}-1]}" == MODE ]] || keep "inhibitor list layout unknown"
    header_seen=1; continue
  fi
  [[ "${f[*]}" =~ ^[0-9]+\ inhibitors?\ listed\.$ ]] && continue
  mode="${f[${#f[@]}-1]}"
  case "$mode" in
    delay) continue ;;
    block|block-weak) ;;
    *) keep "inhibitor with unknown mode ${mode}" ;;
  esac
  for field in "${f[@]}"; do
    [[ ":${field}:" != *":shutdown:"* ]] || keep "${mode} inhibitor on shutdown held by ${f[0]}"
  done
done <<<"$inhibitors"
(( header_seen == 1 )) || keep "inhibitor list empty or layout unknown"

# --- 6. power off ------------------------------------------------------------
echo "idle-poweroff: POWEROFF: started_by=team boot_id=${boot_id} uptime=${uptime_s}s input_quiet=${quiet_s}s runner_idle=${runner_idle}"
if ! "$SYSTEMCTL" poweroff --check-inhibitors=no; then
  echo "idle-poweroff: KEEP: systemctl poweroff refused"
fi
