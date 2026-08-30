# Runbook: corrupted energy statistics in Home Assistant

- **Owner**: Sibyl (`observability-engineer`) for the detector, Hestia (`ha-engineer`) for HA state
- **Written**: 2026-08-30, after `inc-2026-08-30-002`
- **Detector**: `health-energy-sanity` CronJob, daily 07:15 CEST (`obs.energy_sanity`)

---

## The failure mode

A device reports a **backward jump** on a `total_increasing` energy sensor. Home
Assistant reads any backward jump as *"the meter was replaced, start counting
from zero"* and adds the entire subsequent climb to the long-term statistic as
fresh consumption.

One flapping Z-Wave node did this repeatedly and pushed
`sensor.netwerk_electric_consumption_kwh_2` to **168,608 kWh** — 1,069 years of
runtime for a device drawing 18 W. Nobody noticed for three months, and the
Energy dashboard was wrong the whole time.

The important asymmetry:

| | |
|---|---|
| The **inflated total** | the symptom — surfaces months later, when the damage is done |
| The **backward jump** | the event — visible the same day |

Watch for the jump.

---

## Symptoms

- A device on the Energy dashboard reports an implausible share of household use.
- Energy dashboard totals disagree with the P1 meter.
- A `sensor.*_node_status` entity reads `dead`, or flaps between `alive` and `dead`.
- A power sensor is frozen at one value for days while its energy sensor keeps moving.

---

## 1. Confirm it is a reset, not a real load

```bash
# Statistic total — the symptom
./ha-cli.sh ws recorder/statistics_during_period \
  '{"start_time":"2026-01-01T00:00:00+00:00","statistic_ids":["sensor.<entity>"],"period":"month"}'
```

Then look at the raw state history for the backward jump. **The history API
defaults `end_time` to `start + 1 day`** — omit it and a 7-day query silently
returns only the first day, with no error:

```bash
curl -sS -H "Authorization: Bearer $(cat ~/Code/homelab-migration/config/hasskey)" \
  "http://172.16.2.237:8123/api/history/period/2026-08-29T00:00:00Z?filter_entity_id=sensor.<entity>&end_time=2026-08-30T00:00:00Z&minimal_response"
```

A drop that lands **near zero** is a period or session meter rolling over —
normal. A drop that lands at an **arbitrary non-zero value** is corruption.

---

## 2. Find the root cause before clearing anything

Clearing the statistic while the device is still faulty just re-corrupts it.

```bash
# Dead or flapping Z-Wave nodes
./ha-cli.sh states | jq -r '.[] | select(.entity_id|test("node_status")) | select(.state!="alive") | "\(.state)\t\(.entity_id)"'
```

`asleep` is **normal** for battery devices. `dead` is not.

To distinguish "dying device" from "bad RF link", check whether the node
*flaps* (repeated alive↔dead transitions) and whether its power sensor has
frozen. Both together point at the device.

---

## 3. Fix the device first

- Power-cycle the plug (unplug 10 s) and re-interview the node in Z-Wave JS.
- If it still flaps, replace it. Prefer a like-for-like radio — a mains-powered
  Z-Wave node is also a repeater, and 868 MHz avoids the congested 2.4 GHz band.
- Remove the entity from the Energy dashboard until it is replaced, so it stops
  polluting totals in the meantime.

---

## 4. Only then, clear the corrupted statistic

⚠️ **Destructive and irreversible.** It deletes all history for that statistic
id. Get the user's explicit approval. Clear only the affected id — never the
healthy twin.

```bash
./ha-cli.sh ws recorder/clear_statistics '{"statistic_ids":["sensor.<entity>"]}'
```

Verify afterwards that the target returns **0 points** and that any sibling
sensor is untouched.

---

## 5. Confirm the detector would have caught it

```bash
kubectl -n observability create job --from=cronjob/health-energy-sanity energy-sanity-manual
kubectl -n observability logs job/energy-sanity-manual
```

Also run the regression pins after touching any threshold:

```bash
python3 energy_sanity.py --selftest   # needs HA_URL + HA_TOKEN
```

---

## Design notes for whoever edits the detector

The reset rule is **value-based on purpose**, and must stay that way:

- A rollover lands at ~0. Corruption lands somewhere arbitrary. That single
  distinction is the whole rule.
- **Do not reintroduce name matching.** An unanchored `uur` matches
  "Apparat**uur**" and "Sch**uur**", which blinds the detector on
  `sensor.apparatuur_electric_consumption_kwh` — a Z-Wave sibling of the sensor
  the check exists for.
- Even anchored, name matching fails: `sensor.evcc_garage_session_energy` resets
  to zero after every charging session and carries no period token, so a
  name-based rule alerts each time the car finishes charging.
- **Aggregates are scanned for resets** (a reset in a grid meter matters most)
  but skipped for the magnitude checks, where large values are legitimate.

Known limitation, accepted deliberately: corruption that lands at exactly zero
is indistinguishable from a legitimate rollover and is not detected.

Related: `ops/cmdb.yaml` → `obs.energy_sanity`, `hw.plug.netwerk_stube`.
