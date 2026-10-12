#!/usr/bin/env python3
"""AIOps auto-triage (AIOps step 1, AGR-109). Runs every 15 minutes.

Reads LIVE cluster state on every run (not the 02:00 daily raw report, which
would be up to 24 h stale at a 15-minute cadence) and applies the four
A runbooks:

  pod_cleanup        delete Failed/Succeeded/Evicted pods older than 1 h
  flux_reconcile     request a reconcile of a not-Ready Kustomization/HelmRelease
  ha_bridge_restart  rollout-restart Zigbee2MQTT / Z-Wave JS / Mosquitto when
                     the probe sees the bridge down AND the workload has 0 Ready
  crashloop_restart  rollout-restart a Deployment/StatefulSet in CrashLoopBackOff
                     when NO replica is Ready

Switches, read from ConfigMap observability/aiops-mode on EVERY run:
  mode                 aan | alleen-melden | uit     (global)
  runbook.<name>       aan | alleen-melden | uit     (per runbook)
  scope                all | ns1,ns2                 (namespaces it may act in)
The effective mode of a runbook is the stricter of global and per-runbook.
A missing or unreadable ConfigMap means alleen-melden (fail safe). DRY_RUN=true
in the env forces alleen-melden for everything.

Guards that no switch can lift:
  - NEVER_NAMESPACES / NEVER_NAME_TOKENS: Passkey and myPKA territory.
  - RESTART_PROTECTED_NAMESPACES: core (cat 3); restarts there are report-only.
  - Maintenance windows: the restart runbooks (which interrupt a workload) only
    act 01:00-06:00 and 09:00-16:00 Europe/Amsterdam; outside, they report
    "deferred". The throwaway self-test namespace is exempt.
  - Cooldowns per object (kept from the original rules).
  - At most MAX_ACTIONS_PER_OBJECT_PER_DAY real actions per object per day.
  - A restart is verified (rollout status); a failed verification stops all
    further actions on that object for the day (cap filled) and is logged.

Change log: every REAL action writes exactly one line, in the ops change-event
shape, to (a) stdout prefixed "AIOPS_CHANGE " (promtail -> Loki, stream
{namespace="observability", container="triage"}) and (b) the append-only
/data/triage/changes.jsonl on the cluster-health PVC.
"""
from __future__ import annotations

import fnmatch
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, "/scripts")
from lib import RAW_DIR, STATE_DIR, TRIAGE_DIR, log, now_iso, read_json, run, write_json  # noqa: E402

MODE_CM_NS = os.environ.get("AIOPS_MODE_NAMESPACE", "observability")
MODE_CM_NAME = os.environ.get("AIOPS_MODE_CONFIGMAP", "aiops-mode")
DRY_RUN_ENV = os.environ.get("DRY_RUN", "false").lower() == "true"
LOCAL_TZ = ZoneInfo(os.environ.get("TZ") or "Europe/Amsterdam")

COOLDOWN_FILE = STATE_DIR / "cooldowns.json"
DAILY_COUNT_FILE = STATE_DIR / "aiops-daily-counts.json"
CHANGES_FILE = TRIAGE_DIR / "changes.jsonl"

RUNBOOKS = ("pod_cleanup", "flux_reconcile", "ha_bridge_restart", "crashloop_restart")
INTERRUPTING = {"ha_bridge_restart", "crashloop_restart"}
MODES = ("uit", "alleen-melden", "aan")          # ordered strict -> permissive

# Cooldown windows (seconds), unchanged from the original rule engine.
CD_FLUX_RECONCILE = 24 * 3600
CD_WORKLOAD_RESTART = 12 * 3600
MAX_ACTIONS_PER_OBJECT_PER_DAY = 3
POD_CLEANUP_MIN_AGE_S = 3600
ROLLOUT_VERIFY_TIMEOUT_S = 300

