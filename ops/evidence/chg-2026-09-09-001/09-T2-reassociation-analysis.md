# T2 — re-association analysis (Argus condition 3)

Authoritative test uses **`assoc_time`**, an absolute epoch, NOT the `uptime` field.
`uptime` in UniFi `stat/sta` is derived inconsistently per client and produced
misleading deltas on first pass; `assoc_time` is unambiguous.

| IP | HA entity | assoc_time PRE | assoc_time POST | re-assoc? | AP pre->post | network_id stable | IP stable |
|---|---|---|---|---|---|---|---|
| 172.16.4.20 | verlichting_schuur | 2026-09-08 07:22:29Z | 2026-09-08 07:22:29Z | no | same | yes | yes |
| 172.16.4.21 | sonos_keuken | 2026-08-04 23:04:59Z | 2026-09-09 12:54:04Z | **YES** | 56:e5->ac:52 | yes | yes |
| 172.16.4.22 | sonos_surround_rechtsachter | 2026-09-01 08:26:20Z | 2026-09-01 08:26:20Z | no | same | yes | yes |
| 172.16.4.23 | sonos_achtertuin | 2026-07-31 12:46:19Z | 2026-09-09 12:54:14Z | **YES** | same | yes | yes |
| 172.16.4.24 | sonos_surround_linksachter | 2026-08-28 13:02:55Z | 2026-09-09 12:54:38Z | **YES** | 65:43->ac:52 | yes | yes |
| 172.16.4.25 | sonos_play_1 | 2026-09-07 17:41:01Z | 2026-09-09 12:55:32Z | **YES** | ac:52->65:43 | yes | yes |
| 172.16.4.26 | sonos_arc_ultra | 2026-08-07 21:30:43Z | 2026-09-09 12:55:37Z | **YES** | 56:e5->65:43 | yes | yes |
| 172.16.4.27 | sonos_sub | 2026-09-01 01:03:53Z | 2026-09-09 12:55:43Z | **YES** | same | yes | yes |
| 172.16.4.28 | sonos_eetkamer | 2026-09-01 01:06:37Z | 2026-09-09 12:55:48Z | **YES** | same | yes | yes |
| 172.16.4.29 | sonos_bartafel | 2026-07-31 13:07:53Z | 2026-09-09 12:55:55Z | **YES** | same | yes | yes |

**8 of 10 re-associated.**

## Interpretation — this CONTRADICTS Argus's condition-3 prediction

Argus predicted: *"All nine are currently associated on `sta`, so disabling the unused
`sta1` slot should cause **zero** re-association."*

**Observed: 8 of 9 Part-B devices re-associated.** The prediction was wrong.

The attribution is clean and is not guesswork:

| | Part A only (cloud) | Part B (sta1) |
|---|---|---|
| device | `.20` | `.21`–`.29` |
| `SetConfig` returned | `restart_required: **false**` | `restart_required: **true**` |
| re-associated | **no** | **8 of 9** (all but `.22`) |

- `.20` received **only** Part A and did **not** re-associate → **Part A (cloud disable)
  causes zero Wi-Fi disruption.** Confirmed on all 10: no assoc_time moved during Part A.
- Every re-association timestamp falls inside 12:54:04Z–12:55:55Z, which is exactly my
  Part B execution window.
- Shelly's own return value predicted it: Part B returned `restart_required:true` while
  Part A returned `false`. **`WiFi.SetConfig` reinitialises the whole Wi-Fi stack, not just
  the mutated slot** — a partial-merge write is still a full-subsystem apply.
- `.22` not re-associating is the exception, not evidence against this; it simply
  completed the reinit without the controller logging a new association.

## Why the security outcome is nonetheless correct

Every device came back **on VDHIOT / IOT-VLAN**:
- `network_id` = `6226f5bddd6f9706a46a66cb` on **10/10**, unchanged, pre and post.
- IP unchanged on **10/10**, all still inside `172.16.4.0/23`.
- **Zero** devices landed on CLIENT-VLAN. Keyed on `network_id`, never `essid`, per the
  `net.wifi.vdhiot` dual-PPSK trap.
- Satisfaction 78–100. Four devices roamed to a different AP, which is normal BSSID
  re-selection on rejoin.

Crucially the ordering was safe: `sta1` was already disabled at the moment each device
re-joined, so the rejoin could **only** go to `sta`/VDHIOT. There was no window in which
a device could have fallen back onto the trusted VLAN.

## Operational consequence that must be carried forward (NEW risk, now real)

These nine devices are now **single-path**: `sta`=VDHIOT only, `sta1` disabled,
`ap.enable=false`. A Shelly that cannot join VDHIOT has **no fallback and no rescue AP**,
and becomes unrecoverable without physical access to the unit.

That is the intended posture (Argus: "the insurance IS the vulnerability") and the
CMDB records VDHIOT as having strictly broader coverage than VDHFEMFLEX (6/6 APs vs 5/6),
so a fallback could never have rescued coverage anyway. But combined with the newly
proven fact that **`WiFi.SetConfig` forces a full Wi-Fi reinit**, the rule is:

> **Never issue `WiFi.SetConfig` to a Shelly with marginal RF, and never to several at
> once, without accepting that each one will drop and re-join.** Part A (`Cloud.SetConfig`)
> is safe and disruption-free; Part B is not.

`restart_required:true` is now also latched on all nine (it was already latched on all
ten pre-change for unrelated reasons), so the next reboot — including the unattended
`auto_upgrade` at 03:00 — will re-apply this config. `cfg_rev` is persisted, so `sta1`
stays off across that reboot. That is the desired behaviour.
