#!/usr/bin/env python3
"""Auto-triage rule engine. Reads today's raw report, applies the four
approved fix rules, writes an audit log. Honors DRY_RUN env."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, "/scripts")
from lib import RAW_DIR, STATE_DIR, TRIAGE_DIR, log, now_iso, read_json, run, today, write_json  # noqa: E402

DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
COOLDOWN_FILE = STATE_DIR / "cooldowns.json"

# Cooldown windows (seconds)
CD_FLUX_RECONCILE = 24 * 3600          # 1x/day per resource
CD_WORKLOAD_RESTART = 12 * 3600        # 12h per workload


def load_cooldowns() -> dict:
    return read_json(COOLDOWN_FILE, default={}) or {}


def save_cooldowns(cd: dict) -> None:
    write_json(COOLDOWN_FILE, cd)


def cooldown_ok(cd: dict, key: str, window: int) -> bool:
    last = cd.get(key)
    if not last:
        return True
    try:
        last_dt = datetime.fromisoformat(last)
    except Exception:
        return True
    return (datetime.now(timezone.utc) - last_dt).total_seconds() >= window


def stamp_cooldown(cd: dict, key: str) -> None:
    cd[key] = now_iso()


def kubectl(args: list[str], audit: list, action: str, target: str, reason: str) -> bool:
    """Run a mutating kubectl. Records audit entry. Skips real call in DRY_RUN."""
    entry = {
        "ts": now_iso(),
        "action": action,
        "target": target,
        "reason": reason,
        "dry_run": DRY_RUN,
        "command": " ".join(args),
    }
    if DRY_RUN:
        entry["outcome"] = "dry-run"
    else:
        rc, out, err = run(["kubectl", *args], timeout=60)
        entry["outcome"] = "ok" if rc == 0 else f"error: {err.strip()[:200]}"
        entry["rc"] = rc
    audit.append(entry)
    log(f"{'[DRY]' if DRY_RUN else '[FIX]'} {action} {target} -> {entry['outcome']}")
    return entry.get("outcome") == "ok" or entry.get("outcome") == "dry-run"


def rule_pod_cleanup(raw: dict, audit: list) -> None:
    # Re-list pods directly so we get accurate phase + age
    rc, out, err = run(["kubectl", "get", "pods", "-A", "-o", "json"], timeout=60)
    if rc != 0:
        log(f"pod cleanup: list failed: {err}")
        return
    try:
        pods = json.loads(out).get("items", [])
    except Exception:
        return
    now = datetime.now(timezone.utc)
    for p in pods:
        phase = p.get("status", {}).get("phase")
        reason = p.get("status", {}).get("reason", "")
        if phase not in ("Failed", "Succeeded") and reason != "Evicted":
            continue
        ts = p["metadata"].get("creationTimestamp")
        try:
            age = (now - datetime.fromisoformat(ts.replace("Z", "+00:00"))).total_seconds()
        except Exception:
            continue
        if age < 3600:
            continue
        ns = p["metadata"]["namespace"]
        name = p["metadata"]["name"]
        kubectl(
            ["delete", "pod", "-n", ns, name, "--wait=false"],
            audit, "pod_cleanup", f"{ns}/{name}",
            f"phase={phase} reason={reason} age={int(age/60)}m",
        )


def rule_flux_reconcile(raw: dict, audit: list, cd: dict) -> None:
    sections = raw.get("sections", {})
    k8s = sections.get("k8s", {})
    for kind, plural in (("kustomizations.kustomize.toolkit.fluxcd.io", "flux_ks"),
                         ("helmreleases.helm.toolkit.fluxcd.io", "flux_hr")):
        for it in k8s.get(plural, {}).get("items", []):
            if it.get("ready") or it.get("suspended"):
                continue
            ns = it["namespace"]
            name = it["name"]
            cd_key = f"flux:{plural}:{ns}/{name}"
            if not cooldown_ok(cd, cd_key, CD_FLUX_RECONCILE):
                continue
            ok = kubectl(
                ["annotate", kind, "-n", ns, name, f"reconcile.fluxcd.io/requestedAt={now_iso()}", "--overwrite"],
                audit, "flux_reconcile", f"{plural}:{ns}/{name}",
                it.get("message", "not ready")[:200],
            )
            if ok:
                stamp_cooldown(cd, cd_key)


def rule_crashloop_restart(raw: dict, audit: list, cd: dict) -> None:
    pods = raw.get("sections", {}).get("k8s", {}).get("pods", {}).get("crashloop", [])
    # Group by namespace+owning workload (best-effort: use pod name prefix)
    workloads: dict[str, dict] = {}
    for p in pods:
        ns = p["namespace"]
        # Find owner via kubectl
        rc, out, _ = run(["kubectl", "-n", ns, "get", "pod", p["pod"], "-o",
                          "jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}"], timeout=15)
        if rc != 0 or not out.strip():
            continue
        owner_kind, _, owner_name = out.strip().partition("/")
        if owner_kind == "ReplicaSet":
            # Resolve to Deployment
            rc, dep, _ = run(["kubectl", "-n", ns, "get", "rs", owner_name, "-o",
                              "jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}"], timeout=15)
            if rc == 0 and dep.strip():
                owner_kind, _, owner_name = dep.strip().partition("/")
        key = f"{ns}/{owner_kind}/{owner_name}"
        workloads.setdefault(key, {"ns": ns, "kind": owner_kind, "name": owner_name, "count": 0})["count"] += 1

    for key, w in workloads.items():
        if w["kind"] not in ("Deployment", "StatefulSet"):
            continue
        # Only restart when ALL replicas are unhealthy. If even one pod is
        # Ready, leaving the workload alone is the safer call — restarting
        # would kill the only working pod and may cascade an outage if the
        # current pod template is broken (e.g. config schema drift).
        rc, out, _ = run(
            ["kubectl", "-n", w["ns"], "get", w["kind"].lower(), w["name"], "-o",
             "jsonpath={.status.readyReplicas}/{.status.replicas}"],
            timeout=15,
        )
        ready_part, _, total_part = (out or "").partition("/")
        ready = int(ready_part) if ready_part.isdigit() else 0
        total = int(total_part) if total_part.isdigit() else 0
        if ready > 0:
            audit.append({
                "ts": now_iso(),
                "action": "rollout_restart_skipped",
                "target": key,
                "reason": f"{ready}/{total} replicas still Ready — refusing to restart, manual triage required",
                "dry_run": DRY_RUN,
                "outcome": "skipped",
            })
            continue
        cd_key = f"restart:{key}"
        if not cooldown_ok(cd, cd_key, CD_WORKLOAD_RESTART):
            continue
        ok = kubectl(
            ["-n", w["ns"], "rollout", "restart", w["kind"].lower(), w["name"]],
            audit, "rollout_restart", key,
            f"{w['count']} pod(s) in CrashLoopBackOff, 0/{total} replicas Ready",
        )
        if ok:
            stamp_cooldown(cd, cd_key)


def rule_ha_integration_restart(raw: dict, audit: list, cd: dict) -> None:
    sections = raw.get("sections", {})
    # Map: HA-side problem → workload to restart
    candidates = [
        ("z2m", "zigbee2mqtt", "home-automation", "Deployment", "zigbee2mqtt"),
        ("zwave", "zwave", "home-automation", "Deployment", "zwave-js-ui"),
        ("mqtt", "mosquitto", "home-automation", "Deployment", "mosquitto"),
    ]
    for section, label, ns, kind, name in candidates:
        s = sections.get(section, {}) or {}
        unhealthy = False
        if section == "z2m" and not s.get("bridge_online", True):
            unhealthy = True
        if section == "zwave" and s.get("dead", 0) > 0 and s.get("alive", 0) == 0:
            unhealthy = True
        if section == "mqtt" and not s.get("reachable", True):
            unhealthy = True
        if not unhealthy:
            continue
        # Same safety net as crashloop rule: only restart if no replicas Ready
        rc, out, _ = run(
            ["kubectl", "-n", ns, "get", kind.lower(), name, "-o",
             "jsonpath={.status.readyReplicas}/{.status.replicas}"],
            timeout=15,
        )
        ready_part, _, total_part = (out or "").partition("/")
        ready = int(ready_part) if ready_part.isdigit() else 0
        if ready > 0:
            audit.append({
                "ts": now_iso(),
                "action": "ha_integration_restart_skipped",
                "target": f"{ns}/{kind}/{name}",
                "reason": f"{ready} replica(s) Ready — refusing to bounce, will report instead",
                "dry_run": DRY_RUN,
                "outcome": "skipped",
            })
            continue
        cd_key = f"ha-restart:{ns}/{name}"
        if not cooldown_ok(cd, cd_key, CD_WORKLOAD_RESTART):
            continue
        ok = kubectl(
            ["-n", ns, "rollout", "restart", kind.lower(), name],
            audit, "ha_integration_restart", f"{ns}/{kind}/{name}",
            f"{label} unhealthy per HA",
        )
        if ok:
            stamp_cooldown(cd, cd_key)


def rule_network_anomaly(raw: dict, audit: list) -> None:
    """Advisory rule (no auto-fix): flag UniFi ports with rx_errors > 0 or
    elevated link_down_count vs the prior day. Surfaces problems that
    today only manifest as 'z2m bridge offline' with no upstream cause."""
    section = (raw.get("sections") or {}).get("network") or {}
    ports = section.get("ports") or []
    if not ports:
        return

    prior_date = (datetime.now(timezone.utc).date() - timedelta(days=1)).isoformat()
    prior = read_json(RAW_DIR / f"{prior_date}.json", {}) or {}
    prior_ports = {
        f"{p.get('sw_mac')}:{p.get('port_idx')}": p
        for p in (prior.get("sections", {}).get("network", {}).get("ports") or [])
    }
    flap_warn = section.get("thresholds", {}).get("flap_count_warn", 5)
    rx_warn = section.get("thresholds", {}).get("rx_errors_warn", 1)

    for p in ports:
        key = f"{p.get('sw_mac')}:{p.get('port_idx')}"
        prev = prior_ports.get(key) or {}
        prev_flap = prev.get("link_down_count", 0) or 0
        cur_flap = p.get("link_down_count", 0) or 0
        flap_delta = cur_flap - prev_flap
        rx_err = p.get("rx_errors", 0) or 0

        reasons = []
        if rx_err >= rx_warn:
            reasons.append(f"rx_errors={rx_err}")
        if flap_delta >= 2:
            reasons.append(f"link_down_count +{flap_delta} ({prev_flap}→{cur_flap})")
        elif cur_flap >= flap_warn and prev_flap == 0:
            # First-day baseline already over threshold
            reasons.append(f"link_down_count={cur_flap} (≥{flap_warn})")
        if not reasons:
            continue

        audit.append({
            "ts": now_iso(),
            "action": "network_anomaly_flagged",
            "target": f"{p.get('sw_name')}/port-{p.get('port_idx')} ({p.get('friendly') or p.get('client_mac')})",
            "reason": "; ".join(reasons),
            "dry_run": DRY_RUN,
            "outcome": "advisory",
        })


def main() -> int:
    date = today()
    raw_path = RAW_DIR / f"{date}.json"
    if not raw_path.exists():
        log(f"no raw report at {raw_path}, nothing to triage")
        return 0
    raw = read_json(raw_path, {}) or {}
    audit: list = []
    cd = load_cooldowns()

    log(f"triage start (DRY_RUN={DRY_RUN})")
    rule_pod_cleanup(raw, audit)
    rule_flux_reconcile(raw, audit, cd)
    rule_crashloop_restart(raw, audit, cd)
    rule_ha_integration_restart(raw, audit, cd)
    rule_network_anomaly(raw, audit)

    save_cooldowns(cd)

    summary = {
        "date": date,
        "ts": now_iso(),
        "dry_run": DRY_RUN,
        "actions": len(audit),
        "by_action": {},
    }
    for e in audit:
        a = e["action"]
        summary["by_action"][a] = summary["by_action"].get(a, 0) + 1
    summary["audit"] = audit

    write_json(TRIAGE_DIR / f"{date}.json", summary)
    # Append to a single rolling JSONL for long-term audit
    with (TRIAGE_DIR / "audit.jsonl").open("a") as f:
        for e in audit:
            f.write(json.dumps(e, default=str) + "\n")
    log(f"triage done: {len(audit)} actions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
