# FP2 Power-Cycle Watchdog — design spec

- **Status:** DRAFT rev 2 — spec only, awaiting user approval. Nothing built, nothing deployed.
- **rev 2 (2026-07-23):** guards re-derived after Atlas showed the failure rate is bimodal, not
  steady-state. §1.2 (incident structure), §3.2b (second detection signal), §5.0 (counterfactual
  replay), §5.1–5.3 (guards + notifications) are new or rewritten. Detection threshold, ICMP
  corroborator, 15 s off-duration, fresh-lux verification, blueprint choice, §6 and §7 unchanged.
- **Change record:** `chg-2026-07-23-004` (low risk, design/doc only)
- **Author:** Hestia (ha-engineer)
- **Date:** 2026-07-23
- **CMDB:** `ha.sensor.fp2_keuken` (owner `ha-engineer`)
- **Background:** memory `reference_aqara_fp2_wedge`, `docs/research/aqara-fp2-wifi-stability-2026-07.md`, chg-2026-07-20-004

---

## 1. Problem

The kitchen **Aqara Presence-Sensor-FP2-F08E** (model PS-S02D, fw 1.3.6, HomeKit Controller,
MAC `54:ef:44:51:f0:8e`) periodically hangs its IP/application stack while the Wi-Fi radio stays
associated. Diagnosed 2026-07-20: L2 alive (ARP resolves, 50.9 h continuous association), ICMP and
**all** TCP including HAP `tcp/64180` dead. Device firmware hang, not a network fault. Wi-Fi
min-rate / min-RSSI were exonerated with measurements and are explicitly **out of scope** here.

Only known recovery is a **USB power-cycle**. Today that means walking to the kitchen and unplugging it.

It is load-bearing: the FP2 is the only lux + presence sensor on the ground floor. Four automations
depend on it (§7).

### 1.1 How bad is it, measured

Recorder history for `binary_sensor.presence_sensor_fp2_f08e_presence_sensor_1`,
window **2026-07-13T04:01 → 2026-07-23T06:27 (10.1 days)**:

| metric | value |
|---|---|
| distinct `unavailable` episodes | **265** |
| total time unavailable | **81 392 s = 22.6 h** |
| duty cycle unavailable | **9.3 % of wall-clock** |
| median episode | 66 s |
| p90 episode | 504 s (8.4 min) |
| longest episode | 19 074 s (5 h 18 m) |

Episode-length tail (same window):

| ≥ threshold | episodes | per day |
|---|---|---|
| 5 min | 56 | 5.5 |
| 10 min | 28 | 2.8 |
| 15 min | 19 | 1.9 |
| 20 min | 10 | 1.0 |
| 30 min | 5 | 0.50 |
| 45 min | 2 | 0.20 |
| 60 min | 2 | 0.20 |

Two behaviours are mixed in that data and must not be confused:

- **Short blips (seconds to ~10 min)** — the HomeKit Controller connection dropping and
  re-establishing. The device is fine. Power-cycling here is pure wear.
- **Long wedges (≥ ~20 min)** — the firmware hang. Some self-recover after hours; the 5 h 18 m one did.
  These are the ones worth power-cycling.

### 1.2 The rate is NOT steady-state — the device is bimodal

The averages above are misleading and any guard sized against them is wrong. **All 265 episodes fall
inside one contiguous incident**, first episode 2026-07-15 22:55 CEST, last recovery 2026-07-20 11:37
CEST — a 108.7 h span. Before and after: nothing.

| local day | episodes | downtime | longest episode | episodes ≥ 30 min |
|---|---|---|---|---|
| 07-13 | 0 | — | — | 0 |
| 07-14 | 0 | — | — | 0 |
| 07-15 | 2 | 33 min | 28 min | 0 |
| 07-16 | 90 | **366 min** | 23 min | **0** |
| 07-17 | 34 | 71 min | 12 min | 0 |
| 07-18 | 51 | 163 min | 25 min | 0 |
| 07-19 | 72 | **639 min** | **318 min** | 4 |
| 07-20 | 16 | 85 min | 35 min | 1 |
| 07-21 | 0 | — | — | 0 |
| 07-22 | 0 | — | — | 0 |
| 07-23 | 0 | — | — | 0 |

(Bucketing is CEST; counts differ by a few episodes from a UTC bucketing at the day boundaries, the
shape is identical.)

Duty cycle **during the incident is 20.8 %**, not the 9.3 % blended figure. Three completely clean days
since the manual power-cycle on 07-20.

Two consequences that drive the whole guard design:

1. **The device degrades progressively.** It starts with a couple of blips (07-15), escalates to
   high-frequency flapping (07-16, 90 episodes), partially remits (07-17), builds again (07-18), then
   collapses into sustained wedging on 07-19 (10.6 h down, including the single 5 h 18 m event). The
   manual power-cycle on 07-20 ended it.
