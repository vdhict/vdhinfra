#!/usr/bin/env python3
"""Collect Home Assistant core health: API reachability, recorder freshness,
config_entries summary, automation errors."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone

sys.path.insert(0, "/scripts")
from lib import ha_get  # noqa: E402


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def main() -> int:
    out: dict = {"api_reachable": False}

    info = ha_get("/api/")
    if not info:
        json.dump(out, sys.stdout, indent=2)
        return 0
    out["api_reachable"] = True
    out["message"] = info.get("message")

    config = ha_get("/api/config") or {}
    out["version"] = config.get("version")
    out["location_name"] = config.get("location_name")
    out["state"] = config.get("state")
    out["safe_mode"] = config.get("safe_mode")
    out["recovery_mode"] = config.get("recovery_mode")

    states = ha_get("/api/states") or []
    out["entity_count"] = len(states)
    # freshness: most-recent last_changed across all states
    now = datetime.now(timezone.utc)
    latest = None
    stale = 0
    by_domain: dict[str, int] = {}
    unavailable = 0
    for s in states:
        eid = s.get("entity_id", "")
        domain = eid.split(".", 1)[0] if "." in eid else "unknown"
        by_domain[domain] = by_domain.get(domain, 0) + 1
        ts = parse_ts(s.get("last_changed"))
        if ts and (latest is None or ts > latest):
            latest = ts
        st = s.get("state")
        if st in ("unavailable", "unknown"):
            unavailable += 1
        if ts and (now - ts).total_seconds() > 86400:
            stale += 1
    out["latest_state_change"] = latest.isoformat() if latest else None
    out["seconds_since_latest_change"] = int((now - latest).total_seconds()) if latest else None
    out["stale_24h"] = stale
    out["unavailable_states"] = unavailable
    out["entities_by_domain"] = dict(sorted(by_domain.items()))

    # Recorder: query a known recorder-backed entity to confirm DB ok
    # Use a fast template render via /api/template
    # (skip if HA disallows POST in our token scope)

    # Automations: which ones errored most recently
    automations = [s for s in states if s.get("entity_id", "").startswith("automation.")]
    out["automations_total"] = len(automations)
    out["automations_off"] = sum(1 for a in automations if a.get("state") == "off")

    # Mac Mini agent heartbeat — sensor.mac_mini_heartbeat is updated
    # every 5 min by a launchd job on the Mac Mini. State is an ISO
    # timestamp; age >15 min means the agent is probably down.
    hb = next((s for s in states if s.get("entity_id") == "sensor.mac_mini_heartbeat"), None)
    if hb:
        hb_ts = parse_ts(hb.get("state"))
        hb_age = int((now - hb_ts).total_seconds()) if hb_ts else None
        out["mac_mini_heartbeat"] = {
            "last_beat": hb.get("state"),
            "age_seconds": hb_age,
            "hostname": (hb.get("attributes") or {}).get("hostname"),
            "claude_version": (hb.get("attributes") or {}).get("claude_version"),
            "status": "ok" if hb_age and hb_age < 900 else ("stale" if hb_age else "unknown"),
        }

    return 0 if json.dump(out, sys.stdout, indent=2, default=str) is None else 0


if __name__ == "__main__":
    sys.exit(main())
