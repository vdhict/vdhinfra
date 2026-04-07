#!/usr/bin/env python3
"""Zigbee2MQTT health via Home Assistant entities (z2m exposes a bridge sensor + per-device entities)."""
from __future__ import annotations

import json
import sys

sys.path.insert(0, "/scripts")
from lib import ha_get  # noqa: E402


def main() -> int:
    states = ha_get("/api/states") or []
    bridge = None
    devices = []
    for s in states:
        eid = s.get("entity_id", "")
        attrs = s.get("attributes", {}) or {}
        # Bridge state lives at sensor.zigbee2mqtt_bridge_state or similar
        if "zigbee2mqtt" in eid and ("bridge_state" in eid or "bridge" in eid and eid.endswith("_state")):
            bridge = {"entity_id": eid, "state": s.get("state")}
        # Devices: z2m exposes attributes like "device": {"friendlyName": ...}
        if "zigbee2mqtt" in (attrs.get("source") or "") or "via_device_id" in attrs and "zigbee" in eid.lower():
            devices.append({"entity_id": eid, "state": s.get("state")})
    out = {
        "bridge": bridge,
        "bridge_online": (bridge or {}).get("state") in ("online", "on"),
        "device_entity_count": len(devices),
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
