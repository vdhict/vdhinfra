#!/usr/bin/env python3
"""Push the day's markdown report to docs/health-reports/ in the repo.

Authenticates as a GitHub App: signs a short-lived JWT (RS256, 9 min)
with the App's private key, exchanges it for an installation access
token, then uses that token in a one-shot HTTPS push. No static SSH
deploy key required, no token at rest.

Required env:
  GITHUB_APP_ID                 (e.g. 3302753)
  GITHUB_APP_INSTALLATION_ID    (e.g. 122063656)
  GIT_REMOTE                    https://github.com/<owner>/<repo>.git
  GIT_BRANCH                    main
  GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL

Required mounted file:
  /secrets/github-app-key.pem   (RSA private key, mode 0400)

Failure is logged but non-fatal — the report still lives on PVC and the
in-cluster web UI."""
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, "/scripts")
from lib import REPORTS_DIR, log, today  # noqa: E402

GIT_REMOTE = os.environ.get("GIT_REMOTE", "https://github.com/vdhict/vdhinfra.git")
GIT_BRANCH = os.environ.get("GIT_BRANCH", "main")
GIT_NAME = os.environ.get("GIT_AUTHOR_NAME", "cluster-health-bot")
GIT_EMAIL = os.environ.get("GIT_AUTHOR_EMAIL", "cluster-health@bluejungle.net")
APP_ID = os.environ.get("GITHUB_APP_ID")
INSTALL_ID = os.environ.get("GITHUB_APP_INSTALLATION_ID")
KEY_PATH = Path(os.environ.get("GITHUB_APP_KEY_PATH", "/secrets/github-app-key.pem"))


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def mint_installation_token() -> str | None:
    """Sign a JWT with the App private key (via openssl) and exchange for an
    installation access token. Returns None on any failure."""
    if not (APP_ID and INSTALL_ID and KEY_PATH.exists()):
        log(f"git_push: missing app config (APP_ID={bool(APP_ID)} "
            f"INSTALL_ID={bool(INSTALL_ID)} key={KEY_PATH.exists()})")
        return None

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {"iat": now - 30, "exp": now + 540, "iss": APP_ID}
    hb = b64u(json.dumps(header, separators=(",", ":")).encode())
    pb = b64u(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{hb}.{pb}".encode()

    try:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(KEY_PATH)],
            input=signing_input, capture_output=True, check=True, timeout=10,
        )
    except subprocess.CalledProcessError as e:
        log(f"git_push: openssl sign failed rc={e.returncode}: {e.stderr.decode(errors='replace').strip()[:300]}")
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log(f"git_push: openssl sign failed: {e}")
        return None

    jwt = f"{hb}.{pb}.{b64u(proc.stdout)}"
    req = urllib.request.Request(
        f"https://api.github.com/app/installations/{INSTALL_ID}/access_tokens",
        method="POST",
        headers={"Authorization": f"Bearer {jwt}",
                 "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read())
            log(f"git_push: minted installation token, expires {data.get('expires_at')}")
            return data["token"]
    except Exception as e:  # noqa: BLE001
        log(f"git_push: token exchange failed: {e}")
        if hasattr(e, "read"):
            log(f"git_push: response: {e.read().decode()[:300]}")
        return None


def run_git(args, cwd=None, env=None):
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)


def main() -> int:
    date = today()
    md = REPORTS_DIR / f"{date}.md"
    if not md.exists():
        log(f"git_push: no report {md}")
        return 0

    token = mint_installation_token()
    if not token:
        log("git_push: no token, skipping push")
        return 0

    # Build authenticated URL — the token is short-lived and only lives in
    # process memory + git's index for the duration of this push.
    if not GIT_REMOTE.startswith("https://"):
        log(f"git_push: GIT_REMOTE must be https, got {GIT_REMOTE}")
        return 1
    auth_remote = GIT_REMOTE.replace("https://", f"https://x-access-token:{token}@", 1)

    work = Path(tempfile.mkdtemp(prefix="repo-"))
    try:
        p = run_git(["git", "clone", "--depth", "1", "--branch", GIT_BRANCH, auth_remote, str(work)])
        if p.returncode != 0:
            log(f"git_push: clone failed: {p.stderr.strip()[:300]}")
            return 1

        run_git(["git", "config", "user.name", GIT_NAME], cwd=str(work))
        run_git(["git", "config", "user.email", GIT_EMAIL], cwd=str(work))

        target_dir = work / "docs" / "health-reports"
        target_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy(md, target_dir / f"{date}.md")

        # Refresh rolling 30-entry index
        existing = sorted(target_dir.glob("????-??-??.md"), reverse=True)[:30]
        idx_lines = ["# Daily Health Reports", "",
                     "Auto-generated by the `cluster-health` CronJob in the `observability` namespace.",
                     "",
                     "| Date | Report |",
                     "|---|---|"]
        for f in existing:
            d = f.stem
            idx_lines.append(f"| {d} | [{d}.md]({d}.md) |")
        idx_lines.append("")
        (target_dir / "README.md").write_text("\n".join(idx_lines))

        st = run_git(["git", "status", "--porcelain"], cwd=str(work))
        if not st.stdout.strip():
            log("git_push: nothing to commit")
            return 0
        run_git(["git", "add", "docs/health-reports/"], cwd=str(work))
        p = run_git(["git", "commit", "-m", f"chore(health): daily report {date}"], cwd=str(work))
        if p.returncode != 0:
            log(f"git_push: commit failed: {p.stderr.strip()[:300]}")
            return 1
        p = run_git(["git", "push", "origin", GIT_BRANCH], cwd=str(work))
        if p.returncode != 0:
            log(f"git_push: push failed: {p.stderr.strip()[:300]}")
            return 1
        log(f"git_push: pushed {date}.md")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