# Owner brief 2026-10-12: Passkey Point has priority; lab-passkey,
# passkey-point-e2e and devtenant-* are not touched. mypka and family-ai are
# myPKA-team territory. Applies to every runbook, including pod cleanup.
NEVER_NAMESPACES = ("lab-passkey", "passkey-point-e2e", "devtenant-*", "mypka", "family-ai")
# flux-system objects that belong to those areas (lab-passkey-app,
# devtenant-base, mypka-boundary, external-secrets-stores-devtenant, ...).
NEVER_NAME_TOKENS = ("lab-passkey", "passkey-point", "devtenant", "mypka", "family-ai")
# Core production (cat 3): a crashloop there needs a human, not a bounce.
RESTART_PROTECTED_NAMESPACES = ("kube-system", "flux-system", "rook-ceph", "storage", "security",
                                "devtools", "database", "cert-manager", "network")
SELFTEST_NAMESPACES = ("aiops-selftest",)
WINDOWS_LOCAL = ((1, 6), (9, 16))                 # [start_hour, end_hour)


# ---------------------------------------------------------------- switches

def stricter(a: str, b: str) -> str:
    return MODES[min(MODES.index(a), MODES.index(b))]


def norm_mode(v: str | None, default: str) -> str:
    v = (v or "").strip().lower()
    return v if v in MODES else default


def load_switches() -> dict:
    rc, out, _ = run(["kubectl", "-n", MODE_CM_NS, "get", "configmap", MODE_CM_NAME, "-o", "json"], timeout=20)
    data: dict = {}
    source = f"configmap {MODE_CM_NS}/{MODE_CM_NAME}"
    if rc == 0:
        try:
            data = json.loads(out).get("data", {}) or {}
        except Exception:  # noqa: BLE001
            source += " (unparseable -> alleen-melden)"
    else:
        source += f" (unreadable rc={rc} -> alleen-melden)"
    glob = norm_mode(data.get("mode"), "alleen-melden")
    if DRY_RUN_ENV:
        glob = stricter(glob, "alleen-melden")
        source += " + DRY_RUN env"
    per = {rb: stricter(glob, norm_mode(data.get(f"runbook.{rb}"), "aan")) for rb in RUNBOOKS}
    scope_raw = (data.get("scope") or "all").strip()
    scope = None if scope_raw in ("", "all", "*") else [s.strip() for s in scope_raw.split(",") if s.strip()]
    return {"global": glob, "runbooks": per, "scope": scope, "source": source}


def ns_never(ns: str) -> bool:
    return any(fnmatch.fnmatch(ns, p) for p in NEVER_NAMESPACES)


def in_window(now_local: datetime) -> bool:
    return any(s <= now_local.hour < e for s, e in WINDOWS_LOCAL)


def cooldown_ok(cd: dict, key: str, window: int) -> bool:
    last = cd.get(key)
    if not last:
        return True
    try:
        return (datetime.now(timezone.utc) - datetime.fromisoformat(last)).total_seconds() >= window
    except Exception:  # noqa: BLE001
        return True


# ---------------------------------------------------------------- context

