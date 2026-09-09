# Dwell derivation - measured, not chosen

Source: HA recorder history for the ten watched switch.* entities, 2026-09-02 .. 2026-09-09 (8 days),
fetched via /api/history/period in daily chunks. Episode = contiguous run of state == 'unavailable'.

Benign episodes (excluding the real 4-day verlichting_schuur outage): **1196**

| statistic | value |
|---|---|
| median | 1.5 s |
| p95 | 29 s |
| p99 | 94 s |
| p99.9 | 186 s |
| max | 392 s |

## Per-entity census (proves ALL TEN go unavailable, not just the one that failed)

| entity | episodes | max s |
|---|---|---|
| switch.sonos_achtertuin | 358 | 152 |
| switch.sonos_arc_ultra | 44 | 125 |
| switch.sonos_bartafel | 657 | 247 |
| switch.sonos_eetkamer | 10 | 93 |
| switch.sonos_keuken | 19 | 123 |
| switch.sonos_play_1 | 48 | 392 |
| switch.sonos_sub | 16 | 92 |
| switch.sonos_surround_linksachter | 21 | 186 |
| switch.sonos_surround_rechtsachter | 12 | 93 |
| switch.verlichting_schuur | 12 | 26605 |

## Dwell arithmetic

- observed benign max = 392 s
- observed tail ratio  = max / p99.9 = 392 / 186 = 2.11
- dwell = 392 x 2.11 = **827 s = 00:13:47**

## False-page count if the dwell had been set to X, against this same 8-day record

| dwell | false pages / 8 days |
|---|---|
| 120 s | 9 |
| 180 s | 3 |
| 300 s | 1 |
| 392 s | 0 |
| 600 s | 0 |
| 827 s | 0 |
| 900 s | 0 |

827 s yields ZERO false pages on the observed record while detecting a genuine
outage in ~14 min, against the 4-day discovery gap of chg-2026-09-08-001 (~415x faster).

## Nightly maintenance window

The '03:0x' AP/switch reboots are LOCAL CEST = 01:0xZ. (usw_aggregation_uptime rebooted
2026-09-09T01:14:40Z, usw_24_poe 01:09:36Z.) Worst case in that window across 8 days:
247 s on 2026-09-09T01:14:54Z, when ALL TEN dropped together - the all-ten-down regime,
observed for real. 827 s clears that by 3.3x and the fan-in damper turns it into one alert.
