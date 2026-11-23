#!/usr/bin/env bash
# Unit tests for src/input-sampler.sh: fixture /proc, a tick script feeds the interrupt counts.
# Usage: tests/input-sampler.test.sh   (exit 0 = all pass)
# ok/bad always return 0 on purpose (SC2015).
# shellcheck disable=SC2015
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SUT="${here}/../src/input-sampler.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/sampler-test.XXXXXX")"
trap 'find "${T:?}" -delete' EXIT
BOOT=0b5e1d2c-1111-2222-3333-444455556666
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

# new_root <name> <plan>: plan = space separated per-tick increments of the xhci_hcd count
new_root() {
  local d="$T/$1"
  mkdir -p "$d/proc/sys/kernel/random" "$d/run"
  echo "$BOOT" > "$d/proc/sys/kernel/random/boot_id"
  echo "$2" > "$d/plan"; echo 1000 > "$d/uptime0"; echo 500 > "$d/total0"
  cat > "$d/tick" <<TICK
#!/usr/bin/env bash
d="$d"
i="\$1"
inc="\$(tr ' ' '\\n' < "\$d/plan" | sed -n "\${i}p")"
inc="\${inc:-8}"
echo \$(( \$(cat "\$d/total0") + inc )) > "\$d/total0"
echo \$(( \$(cat "\$d/uptime0") + 2 )) > "\$d/uptime0"
echo "\$(cat "\$d/uptime0").00 1.00" > "\$d/proc/uptime"
t="\$(cat "\$d/total0")"
printf '           CPU0       CPU1\\n  1:         5          5   IO-APIC   1-edge      i8042\\n 52:       %s        %s  PCI-MSI 1-edge   xhci_hcd\\n 53:       999        999  PCI-MSI 2-edge   xhci_hcd2\\n 54:       777        777  PCI-MSI 3-edge   nvme0q1\\n' "\$t" "\$t" > "\$d/proc/interrupts"
TICK
  chmod +x "$d/tick"
  echo "1000.00 1.00" > "$d/proc/uptime"
  printf '           CPU0\n 52:       500  PCI-MSI 1-edge   xhci_hcd\n' > "$d/proc/interrupts"
  echo "$d"
}
run() { # run <dir> <iterations>
  VDH_SAMPLER_TEST=1 VDH_SAMPLER_ROOT="$1" VDH_SAMPLER_TICK="$1/tick" VDH_SAMPLER_ITER="$2" bash "$SUT"
}
field() { sed -n "s/^$2=//p" "$1/run/vdh-input-state"; }

# 1. idle only (8 per 2 s tick, i.e. 4/s): never input
d="$(new_root idle "")"; run "$d" 40
[[ "$(field "$d" last_input)" == "" ]] && ok "idle at 4/s -> no input recorded" || bad "idle recorded input: $(cat "$d/run/vdh-input-state")"
[[ "$(field "$d" boot_id)" == "$BOOT" && "$(field "$d" heartbeat)" == 1080 && "$(field "$d" since)" == 1000 ]] \
  && ok "state carries boot_id, heartbeat 1080 and since 1000" || bad "state: $(cat "$d/run/vdh-input-state")"
[[ -f "$d/run/vdh-input-state" && ! -e "$d/run/vdh-input-state.tmp" ]] && ok "state present, no temp file left" || bad "state files"

# 2. a burst at tick 31 (200 interrupts in 2 s): input at that tick's uptime (1062)
plan="$(for _ in $(seq 1 30); do printf '8 '; done)200"
d="$(new_root burst "$plan")"; run "$d" 40
[[ "$(field "$d" last_input)" == 1062 ]] && ok "burst of 200 in 2 s -> last_input at that tick" || bad "burst: $(cat "$d/run/vdh-input-state")"

# 3. small wobble (8 -> 14) is below 2*8+4 = 20: not input
plan="$(for _ in $(seq 1 30); do printf '8 '; done)14 9 8"
d="$(new_root wobble "$plan")"; run "$d" 40
[[ "$(field "$d" last_input)" == "" ]] && ok "wobble 14 per tick is not input" || bad "wobble: $(cat "$d/run/vdh-input-state")"

# 4. a restart in the same boot keeps since and last_input
cp "$T/burst/run/vdh-input-state" "$T/restart-state"
d="$(new_root restart "")"; cp "$T/restart-state" "$d/run/vdh-input-state"; run "$d" 5
[[ "$(field "$d" since)" == 1000 && "$(field "$d" last_input)" == 1062 ]] && ok "restart keeps since and last_input" || bad "restart: $(cat "$d/run/vdh-input-state")"

# 5. state of another boot is not inherited
d="$(new_root newboot "")"; printf 'boot_id=old\nheartbeat=5\nsince=1\nlast_input=3\n' > "$d/run/vdh-input-state"; run "$d" 5
[[ "$(field "$d" boot_id)" == "$BOOT" && "$(field "$d" last_input)" == "" ]] && ok "other boot's state ignored" || bad "newboot: $(cat "$d/run/vdh-input-state")"

echo "input-sampler tests: ${pass} passed, ${fail} failed"
(( fail == 0 ))
