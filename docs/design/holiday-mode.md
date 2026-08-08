# Design: Vakantiemodus (holiday mode)

- **Date**: 2026-08-08
- **Author**: Atlas
- **Status**: proposal — nothing deployed
- **Goal**: cut standby power to a minimum while the house is empty, without compromising safety
- **Trip**: 8 → 31 August 2026, possibly returning a few days early (user will confirm)

---

## Be honest about the prize first

You're leaving in **August**, and the house is currently 23.8 °C in the woonkamer with every
`climate.*` zone either `off` or sitting well above setpoint. **Heating savings will be
essentially zero.** Anyone promising you big numbers from a holiday thermostat setback right
now is selling something.

The real, measurable wins are standby loads:

| Load | Estimate | Basis |
|---|---|---|
| 15 Sonos plugs | **~50–60 W continuous** | measured 1.9–16 W each, mostly 2.6–4.9 W |
| ~~Water heater~~ | **~0 — CORRECTED** | see below |
| AV / kiosk / misc standby | unknown | needs the socket mapping to quantify |

> ### ⚠️ Correction: the water heater is not a saving
>
> I originally costed `water_heater.warm_water` at 1–2 kWh/day of tank standby loss, and it was
> the single biggest item in this table. **That was wrong on three counts.**
>
> It is a **Tado zone** (`integration=tado`, device "Warm water", model "Zone") in front of a
> **gas combi ketel** — an on-demand instantaneous heater with **no storage tank**, so there is
> no standing heat to lose. And it burns **gas, not electricity**, so it could never have shown
> up in an electricity saving at all.
>
> Confirmed by measurement: `sensor.zonneplan_gasverbruik_vandaag` = **0 m³ today**. The boiler
> is not burning anything to keep water warm.
>
> Switching it off while away therefore saves **essentially nothing**. Leave it alone. If you
> ever do want it handled, Tado's own Away mode is the natural mechanism, not an HA automation.

With that removed, the honest figure is **~1.3–1.5 kWh/day**, dominated almost entirely by the
Sonos plugs. Over **8–31 August (23 days)** that is roughly **30–35 kWh**, on the order of
**€9–11**. Worth the one script call; not worth building much else for.

The stronger argument is arguably *risk reduction*: fewer energised appliances in an empty house.

---

## Safety: what must never be touched

This is the part that matters. The house has form here — an old restart automation once
cycled the fridge and freezer plugs.

**Hard exclusions — the automation must never switch these:**

| Category | Why |
|---|---|
| The 9 `switch_lock: on` sockets | Fridge/freezer class. HA already shows them `unavailable`, and the lock is enforced **device-side**, which is a genuine second line of defence. Leave every one alone. |
| `switch.main_equipment_room_mac_mini_1` | Powers the Mac Mini agent host — i.e. the thing that would run the automation. ✅ `switch_lock` **enabled 2026-08-08**; its power switch now reports `unavailable` and cannot be switched off. |
| Anything network | UDM, APs, switches. The CMDB still lists `hw.plug.vdhngfw_power` (UDM on a smart plug); 172.16.3.205 is gone from the network so it looks retired — **confirm before relying on that**. |
| Smoke detectors | `binary_sensor.rookmelder_smoke_detected` ×2 — Zigbee/battery, unaffected by socket switching. Verify they're `off` (not `unavailable`) before you go. |
| Cameras (7) | Deterrent + evidence. |
| Cluster / HA / mosquitto | Obviously. |

**Design rule:** the automation targets an **explicit allow-list** of entities. It must never
iterate over "all switches" — that's exactly how the fridge incident happened.

---

## Proposed design

### Helper

`input_boolean.vakantiemodus` — **manual** toggle. Deliberately *not* driven automatically off
`person.*` state: a phone losing GPS should never power down the house.

### On activation

1. **Sonos** — call the existing `script.sonos_alles_uit` (15 plugs). Already written, already
   tested by you. This is now the *only* significant electrical saving in scope.
