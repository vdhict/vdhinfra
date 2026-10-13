#!/usr/bin/env python3
"""Mini-side bridge for the vdhwslin01 waker (chg-2026-10-05-031).

The waker runs in the cluster and cannot write ops/changes.jsonl or the
handoff directory. This reads its events from ConfigMap
devtools/vdhwslin01-waker-state (no secrets in it) and:
  - appends ONE change-log line per wake event via ./ops/ops change event;
  - for a cap_hit event writes ONE line to Larry in
    ~/mypka-handoff/<day>/<day>-atlas-to-larry-vdhwslin01-cap.md (once per day).
A cursor (~/.config/atlas/vdhwslin01-waker.cursor) makes it idempotent.

Usage: collect-waker-events.py [--dry-run]   (run from anywhere; needs kubectl)
"""
import json
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
CURSOR = os.path.expanduser("~/.config/atlas/vdhwslin01-waker.cursor")
HANDOFF = os.path.expanduser("~/mypka-handoff")
CHG = "chg-2026-10-05-031"


def kubectl_state():
    out = subprocess.run(["kubectl", "-n", "devtools", "get", "configmap", "vdhwslin01-waker-state",
                          "-o", "jsonpath={.data.state\\.json}"], check=True, capture_output=True, text=True).stdout
    return json.loads(out or "{}")


def key(ev):
    return "%s|%s|%s" % (ev.get("ts"), ev.get("event"), ev.get("result", ""))


def main():
    dry = "--dry-run" in sys.argv
    seen = set()
    if os.path.exists(CURSOR):
        with open(CURSOR) as f:
            seen = set(l.strip() for l in f if l.strip())
    events = kubectl_state().get("events", [])
    new = [e for e in events if key(e) not in seen]
    for ev in new:
        payload = dict(ev, regime="AGR-109: tests are the gate", source="vdhwslin01-waker CronJob (collector)")
        cmd = [os.path.join(REPO, "ops", "ops"), "change", "event", CHG, "executed",
               "--actor", "k8s-engineer", "--payload-json", json.dumps(payload, sort_keys=True)]
        if ev.get("event") == "vdhwslin01_wake_cap_hit":
            day = ev["ts"][:10]
            path = os.path.join(HANDOFF, day, "%s-atlas-to-larry-vdhwslin01-cap.md" % day)
            line = ("Atlas -> Larry (%s): vdhwslin01 daily wake cap (%s/day) reached with %s queued job(s); "
                    "no more team boots today, jobs wait for tomorrow or for Sander's own boot. - Atlas\n"
                    % (ev["ts"], ev.get("cap"), ev.get("queued_jobs")))
            if dry:
                print("[dry-run] would write", path)
            elif not os.path.exists(path):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(line)
                print("wrote", path)
        if dry:
            print("[dry-run] would log:", json.dumps(payload, sort_keys=True))
            continue
        subprocess.run(cmd, check=True, cwd=REPO)
        os.makedirs(os.path.dirname(CURSOR), exist_ok=True)
        with open(CURSOR, "a") as f:
            f.write(key(ev) + "\n")
    print("vdhwslin01 waker events: %d total, %d new%s" % (len(events), len(new), " (dry-run)" if dry else ""))


if __name__ == "__main__":
    main()
