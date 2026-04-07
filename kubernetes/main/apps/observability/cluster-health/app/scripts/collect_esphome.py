#!/usr/bin/env python3
"""ESPHome device health via HA: device_tracker / sensor entities tagged with esphome."""
from __future__ import annotations

import json
import sys

sys.path.insert(0, "/scripts")
from lib import ha_get  # noqa: E402


def main() -> int:
    states = ha_get("/api/states") or []
    devices: dict[str, dict] = {}
    for s in states:
        attrs = s.get("attributes", {}) or {}
        # ESPHome surfaces "device_class": "connectivity" status entities
        # and includes "node_name" or "via_device" hints. Heuristic: look for
        # binary_sensor.*_status / *_api_connected
        eid = s.get("entity_id", "")
        if eid.startswith("binary_sensor.") and ("_status" in eid or "_api_connected" in eid):
            name = eid.split(".", 1)[1].rsplit("_status", 1)[0].rsplit("_api_connected", 1)[0]
            devices.setdefault(name, {"name": name, "online": False})["online"] |= (s.get("state") == "on")
    out = {
        "device_count": len(devices),
        "online": sum(1 for d in devices.values() if d["online"]),
        "offline": sum(1 for d in devices.values() if not d["online"]),
        "offline_devices": sorted([d["name"] for d in devices.values() if not d["online"]]),
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
