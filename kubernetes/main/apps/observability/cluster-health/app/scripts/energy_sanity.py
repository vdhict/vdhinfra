#!/usr/bin/env python3
"""Catch energy sensors that are corrupting Home Assistant's long-term statistics.

WHY THIS EXISTS (inc-2026-08-30-002)
------------------------------------
sensor.netwerk_electric_consumption_kwh_2 ("Netwerk Stube") accumulated a
long-term statistic of 168,608 kWh for a device that draws 18 W — 1,069 years'
worth. It ran undetected from May to August 2026 and skewed the Energy dashboard.

The mechanism, confirmed live on 2026-08-30: its Z-Wave node is flapping
(alive→dead→alive→dead across 29–30 Aug) and while flapping it emitted a
spurious BACKWARD JUMP — 285.95 → 122.15 kWh at 05:05. HA's `total_increasing`
handling reads every backward jump as "the meter was replaced, count from zero"
and adds the whole re-climb as fresh consumption: ~164 kWh injected in one
morning.

So the signal to watch is NOT a large total. It is the RESET. A big total is the
symptom that surfaces months later; the reset is the event, visible the same day.

WHAT IT CHECKS
--------------
A. Backward jumps on `total_increasing` kWh sensors  <- the primary detector
B. 24 h forward deltas implying an impossible average power (backstop)
C. Instantaneous power that is physically impossible (counter overflow, e.g.
   sensor.stroomblok_electric_w at 107,374,182.9 W = 2^30 * 0.1)
D. Z-Wave nodes reporting `dead` — the usual root cause of A

Read-only: it reports, it never writes to HA state.

WHY THE RESET RULE IS PURELY VALUE-BASED
----------------------------------------
A meter that rolls over to ~zero is a period or session meter doing its job. A
meter that drops to some arbitrary non-zero value is broken. That single
distinction is the whole rule, and it deliberately uses NO name matching.

An earlier draft suppressed rollovers by matching names like "vandaag"/"today".
Two problems killed it, both found at QA:
  * Unanchored, it matched "Apparat*uur*" and "Sch*uur*", blinding the detector
    on sensor.apparatuur_electric_consumption_kwh — a Z-Wave sibling of the very
    sensor this check exists for.
  * Even anchored, plenty of legitimate meters roll to zero with no period token
    in the name at all: sensor.evcc_garage_session_energy resets after every
    charging session. A name-based rule alerts each time the car finishes.

Measured over 7 days × 162 total_increasing sensors: 26 roll-to-zero events, all
legitimate, all correctly ignored on value alone — and exactly one sensor
flagged, the genuinely broken one.

The accepted trade-off: corruption that happens to land at exactly zero is
missed. That is indistinguishable from a legitimate rollover, and a daily
notification is only worth having if it is trustworthy.

⚠️ HA HISTORY API FOOTGUN
-------------------------
`/api/history/period/<start>` defaults `end_time` to **start + 1 day**. Query a
7-day window without `end_time` and you silently get only the first day back,
with no error. Always pass `end_time` explicitly. This cost a debugging cycle: a
7-day sweep reported "no resets" while the sensor was resetting daily.
"""
from __future__ import annotations

import os
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone

sys.path.insert(0, "/scripts")
from lib import RAW_DIR, ha_get, http_post_json, log, now_iso, write_json  # noqa: E402

# A backward jump smaller than this is noise (rounding, a small genuine swap).
RESET_MIN_KWH = 5.0

# A drop landing at or below this is a rollover, not corruption. See the module
# docstring — this is the entire discriminator.
NEAR_ZERO_KWH = 1.0

# Backstop only; the reset detector is the sensitive one. The largest legitimate
# single-device day measured here is EV charging at ~53 kWh, so 240 is
# deliberately loose and exists to catch overflows, not to tune sensitivity.
MAX_PLAUSIBLE_DAILY_KWH = 240.0

# The EV charger is the biggest real load at ~11 kW; 20 kW leaves headroom while
# still catching counter overflows, which land in the megawatts.
MAX_PLAUSIBLE_W = 20_000

