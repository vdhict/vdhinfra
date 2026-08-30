# Design: optimal EV charging — maximum solar, minimum price

- **Date**: 2026-08-30
- **Author**: Atlas
- **Status**: proposal — nothing changed
- **Ask**: "use as much solar as possible, especially what's being pushed back to the grid, and charge at the cheapest price"

---

## TL;DR — solar charging is not mis-tuned, it is physically impossible

Your loadpoint is in `pv` mode and has been all along. It has never been able to start on solar,
and it never will as currently wired:

| | |
|---|---|
| Charge minimum, 3-phase @ 6 A | **4,140 W** |
| Peak PV ever measured (Growatt 4000TL) | **3,887 W** |
| Realistic surplus (peak PV − ~957 W house baseline) | **~2,900 W** |

**The minimum the car can accept exceeds the maximum the roof can produce.** PV mode waits for a
surplus that cannot occur.

evcc agrees, from its own lifetime statistics:

```
sensor.evcc_stat_total_solar_percentage = 8.18 %      (64 of 784 kWh charged)
```

That 8 % is incidental overlap during grid charging, not solar following.

Meanwhile, over the last 30 days:

| | kWh |
|---|---|
| PV generated | 510 |
| **Exported to grid** | **195 (38 %)** |
| **EV charged** | **189** |

The exported energy and the car's demand are almost the same number. The energy is there; the
configuration cannot connect the two.

---

## What *is* working

Cheap-price charging works. The big sessions (53 kWh on 1 Aug, 40 kWh on 26 Aug, 38 kWh on
28 Aug) are `smartCostLimit` doing its job at €0.17/kWh. Don't break that.

---

## The tariff picture, and a happy coincidence

Next 48 h from Zonneplan:

| | €/kWh |
|---|---|
| min | **0.129** |
| median | 0.235 |
| max | **0.365** |
| spread | **0.236** — nearly 3× |

17 of 48 hours are below your €0.17 limit. Prices never go negative in this window.

**The cheapest hours are 09:00–12:00** — the exact hours the roof is producing. The most
expensive are 17:00–19:00, when it is not.

That matters: *"charge on solar"* and *"charge cheaply"* are not competing objectives here. They
are the same window. A single strategy serves both, which makes this much simpler than it looks.

It also means today's pattern is the worst case: export at midday (~€0.13 credit) and import in
the evening (~€0.36). **Every kWh moved from export to self-consumption is worth roughly the
spread, ~€0.23**, subject to your netting arrangement.

---

## ⚠️ RETRACTED 2026-08-30 — do NOT single-phase the wallbox

The user is building a 3-phase Victron MultiRS Solar ESS (one unit per phase, 6 kVA + 6 kWp
each → 18 kVA / up to 18 kWp) and replacing the 10-year-old 250 Wp array while panels are cheap
ahead of the 1 Jan 2027 end of salderen. With that system, surplus clears the 4,140 W 3-phase
floor routinely and 3-phase charging becomes the *better* option — 11 kW to the car on a sunny
day instead of 3.7 kW.

Single-phasing would be undone by the rebuild. **The EV problem solves itself as a side effect
of the ESS project.** See `docs/design/energy-transition-2027.md`.

Option A below is retained only to document the physics of the current system — the surplus
analysis and the phases:1 warning remain accurate and useful.

## Option A — single-phase the wallbox ~~⭐ recommended~~ (SUPERSEDED)

Rewire the TWC3 to one phase.

| | 3-phase (today) | 1-phase |
|---|---|---|
| Minimum charge | 4,140 W ❌ | **1,380 W** ✅ |
| Maximum @16 A | 11,040 W | 3,680 W |
| Maximum @32 A | — | 7,360 W |

**1-phase brackets the Growatt almost perfectly.** Minimum 1.38 kW means surplus is usable from
mid-morning to late afternoon, not just at a peak that never arrives. Maximum 3.68 kW at 16 A is
just under the inverter's 3,887 W ceiling — the whole roof can go into the car.

Cost: peak charge rate drops from 11 kW to 7.4 kW (at 32 A). For a 78 kWh Model Y that is ~10.5 h
instead of ~7 h for a full charge. Overnight either way.

Then this configuration finally does what you asked:

```yaml
loadpoints:
  - title: Garage
    charger: twc3
    vehicle: tesla
    mode: pv
    phases: 1          # was 3
    mincurrent: 6      # 1.38 kW — reachable
    maxcurrent: 16     # 3.68 kW — matches the inverter
```

