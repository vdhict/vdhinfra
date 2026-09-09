# chg-2026-09-09-007 — test log

All timestamps UTC. HA 2026.9.0, pod home-assistant-69ccfbff69-jrhsq, container app.

## File integrity

| | value |
|---|---|
| baseline /config/automations.yaml | 105637 B, md5 `bf1978a91a4996aa4f76b115bb9ca216` |
| shipped | 115878 B, md5 `917b92e088b3c08b0fafd83e24a45840` |
| write method | `kubectl cp` (never `exec 'cat >'` — 64 KiB silent truncation) |
| append-only proof | md5 of the first 105637 bytes of the shipped file == baseline md5, exactly |
| parsed | 50 → 52 automations; `old == new[:50]` True; ids unique |
| in-pod backup | /config/automations.yaml.chg007.bak |

## T2 check_config — PASS
`POST /api/config/core/check_config` → `{"result":"valid","errors":null,"warnings":null}` before every reload.

## T3 targeted reload, not a restart — PASS
`sensor.uptime` = `2026-09-07T14:34:35+00:00` before AND after all three reloads. A restart would have moved it.

Reload instants (HA-side, from the new automation entities' `last_changed`):

| # | instant | why |
|---|---|---|
| 1 | 2026-09-09T16:00:59.144649Z | initial install |
| 2 | 2026-09-09T16:03:31.354659Z | fix: use live friendly_name (wrong-room hazard) |
| 3 | 2026-09-09T16:07:23.934296Z | fix: count/list predicate divergence |

## T4 inventory — PASS
- 52 automation entities live; all 50 pre-existing ids still present (set difference empty).
- `automation.kantoor_adaptieve_verlichting` (1734200001012): state `on`, `last_changed` **still 2026-09-09T15:20:32.273885+00:00** — i.e. Atlas's observation-window marker was NOT reset by any reload — and `last_triggered` preserved.
- `automation.kantoor_focus_mode_lichten_herstellen` (1734200001004): still `off`. Not re-enabled.

## T5 END-TO-END — PASS (real push, real unavailable Shelly)

Vector: `homeassistant.reload_config_entry` on `switch.verlichting_schuur`. This cycles only HA's own
outbound websocket to the relay. The device is never rebooted, never power-cycled, no `WiFi.SetConfig`,
no load interruption, and it is the shed light — not a Sonos relay. Measured window ≈3 s of genuine
`unavailable` (77 of 120 rapid polls).

Fired `shelly_watchdog_test {"dwell":0}` while the relay was genuinely `unavailable`.

| proof | result |
|---|---|
| `notify.s25_ultra_sander` (the house's own delivery-proof entity, used by `notify_path_watchdog`) | advanced `2026-09-09T16:05:51.637854Z` → **`2026-09-09T16:08:21.650647Z`** |
| automation `last_triggered` | 2026-09-09T16:08:21.434461Z |
| actual payload dispatched to the phone (from HA's execution trace, run 0467effd61422c0ada57945a642adedc) | see `05-t5-actual-phone-payload-from-ha-trace.txt` |
| persistent_notification | see `06-t5-persistent-notification-body.txt` |
| relay afterwards | recovered to `off`; UniFi tracker `home`; all ten trackers `home` |

Rendered message (title + body), verbatim from the trace:

```
Shelly relais onbereikbaar (1/10)
- Verlichting Schuur (172.16.4.20) - 0 s, wifi verbonden, maar HA krijgt geen verbinding
```

The wifi discriminator behaved correctly: the UniFi tracker still read `home`, so the message said
"verbonden, maar HA krijgt geen verbinding" and did NOT tell the user to walk to the shed. That is the
intended associated-but-unreachable case.

## T6 NEGATIVE — PASS (stronger than planned)
With all ten watched relays available, `shelly_watchdog_test {"dwell":0}` produced **no** push
(`notify.s25_ultra_sander` unchanged) and **no** persistent notification.

Stronger than planned because at that moment four *other* Shelly-adjacent switches were genuinely
`unavailable` — `switch.sonos_move_crossfade`, `sonos_move_loudness`, `sonos_move_tv_autoplay`,
`sonos_move_groep_opheffen_bij_autoplay` — and the hard 10-entity allowlist ignored all of them.
That is the ~375-unavailable-entity noise scenario demonstrated live, not argued.

## T7 dwell constant — PASS
See `02-dwell-derivation.md`. 827 s → 0 false pages across 1196 benign episodes / 8 days.

## Two real defects the end-to-end test caught (neither was visible in a template render)

1. **Wrong-room hazard.** The first build hardcoded display names. Live HA has since renamed
   `switch.sonos_eetkamer` → "Sonos Keuken stereopaar (2 van 2)" and `switch.sonos_keuken` →
   "(1 van 2)", exactly as the CMDB warned ("PLUG LABELS ARE NOT RELIABLE"). The alert would have
   named a room that does not correspond to the dead speaker. Fixed: message now uses the live
   `state_attr(e,'friendly_name')`, static list is fallback only.

2. **Count/list predicate divergence.** `down_n` compared the raw float `total_seconds() > d` while
   `down_text` compared `total_seconds() | int > d`. The first real T5 run produced a notification
   reading "Shelly relais onbereikbaar (1/10)" with an **empty device list**. Fixed: both now use the
   identical raw-float predicate, `| int` is applied only for display. Verified count == line count.

## Post-test cleanup
The T5 run left the automation inside its 6 h fan-in damper, which would have suppressed a genuine
alert for 6 h. Cleared with `automation.turn_off {stop_actions:true}` + `automation.turn_on`
(targeted — no extra reload). Verified `current` = 0, state `on`. Test persistent notification dismissed.

## Declared limitation
T5 drives the real condition/action/delivery chain against a real unavailable Shelly via the event
trigger with `dwell:0`, rather than holding a live relay unavailable for the full 827 s of wall clock.
The `for: 00:13:47` timer itself is HA core behaviour and the *constant* is justified by the 8-day
census (T7). Holding a relay down for 14 real minutes was judged a needless risk to a live device.
Stated plainly rather than glossed.