2. **The early days are invisible to a duration threshold.** On 07-16 the device was down for 6.1 h
   cumulative — but in 90 short episodes with a **maximum of 23 minutes**. Zero episodes reached 30 min
   on 07-15, 07-16, 07-17 or 07-18. A rule that only looks at *how long is this episode* is blind to
   four of the six incident days.

Guard sizing must therefore be read as "how does this behave inside a six-day spiral", never as
"how often does this fire per average day".

Availability run-lengths in the same window: 660 runs, **longest healthy run only 10.1 h, just 5 runs ≥ 6 h**.
That kills any "counter resets after N hours healthy" design (§5) — the sensor is never healthy long enough.

---

## 2. Shape of the solution: blueprint vs script

**Recommendation: an automation blueprint** (`blueprints/automation/vdh/fp2_powercycle_watchdog.yaml`),
instantiated once per FP2.

| | blueprint | script + thin automations |
|---|---|---|
| Trigger + logic in one artefact | yes | no — trigger lives in the automation, logic in the script, easy to drift |
| Adding the living-room FP2 | pick 6 entities in the UI | hand-write a second automation, remember every guard |
| Input validation | entity/number/duration selectors, typo-proof | free-form `fields:`, unvalidated |
| Per-instance state (counters, latches) | passed in as inputs — works fine | same |
| `mode` / rate-limit semantics | per instance, correct | script `mode: single` is shared across callers → a second FP2 could be blocked by the first |

The last row is the decider: a shared script would serialise two independent devices. The only cost of the
blueprint is that per-instance helpers (counter, booleans) still have to be created by hand per device —
acceptable, six helpers total for two devices.

### 2.1 Blueprint inputs

| input | selector | kitchen value | purpose |
|---|---|---|---|
| `health_entity` | entity (sensor) | `sensor.presence_sensor_fp2_f08e_light_sensor_light_level` | primary detection subject **and** post-recovery freshness probe |
| `ping_entity` | entity (binary_sensor), optional | `binary_sensor.ping_fp2_keuken` (to be created) | corroborating signal |
| `plug_switch` | entity (switch) | *TBD — no spare plug exists, see §6* | the power cut |
| `suppress_flag` | entity (input_boolean) | `input_boolean.fp2_keuken_watchdog_actief` | tells dependent automations to stand down |
| `paused_flag` | entity (input_boolean) | `input_boolean.fp2_keuken_watchdog_gepauzeerd` | give-up latch |
| `cycles_24h_sensor` | entity (sensor) | `sensor.fp2_keuken_cycles_24u` (`history_stats` count on the plug) | rolling rate cap + notification escalation |
| `downtime_window_sensor` | entity (sensor) | `sensor.fp2_keuken_downtime_4u` (`history_stats` time) | signal A2 |
| `total_counter` | entity (counter) | `counter.fp2_keuken_powercycles_totaal` | never reset — trend visibility |
| `unavailable_for` | duration | **30 min** | signal A1 threshold |
| `degraded_downtime` | duration | **75 min** | signal A2 trailing-window threshold |
| `degraded_dwell` | duration | **10 min** | signal A2 minimum current-outage dwell |
| `off_duration` | duration | **15 s** | power-off dwell |
| `recovery_timeout` | duration | **300 s** | give up waiting for re-join |
| `min_interval` | duration | **30 min** | minimum gap between cycles |
| `max_cycles_24h` | number | **8** | rolling rate cap (runaway brake) |
| `notify_at_cycle` | number | **3** | escalation point (§5.3) |
| `notify_target` | text | `notify.mobile_app_s25_ultra_sander` | give-up / cap notifications only |

---

## 3. Detection signal — the crux

### 3.1 Recommended

Two independent trigger signals, because the device has two failure modes (§1.2). Both are gated by
the same ICMP corroborator.

> **Signal A1 — sustained wedge.** `health_entity` is `unavailable` **continuously for 30 minutes**.
>
> **Signal A2 — degradation / flapping.** `health_entity` is `unavailable` **now, for ≥ 10 minutes**,
> **AND** cumulative unavailable time in the **trailing 4 hours ≥ 75 minutes**.
>
> **Corroborator (both signals):** `ping_entity` is `off` (ICMP unanswered) at the moment of firing,
> and has been for at least 10 minutes. If `ping_entity` is itself `unavailable`/`unknown` (ping
> integration broken), the watchdog proceeds on the primary signal alone but **notifies** that it
> acted un-corroborated.

A2 is implemented with a native `history_stats` sensor
(`sensor.fp2_keuken_downtime_4u`, type `time`, state `unavailable`, rolling 4 h window) — no template
gymnastics, and it doubles as the dashboard degradation gauge (§5.3).

