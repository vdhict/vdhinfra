#!/usr/bin/env python3
"""aiops-morning-summary (chg-2026-10-12-009). Runs 07:00 Europe/Amsterdam.

Night alerts (23:00-07:00) are posted to ntfy at priority 1 (no sound, no
vibration) with a "[night] " title prefix by Alertmanager's ntfy-night
receiver. This job posts ONE summary of that night: priority 3 if anything
happened, priority 2 (silent) on a quiet night, so the owner also learns each
morning that the alert path itself is alive.

Source of truth since 2026-10-13 (self-hosted ntfy, whose alertmanager token
is write-only): Prometheus, not the ntfy topic. An alert counts as a night
alert when it was firing at some point since 23:00 with severity warning or
critical and was NOT already firing at 23:00 (those were sent by day).

Env:
  PROM_URL          Prometheus base URL (in-cluster)
  NTFY_URL          full topic URL, e.g. http://ntfy.ntfy.svc.cluster.local/alerts
  NTFY_TOKEN_FILE   bearer token file (write access to the topic); never printed
  DRY_RUN=1         print instead of posting
"""
from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Amsterdam")
PROM = os.environ.get("PROM_URL", "http://kube-prometheus-stack-prometheus.observability.svc:9090").rstrip("/")
NTFY_URL = os.environ["NTFY_URL"]
TOKEN_FILE = os.environ.get("NTFY_TOKEN_FILE", "/secrets/ntfy/token")
DRY = os.environ.get("DRY_RUN") == "1"
SEV = 'alertstate="firing",severity=~"warning|critical"'


def prom(query: str) -> list:
    url = f"{PROM}/api/v1/query?{urllib.parse.urlencode({'query': query})}"
    with urllib.request.urlopen(url, timeout=20) as r:
        data = json.loads(r.read())
    if data.get("status") != "success":
        raise RuntimeError(f"prometheus query failed: {data.get('error')}")
    return data["data"]["result"]


def main() -> int:
    now = datetime.now(TZ)
    start = (now - timedelta(days=1)).replace(hour=23, minute=0, second=0, microsecond=0)
    if now.hour >= 23:  # manual run late evening: summarise tonight so far
        start = now.replace(hour=23, minute=0, second=0, microsecond=0)
    w = max(60, int((now - start).total_seconds()))
    new_at_night = (f"max by (alertname, severity) (max_over_time(ALERTS{{{SEV}}}[{w}s]) "
                    f"unless on(alertname, severity) ALERTS{{{SEV}}} offset {w}s)")
    night = {(r["metric"]["alertname"], r["metric"].get("severity", "")) for r in prom(new_at_night)}
    still = {(r["metric"]["alertname"], r["metric"].get("severity", ""))
             for r in prom(f"max by (alertname, severity) (ALERTS{{{SEV}}})")}
    span = f"{start:%H:%M}-{now:%H:%M}"
    if not night:
        title, prio, body = f"Night summary {span}: quiet", 2, "No warning or critical alert started tonight."
    else:
        title, prio = f"Night summary {span}: {len(night)} alert(s) started", 3
        body = "\n".join(f"{'still firing' if k in still else 'resolved'}  {k[0]} ({k[1]})"
                         for k in sorted(night, key=lambda k: (k not in still, k[1] != "critical", k[0])))
    print(json.dumps({"night_alerts": len(night), "still_firing": len(night & still),
                      "priority": prio, "window_s": w, "dry_run": DRY}))
    if DRY:
        print(title)
        print(body)
        return 0
    with open(TOKEN_FILE) as fh:
        token = fh.read().strip()
    req = urllib.request.Request(NTFY_URL, data=body.encode(), method="POST",
                                 headers={"Title": title, "Priority": str(prio), "Tags": "sunrise",
                                          "Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        r.read()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