# Whole-house and inverter aggregates legitimately carry large values, so the
# MAGNITUDE checks (B and C) skip them. The RESET check does not — a reset in a
# grid meter matters most of all, and the value rule makes scanning them safe.
AGGREGATE_HINTS = (
    "p1_meter", "electricity_meter", "evcc_", "connect_energiemeter",
    "zonneplan", "growatt", "autolader",
)


def is_aggregate(entity_id: str) -> bool:
    return any(h in entity_id for h in AGGREGATE_HINTS)


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def select_candidates(states) -> list[tuple[str, str]]:
    """Every `total_increasing` kWh sensor — aggregates deliberately included.

    Factored out so --selftest can assert on it directly; the pinned ids in
    _MUST_SCAN must all survive this selection.
    """
    out = []
    for s in states:
        attrs = s.get("attributes") or {}
        if (
            attrs.get("device_class") == "energy"
            and attrs.get("unit_of_measurement") == "kWh"
            and attrs.get("state_class") == "total_increasing"
        ):
            eid = s.get("entity_id", "")
            out.append((eid, attrs.get("friendly_name") or eid))
    return out


def worst_backward_jump(vals: list[float]) -> tuple[float, float]:
    """Largest drop in the series and the value it landed on."""
    worst = landed = 0.0
    for a, b in zip(vals, vals[1:]):
        if a - b > worst:
            worst, landed = a - b, b
    return worst, landed


def is_corrupting(worst: float, landed: float) -> bool:
    """The rule. Value only — no names. See the module docstring."""
    return worst > RESET_MIN_KWH and landed > NEAR_ZERO_KWH


def history(entity_id: str, start: datetime, end: datetime) -> list[float]:
    """State history. end_time is mandatory — see the footgun note."""
    qs = urllib.parse.urlencode(
        {
            "filter_entity_id": entity_id,
            "end_time": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "minimal_response": "",
        }
    )
    path = f"/api/history/period/{start.strftime('%Y-%m-%dT%H:%M:%SZ')}?{qs}"
    h = ha_get(path)
    if not (isinstance(h, list) and h and h[0]):
        return []
    return [v for v in (num(p.get("state")) for p in h[0]) if v is not None]


def main() -> int:
    base = os.environ.get("HA_URL", "")
    token = os.environ.get("HA_TOKEN", "")
    target = os.environ.get("HA_NOTIFY_TARGET", "")
    if not base or not token:
        log("energy_sanity: missing HA_URL/HA_TOKEN, skipping")
        return 0

    states = ha_get("/api/states")
    if not isinstance(states, list):
        log("energy_sanity: could not read /api/states")
        return 1

    impossible_power: list[str] = []
    dead_nodes: list[str] = []

    for s in states:
        eid = s.get("entity_id", "")
        attrs = s.get("attributes") or {}
        name = attrs.get("friendly_name") or eid

        # D: dead Z-Wave nodes — the cause, not the symptom. `asleep` is normal
        # for battery devices and must never be flagged.
        if "node_status" in eid:
            if s.get("state") == "dead":
                dead_nodes.append(f"{name} ({eid})")
            continue

        # C: impossible instantaneous power
        unit = attrs.get("unit_of_measurement")
        if attrs.get("device_class") == "power" and unit in ("W", "kW") and not is_aggregate(eid):
            v = num(s.get("state"))
            if v is not None:
                w = v * 1000 if unit == "kW" else v
                if abs(w) > MAX_PLAUSIBLE_W:
                    impossible_power.append(f"{name}: {w:,.0f} W ({eid})")

    candidates = select_candidates(states)
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=24)
    resets: list[str] = []
    impossible_energy: list[str] = []

    for eid, name in candidates:
        vals = history(eid, start, end)
        if len(vals) < 2:
            continue

        # A: the corruption event itself
        worst, landed = worst_backward_jump(vals)
        if is_corrupting(worst, landed):
            resets.append(
                f"{name}: dropped {worst:,.1f} kWh to {landed:,.1f} — HA will add "
                f"that back as phantom consumption ({eid})"
            )

        # B: backstop on forward movement
        delta = vals[-1] - vals[0]
        if not is_aggregate(eid) and delta > MAX_PLAUSIBLE_DAILY_KWH:
            impossible_energy.append(
                f"{name}: +{delta:,.0f} kWh in 24 h = {delta * 1000 / 24:,.0f} W avg ({eid})"
            )

    findings = {
        "ts": now_iso(),
        "scanned": len(candidates),
        "resets": resets,
        "impossible_energy": impossible_energy,
        "impossible_power": impossible_power,
        "dead_nodes": dead_nodes,
    }
    write_json(RAW_DIR / "energy_sanity.json", findings)

    total = len(resets) + len(impossible_energy) + len(impossible_power) + len(dead_nodes)
    if total == 0:
        log(f"energy_sanity: clean — {len(candidates)} sensors scanned, no resets, no dead nodes")
        return 0

    lines: list[str] = []
    if resets:
        lines.append("Meter resets (these corrupt the Energy dashboard):")
        lines += [f"  • {x}" for x in resets]
    if impossible_energy:
        lines.append("Impossible daily energy:")
        lines += [f"  • {x}" for x in impossible_energy]
    if impossible_power:
        lines.append("Impossible power reading:")
        lines += [f"  • {x}" for x in impossible_power]
    if dead_nodes:
        lines.append("Dead Z-Wave nodes (the usual cause of the above):")
        lines += [f"  • {x}" for x in dead_nodes]
    body = "\n".join(lines)
    log(f"energy_sanity: {total} finding(s) across {len(candidates)} sensors\n{body}")

    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    http_post_json(
        f"{base}/api/services/persistent_notification/create",
        {
            "notification_id": "energy_sanity",
            "title": "⚠️ Energie: verdachte meterwaarden",
            "message": body,
        },
        headers=headers,
    )
    if target:
        http_post_json(
            f"{base}/api/services/notify/{target}",
            {"title": "⚠️ Energie: verdachte meterwaarden", "message": body},
            headers=headers,
        )
    return 0