A2 **requires the device to be down right now**. Firing on trailing history alone would power-cycle a
sensor that had recovered — the one genuinely harmful false positive. The 10-minute dwell keeps A2 off
the short-blip noise floor while letting it act ~20 min sooner than A1 when the device has already
proven it is degrading.

All FP2 entities share one HAP connection, so they all go `unavailable` together; using the lux sensor
as the single `health_entity` keeps the blueprint to one input and lets the same entity serve the
post-recovery freshness check (§4.3).

### 3.2 Why 30 minutes for A1 — re-checked against the incident only

From §1.1: a 30-minute threshold would have fired **5 times in 10.1 days (0.50/day)**, and those 5
episodes account for **8.54 h of the 22.6 h** total unavailable time. With a ~2.5 min recovery, that
8.54 h becomes ~2.7 h — a **5.8 h/10 d reduction in blind time** for 0.5 cycles/day of device wear.

Dropping to 20 min doubles the fire rate (1.0/day) to recover only ~1.6 h more per 10 days.
Dropping to 10 min gives 2.8 cycles/day — 5.6× the wear for a further ~1.5 h. That region is dominated
by ordinary HAP reconnect blips, where the device does not need cycling at all. **30 min is the
specificity-biased choice** the brief asked for, and it sits comfortably under the 3/day rate cap (§5).

**Recomputed over the incident only (07-15 22:55 → 07-20 11:37), as Atlas asked:** the episode-length
distribution is *unchanged* — p50 66 s, p90 504 s, max 19 074 s — because the clean days contribute
**zero** episodes, so dropping them removes nothing from the numerator. What does change is the
*duty cycle* (9.3 % → 20.8 %) and the *per-day fire rate* (0.50/day blended → **1.1/day during the
incident, peak 4 on 07-19**).

So the recomputation does **not** move the A1 threshold — 30 min still sits correctly in the
episode-length tail. It invalidates the **rate cap**, which was sized off the blended 0.5/day figure
(§5.1). That is the actual error, and it is fixed below.

### 3.2b Why A2 exists, and its numbers

A1 alone never fires on 07-15, 07-16, 07-17 or 07-18 — the longest episode on any of those days is
28 min. Four days of the spiral, ~10.5 h of cumulative downtime, watchdog completely silent.

A2 at **75 min in a trailing 4 h** was chosen by simulating candidate windows against the real
timeline (§5.0). Alternatives tested: 30 min/2 h (far too twitchy — 23 raw crossings), 45 min/2 h,
45 min/3 h, 60 min/3 h (12 fires), 75 min/4 h (**11 fires, same realised downtime — best specificity
per unit benefit**). Specificity on the clean days is trivially perfect: 07-13, 07-14, 07-21, 07-22 and
07-23 have zero unavailable seconds, so the trailing-window integral is flat zero and A2 cannot fire.

Honest limitation: the simulation (§5.0) shows A2 buys only ~1.2 h of measured downtime over A1-alone,
for six extra power cycles. **That understates its value, and I can't prove by how much.** The
simulation is forced to assume every later real episode still happens exactly as recorded after an
intervention. The actual hypothesis behind A2 is that the spiral is *progressive* and a cycle on 07-16
might have reset the degradation and prevented 07-19 entirely. That is unfalsifiable from this dataset.
What A2 demonstrably does deliver is **detection of the degradation mode at all**, and with it the
escalation notification three days earlier (§5.3) — which is worth having on its own even if it never
broke a single spiral.

### 3.3 Why ICMP is the right corroborator

The measured wedge signature is **L2 up, L3/L4 dead**. During a mere HomeKit-Controller reconnect blip
(the 265-episode noise floor) the device still answers ping; during a real firmware wedge it does not
(verified 2026-07-20 from 172.16.3.180: ARP resolved the MAC, ICMP and all TCP dead). ICMP therefore
separates "HA lost the HAP session" from "the device's stack is hung" — exactly the discrimination
needed. It also correctly fires when the FP2 has fallen off Wi-Fi entirely, where a power-cycle is also
the right move.

Cost of the corroborator: it needs a stable IP and a working ping path (§6.3, §8).

### 3.4 Rejected: lux `last_updated` staleness

**Rejected outright — it produces a false positive every single night.**

Measured gap distribution between lux state writes, 2026-07-21T00:00 → 2026-07-23T06:00
(1 580 samples): median **14 s**, p90 217 s, p99 959 s — but **max 30 253 s (8 h 24 m)**, second-largest
25 179 s (7 h 00 m). Both maxima are overnight, when the kitchen is dark, lux pins at 0 lx and HA
records no new state at all. (HA only writes a new state object when the state or an attribute
changes, so `last_updated` does **not** refresh on a repeated identical `0`.)

