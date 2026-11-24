#!/bin/bash
# vdhwslin01 (chg-2026-10-05-031, AGR-114): local-input sampler for idle-poweroff.
# Installed as /usr/local/libexec/vdh-runner/input-sampler, run as root by
# vdh-input-sampler.service on team boots only (ConditionPathExists=/run/team-boot).
#
# The agent cannot read /dev/input or Hyprland (measured 2026-10-29), so local use
# is read from the xhci_hcd (USB) interrupt count in /proc/interrupts, the same
# rule as the estate's pka-run sampler (estate_lib.py INPUT_SAMPLER): every 2 s
# take the delta; idle the count rises about 4/s, input adds far more. A delta is
# INPUT when delta > 2 * min(last 450 deltas) + 4 (a 15 min window).
# State, rewritten atomically every 2 s, root-owned in tmpfs:
#   /run/vdh-input-state: boot_id=, heartbeat= and since= (this sampler's start)
#   and last_input= (empty until input is seen), all in whole seconds of uptime.
# A restart in the same boot keeps last_input= but restarts since= (the quiet window
# cannot cover the gap). No xhci_hcd line in /proc/interrupts: no state is written, the
# heartbeat goes stale and idle-poweroff keeps the box on. Samples that count as input
# never enter the baseline, so sustained input cannot raise its own threshold. No state, a stale
# heartbeat or another boot's state makes idle-poweroff KEEP.
set -euo pipefail

if [[ "${VDH_SAMPLER_TEST:-0}" == "1" ]]; then
  ROOT="${VDH_SAMPLER_ROOT:?}"; TICK="${VDH_SAMPLER_TICK:-}"; MAX_ITER="${VDH_SAMPLER_ITER:?}"; PAUSE=0
else
  ROOT=""; TICK=""; MAX_ITER=0; PAUSE=2
fi
IRQ_NAMES="${VDH_IRQ_NAMES:-xhci_hcd}"
WINDOW=450
state="${ROOT}/run/vdh-input-state"

uptime_s() { cut -d. -f1 < "${ROOT}/proc/uptime"; }

irq_total() {
  awk -v names=" ${IRQ_NAMES} " '
    { last=$NF }
    index(names, " " last " ") { hit=1; for (i=2; i<=NF; i++) { if ($i !~ /^[0-9]+$/) break; t += $i } }
    END { if (!hit) exit 1; printf "%d\n", t }' "${ROOT}/proc/interrupts"
}

boot_id="$(tr -d '[:space:]' < "${ROOT}/proc/sys/kernel/random/boot_id")"
[[ -n "$boot_id" ]] || { echo "input-sampler: cannot read boot_id" >&2; exit 1; }
since="$(uptime_s)"
last_input=""
if [[ -f "$state" && ! -L "$state" ]] && [[ "$(sed -n 's/^boot_id=//p' "$state" | head -n1)" == "$boot_id" ]]; then
  l0="$(sed -n 's/^last_input=//p' "$state" | head -n1)"
  [[ "$l0" =~ ^[0-9]+$ ]] && last_input="$l0"
fi

deltas=()
previous=""
iter=0
while :; do
  iter=$((iter + 1))
  [[ -z "$TICK" ]] || "$TICK" "$iter"
  now="$(uptime_s)"
  if ! total="$(irq_total)" || [[ ! "$total" =~ ^[0-9]+$ ]]; then
    (( MAX_ITER == 0 || iter < MAX_ITER )) || break
    (( PAUSE == 0 )) || sleep "$PAUSE"
    continue
  fi
  if [[ -n "$previous" ]]; then
    d=$(( total - previous )); (( d >= 0 )) || d=0
    if (( ${#deltas[@]} )); then
      min="${deltas[0]}"; for x in "${deltas[@]}"; do (( x >= min )) || min="$x"; done
    else min="$d"; fi
    if (( d > 2 * min + 4 )); then last_input="$now"
    else
      deltas+=("$d")
      (( ${#deltas[@]} <= WINDOW )) || deltas=("${deltas[@]:1}")
    fi
  fi
  previous="$total"
  tmp="${state}.tmp"
  printf 'boot_id=%s\nheartbeat=%s\nsince=%s\nlast_input=%s\n' "$boot_id" "$now" "$since" "$last_input" > "$tmp"
  mv -f -- "$tmp" "$state"
  (( MAX_ITER == 0 || iter < MAX_ITER )) || break
  (( PAUSE == 0 )) || sleep "$PAUSE"
done
