#!/usr/bin/env python3
"""Inspect the minio-offsite-mirror CronJob status to report whether the
last offsite sync succeeded recently. We do not call Azure ourselves —
the K8s API is the authoritative source for whether the Job ran cleanly.

Output schema:
{
  "configured": bool,           # CronJob exists in storage ns
  "schedule": str,              # cron expression
  "suspended": bool,
  "last_schedule_time": iso,    # most recent time the controller fired
  "last_successful_time": iso,  # most recent time a Job completed OK
  "hours_since_last_success": float | null,
  "active_jobs": int,
  "status": "ok" | "stale" | "never" | "missing",
}
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone

sys.path.insert(0, "/scripts")
from lib import kubectl_json, log  # noqa: E402

NAMESPACE = "storage"
CRONJOB_NAME = "minio-offsite-mirror"
STALE_HOURS = 36  # alert threshold


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def main() -> int:
    out = {"configured": False, "status": "missing"}
    cj = kubectl_json(["get", "cronjob", "-n", NAMESPACE, CRONJOB_NAME])
    if not cj or "spec" not in cj:
        json.dump(out, sys.stdout, indent=2)
        return 0

    out["configured"] = True
    out["schedule"] = cj["spec"].get("schedule")
    out["suspended"] = bool(cj["spec"].get("suspend", False))
    s = cj.get("status", {}) or {}
    out["last_schedule_time"] = s.get("lastScheduleTime")
    out["active_jobs"] = len(s.get("active", []) or [])

    # CronJob.status.lastSuccessfulTime is only updated by Jobs that the
    # CronJob CONTROLLER spawned — not by manually-triggered Jobs created
    # via `kubectl create job --from=cronjob/...`. Walk the namespace's
    # Jobs directly and find the most recent one whose name starts with
    # the cronjob name AND completed successfully.
    jobs = kubectl_json(["get", "jobs", "-n", NAMESPACE])
    last_ok = None
    if jobs:
        for j in jobs.get("items", []):
            name = j["metadata"].get("name", "")
            # Match either `<cronjob>-<timestamp>` (scheduled) or
            # any name containing the cronjob name (manual-triggered)
            if CRONJOB_NAME not in name and not name.startswith("mirror"):
                continue
            jstatus = j.get("status", {}) or {}
            if jstatus.get("succeeded", 0) >= 1:
                ct = parse_ts(jstatus.get("completionTime"))
                if ct and (last_ok is None or ct > last_ok):
                    last_ok = ct

    out["last_successful_time"] = last_ok.isoformat() if last_ok else None

    if not last_ok:
        out["hours_since_last_success"] = None
        out["status"] = "never"
    else:
        delta = (datetime.now(timezone.utc) - last_ok).total_seconds() / 3600
        out["hours_since_last_success"] = round(delta, 2)
        out["status"] = "ok" if delta <= STALE_HOURS else "stale"

    json.dump(out, sys.stdout, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
