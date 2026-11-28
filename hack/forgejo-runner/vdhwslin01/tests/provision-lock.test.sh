#!/usr/bin/env bash
# shellcheck disable=SC2034  # file-wide: PROV_LOCK/PROV_PROC/DRY are read by the sourced provision.sh
# chg-2026-11-28-101: provision.sh's provisioning lock against the REAL guard.
# Sources provision.sh, replaces the steps with stubs that fire an idle-poweroff
# tick mid-run (as the timer would between writing the guard and restarting the
# sampler), and checks the guard's decision on a fixture box that is otherwise
# idle enough to power off.
# Usage: tests/provision-lock.test.sh   (exit 0 = all pass)
# PROV_SUT / IDLE_SUT let tests/idle-poweroff.mutation.sh run this against mutants.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
PSUT="${PROV_SUT:-${here}/../provision.sh}"
ISUT="${IDLE_SUT:-${here}/../src/idle-poweroff.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/prov-lock.XXXXXX")"
trap 'find "${T:?}" -delete' EXIT
BOOT=0b5e1d2c-1111-2222-3333-444455556666
pass=0; fail=0

# box <name>: team boot, uptime 9000 s, no runner job this boot, no sessions,
# no inhibitors, input quiet since the sampler started at uptime 60.
box() {
  local d="$T/$1"
  mkdir -p "$d/bin" "$d/run/vdh-input" "$d/run/forgejo-runner" "$d/proc/sys/kernel/random"
  echo "$BOOT" > "$d/proc/sys/kernel/random/boot_id"
  printf 'started_by=team\nboot_id=%s\n' "$BOOT" > "$d/run/team-boot"
  echo "9000.50 1.00" > "$d/proc/uptime"
  printf 'boot_id=%s\nheartbeat=9000\nsince=60\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/loginctl"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemctl.calls"\n' "$d" > "$d/bin/systemctl"
  printf '#!/usr/bin/env bash\necho "No inhibitors."\n' > "$d/bin/systemd-inhibit"
  chmod +x "$d/bin/loginctl" "$d/bin/systemctl" "$d/bin/systemd-inhibit"
  echo "$d"
}

tick() { # tick <box>: one idle-poweroff run, decision line on stdout
  VDH_IDLE_TEST=1 VDH_IDLE_ROOT="$1" VDH_IDLE_LOGINCTL="$1/bin/loginctl" \
    VDH_IDLE_SYSTEMCTL="$1/bin/systemctl" VDH_IDLE_INHIBIT="$1/bin/systemd-inhibit" \
    VDH_IDLE_NOW=2000000000 bash "$ISUT" 2>&1 || true
}

check() { # check <name> <text> <expected substring>
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1: got [$2]"; fi
}

# provision <box> <steps csv> [<failing step>]: run_steps from the sourced provision.sh
# in a subshell; every stub step fires a tick and appends its decision to <box>/ticks.
provision() {
  local d="$1" steps="$2" failing="${3:-}"
  (
    # shellcheck source=/dev/null
    . "$PSUT"
    PROV_LOCK="$d/run/vdh-runner/provisioning"; PROV_PROC="$d/proc"; DRY="${PROV_DRY:-0}"
    IFS=, read -r -a STEPS <<<"$steps"
    for s in "${STEPS[@]}"; do
      eval "step_${s}() { echo \"${s}: \$(tick '$d')\" >> '$d/ticks'; [[ '${s}' != '${failing}' ]] || die 'stub ${s} failed'; }"
    done
    run_steps
  ) > "$d/provision.out" 2>&1
}

# 1. a full successful run: every tick after preflight KEEPs, the lock is gone after.
d="$(box ok)"
before="$(tick "$d")"
check "box is idle enough to power off before provisioning (fixture sanity)" "$before" "POWEROFF"
: > "$d/systemctl.calls"
if provision "$d" preflight,packages,payload,golden,services,report; then pass=$((pass+1)); echo "ok   provision run exits 0"
else fail=$((fail+1)); echo "FAIL provision run: $(cat "$d/provision.out")"; fi
for s in payload golden services report; do
  check "tick during step ${s} -> KEEP (provisioning in progress)" "$(grep "^${s}: " "$d/ticks" || true)" "KEEP: provisioning in progress"