2. ~~Water heater~~ — **dropped**, see the correction above. Gas combi ketel, on demand.
3. **Climate** — set every zone to its frost-protection minimum rather than `off`, so the
   house can't freeze if the weather turns. `min_temp` is 5 °C for most zones; **note
   `climate.kantoor` reports `min_temp: 18`**, so it can't be set lower — leave it `off` as it
   already is.
4. **Suspend the automations that would undo all this**, then re-enable on exit:
   - `automation.kantoor_ochtend_klimaat`
   - `automation.kantoor_aanwezig_verwarm_naar_21degc`
   - `automation.ochtend_keuken_routine`
   - `automation.keuken_adaptief_dag`, `automation.keuken_nachtlamp`
   - `automation.adaptieve_verlichting_begane_grond`
   - `automation.keuken_tablet_scherm_aan_uit_bij_aanwezigheid`
5. ~~Arm the alarm~~ — **removed.** There is no house alarm.
   `alarm_control_panel.vdhngfw_alarm_manager` is UniFi's own entity, not a security system.

### Deliberately left running

- **Motion-triggered exterior lighting** — `voordeur_licht_bij_detectie`,
  `achtertuin_verlichting`, `gangverlichting_brandpad`. These are a *deterrent*; switching them
  off to save a few watt-hours is a bad trade for an empty house.
- `automation.verlichting_schuur`, `automation.trapkast_licht` — motion-driven, negligible
  standby, useful if anyone (neighbour, plant-waterer) needs to get in.
- Presence detection, door/window sensors, leak sensors, the P1 meter.

### Lights — the actual priority

Confirmed with you: the point is **lights not coming on when nobody needs them**. Measured
split of what is currently enabled:

**Suspend while away — these fire on a schedule or on adaptive triggers, with nobody home:**

```
ochtend_keuken_routine                 keuken_adaptief_dag
keuken_screen_openen_ochtend           keuken_nachtlamp
adaptieve_verlichting_begane_grond     woonlaag_laatste_licht_uit
kantoor_focus_mode_lichten_dimmen      kantoor_focus_mode_lichten_herstellen
kantoor_einde_werkdag_lichten_uit      kantoor_ochtend_klimaat
kantoor_aanwezig_verwarm_naar_21degc   keuken_tablet_scherm_aan_uit_bij_aanwezigheid
voordeur_uit_om_middernacht
```

**Keep running — motion-triggered, so they only fire if someone is actually there:**

```
gangverlichting_brandpad   verlichting_schuur   trapkast_licht
achtertuin_verlichting     voordeur_licht_bij_detectie
```

Leaving these is deliberate: they cost nothing at idle and a light responding to movement is a
deterrent.

### Presence simulation — confirmed wanted

A light schedule so the house doesn't read as obviously empty: 2–3 rooms on a randomised
evening window (roughly sunset → 23:00, ±20 min jitter). Randomised, not a fixed timer —
a light that switches at exactly 19:00 every night advertises absence rather than hiding it.

### On deactivation

Reverse everything: water heater → `auto`, climate zones → previous mode, automations
re-enabled, Sonos plugs back on, presence simulation off. Restore runs **before** the
auto-exit notification, so you don't walk into a house with every schedule still suspended.

### Guards

- **Auto-exit** if any of the 4 real people (`person.sander_van_der_heijden`,
  `person.femke_den_engelsman`, `person.niko_van_der_heijden`, `person.jurre_van_der_heijden`)
  turns `home` — coming back early shouldn't need the app.
- **Notification** on both activation and exit, so it can't run silently.
- **Frost guard** — if any indoor temperature drops below 8 °C, exit climate setback and alert,
  regardless of holiday mode.
- **Leak/smoke override** — a smoke or moisture trigger exits holiday mode and alerts. Never
  let an energy-saving mode mask an emergency.

---

## Known gap — and it's the same one as the HomeWizard project

**Most sockets are still called `energy_socket_11`, `_12`, `_17`…** so beyond Sonos and the
water heater I can't tell you what else is safe to switch off, because nobody knows what those
sockets feed. That's the same hazard as the `sonos_eetkamer` mislabel that nearly cost you half
the kitchen stereo.