class Ctx:
    def __init__(self, switches: dict):
        self.sw = switches
        self.audit: list = []
        self.cd = read_json(COOLDOWN_FILE, default={}) or {}
        self.now_local = datetime.now(LOCAL_TZ)
        today_local = self.now_local.date().isoformat()
        counts = read_json(DAILY_COUNT_FILE, default={}) or {}
        self.counts = counts if counts.get("_date") == today_local else {"_date": today_local}
        self.run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.seq = 0

    def save(self) -> None:
        write_json(COOLDOWN_FILE, self.cd)
        write_json(DAILY_COUNT_FILE, self.counts)

    def decide(self, runbook: str, ns: str, obj_key: str) -> tuple[bool, str]:
        """Return (act, why_not). act=False means report only."""
        if ns_never(ns):
            return False, "never-namespace"
        mode = self.sw["runbooks"][runbook]
        if mode == "uit":
            return False, "runbook uit"
        scope = self.sw["scope"]
        if scope is not None and ns not in scope:
            return False, "out of scope"
        if mode == "alleen-melden":
            return False, "alleen-melden"
        if runbook in INTERRUPTING:
            if ns in RESTART_PROTECTED_NAMESPACES:
                return False, "protected namespace (core): report only"
            if ns not in SELFTEST_NAMESPACES and not in_window(self.now_local):
                return False, "deferred: outside 01-06/09-16 window"
        if self.counts.get(obj_key, 0) >= MAX_ACTIONS_PER_OBJECT_PER_DAY:
            return False, f"daily cap {MAX_ACTIONS_PER_OBJECT_PER_DAY} reached"
        return True, ""

    def report(self, runbook: str, target: str, reason: str, why: str) -> None:
        if why in ("never-namespace", "runbook uit"):
            return  # silent: not ours / switched off
        self.audit.append({"ts": now_iso(), "runbook": runbook, "action": f"{runbook}_proposed",
                           "target": target, "reason": reason, "outcome": "not-acted", "why": why})

    def act(self, runbook: str, obj_key: str, target: str, reason: str, args: list[str],
            verify=None) -> bool:
        rc, _, err = run(["kubectl", *args], timeout=60)
        outcome = "ok" if rc == 0 else f"error rc={rc}: {err.strip()[:200]}"
        verdict = verify() if (rc == 0 and verify is not None) else None
        self.counts[obj_key] = self.counts.get(obj_key, 0) + 1
        if rc != 0 or (verdict or "").startswith("FAILED"):
            # Stop here for today: no retry loop on something a bounce did not fix.
            self.counts[obj_key] = max(self.counts[obj_key], MAX_ACTIONS_PER_OBJECT_PER_DAY)
        self.seq += 1
        line = {
            "ts": now_iso(),
            "actor": "aiops-triage",
            "chg": f"aiops-{self.run_id}-{self.seq}",
            "event": "executed",
            "risk": "low",
            "resource": target,
            "payload": {
                "runbook": runbook,
                "reason": reason,
                "command": "kubectl " + " ".join(args),
                "outcome": outcome,
                "verify": verdict,
                "count_today": self.counts[obj_key],
                "mode_source": self.sw["source"],
            },
        }
        s = json.dumps(line, sort_keys=True, default=str)
        print("AIOPS_CHANGE " + s, flush=True)                    # Loki stream
        CHANGES_FILE.parent.mkdir(parents=True, exist_ok=True)
        with CHANGES_FILE.open("a") as f:                          # PVC ledger
            f.write(s + "\n")
        self.audit.append({"ts": line["ts"], "runbook": runbook, "action": runbook, "target": target,
                           "reason": reason, "outcome": outcome, "verify": verdict, "chg": line["chg"]})
        log(f"[FIX] {runbook} {target} -> {outcome} verify={verdict}")
        return rc == 0


# ---------------------------------------------------------------- live data

def live_k8s() -> dict:
    import collect_k8s  # same ConfigMap, /scripts on sys.path
    return {"flux_ks": collect_k8s.collect_flux_ks(),
            "flux_hr": collect_k8s.collect_flux_hr(),
            "pods": collect_k8s.collect_pods()}


def live_collector(cmd: list[str]) -> dict:
    rc, out, _ = run(cmd, timeout=60)
    if rc != 0:
        return {"_error": f"rc={rc}"}
    try:
        return json.loads(out)
    except Exception:  # noqa: BLE001
        return {"_error": "bad json"}


def ready_of(ns: str, kind: str, name: str) -> tuple[int, int]:
    _, out, _ = run(["kubectl", "-n", ns, "get", kind.lower(), name, "-o",
                     "jsonpath={.status.readyReplicas}/{.spec.replicas}"], timeout=15)
    r, _, t = (out or "").partition("/")
    return (int(r) if r.isdigit() else 0), (int(t) if t.isdigit() else 0)


