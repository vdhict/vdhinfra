#!/bin/sh
# Collect Ceph cluster status + OSD SSD device health by exec'ing into rook-ceph-tools.
set -u

TOOLS_POD=$(kubectl -n rook-ceph get pod -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$TOOLS_POD" ]; then
  echo '{"_error": "rook-ceph-tools pod not found"}'
  exit 0
fi

CEPH_STATUS=$(kubectl -n rook-ceph exec "$TOOLS_POD" -- ceph -s -f json 2>/dev/null || echo '{}')
CEPH_DF=$(kubectl -n rook-ceph exec "$TOOLS_POD" -- ceph df -f json 2>/dev/null || echo '{}')
CEPH_OSD=$(kubectl -n rook-ceph exec "$TOOLS_POD" -- ceph osd tree -f json 2>/dev/null || echo '{}')
CEPH_HEALTH=$(kubectl -n rook-ceph exec "$TOOLS_POD" -- ceph health detail -f json 2>/dev/null || echo '{}')
# Device list (text; no -f json in older Ceph builds)
CEPH_DEVICE_LS=$(kubectl -n rook-ceph exec "$TOOLS_POD" -- ceph device ls 2>/dev/null || echo '')

python3 - "$TOOLS_POD" "$CEPH_STATUS" "$CEPH_DF" "$CEPH_OSD" "$CEPH_HEALTH" "$CEPH_DEVICE_LS" <<'PY'
import json, subprocess, sys

tools_pod   = sys.argv[1]
status      = json.loads(sys.argv[2] or "{}")
df          = json.loads(sys.argv[3] or "{}")
osd         = json.loads(sys.argv[4] or "{}")
health      = json.loads(sys.argv[5] or "{}")
device_ls   = sys.argv[6] if len(sys.argv) > 6 else ""


def parse_device_ls(raw):
    """Return list of {device_id, host, device, osd, wear_pct}."""
    devices = []
    for line in raw.strip().splitlines():
        line = line.strip()
        if not line or line.startswith("DEVICE"):
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        dev_id = parts[0]
        host, _, dev = parts[1].partition(":")
        daemon = parts[2]
        wear = parts[3] if len(parts) > 3 else ""
        wear_pct = None
        if wear.endswith("%"):
            try:
                wear_pct = int(wear[:-1])
            except ValueError:
                pass
        devices.append({"device_id": dev_id, "host": host, "device": dev,
                         "osd": daemon, "wear_pct": wear_pct})
    return devices


def get_smart_attrs(dev_id):
    """Fetch selected SMART attr raw values for device_id via ceph-tools exec."""
    try:
        result = subprocess.run(
            ["kubectl", "-n", "rook-ceph", "exec", tools_pod, "--",
             "ceph", "device", "get-health-metrics", dev_id],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return {}
        data = json.loads(result.stdout)
    except Exception:
        return {}

    if not data:
        return {}
    latest = sorted(data.keys())[-1]
    metrics = data[latest]
    ata = metrics.get("ata_smart_attributes", {})
    attrs = {}
    for attr in ata.get("table", []):
        aid = attr.get("id")
        if aid in (5, 9, 231, 233, 241):
            attrs[aid] = {
                "name": attr.get("name", ""),
                "value": attr.get("value", 0),
                "raw": attr.get("raw", {}).get("value", 0),
            }
    return attrs


devices = parse_device_ls(device_ls)

# Collect SMART attrs for each device
for d in devices:
    d["smart"] = get_smart_attrs(d["device_id"])

# --- yesterday's realloc count for delta calculation ---
# Not available here (would need trend data); emit raw totals only.
# The PrometheusRule computes increase() from the time-series in Prometheus.

ssd_devices = [
    {
        "device_id": d["device_id"],
        "host": d["host"],
        "device": d["device"],
        "osd": d["osd"],
        "wear_pct": d["wear_pct"],
        "reallocated_sectors": d["smart"].get(5, {}).get("raw"),
        "power_on_hours": d["smart"].get(9, {}).get("raw"),
        "ssd_life_left_val": d["smart"].get(231, {}).get("value"),
        "media_wearout_raw": d["smart"].get(233, {}).get("raw"),
    }
    for d in devices
]

out = {
    "health": status.get("health", {}).get("status"),
    "fsid": status.get("fsid"),
    "mon_quorum": len(status.get("quorum_names", [])),
    "mon_total": status.get("monmap", {}).get("num_mons"),
    "mgr_active": status.get("mgrmap", {}).get("active_name"),
    "osd_up": status.get("osdmap", {}).get("num_up_osds"),
    "osd_in": status.get("osdmap", {}).get("num_in_osds"),
    "osd_total": status.get("osdmap", {}).get("num_osds"),
    "pgs": status.get("pgmap", {}).get("num_pgs"),
    "pg_states": {s.get("state_name"): s.get("count") for s in status.get("pgmap", {}).get("pgs_by_state", [])},
    "raw_used_pct": round(df.get("stats", {}).get("total_used_raw_ratio", 0) * 100, 2),
    "raw_used_bytes": df.get("stats", {}).get("total_used_bytes"),
    "raw_total_bytes": df.get("stats", {}).get("total_bytes"),
    "pools": [
        {
            "name": p.get("name"),
            "used_bytes": p.get("stats", {}).get("bytes_used"),
            "pct_used": round(p.get("stats", {}).get("percent_used", 0) * 100, 2),
            "objects": p.get("stats", {}).get("objects"),
        }
        for p in df.get("pools", [])
    ],
    "health_checks": list(health.get("checks", {}).keys()),
    "ssd_devices": ssd_devices,
}
json.dump(out, sys.stdout, indent=2, default=str)
PY