Any stale threshold useful for a 30-minute detection would fire on a perfectly healthy sensor every
night. A threshold above 8.5 h would be useless. The "~2.5–5 min normal reporting" figure in the
memory note is a **daytime** average and does not hold after dark. This signal is unusable; it stays
out of the design entirely, not merely as a secondary.

### 3.5 Rejected: presence stuck on / stuck off

Also rejected. Presence zone 3 legitimately reads `off` for the whole night and legitimately reads `on`
for many consecutive hours during an evening in the kitchen — no "implausible duration" exists that is
simultaneously safe and useful. It is also redundant: when presence is frozen by a wedge, the entity is
`unavailable`, which the primary signal already catches. Adding it would only add false positives.

---

## 4. Recovery action

### 4.1 Sequence

```
0.  guard checks (§5): paused_flag off
                       now - last_cycle >= min_interval (30 min)
                       cycles_24h < max_cycles_24h (8)   -> else high-prio notify, exit (§5.1)
                       plug_switch not unavailable        -> else notify, exit (§5.4)
1.  input_boolean.turn_on  suppress_flag                # dependent automations stand down (§7)
2.  set variable t0 = now()
3.  switch.turn_off        plug_switch
4.  delay                  15 s
5.  switch.turn_on         plug_switch
6.  counter.increment      cycle_counter, total_counter
7.  wait_template          (fresh lux report, §4.3)     timeout 300 s
8a. success -> reset consecutive_failures to 0
    logbook.log "FP2 hersteld na power-cycle (Ns)"
    delay 120 s ; re-check still available   # guard against instant re-drop
    input_boolean.turn_off suppress_flag
    if cycles_24h == notify_at_cycle (3) -> notify "lijkt te degraderen" (§5.3)
    else silent
8b. timeout -> increment consecutive_failures
    logbook.log "FP2 kwam niet terug"
    input_boolean.turn_off suppress_flag
    if consecutive_failures >= 2 -> set paused_flag + high-prio notify (§5.2)
```

`mode: single`, `max_exceeded: silent`.

### 4.2 Off-duration: 15 s — justification

The FP2 is a 5 V USB device. Its bulk input capacitance is on the order of a few hundred µF; with the
board's own quiescent load the 5 V and 3.3 V rails collapse in well under a second, and even a
worst-case 470 µF against a 100 kΩ bleeder is ~47 s per RC — but the SoC brown-out threshold is
crossed within the first ~1–2 s, which is what actually matters for a cold boot. The empirically
established procedure that works is the user's manual "unplug ~10 s".

**15 s** is chosen as ~10× the practical rail-collapse time and a 50 % margin over the manual
procedure that is already known to work, while still being short enough that the FP2 is blind for well
under a minute of the total cycle. Nothing is gained above ~30 s; below ~5 s there is a real risk of the
SoC never reaching brown-out and the hang surviving the cycle.

### 4.3 Re-join expectation

**Not yet measured** — the 2026-07-20 manual power-cycle was not timed, and I will not invent a number.
Design budget:

- expected: Aqara FP2 boot + Wi-Fi association + mDNS/HAP re-advertise ≈ **20–60 s**, plus HA's
  homekit_controller reconnect (zeroconf-driven, usually immediate on re-advertise).
- **success window: 180 s** — used for the "fast recovery" logbook classification.
- **hard timeout: 300 s** — beyond this the cycle is declared failed.

**Action for build phase:** the automation logs the measured `now() - t0` on every successful recovery.
After the first 3–5 real recoveries, tune `recovery_timeout` to measured p95 + 60 s and record the
result in the build change record. Until then 300 s is a deliberately generous guess, stated as such.

---

## 5. Guards

### 5.0 Counterfactual replay against the 07-15 → 07-20 incident

Every guard below is sized by replaying the detection rule against the real recorder timeline. The
replay models the intervention: when the watchdog fires at time *t*, the in-progress outage is
truncated at *t* and the device is treated as up from *t*+150 s. **Conservative assumption, stated
explicitly:** every *later* real episode is assumed to still occur exactly as recorded. A real power
cycle might have prevented some of them; the replay gives that no credit. Simulation script and raw
episode data are attached to `chg-2026-07-23-004`.

#### Run 1 — the design as originally specced (A1 only, cap 3/day)

```
07-15   0 fires
07-16   0 fires          <- 90 episodes, 366 min down, longest 23 min. Invisible to A1.
07-17   0 fires
07-18   0 fires
07-19   3 fires   04:19 (A1, waited 30m, #1)
                  12:01 (A1, waited 30m, #2)
                  20:41 (A1, waited 30m, #3)   <- rate cap now full
              !!  22:17  BLOCKED BY CAP  <- this is the 318-minute wedge,
                                            the worst single event in the dataset
07-20   1 fire    11:32 (A1, #3 of that day)

realised downtime 21.36 h  (baseline 22.61 h)  -> 1.25 h saved out of 22.6
```

