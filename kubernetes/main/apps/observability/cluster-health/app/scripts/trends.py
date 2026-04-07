#!/usr/bin/env python3
"""Trend analysis. Pulls 7d (and where useful 30d) range data from Prometheus,
fits a simple linear regression, projects when each PVC will fill, and
emits warnings + raw series for the report renderer."""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, "/scripts")
from lib import TRENDS_DIR, log, now_iso, prom_query_range, today, write_json  # noqa: E402

DAY = 86400
WEEK = 7 * DAY


def linreg(points: list[tuple[float, float]]) -> tuple[float, float] | None:
    """Return (slope, intercept) for y = slope*x + intercept. None if degenerate."""
    n = len(points)
    if n < 2:
        return None
    sx = sum(p[0] for p in points)
    sy = sum(p[1] for p in points)
    sxx = sum(p[0] * p[0] for p in points)
    sxy = sum(p[0] * p[1] for p in points)
    denom = n * sxx - sx * sx
    if denom == 0:
        return None
    slope = (n * sxy - sx * sy) / denom
    intercept = (sy - slope * sx) / n
    return slope, intercept


def to_points(series: dict) -> list[tuple[float, float]]:
    out = []
    for ts, val in series.get("values", []):
        try:
            out.append((float(ts), float(val)))
        except Exception:
            continue
    return out


def trend_pvc_fill() -> list[dict]:
    end = int(time.time())
    start = end - WEEK
    step = 3600  # 1h resolution
    q = '(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100'
    out = []
    for r in prom_query_range(q, start, end, step):
        m = r.get("metric", {})
        pts = to_points(r)
        if len(pts) < 24:
            continue
        # Normalize x to days from window start
        t0 = pts[0][0]
        norm = [((p[0] - t0) / DAY, p[1]) for p in pts]
        lr = linreg(norm)
        if not lr:
            continue
        slope_per_day, intercept = lr
        latest = norm[-1][1]
        days_to_full = None
        if slope_per_day > 0.01:
            days_to_full = (100 - latest) / slope_per_day
        out.append({
            "namespace": m.get("namespace"),
            "pvc": m.get("persistentvolumeclaim"),
            "current_pct": round(latest, 2),
            "growth_pct_per_day": round(slope_per_day, 4),
            "days_to_full": round(days_to_full, 1) if days_to_full else None,
            "series": [(int(p[0] - t0) // 3600, round(p[1], 2)) for p in pts],
        })
    out.sort(key=lambda x: (x["days_to_full"] is None, x["days_to_full"] or 1e9))
    return out


def trend_ceph_raw() -> dict | None:
    end = int(time.time())
    start = end - WEEK
    step = 3600
    q = '(ceph_cluster_total_used_bytes / ceph_cluster_total_bytes) * 100'
    res = prom_query_range(q, start, end, step)
    if not res:
        return None
    pts = to_points(res[0])
    if len(pts) < 24:
        return None
    t0 = pts[0][0]
    norm = [((p[0] - t0) / DAY, p[1]) for p in pts]
    lr = linreg(norm)
    slope, _ = lr if lr else (0, 0)
    latest = norm[-1][1]
    days_to_80 = ((80 - latest) / slope) if slope > 0.01 and latest < 80 else None
    return {
        "current_pct": round(latest, 2),
        "growth_pct_per_day": round(slope, 4),
        "days_to_80pct": round(days_to_80, 1) if days_to_80 else None,
        "series": [(int(p[0] - t0) // 3600, round(p[1], 2)) for p in pts],
    }


def trend_node_pressure() -> dict:
    end = int(time.time())
    start = end - WEEK
    step = 3600
    cpu_q = 'avg by (instance) (100 - rate(node_cpu_seconds_total{mode="idle"}[5m]) * 100)'
    mem_q = '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))'
    out: dict = {"cpu": {}, "mem": {}}
    for r in prom_query_range(cpu_q, start, end, step):
        inst = r["metric"].get("instance")
        pts = to_points(r)
        if not pts:
            continue
        t0 = pts[0][0]
        out["cpu"][inst] = {
            "avg": round(sum(p[1] for p in pts) / len(pts), 2),
            "max": round(max(p[1] for p in pts), 2),
            "series": [(int(p[0] - t0) // 3600, round(p[1], 2)) for p in pts],
        }
    for r in prom_query_range(mem_q, start, end, step):
        inst = r["metric"].get("instance")
        pts = to_points(r)
        if not pts:
            continue
        t0 = pts[0][0]
        out["mem"][inst] = {
            "avg": round(sum(p[1] for p in pts) / len(pts), 2),
            "max": round(max(p[1] for p in pts), 2),
            "series": [(int(p[0] - t0) // 3600, round(p[1], 2)) for p in pts],
        }
    return out


def main() -> int:
    log("trends start")
    out = {
        "computed_at": now_iso(),
        "pvc_fill": trend_pvc_fill(),
        "ceph_raw": trend_ceph_raw(),
        "node_pressure": trend_node_pressure(),
    }
    # Surface alerts
    alerts: list[dict] = []
    for p in out["pvc_fill"]:
        if p["days_to_full"] is not None and p["days_to_full"] < 14:
            alerts.append({
                "kind": "pvc_fill",
                "severity": "crit" if p["days_to_full"] < 7 else "warn",
                "message": f"PVC {p['namespace']}/{p['pvc']} projected full in {p['days_to_full']} days",
            })
    if out["ceph_raw"] and out["ceph_raw"].get("days_to_80pct") and out["ceph_raw"]["days_to_80pct"] < 30:
        alerts.append({
            "kind": "ceph_raw",
            "severity": "warn",
            "message": f"Ceph raw usage will hit 80% in {out['ceph_raw']['days_to_80pct']} days",
        })
    out["alerts"] = alerts
    write_json(TRENDS_DIR / f"{today()}.json", out)
    log(f"trends done: {len(alerts)} alerts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
