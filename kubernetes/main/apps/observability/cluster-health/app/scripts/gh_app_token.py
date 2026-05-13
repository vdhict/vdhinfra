#!/usr/bin/env python3
"""Print a GitHub App installation token to stdout.

Reuses the token-minting logic from git_push.py. Used by other CronJobs
(ops dashboard render, ops digest) that need to clone the repo at runtime
without static deploy keys.

Required env (same as git_push.py):
  GITHUB_APP_ID
  GITHUB_APP_INSTALLATION_ID
  GITHUB_APP_KEY_PATH   (default /secrets/github-app-key.pem)

Exit non-zero with stderr on any failure so the caller can detect.
"""
from __future__ import annotations

import sys

sys.path.insert(0, "/scripts")
from git_push import mint_installation_token  # noqa: E402


def main() -> int:
    tok = mint_installation_token()
    if not tok:
        print("gh_app_token: mint failed", file=sys.stderr)
        return 1
    print(tok)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
