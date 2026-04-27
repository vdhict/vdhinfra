"""Shared helpers for cluster-health scripts."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
RAW_DIR = DATA_DIR / "raw"
TRIAGE_DIR = DATA_DIR / "triage"
TRENDS_DIR = DATA_DIR / "trends"
REPORTS_DIR = DATA_DIR / "reports"
WEB_DIR = DATA_DIR / "web"
STATE_DIR = DATA_DIR / "state"

for d in (RAW_DIR, TRIAGE_DIR, TRENDS_DIR, REPORTS_DIR, WEB_DIR, STATE_DIR):
    d.mkdir(parents=True, exist_ok=True)


def today() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(msg: str) -> None:
    print(f"[{now_iso()}] {msg}", file=sys.stderr, flush=True)


def run(cmd: list[str], check: bool = False, timeout: int = 60) -> tuple[int, str, str]:
    """Run a command, return (rc, stdout, stderr). Never raises unless check=True."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=check)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        return 124, "", f"timeout after {timeout}s: {e}"
    except subprocess.CalledProcessError as e:
        return e.returncode, e.stdout or "", e.stderr or ""
    except FileNotFoundError as e:
        return 127, "", str(e)


def kubectl_json(args: list[str], timeout: int = 30) -> Any:
    """Run kubectl ... -o json and return parsed JSON or {}."""
    rc, out, err = run(["kubectl", *args, "-o", "json"], timeout=timeout)
    if rc != 0:
        log(f"kubectl {' '.join(args)} failed: {err.strip()[:300]}")
        return {}
    try:
        return json.loads(out)
    except json.JSONDecodeError as e:
        log(f"kubectl {' '.join(args)} bad json: {e}")
        return {}


def http_get_json(url: str, headers: dict[str, str] | None = None, timeout: int = 15) -> Any:
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001
        log(f"GET {url} failed: {e}")
        return None


def http_post_json(url: str, body: dict, headers: dict[str, str] | None = None, timeout: int = 15) -> tuple[int, str]:
    data = json.dumps(body).encode()
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode() if e.fp else str(e)
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def prom_query(query: str, base: str | None = None) -> list[dict]:
    base = base or os.environ.get("PROM_URL", "http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090")
    url = f"{base}/api/v1/query?query={urllib.parse.quote(query)}"
    j = http_get_json(url)
    if not j or j.get("status") != "success":
        return []
    return j.get("data", {}).get("result", [])


def prom_query_range(query: str, start: int, end: int, step: int, base: str | None = None) -> list[dict]:
    base = base or os.environ.get("PROM_URL", "http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090")
    params = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    j = http_get_json(f"{base}/api/v1/query_range?{params}")
    if not j or j.get("status") != "success":
        return []
    return j.get("data", {}).get("result", [])


def ha_get(path: str) -> Any:
    base = os.environ.get("HA_URL", "")
    token = os.environ.get("HA_TOKEN", "")
    if not base or not token:
        return None
    return http_get_json(f"{base}{path}", headers={"Authorization": f"Bearer {token}"})


def unifi_get(path: str, timeout: int = 10) -> Any:
    """GET against the UniFi controller. `path` is appended verbatim to UNIFI_BASE_URL.

    Examples (legacy v4 API, still exposed by the integration controller):
        unifi_get("/api/s/default/stat/device")
        unifi_get("/api/s/default/stat/device/<switch_mac>")

    UniFi's TLS uses a self-signed cert, so we disable verification.
    """
    base = os.environ.get("UNIFI_BASE_URL", "").rstrip("/")
    key = os.environ.get("UNIFI_API_KEY", "")
    if not base or not key:
        return None
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(f"{base}{path}", headers={"X-API-KEY": key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001
        log(f"unifi GET {path} failed: {e}")
        return None


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True, default=str))


def read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:  # noqa: BLE001
        return default


def status_for(passed: int, warned: int, failed: int) -> str:
    if failed > 0:
        return "red"
    if warned > 0:
        return "yellow"
    return "green"