def rollout_verifier(ns: str, kind: str, name: str):
    def _v() -> str:
        rc, _, err = run(["kubectl", "-n", ns, "rollout", "status", f"{kind.lower()}/{name}",
                          f"--timeout={ROLLOUT_VERIFY_TIMEOUT_S}s"], timeout=ROLLOUT_VERIFY_TIMEOUT_S + 15)
        if rc == 0:
            r, t = ready_of(ns, kind, name)
            return f"healthy {r}/{t} Ready"
        return f"FAILED: not healthy after {ROLLOUT_VERIFY_TIMEOUT_S}s ({err.strip()[:120]})"
    return _v


# ---------------------------------------------------------------- runbooks

def rb_pod_cleanup(ctx: Ctx) -> None:
    rc, out, err = run(["kubectl", "get", "pods", "-A", "-o", "json"], timeout=60)
    if rc != 0:
        log(f"pod cleanup: list failed: {err.strip()[:200]}")
        return
    try:
        pods = json.loads(out).get("items", [])
    except Exception:  # noqa: BLE001
        return
    now = datetime.now(timezone.utc)
    for p in pods:
        st = p.get("status", {})
        phase, reason = st.get("phase"), st.get("reason", "")
        if phase not in ("Failed", "Succeeded") and reason != "Evicted":
            continue
        try:
            created = datetime.fromisoformat(p["metadata"]["creationTimestamp"].replace("Z", "+00:00"))
        except Exception:  # noqa: BLE001
            continue
        age = (now - created).total_seconds()
        if age < POD_CLEANUP_MIN_AGE_S:
            continue
        ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
        key = f"pod:{ns}/{name}"
        why_reason = f"phase={phase} reason={reason or '-'} age={int(age / 60)}m"
        act, why = ctx.decide("pod_cleanup", ns, key)
        if not act:
            ctx.report("pod_cleanup", f"{ns}/{name}", why_reason, why)
            continue
        ctx.act("pod_cleanup", key, f"pod/{ns}/{name}", why_reason,
                ["delete", "pod", "-n", ns, name, "--wait=false"])


def rb_flux_reconcile(ctx: Ctx, k8s: dict) -> None:
    for kind, plural in (("kustomizations.kustomize.toolkit.fluxcd.io", "flux_ks"),
                         ("helmreleases.helm.toolkit.fluxcd.io", "flux_hr")):
        for it in k8s.get(plural, {}).get("items", []):
            if it.get("ready") or it.get("suspended"):
                continue
            ns, name = it["namespace"], it["name"]
            target_ns = "devtenant-never" if any(t in name for t in NEVER_NAME_TOKENS) else ns
            key = f"flux:{plural}:{ns}/{name}"
            msg = (it.get("message") or "not ready")[:200]
            act, why = ctx.decide("flux_reconcile", target_ns, key)
            if act and not cooldown_ok(ctx.cd, key, CD_FLUX_RECONCILE):
                act, why = False, "cooldown 24h"
            if not act:
                ctx.report("flux_reconcile", f"{plural}:{ns}/{name}", msg, why)
                continue
            if ctx.act("flux_reconcile", key, f"{plural}:{ns}/{name}", msg,
                       ["annotate", kind, "-n", ns, name,
                        f"reconcile.fluxcd.io/requestedAt={now_iso()}", "--overwrite"]):
                ctx.cd[key] = now_iso()


def owner_workload(ns: str, pod: str) -> tuple[str, str] | None:
    rc, out, _ = run(["kubectl", "-n", ns, "get", "pod", pod, "-o",
                      "jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}"], timeout=15)
    if rc != 0 or not out.strip():
        return None
    kind, _, name = out.strip().partition("/")
    if kind == "ReplicaSet":
        rc, dep, _ = run(["kubectl", "-n", ns, "get", "rs", name, "-o",
                          "jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}"], timeout=15)
        if rc == 0 and dep.strip():
            kind, _, name = dep.strip().partition("/")
    return kind, name


