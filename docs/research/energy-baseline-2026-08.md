# Energy analysis: where the unexplained consumption goes

- **Date**: 2026-08-27
- **Author**: Atlas
- **Status**: analysis — nothing changed
- **Question**: "there is a lot of electricity consumption of which we don't know what is consuming"

---

## The number that matters

The 8–31 August holiday handed us a perfect experiment: **an empty house, measured for two weeks.**

| Period | kWh/day |
|---|---|
| 10–24 Aug (nobody home, no EV) | **13.2 – 15.3** |
| Typical occupied day (no EV) | 18 – 22 |
| With EV charging | 30 – 67 |

**An empty house draws 13.3 kWh/day = ~554 W continuously.**

Annualised that is **≈ 4,850 kWh/yr**, roughly **€1,450/yr at €0.30/kWh** — before anyone
switches anything on. That is the real target, and it is much easier to attack than occupied-day
usage because it runs 24/7/365.

> The EV dominates the *totals* (40–53 kWh on a charging day) but it is not waste — it is
> transport you'd otherwise buy as petrol. I've excluded it from the baseline throughout.

---

## Where the 554 W goes

Measured per-device over 10–24 Aug, the house empty:

| W (avg) | Device | kWh/14d |
|---:|---|---:|
| **87.4** | **Synology NAS** | 29.4 |
| **53.4** | **VDHPOESW01 (PoE switch)** | 18.0 |
| **44.2** | **Pomp vloerverwarming** ⚠️ | 14.9 |
| 34.9 | Wijnkoelkast Wit | 11.7 |
| 27.6 | Vriezer | 9.3 |
| 26.5 | Computer (Z-Wave) | 8.9 |
| 24.3 | UPS | 8.2 |
| 18.2 | Computer Niko | 6.1 |
| 18.0 | Netwerk B | 6.1 |
| 17.4 | Netwerk A | 5.9 |
| 16.8 | Wijnkoelkast Rood | 5.7 |
| 16.4 | Koelkast | 5.5 |
| 14.6 | Computer Jurre | 4.9 |
| 13.6 | BackUPS | 4.6 |
| 5.6 | Mech. ventilatie | 1.9 |
| **419** | **subtotal** | |
| ~71 | 21 Sonos plugs (spot reading) | |
| **~490** | **identified** | |
| **~64** | **still unidentified (12%)** | |

So the honest answer to "we don't know what's consuming": **we now know about 88% of it.**
The remaining ~64 W is almost certainly hardwired circuits with no meter — lighting, oven/hob,
boiler electronics, doorbell transformer, extractor.

---

## The findings worth acting on

### 1. ⚠️ The floor-heating pump runs 24/7 — in August

```
sensor.0xa4c138909e11e8e9_power        = 44 W
switch.0xa4c138909e11e8e9              = on
automation.vloerverwarmingspomp_beheer = off      ← its manager is DISABLED
```

**44 W continuously, in summer, with the heating off.** There is an automation whose entire job
is to manage this pump and it is switched off. (It was already off before the holiday — this is
not holiday fallout.)

- **≈ 385 kWh/yr ≈ €115/yr**, for a pump circulating water nobody is heating.
- Best single fix available, and it is free.
- ⚠️ Check *why* it was disabled before re-enabling — a seized pump is a real risk if it sits
  unused all summer, and some installers deliberately run a periodic anti-seize cycle. The right
  answer is probably "run it 5 minutes a week", not "off forever".

### 2. The NAS is the single largest always-on load

**87 W = 766 kWh/yr ≈ €230/yr.** Worth asking what it actually serves overnight. Synology
supports disk hibernation and scheduled power on/off; if it is only used for media and backup
targets, a nightly window could halve it.

### 3. Computers were left running for three weeks

Niko (18 W), Jurre (15 W), plus the Z-Wave "Computer" (27 W) = **~59 W** ran the entire holiday.
That's **~30 kWh wasted** on machines nobody could use. All three are on switchable sockets, so
this is exactly what the holiday-mode design should cover — I'd add them to it.

### 4. Two wine coolers, and one is drawing double the other

Wijnkoelkast **Wit 34.9 W** vs **Rood 16.8 W**. Same class of appliance, 2× the draw. Worth
checking the white one's door seal, setpoint, and whether it is in direct sun or next to a heat
source. If it's faulty, that gap is ~160 kWh/yr.

### 5. Two UPSes cost 38 W in conversion losses

UPS 24 W + BackUPS 14 W. Unavoidable if both are needed, but worth confirming both still protect
something that matters.

### 6. Network gear: ~88 W measured, and that's only part of it

`VDHPOESW01` 53 W + Netwerk A/B 35 W. This doesn't include everything — it supports the
right-sizing case in `docs/design/wifi-redesign-2026-08.md`. **Nine switches and six APs for one
house.** Consolidation would save year-round.

---

## Fixing the dashboard itself

Two things are actively degrading it:

1. **`sensor.stroomblok_electric_w` reports 107374182.9 W** — a counter overflow (2³⁰ × 100), not
   a real reading. Any dashboard card that averages or sums power will be poisoned by it. Exclude
   or fix it.
2. **Five different whole-house meters are exposed as if they were devices** —
   `p1_meter_power`, `electricity_meter_energieverbruik`, `evcc_home_power`, `evcc_grid_power`,
   `connect_energiemeter_*`. They all report the same ~2,487 W. If any of these are on the Energy
   dashboard alongside individual devices, consumption is being counted several times over. **This
   alone could explain why the dashboard looks like it doesn't add up.** Pick `p1_meter_*` as the
   single source of truth for house totals and drop the rest from the dashboard.

Also: several Z-Wave sockets expose the same measurement twice (`*_power` and
`*_electric_consumption_w`). Harmless for reading, but they will double-count if both are added.

---

## Recommended order

| # | Action | Saving | Effort |
|---|---|---|---|
| 1 | Fix the whole-house meter double-counting on the dashboard | — (accuracy) | minutes |
| 2 | Exclude the `stroomblok_electric_w` overflow sensor | — (accuracy) | minutes |
| 3 | Resolve the floor-heating pump (with an anti-seize cycle) | **~385 kWh/yr** | small |
| 4 | Add the three computers to holiday mode | ~30 kWh/trip | small |
| 5 | Investigate Wijnkoelkast Wit's 2× draw | up to ~160 kWh/yr | small |
| 6 | NAS overnight hibernation, if viable | up to ~380 kWh/yr | medium |
| 7 | Network right-sizing (see wifi-redesign doc) | ~100–300 kWh/yr | project |
| 8 | Map the remaining sockets to close the last ~64 W | — (visibility) | house walk |

Items 1–5 are the cheap ones and together plausibly remove **~600 kWh/yr (≈ €180)**.

---

## Method / caveats

- Baseline from HA long-term statistics (`recorder/statistics_during_period`, daily), not
  short-window recorder history — the recorder only retains a few days.
- Per-device figures are 14-day averages over the empty-house window, so they are genuine
  always-on figures, not spot readings. The Sonos figure **is** a spot reading and is the least
  reliable line.
- Aggregate/whole-house sensors were excluded from device sums, and readings were deduplicated
  per physical device (via `device_id`) to avoid the twin-entity problem described above.
- The ~64 W unidentified is a residual, so it also absorbs any measurement error in the other
  lines. Treat it as "roughly 50–100 W of unmetered circuits", not a precise figure.