# Regression pins. These exercise the REAL selection function and the REAL rule,
# not a parallel harness — an earlier round of this change was QA-failed for
# testing a value-only rule while shipping a different one.
_MUST_SCAN = (
    # over-matched by the old name regex; must stay scanned
    "sensor.apparatuur_electric_consumption_kwh",
    "sensor.verlichting_schuur_energie",
    "sensor.verlichting_schuur_energy_returned",
    # the incident sensor
    "sensor.netwerk_electric_consumption_kwh_2",
    # aggregates: a reset in a grid meter matters most, so they must be scanned
    "sensor.p1_meter_energy_import_tariff_1",
    "sensor.p1_meter_energy_export",
    "sensor.zonneplan_verbruik_vandaag",
)


def selftest() -> int:
    """`python3 energy_sanity.py --selftest` — needs HA_URL/HA_TOKEN."""
    bad: list[str] = []

    # The rule, against real observed values.
    cases = [
        # (worst, landed, should_flag, what)
        (163.8, 122.15, True, "Netwerk Stube 285.95->122.15, the incident"),
        (35.26, 0.0, False, "evcc_garage_session_energy rollover after a charge"),
        (13.22, 0.0, False, "zonneplan verbruik vandaag midnight rollover"),
        (0.5, 4.0, False, "small jitter below RESET_MIN_KWH"),
    ]
    for worst, landed, want, what in cases:
        if is_corrupting(worst, landed) != want:
            bad.append(f"rule: expected flag={want} for {what}")

    # Selection, against the live entity set.
    states = ha_get("/api/states")
    if isinstance(states, list):
        picked = {eid for eid, _ in select_candidates(states)}
        known = {s.get("entity_id") for s in states}
        for eid in _MUST_SCAN:
            if eid not in known:
                # A missing pin must FAIL, not skip. A typo'd pin
                # (sensor.p1_meter_energie_import_tarief_1) once passed while
                # asserting nothing at all.
                bad.append(f"selection: pinned {eid} does not exist — fix the pin or the entity")
            elif eid not in picked:
                bad.append(f"selection: {eid} must be scanned but was excluded")
        log(f"selftest: select_candidates picked {len(picked)} sensors")
    else:
        bad.append("selection: could not read /api/states (set HA_URL/HA_TOKEN)")

    for b in bad:
        log(f"selftest FAIL: {b}")
    if bad:
        return 1
    log("selftest OK: reset rule and candidate selection behave as pinned")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    raise SystemExit(main())