def rb_crashloop_restart(ctx: Ctx, k8s: dict) -> None:
    workloads: dict[str, dict] = {}
    for p in k8s.get("pods", {}).get("crashloop", []):
        ns = p["namespace"]
        if ns_never(ns):
            continue
        ow = owner_workload(ns, p["pod"])
        if not ow:
            continue
        kind, name = ow
        w = workloads.setdefault(f"{ns}/{kind}/{name}", {"ns": ns, "kind": kind, "name": name, "count": 0})
        w["count"] += 1
    for key, w in workloads.items():
        if w["kind"] not in ("Deployment", "StatefulSet"):
            continue
        ready, total = ready_of(w["ns"], w["kind"], w["name"])
        reason = f"{w['count']} pod(s) in CrashLoopBackOff, {ready}/{total} replicas Ready"
        if ready > 0:
            ctx.report("crashloop_restart", key, reason, "a replica is still Ready: manual triage")
            continue
        obj_key = f"workload:{key}"
        cd_key = f"restart:{key}"
        act, why = ctx.decide("crashloop_restart", w["ns"], obj_key)
        if act and not cooldown_ok(ctx.cd, cd_key, CD_WORKLOAD_RESTART):
            act, why = False, "cooldown 12h"
        if not act:
            ctx.report("crashloop_restart", key, reason, why)
            continue
        if ctx.act("crashloop_restart", obj_key, key, reason,
                   ["-n", w["ns"], "rollout", "restart", f"{w['kind'].lower()}/{w['name']}"],
                   verify=rollout_verifier(w["ns"], w["kind"], w["name"])):
            ctx.cd[cd_key] = now_iso()


def rb_ha_bridge_restart(ctx: Ctx) -> None:
    candidates = [
        ("z2m", ["python3", "/scripts/collect_z2m.py"], "home-automation", "Deployment", "zigbee2mqtt"),
        ("zwave", ["python3", "/scripts/collect_zwave.py"], "home-automation", "Deployment", "zwave-js-ui"),
        ("mqtt", ["sh", "/scripts/collect_mqtt.sh"], "home-automation", "Deployment", "mosquitto"),
    ]
    for section, cmd, ns, kind, name in candidates:
        s = live_collector(cmd)
        if s.get("_error"):
            continue
        unhealthy = False
        # z2m: only trust "offline" when HA actually returned the bridge entity
        # (an unreachable HA must never look like a dead bridge).
        if section == "z2m" and s.get("bridge") and not s.get("bridge_online", True):
            unhealthy = True
        if section == "zwave" and s.get("dead", 0) > 0 and s.get("alive", 0) == 0:
            unhealthy = True
        if section == "mqtt" and not s.get("reachable", True):
            unhealthy = True
        if not unhealthy:
            continue
        key = f"{ns}/{kind}/{name}"
        ready, total = ready_of(ns, kind, name)
        reason = f"{name} unhealthy per {section} probe, {ready}/{total} Ready"
        if ready > 0:
            ctx.report("ha_bridge_restart", key, reason, "a replica is still Ready: report only")
            continue
        obj_key = f"workload:{key}"
        cd_key = f"ha-restart:{ns}/{name}"
        act, why = ctx.decide("ha_bridge_restart", ns, obj_key)
        if act and not cooldown_ok(ctx.cd, cd_key, CD_WORKLOAD_RESTART):
            act, why = False, "cooldown 12h"
        if not act:
            ctx.report("ha_bridge_restart", key, reason, why)
            continue
        if ctx.act("ha_bridge_restart", obj_key, key, reason,
                   ["-n", ns, "rollout", "restart", f"{kind.lower()}/{name}"],
                   verify=rollout_verifier(ns, kind, name)):
            ctx.cd[cd_key] = now_iso()


