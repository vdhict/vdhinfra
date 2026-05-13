#!/bin/sh
# Clone the repo (shallow) and render the ops portal HTML into the
# nginx-served path. Idempotent — runs every 10 minutes via CronJob.
#
# Inputs (env):
#   GIT_REMOTE                — https://github.com/vdhict/vdhinfra.git
#   GIT_BRANCH                — main
#   GITHUB_APP_*              — used by gh_app_token.py
#
# Output (portal v2 — chg-2026-05-13-018):
#   /data/web/index.html, changes.html, incidents.html, cmdb.html,
#   risks.html, team.html — the multi-page ops portal
#   /data/web/ops-snapshot.json — machine-readable snapshot
#
# Historic note: pre-v2 wrote a single /data/web/ops.html; that file is
# left in place by this script (not deleted) so old bookmarks still work
# until the daily prune cycle cleans it up.
set -eu

WORK=/tmp/ops-render-$$
trap 'rm -rf "$WORK"' EXIT

# Mint an installation token. If this fails, bail loudly — the dashboard
# being out of date is a clear signal something is broken.
echo "[ops_render] minting GitHub App token" >&2
TOK=$(python3 /scripts/gh_app_token.py)
if [ -z "${TOK:-}" ]; then
  echo "[ops_render] FAIL: no token" >&2
  exit 1
fi

echo "[ops_render] cloning $GIT_REMOTE @ $GIT_BRANCH (shallow)" >&2
GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$GIT_BRANCH" \
  "https://x-access-token:${TOK}@${GIT_REMOTE#https://}" "$WORK"

cd "$WORK"

mkdir -p /data/web
chmod +x ops/ops

echo "[ops_render] rendering portal v2 → /data/web (directory mode)" >&2
python3 ops/ops dashboard --html /data/web

# Also write a JSON snapshot (just the state, for any future API consumer).
# This is best-effort; failure here doesn't fail the job.
python3 - <<'PY' || echo "[ops_render] snapshot write failed (non-fatal)" >&2
import json, sys, datetime as dt
sys.path.insert(0, "ops")
# Reuse the CLI's parsing functions via a tiny subprocess to keep this independent
import subprocess, json as _j
out = subprocess.check_output(["python3", "ops/ops", "change", "list"]).decode()
incs = subprocess.check_output(["python3", "ops/ops", "incident", "list"]).decode()
snapshot = {
    "ts": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00","Z"),
    "changes_table": out,
    "incidents_table": incs,
}
with open("/data/web/ops-snapshot.json", "w") as f:
    _j.dump(snapshot, f)
PY

bytes_index=$(wc -c < /data/web/index.html 2>/dev/null || echo 0)
echo "[ops_render] OK — wrote /data/web/index.html (${bytes_index} bytes) + siblings" >&2
