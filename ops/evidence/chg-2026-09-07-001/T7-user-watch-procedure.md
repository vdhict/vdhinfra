# T7 — Kantoor aircon cool-start: what to watch, and what to do

**chg-2026-09-07-001.** Written because a closed change record watches nothing.
**Holder: the user (Sander).** Atlas cannot observe this; it needs a genuinely hot office.

## Why this exists

The cool-start threshold moved **23.0 → 23.5 °C** and the automation now forces a
sensor refresh before deciding. The *negative* path is proven live. The *positive*
path — the aircon still starting when it genuinely should — is proven only by replay
against real historical data.

A live positive test is **impossible by construction**, not merely inconvenient: a
faked sensor value would be wiped by the automation's own `update_entity` before any
branch reads it. So the first real hot weekday is the test.

## Trigger condition

The **first weekday** the office reaches **≥ 23.5 °C between 08:00 and 18:00**, with
the window shut. Two automations can start the unit:
- `Kantoor Ochtend - Klimaat` (08:30 one-shot, weekdays)
- `Kantoor Aanwezig - Comfort setpoint` (on presence latch)

## What SHOULD happen

Aircon starts, cool, setpoint 21 °C. Possibly ~30 min later than you'd have expected
before — that delay is the fix working, not a fault.

## What FAILURE looks like

| Symptom | Meaning |
|---|---|
| Office ≥ 23.5 °C in-window, sat there 30+ min, aircon never starts | **Real failure.** Threshold or freshness gate too strict. |
| Aircon starts when the room is clearly comfortable (< 23 °C) | Dead-band not doing its job. |
| Aircon starts, then room drops well below 21 °C and it keeps cooling | Known, **not** this change — nothing re-evaluates until 18:00. Separate follow-up. |

## What to do on failure

Tell Atlas. Do not edit anything. Say: the time, the room temperature you saw, and
which of the three rows above it matched.

## Rollback (Atlas runs this; recorded so it is not lost)

```bash
POD=$(kubectl -n home-automation get pod -l app.kubernetes.io/name=home-assistant \
       -o jsonpath='{.items[0].metadata.name}')
kubectl -n home-automation cp \
  ops/evidence/chg-2026-09-07-001/automations.before.yaml \
  $POD:/config/automations.yaml -c app
# verify in-pod md5 == 5b629a4edd1541fac11c8f6f9d7cb178 (89466 B)
# POST /api/config/core/check_config  -> must be "valid"
# POST /api/services/automation/reload
```
Rollback is additive-free and fully restores prior behaviour.

## Residual risk carried into production (accepted, Themis)

**R1** — if the forced refresh *fails*, a reading up to 2 h old is still permitted.
Measured 120-min drift p99 **1.51 °C**, max **2.14 °C**, which fully consumes the
0.5 °C dead-band. Same failure class as the original incident, but it now needs **two**
failures where the old code needed none. Proper fix gates on the coordinator outcome
rather than publish age — not done here.