**Atlas was right, and the failure arrives through the rate cap, not the give-up latch.** The
give-up latch never fires at all in this incident — the FP2 always did come back on its own, so every
modelled recovery succeeds and the "2 consecutive failed recoveries" counter never leaves zero. But the
**3-per-day cap blocks the 5 h 18 m outage at 22:17 on 07-19**, the single event the watchdog most
exists for. Combined with four days of total blindness, the as-specced design recovers 5.5 % of the
lost time. It is, as Atlas put it, worse than useless — it would also have created the false
impression that the problem was handled.

#### Run 2 — A1 only, cap raised to 6 per rolling 24 h

```
07-15..18   0 fires       <- still blind for four days
07-19       4 fires   04:19, 12:01, 20:41, 22:17 (A1)   <- 22:17 now acted on
07-20       1 fire    11:32
realised downtime 16.57 h   (6.0 h saved)
```

Raising the cap alone fixes the blocked-worst-event hole and quadruples the benefit. Still blind
07-15→07-18.

#### Run 3 — RECOMMENDED: A1 (30 min) + A2 (75 min / 4 h, dwell 10 min), min-interval 30 min, cap 8 / 24 h

```
07-15   0 fires
07-16   5 fires   03:24 (A2, down 10m, #1)   silent
                  04:56 (A2, down 10m, #2)   silent
                  07:21 (A2, down 10m, #3)   *** NOTIFY: degrading ***
                  08:08 (A2, down 10m, #4)
                  11:50 (A2, down 13m, #5)
07-17   0 fires
07-18   0 fires
07-19   5 fires   04:19 (A1, waited 30m, #1) silent
                  12:01 (A1, waited 30m, #2) silent
                  20:01 (A2, down 12m, #3)   *** NOTIFY: degrading ***
                  20:32 (A2, down 21m, #4)
                  21:57 (A2, down 10m, #5)   <- pre-empts the 318-min wedge
07-20   1 fire    11:32 (A1, waited 30m)

total 11 fires, 0 blocked by cap (peak day 5, cap 8 -> 3 spare)
realised downtime 15.35 h   (7.3 h saved, 32 % reduction)
```

The 318-minute wedge is now cut off at 21:57 on 07-19, 10 minutes in, instead of running to 03:05.
No day approaches the cap. Nothing fires on any of the five clean days.

### 5.1 Rate cap — max 8 cycles per rolling 24 h (was 3/day)

**Rolling 24 h, not a wall-clock day.** Implemented as a `history_stats` sensor of type `count` on the
plug switch entering `off` in the last 24 h — self-maintaining, no counter helper, no reset trigger,
and no artificial midnight/04:00 boundary that a spiral can straddle. (The original 04:00-reset counter
is dropped; `counter.fp2_keuken_powercycles_totaal` is retained, never reset, purely for trend.)

Health-based reset remains rejected: the longest continuous healthy run in the whole window was 10.1 h
and only 5 runs exceeded 6 h, so "reset after N hours healthy" would essentially never reset.

**Cap = 8.** Sized off the replay, not off an average: the worst modelled day needs 5 cycles, so 8
leaves 3 spare. The cost of a cycle is ~2.5 min of blindness and one relay operation — 8/day is 20 min
of blindness against the 10.6 h the device lost on 07-19, and is nothing for a relay rated in the tens
of thousands of operations. **The cap is a runaway brake, not a wear budget.** Sizing it near the
expected rate is precisely the mistake that produced Run 1.

**Minimum interval between cycles: 30 minutes.** This, not the cap, is what prevents pathological
back-to-back cycling. It bounds the worst case at 48/day structurally, and the cap then trims that to 8.

**Hitting the cap must never mean silence.** In Run 1 the cap fired at exactly the moment of peak need
and did nothing, quietly. New rule: when the cap is reached **and the device is still or again down**,
the watchdog sends a **high-priority notification** — *"FP2 keuken: 8× power-cycled in 24 u en nog
steeds offline. Watchdog is uitgeput, handmatige aandacht nodig."* A device needing more than 8 cycles
in a day needs a human, and the user must not discover a five-hour outage the next morning.

### 5.2 Give-up — two distinct outcomes, only one of which may latch

The original "2 consecutive failures" was sized against a steady trickle. Re-sequenced to separate the
two outcomes explicitly, as Atlas asked:

