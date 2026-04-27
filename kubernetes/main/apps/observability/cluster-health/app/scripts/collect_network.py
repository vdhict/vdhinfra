#!/usr/bin/env python3
"""Network health: UniFi switch port stats for a curated allowlist of
critical wired devices. Catches the failure mode the daily report misses
today (e.g. SLZB-06 hangs at L3 while link stays up) by surfacing
link_down_count, rx_errors, and last_seen freshness per port.

Allowlist is intentional: dumping all 145+ wired clients adds noise.
Only devices whose flap pattern changes operator behavior belong here.
"""
from __future__ import annotations

import json
import sys
from typing import Any

sys.path.insert(0, "/scripts")
from lib import log, unifi_get  # noqa: E402

# MACs we actively care about. Keep tight — anything here shows up in the
# daily report and triage. Add only when an outage of this device would
# trigger an action.
WATCH_MACS = {
    "14:2b:2f:db:ab:17": "slzb-06",            # Zigbee coordinator (recurring flaps)
    "00:11:32:91:af:61": "synology-nas",       # /home/media NFS source
    "e4:5f:01:4a:2d:a9": "pikvm",              # bare-metal recovery console
    "78:55:36:03:d3:ab": "vdhclu01master01",
    "78:55:36:04:90:19": "vdhclu01master02",
    "78:55:36:04:97:ce": "vdhclu01master03",
    "88:ae:dd:62:1b:3c": "vdhclu01node01",
    "88:ae:dd:62:29:bf": "vdhclu01node02",
    "88:ae:dd:62:17:a6": "vdhclu01node03",
}

# rx_errors > 0 is suspicious on a healthy LAN; flap_count >= this is too.
FLAP_THRESHOLD = 5
RX_ERROR_THRESHOLD = 1


def list_switches() -> list[dict]:
    j = unifi_get("/api/s/default/stat/device") or {}
    return [d for d in j.get("data", []) if (d.get("type") == "usw" or d.get("type") == "udm")]


def port_record(sw_name: str, sw_mac: str, port: dict, friendly: str | None) -> dict:
    lc = port.get("last_connection") or {}
    return {
        "sw_name": sw_name,
        "sw_mac": sw_mac,
        "port_idx": port.get("port_idx"),
        "port_name": port.get("name"),
        "friendly": friendly,
        "client_mac": (lc.get("mac") or "").lower(),
        "client_ip": lc.get("ip"),
        "up": port.get("up"),
        "speed_mbps": port.get("speed"),
        "poe_mode": port.get("poe_mode"),
        "poe_power_w": _try_float(port.get("poe_power")),
        "poe_good": port.get("poe_good"),
        "link_down_count": port.get("link_down_count", 0),
        "rx_errors": port.get("rx_errors", 0),
        "tx_errors": port.get("tx_errors", 0),
        "last_seen": lc.get("last_seen"),
    }


def _try_float(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main() -> int:
    switches = list_switches()
    if not switches:
        log("no switches returned from UniFi (creds missing or API down)")
        json.dump({"_error": "unifi_unreachable", "ports": []}, sys.stdout, indent=2)
        return 0

    ports: list[dict] = []
    for sw in switches:
        sw_name = sw.get("name") or sw.get("model") or "?"
        sw_mac = sw.get("mac")
        for p in sw.get("port_table", []) or []:
            lc = p.get("last_connection") or {}
            mac = (lc.get("mac") or "").lower()
            # Skip stale last_connection rows (device moved to another port).
            if mac in WATCH_MACS and lc.get("connected"):
                ports.append(port_record(sw_name, sw_mac, p, WATCH_MACS[mac]))

    # Sort: anomalies first
    def severity(r: dict) -> tuple:
        anomaly = (r["rx_errors"] >= RX_ERROR_THRESHOLD) or (r["link_down_count"] >= FLAP_THRESHOLD)
        return (0 if anomaly else 1, -(r["link_down_count"] or 0), -(r["rx_errors"] or 0))

    ports.sort(key=severity)

    flapping = [p for p in ports if p["link_down_count"] >= FLAP_THRESHOLD]
    rx_err_ports = [p for p in ports if p["rx_errors"] >= RX_ERROR_THRESHOLD]

    out = {
        "ports": ports,
        "watched": len(WATCH_MACS),
        "found": len(ports),
        "flapping_count": len(flapping),
        "rx_error_count": len(rx_err_ports),
        "thresholds": {
            "flap_count_warn": FLAP_THRESHOLD,
            "rx_errors_warn": RX_ERROR_THRESHOLD,
        },
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