So this proposal deliberately covers **only what is positively identified**. Extending it to the
remaining ~15 switchable sockets should wait for the mapping in
`docs/runbooks/homewizard-iot-walk-sheet.md`. I'd rather save you €4 less than switch off
something that matters.

---

## Before you walk out the door

Regardless of whether this gets built:

1. **`script.sonos_alles_uit`** — this exists and works today. Running it manually captures the
   single biggest chunk of the saving with zero new code.
2. ~~`water_heater.warm_water` → `off`~~ — **dropped.** Gas combi ketel, on-demand, no tank.
   Saves nothing. (See the correction above.)
3. **Suspend the scheduled/adaptive light automations** (list below) — this is the bit you
   actually care about, and it is the one thing the manual checklist cannot do well by hand.
4. **Check `binary_sensor.rookmelder_smoke_detected` ×2 read `off`, not `unavailable`.**
5. ✅ **`switch_lock` on the Mac Mini socket — DONE 2026-08-08.** Its power switch now reports
   `unavailable`, i.e. it can no longer be switched off.

Those take about two minutes and get you most of the benefit without deploying anything.

---

## Separate finding: the UniFi estate is probably your biggest always-on load

You suspected this, and the evidence supports it — with caveats.

**16 UniFi devices**: 1 UDM Pro Max, 6 APs, and **9 switches** (USL24P, USL16P, USWED72,
USWED36, USF5P, USC8, USL8A, 2× USMINI).

Measured, 2026-08-08:

| Source | Reading |
|---|---|
| PoE actually delivered | **66.6 W** (USL24P 30.3, USWED72 15.7, USF5P 11.5, USL16P 9.1) |
| `sensor.netwerk_power` + `_2` | 17.3 + 18.2 = **35.5 W** |
| Stroomblok (rack strip) channels | 19.1 + 36.2 + 37.6 ≈ **93 W** |

⚠️ **I cannot cleanly total these** — I don't know which meter covers which gear, and the
Netwerk/Stroomblok readings may overlap with the PoE figure rather than add to it. Directionally
it lands around **100–150 W continuous**, i.e. **2.4–3.6 kWh/day** — comfortably more than the
Sonos plugs. But treat that as an estimate, not a measurement, until the sockets are mapped.

**This is NOT a holiday-mode item.** Switching off the network while away would take out Home
Assistant, the cameras, remote access, and any ability to switch things back on. It is a
**right-sizing project**: nine switches for one house is a lot, and consolidation would save
year-round rather than a fortnight. Worth a proper look when you're back — I'd start by
identifying what each of the nine actually serves.

Also spotted: `sensor.stroomblok_electric_w` reports **107374182.9 W** — a counter overflow
(2³⁰×100), not a real reading. Harmless but it will poison any energy dashboard that averages
it. Worth excluding or fixing.

## Risk

| # | Risk | Mitigation |
|---|---|---|
| 1 | Switching a critical load | Explicit allow-list only; never iterate all switches. Device-side `switch_lock` is the backstop. |
| 2 | House freezes | Frost-protection setback, not `off`; plus an 8 °C override that fires regardless of mode. |
| 3 | Automation fails half-way, house left in a mixed state | Idempotent restore path; exit is safe to run repeatedly. |
| 4 | Returning to a dark/alarmed house | Auto-exit on `person → home`; restore runs before disarm. |
| 5 | Silent operation | Notify on entry and exit. |
| 6 | Suspended automations never re-enabled | Restore list is explicit and mirrors the suspend list; verify after the first exit. |

## Open questions

1. **Deploy before you leave, or run the 5-item manual checklist this trip and build it properly
   after?** Given you leave today, I lean toward the checklist — an untested automation running
   unattended for two weeks is a worse risk than €10 of standby.
2. **EV charger** — should holiday mode stop evcc/`autolader`, or is the car coming with you?
3. **Presence simulation** — want it, or do you prefer the house genuinely dark?
4. **Alarm** — should holiday mode arm it, or do you arm manually?