| outcome | meaning | response |
|---|---|---|
| **failed recovery** — cycled, no fresh lux report within `recovery_timeout` | the device never came back. Dead hardware, dead PSU, dead plug. | **latches fast** — 2 consecutive ⇒ pause + notify |
| **recovered-then-re-wedged** — came back with a fresh lux report, degraded again later | this is the spiral. The mechanism is *working*. | **never latches** — drives escalation only (§5.3) and consumes rate-cap budget |

This separation is what makes the latch safe during a spiral, and the replay proves it: across the
entire 07-15→07-20 incident the FP2 always did come back, so **the failed-recovery counter never
leaves zero and the latch never arms.** All eleven modelled cycles are "recovered-then-re-wedged",
which under the revised rules costs nothing but a counter increment.

Conversely the latch stays genuinely fast for its actual purpose: if the FP2 is physically dead, two
cycles ~30 min apart is all the evidence needed, and there is no scenario in the data where a live
device fails to return twice in a row.

**Failed-recovery detail:** two *consecutive* failures, and a single success resets the streak to zero.
Counting cumulative rather than consecutive failures would let a spiral with one slow boot creep
toward the latch.

When 2 consecutive failed recoveries do occur:

- set `input_boolean.fp2_keuken_watchdog_gepauzeerd` = on
- send **one** notification: *"FP2 keuken reageert niet na 2 power-cycles — watchdog gepauzeerd.
  Waarschijnlijk hardware. Zet `input_boolean.fp2_keuken_watchdog_gepauzeerd` uit om te hervatten."*
- stand down; every later trigger exits at guard 0 silently.

Resume is manual only (deliberate).

### 5.3 Notification policy — escalating, sized for the spiral

"Silent on success, Monday digest otherwise" was right for an isolated blip and **wrong for a spiral**.
On 07-19 the user needed telling while it was happening; under rev 1 their first signal would have been
a rate-cap message at 20:41 on day five, and the 5 h 18 m outage that followed would have been
discovered the next morning. Revised, driven by the rolling-24 h cycle count:

