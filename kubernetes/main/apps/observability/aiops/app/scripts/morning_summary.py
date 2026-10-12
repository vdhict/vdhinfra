#!/usr/bin/env python3
"""aiops-morning-summary (chg-2026-10-12-009). Runs 07:00 Europe/Amsterdam.

Night alerts (23:00-07:00) are posted to the infra ntfy topic at priority 1
(no sound, no vibration) with a "[night] " title prefix, by Alertmanager's
ntfy-night receiver and by the Mac heartbeat agents. This job reads those
messages back from the topic (ntfy caches 12 h) and posts ONE summary:
priority 3 if anything happened, priority 2 (silent) on a quiet night, so the
owner also learns each morning that the alert path itself is alive.

Env: NTFY_SERVER, NTFY_TOPIC (from the alertmanager-ntfy Secret). The topic is
never printed.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Amsterdam")
SERVER = os.environ["NTFY_SERVER"].rstrip("/")
TOPIC = os.environ["NTFY_TOPIC"]
DRY = os.environ.get("DRY_RUN") == "1"


def main() -> int:
    now = datetime.now(TZ)
    start = (now - timedelta(days=1)).replace(hour=23, minute=0, second=0, microsecond=0)
    if now.hour >= 23:  # manual run late evening: summarise tonight so far
        start = now.replace(hour=23, minute=0, second=0, microsecond=0)
    url = f"{SERVER}/{TOPIC}/json?poll=1&since={int(start.timestamp())}"
    with urllib.request.urlopen(url, timeout=20) as r:
        msgs = [json.loads(l) for l in r.read().decode().splitlines() if l.strip()]
    night = [m for m in msgs if m.get("event") == "message" and (m.get("title") or "").startswith("[night] ")]
    firing = Counter()
    resolved = Counter()
    for m in night:
        for line in (m.get("message") or "").splitlines():
            parts = line.split(" ", 2)
            if len(parts) >= 2 and parts[0] in ("FIRING", "RESOLVED", "LOST", "BACK"):
                (firing if parts[0] in ("FIRING", "LOST") else resolved)[parts[1].rstrip(":")] += 1
    span = f"{start:%H:%M}-{now:%H:%M}"
    if not night:
        title, prio, body = f"Night summary {span}: quiet", 2, "No night alerts were posted."
    else:
        title, prio = f"Night summary {span}: {len(night)} night message(s)", 3
        lines = [f"firing  {k} x{v}" for k, v in firing.most_common(15)]
        lines += [f"resolved {k} x{v}" for k, v in resolved.most_common(15)]
        body = "\n".join(lines) or "\n".join((m.get("title") or "")[8:] for m in night[:15])
    print(json.dumps({"night_messages": len(night), "firing_kinds": len(firing),
                      "resolved_kinds": len(resolved), "priority": prio, "dry_run": DRY}))
    if DRY:
        print(title)
        print(body)
        return 0
    req = urllib.request.Request(f"{SERVER}/{TOPIC}", data=body.encode(), method="POST",
                                 headers={"Title": title, "Priority": str(prio), "Tags": "sunrise"})
    with urllib.request.urlopen(req, timeout=20) as r:
        r.read()
    return 0


if __name__ == "__main__":
    sys.exit(main())