def rb_network_anomaly(ctx: Ctx) -> None:
    """Advisory only (no fix). Day-over-day UniFi port counters from the daily
    raw report; evaluated once a day."""
    date = ctx.now_local.strftime("%Y-%m-%d")
    raw = read_json(RAW_DIR / f"{date}.json", {}) or {}
    section = (raw.get("sections") or {}).get("network") or {}
    ports = section.get("ports") or []
    if not ports:
        return
    prior_date = (ctx.now_local.date() - timedelta(days=1)).isoformat()
    prior = read_json(RAW_DIR / f"{prior_date}.json", {}) or {}
    prior_ports = {f"{p.get('sw_mac')}:{p.get('port_idx')}": p
                   for p in (prior.get("sections", {}).get("network", {}).get("ports") or [])}
    flap_warn = section.get("thresholds", {}).get("flap_count_warn", 5)
    rx_warn = section.get("thresholds", {}).get("rx_errors_warn", 1)
    for p in ports:
        prev = prior_ports.get(f"{p.get('sw_mac')}:{p.get('port_idx')}") or {}
        prev_flap = prev.get("link_down_count", 0) or 0
        cur_flap = p.get("link_down_count", 0) or 0
        rx_err = p.get("rx_errors", 0) or 0
        reasons = []
        if rx_err >= rx_warn:
            reasons.append(f"rx_errors={rx_err}")
        if cur_flap - prev_flap >= 2:
            reasons.append(f"link_down_count +{cur_flap - prev_flap} ({prev_flap}->{cur_flap})")
        elif cur_flap >= flap_warn and prev_flap == 0:
            reasons.append(f"link_down_count={cur_flap} (>={flap_warn})")
        if reasons:
            ctx.audit.append({"ts": now_iso(), "runbook": "network_anomaly", "action": "network_anomaly_flagged",
                              "target": f"{p.get('sw_name')}/port-{p.get('port_idx')} ({p.get('friendly') or p.get('client_mac')})",
                              "reason": "; ".join(reasons), "outcome": "advisory"})


# ---------------------------------------------------------------- main

def main() -> int:
    t0 = time.time()
    sw = load_switches()
    ctx = Ctx(sw)
    log(f"triage start: global={sw['global']} runbooks={sw['runbooks']} scope={sw['scope'] or 'all'} "
        f"window={'open' if in_window(ctx.now_local) else 'closed'} ({ctx.now_local:%H:%M} local) src={sw['source']}")
    if sw["global"] == "uit":
        log("aiops-mode=uit: nothing evaluated")
        return 0

    k8s = live_k8s()
    rb_pod_cleanup(ctx)
    rb_flux_reconcile(ctx, k8s)
    rb_crashloop_restart(ctx, k8s)
    rb_ha_bridge_restart(ctx)
    if ctx.now_local.hour == 3 and ctx.now_local.minute < 15:
        rb_network_anomaly(ctx)    # day-over-day counters: once a day is enough
    ctx.save()

    date = ctx.now_local.strftime("%Y-%m-%d")
    acted = [e for e in ctx.audit if e["action"] in RUNBOOKS]
    summary = {"date": date, "ts": now_iso(), "switches": sw, "acted": len(acted),
               "proposed": len(ctx.audit) - len(acted), "by_action": {}, "audit": ctx.audit,
               "duration_s": round(time.time() - t0, 1)}
    for e in ctx.audit:
        summary["by_action"][e["action"]] = summary["by_action"].get(e["action"], 0) + 1
    write_json(TRIAGE_DIR / f"{date}.json", summary)   # latest run of the day
    # Rolling audit keeps acted + advisory only; per-run proposals would
    # repeat 96x a day and live in the day file above.
    with (TRIAGE_DIR / "audit.jsonl").open("a") as f:
        for e in ctx.audit:
            if e.get("outcome") != "not-acted":
                f.write(json.dumps(e, default=str) + "\n")
    log(f"triage done: acted={len(acted)} proposed={summary['proposed']} by_action={summary['by_action']} "
        f"in {summary['duration_s']}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
