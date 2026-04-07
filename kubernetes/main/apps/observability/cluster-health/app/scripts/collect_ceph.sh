#!/bin/sh
# Collect Ceph cluster status by exec'ing into rook-ceph-tools.
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

python3 - "$CEPH_STATUS" "$CEPH_DF" "$CEPH_OSD" "$CEPH_HEALTH" <<'PY'
import json, sys
status = json.loads(sys.argv[1] or "{}")
df = json.loads(sys.argv[2] or "{}")
osd = json.loads(sys.argv[3] or "{}")
health = json.loads(sys.argv[4] or "{}")

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
}
json.dump(out, sys.stdout, indent=2, default=str)
PY
