# Design note: the 2027 energy transition — heat pump, ESS, solar, EV

- **Date**: 2026-08-30
- **Author**: Atlas
- **Status**: design input — nothing changed
- **Context**: user plan — replace the gas combi with a heat pump, aircon in Jurre's and Niko's
  bedrooms, a 3-phase Victron MultiRS Solar ESS, and re-do the 10-year-old 250 Wp array while
  panels are cheap ahead of the **1 Jan 2027** regulation change.

---

## First: this retracts yesterday's EV recommendation

`docs/design/evcc-solar-charging-2026-08.md` recommends single-phasing the TWC3, because a
3-phase 6 A floor (4,140 W) can never be met by a 3,887 W peak inverter.

**That advice was correct for the system as it stands and wrong for the system you are building.
Do not single-phase the wallbox.**

With 3× MultiRS Solar (one per phase — the unit does not support parallel operation) you get
**18 kVA of inverter and up to 18 kWp of PV**, since each unit carries two independent 3 kWp
MPPT trackers. Surplus will clear 4,140 W routinely, and 3-phase charging becomes not just
viable but the better option: 11 kW to the car when the sun is strong, instead of 3.7 kW.

The EV problem solves itself as a side effect of the ESS project. Nothing to spend on it.

---

## The connection worth making: your aircon plan fixes the heat pump's biggest weakness

This is the point I would most want you to take from this note.

A water heat pump's efficiency is set by **flow temperature**. Low-temperature emitters (floor
heating) give a COP of 4–5. Radiators sized for a 70–80 °C gas boiler need high flow
temperatures and drag COP down to 2–2.5 — often the single biggest disappointment in a gas-to-
heat-pump conversion.

Your house is mixed:

| Zone | Emitter | Heat-pump friendliness |
|---|---|---|
| Woonkamer | **Floor heating** (that pump on stroomblok ch6) | ✅ ideal |
| Slaapkamer Jurre | **Radiator** (confirmed by you) | ❌ poor |
| Slaapkamer Niko | **Radiator** (confirmed by you) | ❌ poor |
| Badkamer | Tuya thermostat, likely electric UFH | independent |
| Slaapkamer, Kantoor | unknown — worth confirming |

The usual fix is expensive: oversize the radiators, or accept a bad COP for the whole house
because one circuit needs 60 °C.

**But you are already planning aircon in exactly the two radiator rooms.** An air-to-air unit
*is* a heat pump, and a very efficient one (SCOP 4–5) because it makes 35 °C air rather than
55 °C water. So:

- Let the **aircon heat Jurre's and Niko's rooms** — they are the two rooms that would otherwise
  force a high flow temperature.
- Let the **water heat pump serve only the low-temperature circuits**, sized for ~35 °C flow.
- You get a high COP everywhere, avoid replacing radiators, and the aircon earns its keep in
  winter instead of sitting idle nine months a year.

Specify the aircon as **heat-pump capable (reverse cycle) and cold-climate rated**, not
cooling-only. That is a small spec decision now with a large effect later.

---

## Sizing: what I can and cannot tell you

**I cannot size the heat pump from your data yet.** Home Assistant only holds gas statistics from
April 2026, so I have summer months only:

| Month | Gas m³ |
|---|---|
| Apr 2026 | 27.7 |
| May 2026 | 19.6 |
| Jun 2026 | 18.3 |
| Jul 2026 | 5.5 |

That is domestic hot water plus a little shoulder-season heating — it says nothing about your
January load, which is what sizes the machine. **The winter data will arrive on its own**; by
February you will have a real heating curve. If you need to specify sooner, your annual m³ from
the energy bill is the number to hand the installer.

The arithmetic, for when you have it:

```
useful heat (kWh)      = annual m³ × 9.77 kWh/m³ × ~0.90 boiler efficiency
heat-pump electricity  = useful heat ÷ SCOP        (3.5–4.5 low-temp, 2.5 with radiators)
```

Two things that number then feeds:

1. **Load growth.** Your house already runs a ~957 W always-on baseline (~8,400 kWh/yr). A heat
   pump is typically the largest single load a Dutch house has. Check the main fuse and the
   3× 6 kVA ESS capacity against the winter peak, not the average.