⚠️ **Do not set `phases: 1` in evcc without rewiring.** evcc would compute 6 A as 1.38 kW while
the car actually draws 4.14 kW across three phases, so it would import from the grid believing it
was on surplus. The setting describes the wiring; it does not change it. `select.evcc_garage_phases_configured`
offers "1" in the UI, which makes this an easy and expensive mistake.

---

## Option B — no hardware change

If rewiring is not wanted, stop pretending PV mode works and optimise the price axis instead.

1. **Lower `mincurrent` and measure.** evcc offers values below 6 A, and Tesla will accept ~5 A.
   3 × 5 A = 3,450 W, still above realistic surplus (~2,900 W) — so this alone will not fix it,
   but on the very best days it moves from "never" to "occasionally". Cheap to try, low ceiling.
2. **Make `smartCostLimit` dynamic instead of a fixed €0.17.** A fixed threshold charges on a
   cheap *day* and never on an expensive one, even if that day has a clear trough. Better: set it
   each morning to, say, the 35th percentile of the coming 24 h. On the current window that
   yields ≈ €0.17 anyway, but it adapts. HA automation, no evcc change.
3. **Use a departure plan.** `limit_soc` is 100 % with no target time, so evcc has no deadline to
   optimise against. Give it "80 % by 07:00" and it will select the cheapest hours itself —
   which, per the tariff data, are the sunny ones.
4. Set `residual_power` to ~50–100 W so surplus tracking does not oscillate around zero.

Expect this to capture most of the *price* benefit and little of the *solar* benefit.

---

## Option C — wait for the ESS

You mentioned an ESS arriving with the utility-room split. That changes the arithmetic
fundamentally, and some of the above becomes moot:

- A home battery absorbs midday surplus at any power level, with **no 4.1 kW floor**. It solves
  the export problem without touching the wallbox.
- The EV then becomes the *second* sink, charged from the battery or from cheap grid at night.
- evcc supports battery meters natively (`sensor.evcc_battery_soc`, `evcc_battery_mode`,
  `evcc_battery_grid_charge_limit` all exist but read `unknown` today) plus
  `buffer_soc` / `priority_soc` to arbitrate between house battery and car.

**But the ESS does not make single-phasing pointless.** With a 4 kW roof, a battery will often be
full by early afternoon; a 1-phase wallbox lets the surplus go straight to the car instead of
cycling the battery. The two are complementary.

**Recommendation:** do Option B now, decide Option A independently of the ESS, and design the
battery arbitration when the hardware is specified.

---

## Suggested target design (post-rewire)

```yaml
loadpoints:
  - title: Garage
    charger: twc3
    vehicle: tesla
    mode: pv
    phases: 1
    mincurrent: 6
    maxcurrent: 16
    enable:  { delay: 60s,  threshold: 0 }      # start when surplus ≥ 1.38 kW for 60 s
    disable: { delay: 180s, threshold: 0 }      # stop after 3 min deficit — rides out clouds
    soc:
      poll: { mode: connected }
```

Plus, in HA:

- **A departure plan**: 80 % by 07:00 on weekdays. Lets evcc price-optimise and protects the
  battery (Tesla LFP aside, 80 % daily is kinder than 100 %).
- **A dynamic `smartCostLimit`**: set each morning from the day's price curve rather than a fixed
  €0.17.
- **A "cheap + sunny" override**: if price < €0.15 *and* forecast surplus is high, allow `now`
  mode to grab the trough — the data shows those coincide late morning.
- **Do not** automate around `sensor.evcc_stat_total_solar_percentage`; it is a lifetime average
  and will move far too slowly to drive anything.

---

## What I would measure afterwards

`sensor.evcc_stat_total_solar_percentage` is the honest scoreboard. It is **8.18 %** today.
Post-rewire, with a 4 kW roof and ~190 kWh/month of demand, 50–70 % is a realistic target in
summer, much less in winter. If it does not move, the change did not work.

Also watch `p1_meter_energy_export`: success looks like the 38 % export share falling.

---

## Open questions

1. **Is the TWC3 currently wired 3-phase at the consumer unit**, and is single-phasing a
   breaker-and-cable job or a bigger one? This decides whether Option A is an afternoon or a
   project.
2. **How often do you genuinely need >7.4 kW charging?** If the car is home overnight most days,
   the 11 kW capability is unused and costs you the solar capture.
3. **What is your actual export compensation** under the Zonneplan contract? It sets the true
   value of every kWh shifted from export to self-consumption. Today's meter shows €5.69 imported
   vs €0.11 compensated, but that is one partial day and not a rate.
4. **ESS size and chemistry?** Determines whether the car or the battery should get midday
   surplus first.