| event | notification |
|---|---|
| cycle #1, #2 in trailing 24 h | **silent** — logbook + counter only |
| **cycle #3 in trailing 24 h** | **notify, normal priority.** *"FP2 keuken is 3× hersteld in 24 u — sensor lijkt te degraderen."* This is the pattern-establishing signal. |
| cycles #4–#7 | silent (no repeat spam; the user has been told) |
| **cap reached (#8) and still down** | **notify, high priority** (§5.1) |
| **2 consecutive failed recoveries** | **notify, high priority** + latch (§5.2) |
| A2 degradation crossing while *not* firing (device recovered on its own) | notify at most once per 12 h: *"FP2 keuken was N min offline in de laatste 4 uur."* |
| plug unreachable (§5.4) | notify once per day |

Replayed against the incident, the user receives:

```
07-16 07:21   "3× hersteld in 24 u, lijkt te degraderen"      <- day two of the spiral
07-19 20:01   "3× hersteld in 24 u, lijkt te degraderen"
(nothing else)
```

Two messages across a six-day incident, the **first three days earlier than rev 1 would have managed**,
and zero messages on the five clean days. That is the balance the brief asked for: silent for the
isolated case, loud enough to be actionable once the pattern establishes, never per-event.

**Trend, not events:** `counter.fp2_keuken_powercycles_totaal` (never reset), the rolling-24 h count,
and `sensor.fp2_keuken_downtime_4u` (the A2 gauge, which doubles as a live degradation read-out) go on
the kitchen dashboard diagnostics/Netwerk subview. Optional Monday 09:00 digest, fires **only if** the
week's count > 0: *"FP2 keuken: N power-cycles afgelopen week."*

### 5.4 Plug-availability guard

If `plug_switch` is `unavailable` when the watchdog wants to act, it cannot recover the FP2 and must
not fail silently: log + notify once per day *"FP2 watchdog kan de stekker niet bereiken"*.

**Specific footgun:** on HomeWizard Energy Sockets, enabling **Schakelslot** (switch lock) makes the
`switch.` entity go `unavailable`. 15 of the household's 25 sockets are in that state today
(fridge, freezer, steam oven, boiling-water tap…). If anyone enables the lock on the FP2's socket the
watchdog dies quietly. This guard is what makes that visible.

---

## 6. Prerequisites the user must action

### 6.1 There is no spare smart plug — this needs a purchase

Checked against the local entity catalog and confirmed live: the household has **25 HomeWizard Energy
Sockets** (`button.energy_socket_identify` … `_25`). **Every one is assigned to a named load** —
Koelkast, Vriezer, Stoomoven, Kokendwaterkraan, Espresso Volautomaat, Combimagnetron, Chiller Kraan,
Synology NAS, Sonos ×9, Computer Jurre/Niko, Mac Studio 1, Platenspeler Versterker, Subwoofer,
Elektrische Fiets Lader, VDHPOESW01, VDHNGFW. No unassigned or idle socket exists.

Other switchable things in HA are not candidates: the Shelly 1PM Mini G3 units are inline relays behind
fixed Sonos loads, and the Greenwave "Stroomblok" Z-Wave strips are in the AV cabinet, not the kitchen.

### 6.2 What to buy

- **1× HomeWizard Energy Socket** (~€30). Recommended because it is the household standard, already
  integrated locally (no cloud dependency), and gives power metering as a free bonus signal —
  the FP2's ~1 W draw confirms the cycle physically happened, independent of HA's HAP view.
- **1× USB power adapter, 5 V / ≥1 A** — the FP2 is USB powered and ships with a cable but the
  adapter must be plugged into the Energy Socket. Any decent 5 V 1 A/2 A brick.
- Physical placement: the socket must be at the FP2's mounting location in the kitchen and must carry
  **nothing else** — the watchdog will cut it without warning.
- After install: leave **Schakelslot / switch lock OFF** on this socket (§5.4).

Alternative if the user prefers not to buy HomeWizard: a Zigbee plug on the existing z2m network
(channel 25, clean) works equally well and is cheaper, at the cost of a second plug ecosystem.
Either is fine; the blueprint takes any `switch.` entity.

### 6.3 DHCP reservation (Iris, medium risk — separate change)

For the ICMP corroborator the FP2 needs a stable IP. Per memory `reference_aqara_fp2_wedge` the UniFi
client object already carries `fixed_ip: 172.16.3.81` but `use_fixedip: false`, so it is currently on a
dynamic lease (.79). Iris should activate the reservation. This is worth doing **regardless** of the
watchdog — it stops HA's HomeKit endpoint breaking on a lease change.

### 6.4 Firmware

Still on 1.3.6. Check the Aqara app for a newer build before we build the watchdog — if a firmware fix
exists, the watchdog becomes a safety net rather than the primary mitigation. Athena could not verify
the current latest version (Aqara FAQ served a placeholder), so this is a manual check by the user.

---

## 7. Interaction risk with existing automations

Read live from `/config/automations.yaml` on 2026-07-23.

### 7.1 `Adaptieve Verlichting Begane Grond` (id 1753005600006) — LOW risk, real but bounded

- Trigger `presence` is `to: 'on'` **`from: 'off'`**. On recovery the transition is `unavailable → on`,
  which does **not** match `from: 'off'`. **No spurious fire from this trigger.**
- Trigger `lux_dark` is `numeric_state below: 40 for: 2 min`. A numeric_state trigger whose previous
  state was non-numeric (`unavailable`) **will** fire when a valid value below 40 arrives. So a
  power-cycle that returns a dark reading *can* fire this. It is however gated by:
  time 12:00–23:00, sun after sunset−1 h, the `input_boolean.adaptief_bg_vanavond_gedaan` once-per-evening
  latch, and a live `presence_sensor_3 == 'on'` condition.
- **Net:** a spurious light-on is only possible in the sunset−1h→23:00 window, on an evening where the
  lights had not already been switched on, while someone is actually standing in the kitchen and it is
  actually dark. In that situation turning the lights on is the intended behaviour anyway. The
  fail-safe `has_value()` condition already handles the `unavailable` state correctly.
- Worth noting this risk **exists today** on all 265 unavailable episodes; the watchdog does not create it.

### 7.2 `Woonlaag - Nachtelijke uit` (id 1753005600008) — NO spurious off; slight delay

- Both the `all_clear_15m` trigger and the "Alle activiteit weg" condition use
  `is_state(presence_3, 'off')`. While the FP2 is `unavailable` that is **False**, so the automation is
  inert during the power cycle and the 15-minute template timer **resets**.
- After recovery, if someone is in the kitchen the FP2 reports `on` well within the 15-minute window,
  so the template never sustains. If nobody is there it reports `off` and the lights go out — which is
  the correct, desired behaviour and is precisely what the wedge was *blocking*.
- **Only side effect:** a power cycle can delay the nightly lights-off by up to ~15 min. Benign.

### 7.3 `Ochtend Keuken Routine` (1742276544597) and `… Weekend` (1761372469810) — LOW risk, worth suppressing

- Both trigger on `presence_sensor_3` `to: 'on'` **`from: 'off'`**. `unavailable → on` does not match.
- The residual path is `unavailable → off → on`: the FP2 boots, reports `off`, then its mmWave settles
  and detects (correctly, or spuriously during settling) within the 05:30–09:30 window. That would
  start the coffee machine and Radio Veronica.
- Both already carry a 4-hour `last_triggered` self-guard, so blast radius is one event.
- **This is the one case worth actively preventing** — a spurious Radio Veronica at 06:10 is exactly
  the kind of noise the user does not want.

### 7.4 Recommended mitigation

Add `input_boolean.fp2_keuken_watchdog_actief` (set for the whole cycle **plus a 3-minute settle tail**
after recovery) as a `state: 'off'` condition on the four automations above. That is a **medium-risk**
change touching four existing automations and should be its own change record in the build phase,
QA'd by Themis, with a documented rollback (the condition is additive and removable).

If the user prefers not to touch working automations, §7.1–7.3 show the residual risk is small and
mostly self-correcting — but then the morning-routine path in §7.3 stays open. **My recommendation is
to add the suppression flag**; it is 4 one-line condition additions and it makes the watchdog's
side-effects provably zero.

### 7.5 Incidental finding — not part of this design

The weekday/weekend morning routines look **swapped**: `Ochtend Keuken Routine` (with Radio Veronica)
has a weekday condition listing **all seven days**, while `Ochtend Keuken Routine - Weekend`
(no radio) has a weekday condition of **mon–fri**. As written, on Mon–Fri *both* fire and on Sat/Sun the
"weekday" one with radio fires. Flagged to Atlas as a separate item; **no change made here.**

---

## 8. Open questions / risks to resolve before building

1. **Can the HA pod ICMP into 172.16.3.0/24?** HA runs in Kubernetes; the `ping` integration needs
   either a `ping` binary in the container or raw-socket capability. If neither works from the pod,
   the ICMP corroborator is unavailable and we fall back to §8.2. **Must be tested first** — this is
   the single biggest unknown in the design.
2. **Fallback corroborator:** add the FP2 (`54:ef:44:51:f0:8e`) to the UniFi integration's tracked
   clients, giving a `device_tracker` for the FP2. `home` (still associated) + entity `unavailable`
   is the exact wedge signature. Weaker than ICMP — "associated" is also true when HA itself is the
   problem — but better than no corroborator. No such tracker exists today.
3. **Rejoin time is a guess (§4.3)** until measured on the first real recovery.
4. **A power cycle is not guaranteed to fix every wedge.** The give-up latch (§5.2) is what bounds that.
5. **Reducing single-sensor dependence** remains the real structural fix — four automations hang off one
   flaky €50 sensor. A second lux source on the ground floor would de-risk this more than any watchdog.
   Out of scope here; recommended as a follow-up.

---

## 9. Build plan (for approval, not yet executed)

| step | risk | owner | artefact |
|---|---|---|---|
| 0 | — | user | buy Energy Socket + USB adapter; install in kitchen; check FP2 firmware |
| 1 | medium | Iris | activate DHCP reservation 172.16.3.81 for the FP2 |
| 2 | low | Hestia | test ICMP reachability from the HA pod; decide corroborator (§8.1/§8.2) |
| 3 | low | Hestia | create helpers: 1 counter, 2 input_booleans, 1 input_number (consecutive failures), 2 `history_stats` sensors (`_downtime_4u`, `_cycles_24u`) |
| 4 | medium | Hestia | ping binary_sensor (or UniFi tracked client) |
| 5 | medium | Hestia | blueprint + kitchen instance |
| 6 | medium | Hestia | suppression condition on the 4 dependent automations (§7.4) |
| 7 | — | Hestia | end-to-end test: force the FP2 offline, observe detection → cycle → recovery, capture evidence |

Test-evidence plan for the medium steps: the end-to-end test is step 7 — physically pull the FP2 (or
switch its plug off manually) and let the watchdog run unassisted, with the logbook, both counters and
the lux `last_updated` timestamps captured as the artefact. That is a real end-to-end run against the
real device, not a simulated trigger.

---

## Appendix — evidence sources

All figures above come from live reads on 2026-07-23:

- `sensor.presence_sensor_fp2_f08e_light_sensor_light_level` history, 2026-07-21T00:00→2026-07-23T06:00,
  1 580 samples — gap distribution (§3.4).
- `binary_sensor.presence_sensor_fp2_f08e_presence_sensor_1` history, 2026-07-13T04:01→2026-07-23T06:27,
  265 unavailable episodes — episode statistics and threshold sweep (§1.1, §3.2), per-day incident
  structure (§1.2), availability run-lengths (§5.1).
- Counterfactual replay simulation over the same episode list, modelling truncation-on-intervention —
  §5.0 Runs 1–3 and the A2 window selection in §3.2b. Script + episode data attached to
  `chg-2026-07-23-004`.
- Live entity states for all 25 HomeWizard Energy Sockets (§6.1).
- `/config/automations.yaml` read from the HA PVC — automations 1742276544597, 1753005600006,
  1753005600008, 1761372469810 (§7).
