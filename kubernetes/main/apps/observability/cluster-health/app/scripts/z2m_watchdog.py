#!/usr/bin/env python3
"""z2m bridge auto-recovery.

Polls Home Assistant for the zigbee2mqtt bridge connection state.
If the bridge has been offline long enough that this is unlikely to be
a transient blip, restart the deployment — which forces a fresh TCP
handshake to the SLZB-06 coordinator and clears the half-open-session
wedge that caused the 30h crashloop on 2026-04-27.

Designed to run on a 5-minute CronJob. State persists at /data/state/z2m_watchdog.json.

Recovery decision:
  bridge "off" for >= MIN_OFFLINE_MINUTES → rollout restart, set cooldown
  bridge "on"                              → clear "first seen offline" stamp
  cooldown active                          → log skip, do nothing

The cooldown prevents thrashing when restart-doesn't-fix-it (e.g. SLZB
hardware actually dead). One restart per RESTART_COOLDOWN_MINUTES window.
DRY_RUN is honored so the user can audit before it acts on prod.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, "/scripts")
from lib import STATE_DIR, ha_get, log, now_iso, read_json, run, write_json  # noqa: E402

DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
MIN_OFFLINE_MINUTES = int(os.environ.get("Z2M_OFFLINE_MIN_MINUTES", "10"))
RESTART_COOLDOWN_MINUTES = int(os.environ.get("Z2M_RESTART_COOLDOWN_MINUTES", "30"))
TARGET_NS = os.environ.get("Z2M_NAMESPACE", "home-automation")
TARGET_DEPLOY = os.environ.get("Z2M_DEPLOYMENT", "zigbee2mqtt")
ENTITY_ID = os.environ.get("Z2M_BRIDGE_ENTITY", "binary_sensor.zigbee2mqtt_bridge_connection_state")

STATE_FILE = STATE_DIR / "z2m_watchdog.json"


def load_state() -> dict:
    return read_json(STATE_FILE, default={}) or {}


def save_state(s: dict) -> None:
    write_json(STATE_FILE, s)


def parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def main() -> int:
    bridge = ha_get(f"/api/states/{ENTITY_ID}")
    if not bridge:
        log("could not fetch bridge state from HA — aborting (HA may be down too)")
        return 0  # don't fail the cronjob

    state = bridge.get("state")
    log(f"bridge {ENTITY_ID} state={state}")

    s = load_state()
    now = datetime.now(timezone.utc)

    # Bridge healthy → reset offline tracking. Leave cooldown alone so we
    # don't immediately restart again if it flips off in the next minute.
    if state == "on":
        if "first_seen_offline" in s:
            log("bridge recovered — clearing first_seen_offline")
            s.pop("first_seen_offline", None)
            save_state(s)
        return 0

    # Bridge is off (or unavailable / unknown — treat all non-"on" as bad).
    first_seen = parse_iso(s.get("first_seen_offline"))
    if not first_seen:
        s["first_seen_offline"] = now_iso()
        save_state(s)
        log(f"bridge offline first observed at {s['first_seen_offline']}")
        return 0

    offline_minutes = (now - first_seen).total_seconds() / 60.0
    log(f"bridge has been offline for {offline_minutes:.1f} min (threshold {MIN_OFFLINE_MINUTES})")

    if offline_minutes < MIN_OFFLINE_MINUTES:
        return 0

    # Cooldown gate
    last_restart = parse_iso(s.get("last_restart"))
    if last_restart:
        cooldown_minutes = (now - last_restart).total_seconds() / 60.0
        if cooldown_minutes < RESTART_COOLDOWN_MINUTES:
            log(f"in cooldown ({cooldown_minutes:.1f}/{RESTART_COOLDOWN_MINUTES} min) — skipping restart")
            return 0

    log(f"{'[DRY]' if DRY_RUN else '[FIX]'} rolling restart deploy/{TARGET_DEPLOY} in {TARGET_NS}")
    audit = {
        "ts": now_iso(),
        "action": "z2m_rollout_restart",
        "target": f"{TARGET_NS}/Deployment/{TARGET_DEPLOY}",
        "reason": f"bridge {ENTITY_ID} offline for {offline_minutes:.1f} min",
        "dry_run": DRY_RUN,
    }
    if DRY_RUN:
        audit["outcome"] = "dry-run"
    else:
        rc, out, err = run(
            ["kubectl", "-n", TARGET_NS, "rollout", "restart", "deployment", TARGET_DEPLOY],
            timeout=30,
        )
        audit["outcome"] = "ok" if rc == 0 else f"error: {err.strip()[:200]}"
        audit["rc"] = rc
        if rc == 0:
            s["last_restart"] = now_iso()
            # Clear first_seen_offline so the next failure window starts
            # only after we observe the post-restart state.
            s.pop("first_seen_offline", None)
            save_state(s)

    # Append to the same audit log triage.py uses, so the daily report
    # shows watchdog actions next to the auto-fix entries.
    audit_path = Path("/data/triage/audit.jsonl")
    audit_path.parent.mkdir(parents=True, exist_ok=True)
    with audit_path.open("a") as f:
        f.write(json.dumps(audit, default=str) + "\n")

    log(f"action={audit.get('action')} outcome={audit.get('outcome')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
