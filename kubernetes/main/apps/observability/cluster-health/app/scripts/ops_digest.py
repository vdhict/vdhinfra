#!/usr/bin/env python3
"""Daily digest: clone the repo, run `ops digest`, post to HA persistent_notification.

Runs at 06:30 local. Posts a single persistent_notification (id=ops_digest_<date>)
so every HA dashboard shows it. Fully best-effort: if anything fails we log and
exit clean — the digest reappears tomorrow.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error
from pathlib import Path

sys.path.insert(0, "/scripts")
from git_push import mint_installation_token  # noqa: E402
from lib import log, today  # noqa: E402

GIT_REMOTE = os.environ.get("GIT_REMOTE", "https://github.com/vdhict/vdhinfra.git")
GIT_BRANCH = os.environ.get("GIT_BRANCH", "main")
HA_URL = os.environ.get("HA_URL", "")
HA_TOKEN = os.environ.get("HA_TOKEN", "")
REPORT_BASE_URL = os.environ.get("REPORT_BASE_URL", "")
DIGEST_DAYS = int(os.environ.get("DIGEST_DAYS", "1"))


def run_digest_cli(workdir: Path) -> str:
    """Run `ops/ops digest --days N` and return its plain-text output (no ANSI)."""
    env = os.environ.copy()
    env["TERM"] = "dumb"  # avoid colour codes
    proc = subprocess.run(
        ["python3", "ops/ops", "digest", "--days", str(DIGEST_DAYS)],
        cwd=str(workdir),
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if proc.returncode != 0:
        log(f"ops_digest: CLI rc={proc.returncode}: {proc.stderr[:300]}")
    # Strip ANSI escape codes defensively
    import re
    return re.sub(r"\x1b\[[0-9;]*m", "", proc.stdout)


def clone(workdir: Path) -> bool:
    tok = mint_installation_token()
    if not tok:
        log("ops_digest: no token, cannot clone — falling back to no digest")
        return False
    # remote without https://
    remote_path = GIT_REMOTE.removeprefix("https://")
    auth_url = f"https://x-access-token:{tok}@{remote_path}"
    res = subprocess.run(
        ["git", "clone", "--quiet", "--depth", "1", "--branch", GIT_BRANCH, auth_url, str(workdir)],
        capture_output=True, text=True, timeout=120,
    )
    if res.returncode != 0:
        log(f"ops_digest: clone failed: {res.stderr[:300]}")
        return False
    return True


def post_persistent_notification(title: str, message: str, notification_id: str) -> None:
    if not (HA_URL and HA_TOKEN):
        log("ops_digest: missing HA_URL/HA_TOKEN, skipping HA post")
        return
    body = {
        "title": title,
        "message": message,
        "notification_id": notification_id,
    }
    req = urllib.request.Request(
        f"{HA_URL}/api/services/persistent_notification/create",
        method="POST",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {HA_TOKEN}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            log(f"ops_digest: HA persistent_notification {r.status}")
    except urllib.error.HTTPError as e:
        log(f"ops_digest: HA POST {e.code}: {e.read().decode(errors='replace')[:200]}")
    except Exception as e:  # noqa: BLE001
        log(f"ops_digest: HA POST failed: {e}")


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="ops-digest-"))
    try:
        if not clone(workdir):
            return 0  # logged; not fatal
        text = run_digest_cli(workdir).strip() or "(no changes/incidents)"
        date = today()
        # Markdown so HA renders headings cleanly
        message = f"```\n{text}\n```"
        if REPORT_BASE_URL:
            message += f"\n\n[Open ops portal]({REPORT_BASE_URL}/ops.html) · [Cluster health]({REPORT_BASE_URL}/{date}.html)"
        post_persistent_notification(
            title=f"vdhinfra ops digest — {date}",
            message=message,
            notification_id=f"ops_digest_{date}",
        )
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
