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
#   4. seat0 IdleHint=yes for >= 60 min, and every other user session (not
#      agent/runner) is idle >= 60 min as well.
#   5. no logind block inhibitor (systemctl --check-inhibitors=yes).
# Anything it cannot read means KEEP (fail safe: never power off on doubt).
# Every decision is one line on stdout, which systemd writes to the journal.
set -euo pipefail

# Test seam: tests/idle-poweroff.test.sh points these at fixtures and stubs.
# The systemd unit runs with a clean environment, so production never sets it.
if [[ "${VDH_IDLE_TEST:-0}" == "1" ]]; then
  ROOT="${VDH_IDLE_ROOT:?}"
  LOGINCTL="${VDH_IDLE_LOGINCTL:?}"
  SYSTEMCTL="${VDH_IDLE_SYSTEMCTL:?}"
  NOW="${VDH_IDLE_NOW:?}"
else
  ROOT=""
  LOGINCTL="loginctl"
  SYSTEMCTL="systemctl"
  NOW="$(date +%s)"
fi

SEAT_IDLE_MIN_S=3600
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

# --- 4. interactive idleness (logind) ----------------------------------------
# idle_age <IdleHint> <IdleSinceHint-usec> -> prints seconds idle, or "busy"
idle_age() {
  local hint="$1" since_us="$2"
  if [[ "$hint" != "yes" ]]; then echo busy; return; fi
  [[ "$since_us" =~ ^[0-9]+$ ]] || { echo busy; return; }
  echo $(( NOW - since_us / 1000000 ))
}

prop() { # prop <key> <text>
  sed -n "s/^$1=//p" <<<"$2" | head -n1
}

seat="$("$LOGINCTL" show-seat seat0 -p IdleHint -p IdleSinceHint 2>/dev/null)" \
  || keep "cannot read seat0 from logind"
seat_age="$(idle_age "$(prop IdleHint "$seat")" "$(prop IdleSinceHint "$seat")")"
[[ "$seat_age" != busy ]] || keep "seat0 IdleHint=no (someone is using the desktop)"
(( seat_age >= SEAT_IDLE_MIN_S )) || keep "seat0 idle ${seat_age}s < ${SEAT_IDLE_MIN_S}s"

sessions="$("$LOGINCTL" list-sessions --no-legend 2>/dev/null)" \
  || keep "cannot list logind sessions"
while read -r sid _; do
  [[ -n "${sid:-}" ]] || continue
  info="$("$LOGINCTL" show-session "$sid" -p Name -p Class -p IdleHint -p IdleSinceHint 2>/dev/null)" \
    || keep "cannot read session ${sid}"
  name="$(prop Name "$info")"
  class="$(prop Class "$info")"
  [[ "$class" == "user" ]] || continue
  [[ "$EXCLUDED_USERS" != *" ${name} "* ]] || continue
  age="$(idle_age "$(prop IdleHint "$info")" "$(prop IdleSinceHint "$info")")"
  [[ "$age" != busy ]] || keep "session ${sid} (${name}) is active"
  (( age >= SEAT_IDLE_MIN_S )) || keep "session ${sid} (${name}) idle ${age}s < ${SEAT_IDLE_MIN_S}s"
done <<<"$sessions"

# --- 5. power off ------------------------------------------------------------
echo "idle-poweroff: POWEROFF: started_by=team boot_id=${boot_id} uptime=${uptime_s}s seat0_idle=${seat_age}s runner_idle=${runner_idle}"
if ! "$SYSTEMCTL" poweroff --check-inhibitors=yes; then
  echo "idle-poweroff: KEEP: systemctl poweroff refused (inhibitor?)"
fi
