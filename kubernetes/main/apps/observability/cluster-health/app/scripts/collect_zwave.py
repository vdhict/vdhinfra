#!/usr/bin/env python3
"""Z-Wave health via HA: count nodes alive vs dead via zwave_js entities."""
from __future__ import annotations

import json
import sys

sys.path.insert(0, "/scripts")
from lib import ha_get  # noqa: E402


def main() -> int:
    states = ha_get("/api/states") or []
    nodes_seen: dict[str, dict] = {}
    for s in states:
        attrs = s.get("attributes", {}) or {}
        node_id = attrs.get("node_id")
        if node_id is None:
            continue
        # Heuristic: zwave entities tend to have a node_id attribute
        eid = s.get("entity_id", "")
        if "zwave" not in eid and "z_wave" not in eid:
            # Could still be a zwave device entity — check device_class or friendly_name
            pass
        nid = str(node_id)
        existing = nodes_seen.setdefault(nid, {"node_id": nid, "alive": True, "entities": 0})
        existing["entities"] += 1
        if s.get("state") in ("unavailable", "unknown"):
            existing["alive"] = False

    out = {
        "node_count": len(nodes_seen),
        "alive": sum(1 for n in nodes_seen.values() if n["alive"]),
        "dead": sum(1 for n in nodes_seen.values() if not n["alive"]),
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
