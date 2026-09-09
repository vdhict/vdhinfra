# Like-for-like replay — Kantoor adaptive lighting
Same real input stream for every row: `sensor.multisensor_illuminance`,
2026-09-09 00:00:00Z → 12:59:43Z (183 numeric samples), entirely BEFORE the
param 40/42 write, so no row is contaminated by chg-2026-09-09-003.
Occupancy from the real `binary_sensor.kantoor_bezet` (261 occupied minutes).

## Engine validated before use
Replaying the SHIPPED logic reproduces reality, so the new-logic rows mean something:

| check | result |
|---|---|
| service calls predicted | **17** (Themis independently reported 17, from different code) |
| on/off transitions predicted | **9** |
| match vs real `light.kantoor` logbook | all 9, correct order + direction, worst timing delta **1.3 s** |
| Themis spot-check `31%→73% in 94 s` | reproduced: 11:48:32 → 11:50:06 |
| Themis spot-check `27%→62% in 6 min` | reproduced: 12:43:26 → 12:49:42 |

The two events at `08:32:41 on` / `08:32:55 off` are NOT reproduced, because they
were not ours — see the exogenous-artefact note below.

## The comparison

| | service calls | on/off transitions | of which daylight-driven | dark & unlit (min) | MAE when lamp should be lit |
|---|---|---|---|---|---|
| **IDEAL controller, ORIGINAL policy** (perfect, noise-free, off above 600 lux) | n/a | **7** | 7 | 0 | 0 by definition |
| **OLD (shipped)** | 17 | 9 | 7 | 0 | 11.3 pts |
| **IDEAL controller, NEW policy** (10% floor, off only >1500 sustained / absence) | n/a | **0** | 0 | 0 | 0 by definition |
| **NEW (this change)** | **10** | **3** | **0** | **0** | 12.1 pts |

Read the ideal rows first. Against zero, OLD's 9 transitions look like a disaster.
Against what is **achievable**, OLD's excess was only **2** — the day genuinely
crossed the 600-lux line seven times (true ambient swung 75 → 1618 lux). That is
why filtering could not be the fix, and why the fix had to be a **policy** change:
under the new policy the achievable number of daylight transitions is 0, and the
new logic achieves 0.

`dark & unlit` = occupied minutes where the room was genuinely dim (<400 lux) and
the lamp was OFF. **This is the row that stops us fooling ourselves.** Optimising
for "fewest service calls" alone produced a 1-call design with **65** dark-and-unlit
minutes — a lamp that had stopped doing its job. That candidate was rejected on
this column alone.

## Robustness to the kappa uncertainty
kappa (lamp's own lux per brightness-%) is only bounded to 0.73–2.0, so it was swept
rather than assumed:

| kappa | service calls | on/off transitions | dark & unlit |
|---|---|---|---|
| 0.73 | 9 | 3 | 0 |
| 1.1 | 10 | 3 | 0 |
| 2.0 | 10 | 3 | 0 |

The result does not depend on which kappa is true.

## The 3 remaining transitions are all presence, none daylight
`07:59:23 on` (arrival) · `10:20:00 off` (real 10:02:28 departure + the new 10-min
dwell) · `10:50:00 on` (real 10:41:05 return, delayed 9 min because the room was
still >1200 lux — correct behaviour, not a fault).

## Honest limits of this replay
- The recorded lux contains the OLD lamp's own contribution. To replay a different
  trajectory it is backed out (`ambient_true = recorded − kappa·br_old`) and the
  simulated one re-added. That reconstruction is only as good as kappa — hence the sweep.
- Replay is **necessary, not sufficient**. Live regime tests still have to pass.
- **REGIME-INCOMPLETE**: sustained clear sky does not occur anywhere in the captured
  history, so the 1500-lux hard-off valve is exercised in **simulation only**. It has
  never fired against real data. This change must not be closed as if that regime were tested.

## Reproduce it
`ops/evidence/chg-2026-09-09-003/replay.py` + `luxlib.py`, fixtures in the same directory.
