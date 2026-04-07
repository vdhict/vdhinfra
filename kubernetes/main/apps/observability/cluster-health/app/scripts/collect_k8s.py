#!/usr/bin/env python3
"""Collect Kubernetes-level health: nodes, Flux, pods, events, certs, ESO, Gateway."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, "/scripts")
from lib import kubectl_json, log  # noqa: E402


def parse_ts(s: str | None):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def collect_nodes() -> dict:
    j = kubectl_json(["get", "nodes"])
    nodes = []
    ready_count = 0
    for item in j.get("items", []):
        name = item["metadata"]["name"]
        conds = {c["type"]: c for c in item.get("status", {}).get("conditions", [])}
        ready = conds.get("Ready", {}).get("status") == "True"
        if ready:
            ready_count += 1
        nodes.append({
            "name": name,
            "ready": ready,
            "kubelet_version": item.get("status", {}).get("nodeInfo", {}).get("kubeletVersion"),
            "os_image": item.get("status", {}).get("nodeInfo", {}).get("osImage"),
            "conditions": {k: v.get("status") for k, v in conds.items()},
        })
    return {"total": len(nodes), "ready": ready_count, "nodes": nodes}


def collect_flux_ks() -> dict:
    j = kubectl_json(["get", "kustomizations.kustomize.toolkit.fluxcd.io", "-A"])
    items = []
    ready = 0
    for it in j.get("items", []):
        name = it["metadata"]["name"]
        ns = it["metadata"]["namespace"]
        suspended = it.get("spec", {}).get("suspend", False)
        cond = next((c for c in it.get("status", {}).get("conditions", []) if c["type"] == "Ready"), {})
        is_ready = cond.get("status") == "True"
        if is_ready:
            ready += 1
        items.append({
            "namespace": ns,
            "name": name,
            "ready": is_ready,
            "suspended": suspended,
            "message": cond.get("message", "")[:200],
            "last_transition": cond.get("lastTransitionTime"),
        })
    return {"total": len(items), "ready": ready, "items": items}


def collect_flux_hr() -> dict:
    j = kubectl_json(["get", "helmreleases.helm.toolkit.fluxcd.io", "-A"])
    items = []
    ready = 0
    for it in j.get("items", []):
        name = it["metadata"]["name"]
        ns = it["metadata"]["namespace"]
        suspended = it.get("spec", {}).get("suspend", False)
        cond = next((c for c in it.get("status", {}).get("conditions", []) if c["type"] == "Ready"), {})
        is_ready = cond.get("status") == "True"
        if is_ready:
            ready += 1
        items.append({
            "namespace": ns,
            "name": name,
            "ready": is_ready,
            "suspended": suspended,
            "message": cond.get("message", "")[:200],
            "last_transition": cond.get("lastTransitionTime"),
        })
    return {"total": len(items), "ready": ready, "items": items}


def collect_pods() -> dict:
    j = kubectl_json(["get", "pods", "-A"])
    phases: dict[str, int] = {}
    crashloop: list[dict] = []
    pending_long: list[dict] = []
    image_pull_back_off: list[dict] = []
    oom_killed: list[dict] = []
    now = datetime.now(timezone.utc)
    total = 0
    for it in j.get("items", []):
        total += 1
        ns = it["metadata"]["namespace"]
        name = it["metadata"]["name"]
        phase = it.get("status", {}).get("phase", "Unknown")
        phases[phase] = phases.get(phase, 0) + 1
        cs_list = it.get("status", {}).get("containerStatuses", []) or []
        for cs in cs_list:
            waiting = cs.get("state", {}).get("waiting") or {}
            if waiting.get("reason") == "CrashLoopBackOff":
                crashloop.append({"namespace": ns, "pod": name, "container": cs["name"],
                                  "restarts": cs.get("restartCount", 0), "message": waiting.get("message", "")[:200]})
            if waiting.get("reason") in ("ImagePullBackOff", "ErrImagePull"):
                image_pull_back_off.append({"namespace": ns, "pod": name, "container": cs["name"],
                                            "reason": waiting.get("reason"), "message": waiting.get("message", "")[:200]})
            last = cs.get("lastState", {}).get("terminated") or {}
            if last.get("reason") == "OOMKilled":
                oom_killed.append({"namespace": ns, "pod": name, "container": cs["name"],
                                   "finishedAt": last.get("finishedAt")})
        if phase == "Pending":
            start = parse_ts(it["metadata"].get("creationTimestamp"))
            if start and (now - start) > timedelta(minutes=15):
                pending_long.append({"namespace": ns, "pod": name,
                                     "age_minutes": int((now - start).total_seconds() / 60)})
    return {
        "total": total,
        "phases": phases,
        "crashloop": crashloop,
        "image_pull_back_off": image_pull_back_off,
        "oom_killed": oom_killed,
        "pending_long": pending_long,
    }


def collect_events() -> dict:
    j = kubectl_json(["get", "events", "-A", "--field-selector=type=Warning"])
    cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
    by_reason: dict[str, int] = {}
    samples: list[dict] = []
    for it in j.get("items", []):
        ts = parse_ts(it.get("lastTimestamp") or it.get("eventTime") or it.get("metadata", {}).get("creationTimestamp"))
        if not ts or ts < cutoff:
            continue
        reason = it.get("reason", "Unknown")
        by_reason[reason] = by_reason.get(reason, 0) + 1
        if len(samples) < 30:
            samples.append({
                "namespace": it["metadata"].get("namespace"),
                "object": f"{it.get('involvedObject', {}).get('kind')}/{it.get('involvedObject', {}).get('name')}",
                "reason": reason,
                "message": (it.get("message") or "")[:200],
                "ts": it.get("lastTimestamp"),
            })
    return {"by_reason": by_reason, "samples": samples}


def collect_certs() -> dict:
    j = kubectl_json(["get", "certificates.cert-manager.io", "-A"])
    now = datetime.now(timezone.utc)
    items = []
    for it in j.get("items", []):
        not_after = parse_ts(it.get("status", {}).get("notAfter"))
        days = int((not_after - now).total_seconds() / 86400) if not_after else None
        cond = next((c for c in it.get("status", {}).get("conditions", []) if c["type"] == "Ready"), {})
        items.append({
            "namespace": it["metadata"]["namespace"],
            "name": it["metadata"]["name"],
            "ready": cond.get("status") == "True",
            "days_until_expiry": days,
            "not_after": it.get("status", {}).get("notAfter"),
        })
    return {"total": len(items), "items": items}


def collect_external_secrets() -> dict:
    j = kubectl_json(["get", "externalsecrets.external-secrets.io", "-A"])
    items = []
    failed = 0
    for it in j.get("items", []):
        cond = next((c for c in it.get("status", {}).get("conditions", []) if c["type"] == "Ready"), {})
        is_ready = cond.get("status") == "True"
        if not is_ready:
            failed += 1
        items.append({
            "namespace": it["metadata"]["namespace"],
            "name": it["metadata"]["name"],
            "ready": is_ready,
            "message": cond.get("message", "")[:200],
        })
    return {"total": len(items), "failed": failed, "items": [i for i in items if not i["ready"]]}


def collect_httproutes() -> dict:
    j = kubectl_json(["get", "httproutes.gateway.networking.k8s.io", "-A"])
    items = []
    not_accepted = 0
    for it in j.get("items", []):
        parents = it.get("status", {}).get("parents", [])
        accepted = all(
            any(c["type"] == "Accepted" and c["status"] == "True" for c in p.get("conditions", []))
            for p in parents
        ) if parents else False
        if not accepted:
            not_accepted += 1
        items.append({
            "namespace": it["metadata"]["namespace"],
            "name": it["metadata"]["name"],
            "accepted": accepted,
            "hostnames": it.get("spec", {}).get("hostnames", []),
        })
    return {"total": len(items), "not_accepted": not_accepted,
            "items": [i for i in items if not i["accepted"]]}


def main() -> int:
    out = {
        "nodes": collect_nodes(),
        "flux_ks": collect_flux_ks(),
        "flux_hr": collect_flux_hr(),
        "pods": collect_pods(),
        "events": collect_events(),
        "certs": collect_certs(),
        "external_secrets": collect_external_secrets(),
        "httproutes": collect_httproutes(),
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
