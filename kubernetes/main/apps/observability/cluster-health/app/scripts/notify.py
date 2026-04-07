#!/usr/bin/env python3
"""Send the daily report summary as a mobile push notification via HA."""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, "/scripts")
from lib import REPORTS_DIR, http_post_json, log, today  # noqa: E402


def main() -> int:
    base = os.environ.get("HA_URL", "")
    token = os.environ.get("HA_TOKEN", "")
    target = os.environ.get("HA_NOTIFY_TARGET", "")
    report_base = os.environ.get("REPORT_BASE_URL", "")
    if not base or not token or not target:
        log("notify: missing HA_URL/HA_TOKEN/HA_NOTIFY_TARGET, skipping")
        return 0

    date = today()
    md_path = REPORTS_DIR / f"{date}.md"
    if not md_path.exists():
        log(f"notify: no report at {md_path}")
        return 0
    md = md_path.read_text()
    headline = "Cluster Health"
    m = re.search(r"\*\*(.+?)\*\*", md)
    if m:
        headline = m.group(1)

    title = "Cluster Health"
    if "🔴" in headline:
        title = "🔴 Cluster Health — action needed"
    elif "🟡" in headline:
        title = "🟡 Cluster Health — warnings"
    else:
        title = "🟢 Cluster Health — all good"

    url = f"{report_base}/{date}.html" if report_base else ""
    body = {
        "title": title,
        "message": headline,
        "data": {"url": url, "clickAction": url},
    }
    code, resp = http_post_json(
        f"{base}/api/services/notify/{target}",
        body,
        headers={"Authorization": f"Bearer {token}"},
    )
    log(f"notify: HA notify.{target} returned {code} {resp[:200]}")
    return 0 if 200 <= code < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
