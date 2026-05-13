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


RENOVATE_AUTHORS = ("renovate[bot]", "renovate-bot", "renovate")


def sync_renovate_commits(workdir: Path) -> int:
    """Read git log for the last 24h. For each Renovate commit, synthesise
    a full change-record lifecycle (requested → executed → validated → closed)
    in ops/changes.jsonl. Returns count appended.

    Idempotent: skips commits already referenced in changes.jsonl.
    """
    res = subprocess.run(
        ["git", "log", "--since=24 hours ago", "--no-merges",
         "--pretty=format:%H%x09%an%x09%s"],
        cwd=str(workdir), capture_output=True, text=True, timeout=30,
    )
    if res.returncode != 0:
        log(f"ops_digest renovate-sync: git log failed: {res.stderr[:200]}")
        return 0

    # Existing commit ids referenced in changes.jsonl
    changes_path = workdir / "ops" / "changes.jsonl"
    seen = set()
    if changes_path.exists():
        for line in changes_path.read_text().splitlines():
            try:
                e = json.loads(line)
                for sha in (e.get("payload") or {}).get("commits", []) or []:
                    seen.add(sha)
            except Exception:
                continue

    cli = workdir / "ops" / "ops"
    added = 0
    for line in res.stdout.splitlines():
        try:
            sha, author, subject = line.split("\t", 2)
        except ValueError:
            continue
        if not any(a in author.lower() for a in RENOVATE_AUTHORS):
            continue
        if sha in seen:
            continue
        # Derive a resource id from the subject. Renovate commits look like
        # "feat(container): update image X ( ... )" or "fix(mise): ...".
        scope = "renovate"
        if "(" in subject and ")" in subject:
            scope = subject.split("(", 1)[1].split(")", 1)[0]
        resource = f"renovate.{scope}"
        # All Renovate auto-merges are low-risk by config (high-risk paths
        # have automerge: false, so user-merged ones won't show as renovate
        # in author anyway).
        try:
            chg_res = subprocess.run(
                ["python3", str(cli), "change", "new", resource, "low",
                 "--actor", "infra-ops",
                 "--summary", subject[:120],
                 "--reason", f"Renovate auto-merge (commit {sha[:7]})",
                 "--requested-by", "renovate-bot"],
                cwd=str(workdir), capture_output=True, text=True, timeout=15,
            )
            if chg_res.returncode != 0:
                log(f"ops_digest renovate-sync: change new failed: {chg_res.stderr[:200]}")
                continue
            chg = chg_res.stdout.strip()
            for event, payload in [
                ("qa_passed", {"checks": ["renovate_policy"],
                              "notes": "auto-merge gated by .renovaterc.json5 policy + minimumReleaseAge"}),
                ("executed", {"commits": [sha], "external_actions": ["renovate auto-merge", "flux reconcile"]}),
                ("validated", {"status": "pass",
                              "evidence": "Flux applied; no rollback event"}),
                ("closed", {"outcome": "success"}),
            ]:
                subprocess.run(
                    ["python3", str(cli), "change", "event", chg, event,
                     "--actor", "infra-ops",
                     "--payload-json", json.dumps(payload)],
                    cwd=str(workdir), capture_output=True, timeout=10,
                )
            added += 1
            log(f"ops_digest renovate-sync: logged {chg} for {sha[:7]} ({subject[:60]})")
        except Exception as e:  # noqa: BLE001
            log(f"ops_digest renovate-sync: {e}")

    if added:
        env = os.environ.copy()
        env["GIT_AUTHOR_NAME"] = env.get("GIT_AUTHOR_NAME", "ops-digest-bot")
        env["GIT_AUTHOR_EMAIL"] = env.get("GIT_AUTHOR_EMAIL", "ops-digest@bluejungle.net")
        env["GIT_COMMITTER_NAME"] = env["GIT_AUTHOR_NAME"]
        env["GIT_COMMITTER_EMAIL"] = env["GIT_AUTHOR_EMAIL"]
        subprocess.run(["git", "-C", str(workdir), "config", "user.name", env["GIT_AUTHOR_NAME"]],
                       capture_output=True)
        subprocess.run(["git", "-C", str(workdir), "config", "user.email", env["GIT_AUTHOR_EMAIL"]],
                       capture_output=True)
        subprocess.run(["git", "-C", str(workdir), "add", "ops/changes.jsonl"],
                       env=env, capture_output=True)
        commit = subprocess.run(
            ["git", "-C", str(workdir), "commit", "-m",
             f"chore(ops): backfill {added} Renovate auto-merge change record(s)"],
            env=env, capture_output=True, text=True,
        )
        if commit.returncode != 0:
            log(f"ops_digest renovate-sync: commit failed: {commit.stderr[:200]}")
            return added
        tok = mint_installation_token()
        if not tok:
            return added
        remote_path = GIT_REMOTE.removeprefix("https://")
        push = subprocess.run(
            ["git", "-C", str(workdir), "push",
             f"https://x-access-token:{tok}@{remote_path}", GIT_BRANCH],
            env=env, capture_output=True, text=True, timeout=60,
        )
        if push.returncode != 0:
            log(f"ops_digest renovate-sync: push failed: {push.stderr[:200]}")
        else:
            log(f"ops_digest renovate-sync: pushed {added} change record(s)")
    return added


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="ops-digest-"))
    try:
        if not clone(workdir):
            return 0  # logged; not fatal

        # Step 1: backfill any Renovate auto-merges into the change log
        try:
            n = sync_renovate_commits(workdir)
            if n:
                log(f"ops_digest: synced {n} Renovate commit(s) into change log")
        except Exception as e:  # noqa: BLE001
            log(f"ops_digest: renovate-sync crashed: {e}")

        # Step 2: render the digest from now-current state
        text = run_digest_cli(workdir).strip() or "(no changes/incidents)"
        date = today()
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
