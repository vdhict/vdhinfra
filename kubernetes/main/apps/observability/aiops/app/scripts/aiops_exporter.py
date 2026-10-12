#!/usr/bin/env python3
"""aiops-exporter (chg-2026-10-12-009).

Exposes on :9900/metrics, for the aiops PrometheusRules:

  Token expiry, read from the token-expiry ConfigMap on EVERY scrape
  (names + dates only, never a value):
    aiops_token_expiry_timestamp_seconds{token,kind,owner}
    aiops_tokens_config_valid                       1 = parsed, 0 = broken

  Renovate health, polled from the GitHub API every GITHUB_INTERVAL seconds:
    renovate_last_activity_timestamp_seconds        newest updated_at of any
                                                    issue/PR authored by
                                                    renovate[bot]
    renovate_open_prs                               open PRs by renovate[bot]
    renovate_pr_created_timestamp_seconds{number}   one series per open
                                                    Renovate PR (bounded by the
                                                    open-PR count, < 100)
    aiops_github_up                                 1 = last poll succeeded
    aiops_github_last_success_timestamp_seconds

GitHub auth reuses the cluster-health GitHub App (read-only use here): a 9-min
RS256 JWT signed with openssl from the mounted key, exchanged for a 1-hour
installation token held in memory only. The token is never logged.
Stdlib only, so it runs in the existing cluster-health image.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKENS_FILE = os.environ.get("TOKENS_FILE", "/config/tokens.json")
REPO = os.environ.get("GITHUB_REPO", "vdhict/vdhinfra")
APP_ID = os.environ.get("GITHUB_APP_ID", "")
INSTALL_ID = os.environ.get("GITHUB_APP_INSTALLATION_ID", "")
KEY_PATH = os.environ.get("GITHUB_APP_KEY_PATH", "/secrets/github-app-key.pem")
INTERVAL = int(os.environ.get("GITHUB_INTERVAL", "900"))
PORT = int(os.environ.get("PORT", "9900"))
BOT = "renovate[bot]"

_lock = threading.Lock()
_gh = {"up": 0, "last_success": 0.0, "last_activity": None, "prs": []}


def log(msg: str) -> None:
    print(json.dumps({"ts": datetime.utcnow().isoformat() + "Z", "msg": msg}), flush=True)


def esc(v: str) -> str:
    return str(v).replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


def ts(iso: str) -> float:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


# ---------- GitHub ----------

def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def normalize_pem(raw: str) -> str:
    import re
    m = re.match(r"(-----BEGIN [A-Z0-9 ]+-----)(.*?)(-----END [A-Z0-9 ]+-----)\s*$", raw.strip(), re.S)
    if not m:
        return raw
    h, body, f = m.groups()
    body = re.sub(r"\s+", "", body)
    return h + "\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n" + f + "\n"


_tok = {"value": None, "exp": 0.0}


def install_token() -> str:
    if _tok["value"] and time.time() < _tok["exp"] - 300:
        return _tok["value"]
    now = int(time.time())
    hb = b64u(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    pb = b64u(json.dumps({"iat": now - 30, "exp": now + 540, "iss": APP_ID}, separators=(",", ":")).encode())
    with open(KEY_PATH) as fh:
        pem = normalize_pem(fh.read())
    with tempfile.NamedTemporaryFile("w", suffix=".pem", dir="/tmp", delete=True) as kf:
        os.chmod(kf.name, 0o600)
        kf.write(pem)
        kf.flush()
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", kf.name],
                             input=f"{hb}.{pb}".encode(), capture_output=True, check=True, timeout=10).stdout
    req = urllib.request.Request(
        f"https://api.github.com/app/installations/{INSTALL_ID}/access_tokens", method="POST",
        headers={"Authorization": f"Bearer {hb}.{pb}.{b64u(sig)}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read())
    _tok["value"] = data["token"]
    _tok["exp"] = ts(data["expires_at"])
    return _tok["value"]


def gh_get(path: str, params: dict) -> list:
    url = f"https://api.github.com{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {install_token()}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def poll_github() -> None:
    newest = gh_get(f"/repos/{REPO}/issues", {"state": "all", "creator": BOT, "sort": "updated",
                                             "direction": "desc", "per_page": 1})
    prs, page = [], 1
    while page <= 5:
        batch = gh_get(f"/repos/{REPO}/pulls", {"state": "open", "per_page": 100, "page": page})
        prs += [p for p in batch if (p.get("user") or {}).get("login") == BOT]
        if len(batch) < 100:
            break
        page += 1
    with _lock:
        _gh["last_activity"] = ts(newest[0]["updated_at"]) if newest else None
        _gh["prs"] = [(p["number"], ts(p["created_at"])) for p in prs]
        _gh["up"] = 1
        _gh["last_success"] = time.time()
    log(f"github poll ok: renovate open_prs={len(prs)}")


def github_loop() -> None:
    while True:
        try:
            poll_github()
        except Exception as e:  # noqa: BLE001 - keep serving; aiops_github_up says why
            with _lock:
                _gh["up"] = 0
            log(f"github poll failed: {type(e).__name__}: {str(e)[:200]}")
        time.sleep(INTERVAL)


# ---------- metrics ----------

def token_lines() -> list[str]:
    out = ["# HELP aiops_token_expiry_timestamp_seconds Expiry (or forced revocation) time of a named credential, from the token-expiry ConfigMap.",
           "# TYPE aiops_token_expiry_timestamp_seconds gauge"]
    try:
        with open(TOKENS_FILE) as fh:
            doc = json.load(fh)
        for t in doc["tokens"]:
            out.append('aiops_token_expiry_timestamp_seconds{token="%s",kind="%s",owner="%s"} %d' % (
                esc(t["name"]), esc(t.get("kind", "")), esc(t.get("owner", "")), ts(t["expires"])))
        valid = 1
    except Exception as e:  # noqa: BLE001
        log(f"token config invalid: {type(e).__name__}: {str(e)[:200]}")
        valid = 0
    out += ["# TYPE aiops_tokens_config_valid gauge", f"aiops_tokens_config_valid {valid}"]
    return out


def gh_lines() -> list[str]:
    with _lock:
        g = dict(_gh)
    out = ["# TYPE aiops_github_up gauge", f"aiops_github_up {g['up']}",
           "# TYPE aiops_github_last_success_timestamp_seconds gauge",
           f"aiops_github_last_success_timestamp_seconds {g['last_success']:.0f}"]
    if g["last_success"]:
        if g["last_activity"] is not None:
            out += ["# HELP renovate_last_activity_timestamp_seconds Newest updated_at of any issue/PR by renovate[bot].",
                    "# TYPE renovate_last_activity_timestamp_seconds gauge",
                    f"renovate_last_activity_timestamp_seconds {g['last_activity']:.0f}"]
        out += ["# TYPE renovate_open_prs gauge", f"renovate_open_prs {len(g['prs'])}",
                "# TYPE renovate_pr_created_timestamp_seconds gauge"]
        out += [f'renovate_pr_created_timestamp_seconds{{number="{n}"}} {c:.0f}' for n, c in g["prs"]]
    return out


class H(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path not in ("/metrics", "/healthz"):
            self.send_response(404)
            self.end_headers()
            return
        body = ("ok\n" if self.path == "/healthz" else "\n".join(token_lines() + gh_lines()) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # silence per-request logs
        pass


if __name__ == "__main__":
    if not (APP_ID and INSTALL_ID and os.path.exists(KEY_PATH)):
        log("github app config missing; Renovate metrics disabled, aiops_github_up stays 0")
    else:
        threading.Thread(target=github_loop, daemon=True).start()
    log(f"listening on :{PORT}")
    ThreadingHTTPServer(("", PORT), H).serve_forever()
    sys.exit(1)
