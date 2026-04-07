#!/usr/bin/env python3
"""Collect Prometheus-derived metrics: PVC usage, restart counts, OOMs, node pressure."""
from __future__ import annotations

import json
import sys

sys.path.insert(0, "/scripts")
from lib import prom_query  # noqa: E402


def pvc_usage() -> list[dict]:
    q = (
        '(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100'
    )
    out = []
    for r in prom_query(q):
        m = r.get("metric", {})
        v = r.get("value", [None, None])
        try:
            pct = round(float(v[1]), 2)
        except Exception:
            continue
        out.append({
            "namespace": m.get("namespace"),
            "pvc": m.get("persistentvolumeclaim"),
            "pct_used": pct,
        })
    out.sort(key=lambda x: x["pct_used"], reverse=True)
    return out


def restart_counts_24h() -> list[dict]:
    q = 'increase(kube_pod_container_status_restarts_total[24h]) > 5'
    out = []
    for r in prom_query(q):
        m = r.get("metric", {})
        try:
            val = float(r.get("value", [None, 0])[1])
        except Exception:
            val = 0
        out.append({
            "namespace": m.get("namespace"),
            "pod": m.get("pod"),
            "container": m.get("container"),
            "restarts_24h": int(val),
        })
    out.sort(key=lambda x: x["restarts_24h"], reverse=True)
    return out


def node_pressure() -> dict:
    cpu = {}
    for r in prom_query(
        '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
    ):
        try:
            cpu[r["metric"].get("instance")] = round(float(r["value"][1]), 2)
        except Exception:
            pass
    mem = {}
    for r in prom_query(
        '100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))'
    ):
        try:
            mem[r["metric"].get("instance")] = round(float(r["value"][1]), 2)
        except Exception:
            pass
    return {"cpu_pct": cpu, "mem_pct": mem}


def main() -> int:
    out = {
        "pvc_usage": pvc_usage(),
        "restarts_24h": restart_counts_24h(),
        "nodes": node_pressure(),
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