2. **Winter is when PV is absent.** Heat demand and solar production are exactly out of phase.
   The ESS shifts hours, not seasons — in December the heat pump runs largely on bought
   electricity, so the **dynamic tariff arbitrage matters more than solar** for heating.

---

## Solar: the panel replacement is the highest-return part

10-year-old 250 Wp panels against modern 430–450 Wp: **roughly double the output for the same
roof area**, and today's panel prices are the lowest they will be. Your array already saturates
the 4 kW Growatt (peak 3,887 W measured), so it is inverter-limited as well as panel-limited.

Watch the MPPT ceiling: **3 kWp per tracker, 6 kWp per unit, 18 kWp across three**. That is
generous, but each *tracker* is only 3 kWp, so plan strings accordingly — roof orientation groups
map naturally onto trackers.

**DC- vs AC-coupling** is the decision I would think hardest about. Routing the array through the
MultiRS MPPTs (DC-coupled) is one conversion to the battery instead of two, so it is meaningfully
more efficient for storage — but it caps you at 18 kWp and ties the array to the Victron. Keeping
some capacity AC-coupled via a separate inverter costs efficiency but adds headroom and
redundancy. Worth asking your installer to price both.

---

## Phase balance — a small thing that matters with one unit per phase

With a single MultiRS per phase, **each unit only serves its own phase**. An unbalanced house
means one unit works hard while another idles, and a heavy single-phase load can exceed one
unit's 6 kVA while 12 kVA sits unused.

Right now you are well balanced (219 / 180 / 259 W at the moment of writing), but that is a quiet
moment. During the rebuild it is worth deliberately spreading the big new loads — heat pump,
both aircon units, the EV charger, the oven/hob — across phases rather than letting them land
wherever the cable run was convenient.

---

## The ESS, and keeping the car out of it

Noted that the battery is for the **house, not the car** — sensible, since a car battery is an
order of magnitude larger than a house ESS and would simply drain it.

evcc supports this natively and it is worth configuring explicitly rather than hoping:

- `buffer_soc` — only let the car use house-battery energy above this SoC
- `priority_soc` — house battery charges to this level before the car gets anything
- With the battery meter configured, evcc distinguishes *PV surplus* from *battery discharge*

Set these when the ESS lands, or the car will happily empty your house battery on the first
sunny-then-cloudy afternoon.

---

## Why 1 Jan 2027 is the whole reason this works

The regulation change is the **end of salderen** (net metering). Today an exported kWh offsets an
imported one at retail price. After it ends, export earns roughly the market rate while import
still costs retail.

That is exactly what your data shows already, on the dynamic contract: exporting at midday
(~€0.13) and importing in the evening (~€0.36) — a **~€0.23/kWh spread**, and you exported
**195 kWh in 30 days (38 % of production)**.

Post-2027 that gap widens for everyone. Self-consumption stops being a nice-to-have and becomes
the entire economic case — which is precisely what an ESS, a heat pump on cheap hours, and
solar-charged EV all deliver. **The plan is sound and the timing is right.**

---

## What I would do in what order

| When | Action |
|---|---|
| **Now, free** | Departure plan + dynamic `smartCostLimit` in evcc (price axis only; see the EV doc). Nothing here is wasted by the rebuild. |
| **Now, free** | Let winter gas data accumulate — by February you can size the heat pump from measurement rather than estimate. |
| **Before 2027** | Panels + MultiRS + ESS while panel prices are low. Biggest and most time-sensitive item. |
| **With the ESS** | Balance the new loads across phases; configure `buffer_soc`/`priority_soc`. |
| **With the aircon** | Specify reverse-cycle, cold-climate rated, and let them heat the two radiator rooms. |
| **Never** | Single-phase the TWC3. |

## Open questions

1. **Emitters in Slaapkamer (main), Kantoor and Badkamer** — floor heating or radiators? Decides
   whether the water heat pump can genuinely run low-temperature everywhere else.
2. **DC-coupled through the MultiRS MPPTs, or keep an AC-coupled inverter?** Efficiency vs
   headroom.
3. **Target ESS capacity?** House-only overnight at your ~950 W baseline is ~10 kWh; covering the
   evening peak *plus* a heat pump in winter is a very different number.
4. **Main fuse rating** — 3×25 A or 3×35 A? A heat pump plus 11 kW EV charging plus induction can
   approach the limit, and the ESS can be configured to shave that peak.