done
check "preflight runs before the lock is taken (guard decides normally)" "$(grep '^preflight: ' "$d/ticks" || true)" "POWEROFF"
if [[ "$(cat "$d/systemctl.calls")" == "poweroff --check-inhibitors=no" ]]; then
  pass=$((pass+1)); echo "ok   one poweroff call (the preflight tick), none once the lock was taken"
else fail=$((fail+1)); echo "FAIL poweroff calls: $(cat "$d/systemctl.calls")"; fi
check "lock-taken line printed once" "$(grep -c "provisioning lock taken" "$d/provision.out")" "1"
if [[ ! -e "$d/run/vdh-runner/provisioning" ]]; then pass=$((pass+1)); echo "ok   lock released after a successful run"
else fail=$((fail+1)); echo "FAIL lock still present after success"; fi
check "after the run the guard decides normally again" "$(tick "$d")" "provisioning=none"

# 2. the gap itself: guard rewritten (payload) and sampler restarted (services) are
# separate steps; a tick between them, here in step golden, must KEEP.
d="$(box gap)"
provision "$d" preflight,payload,golden,services || true
check "tick between guard write and sampler restart -> KEEP" "$(grep '^golden: ' "$d/ticks" || true)" "KEEP: provisioning in progress"

# 3. a failed run keeps the lock; it holds the box < 2 h, then goes stale.
d="$(box failed)"
if provision "$d" preflight,payload,golden,services golden; then fail=$((fail+1)); echo "FAIL failing run exited 0"
else pass=$((pass+1)); echo "ok   failing run exits non-zero"; fi
check "lock carries this boot_id" "$(cat "$d/run/vdh-runner/provisioning" 2>/dev/null || true)" "boot_id=${BOOT}"
check "lock since = uptime at the last step" "$(cat "$d/run/vdh-runner/provisioning" 2>/dev/null || true)" "since=9000"
check "tick after a failed run (lock 0 s old) -> KEEP" "$(tick "$d")" "KEEP: provisioning in progress"
echo "16199.00 1.00" > "$d/proc/uptime"; printf 'boot_id=%s\nheartbeat=16199\nsince=60\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
check "same lock 7199 s later -> still KEEP" "$(tick "$d")" "KEEP: provisioning in progress (lock 7199s old"
echo "16200.00 1.00" > "$d/proc/uptime"; printf 'boot_id=%s\nheartbeat=16200\nsince=60\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
check "same lock 2 h later is stale -> POWEROFF" "$(tick "$d")" "provisioning=stale-7200s"

# 4. a dry run writes no lock.
d="$(box dry)"
PROV_DRY=1 provision "$d" preflight,payload,services || true
if [[ ! -e "$d/run/vdh-runner/provisioning" ]]; then pass=$((pass+1)); echo "ok   dry run writes no lock"
else fail=$((fail+1)); echo "FAIL dry run wrote a lock"; fi

# 5. symlink refusal: a planted symlink is never written through.
d="$(box symlink)"; mkdir -p "$d/run/vdh-runner"; : > "$d/target"; ln -s "$d/target" "$d/run/vdh-runner/provisioning"
if provision "$d" preflight,payload; then fail=$((fail+1)); echo "FAIL provision wrote through a symlinked lock"
else check "symlinked lock -> provision refuses" "$(cat "$d/provision.out")" "symlink; refusing"; fi
check "symlink target untouched" "$(wc -c < "$d/target" | tr -d ' ')" "0"

# 6. symlinked lock dir: provision refuses and writes nothing through it.
d="$(box dirsymlink)"; mkdir -p "$d/elsewhere"; ln -s "$d/elsewhere" "$d/run/vdh-runner"
if provision "$d" preflight,payload; then fail=$((fail+1)); echo "FAIL provision used a symlinked lock dir"
else check "symlinked lock dir -> provision refuses" "$(cat "$d/provision.out")" "is a symlink; refusing"; fi
check "nothing written through the symlinked dir" "$(find "$d/elsewhere" -type f | wc -l | tr -d ' ')" "0"

echo "provision-lock tests: ${pass} passed, ${fail} failed"
(( fail == 0 ))
