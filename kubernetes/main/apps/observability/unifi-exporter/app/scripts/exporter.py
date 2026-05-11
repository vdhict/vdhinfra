#!/usr/bin/env python3
"""Minimal UniFi exporter — exposes WAN throughput + gateway uptime only.

Polls the lightweight /stat/health endpoint (one small JSON, no per-port loop).
The UDM precomputes rate-fields (rx_bytes-r / tx_bytes-r) so we expose them as
gauges directly — no Prometheus rate() math needed.

Kindness to the UDM:
  - default 60s interval (previous exporter was 30s on the heavy /stat/device)
  - exponential backoff up to 10m on consecutive failures
  - 5s jitter so restarts don't synchronize
"""
import http.server
import json
import os
import random
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

BASE_URL = os.environ.get("UNIFI_BASE_URL", "https://172.16.2.1/proxy/network").rstrip("/")
SITE = os.environ.get("UNIFI_SITE", "default")
API_KEY = os.environ["UNIFI_API_KEY"]
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9100"))
TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "10"))

_state = {"text": "# exporter starting\nunifi_exporter_up 0\n"}
_lock = threading.Lock()


def render(rx_bps: int, tx_bps: int, uptime_s: int, ok: bool) -> str:
    now = int(time.time())
    return (
        "# HELP unifi_wan_rx_bytes_per_second Current WAN receive (download) rate in bytes per second.\n"
        "# TYPE unifi_wan_rx_bytes_per_second gauge\n"
        f"unifi_wan_rx_bytes_per_second {rx_bps}\n"
        "# HELP unifi_wan_tx_bytes_per_second Current WAN transmit (upload) rate in bytes per second.\n"
        "# TYPE unifi_wan_tx_bytes_per_second gauge\n"
        f"unifi_wan_tx_bytes_per_second {tx_bps}\n"
        "# HELP unifi_gateway_uptime_seconds UDM gateway uptime in seconds since boot.\n"
        "# TYPE unifi_gateway_uptime_seconds gauge\n"
        f"unifi_gateway_uptime_seconds {uptime_s}\n"
        "# HELP unifi_exporter_up Whether the last UDM poll succeeded (1) or failed (0).\n"
        "# TYPE unifi_exporter_up gauge\n"
        f"unifi_exporter_up {1 if ok else 0}\n"
        "# HELP unifi_exporter_last_poll_timestamp_seconds Unix timestamp of the most recent successful poll.\n"
        "# TYPE unifi_exporter_last_poll_timestamp_seconds gauge\n"
        f"unifi_exporter_last_poll_timestamp_seconds {now if ok else 0}\n"
    )


def fetch():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(
        f"{BASE_URL}/api/s/{SITE}/stat/health",
        headers={"X-API-KEY": API_KEY, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=TIMEOUT) as resp:
        body = resp.read()
    payload = json.loads(body)
    data = payload.get("data") or []
    wan = next((s for s in data if s.get("subsystem") == "wan"), {}) or {}
    www = next((s for s in data if s.get("subsystem") == "www"), {}) or {}
    rx = int(wan.get("rx_bytes-r") or www.get("rx_bytes-r") or 0)
    tx = int(wan.get("tx_bytes-r") or www.get("tx_bytes-r") or 0)
    gw_stats = wan.get("gw_system-stats") or {}
    uptime = int(gw_stats.get("uptime") or 0)
    return rx, tx, uptime


def poll_loop():
    backoff = INTERVAL
    last_good = None
    while True:
        try:
            rx, tx, uptime = fetch()
            with _lock:
                _state["text"] = render(rx, tx, uptime, ok=True)
            last_good = (rx, tx, uptime)
            backoff = INTERVAL
        except (urllib.error.URLError, urllib.error.HTTPError,
                json.JSONDecodeError, KeyError, ValueError, OSError) as exc:
            print(f"poll failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            # Keep last-good values visible but flag exporter as down.
            rx, tx, uptime = last_good if last_good else (0, 0, 0)
            with _lock:
                _state["text"] = render(rx, tx, uptime, ok=False)
            backoff = min(backoff * 2, 600)
        time.sleep(backoff + random.uniform(0, 5))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/metrics"):
            self.send_error(404)
            return
        with _lock:
            body = _state["text"].encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args, **kwargs):  # silence access logs
        pass


def main():
    threading.Thread(target=poll_loop, daemon=True).start()
    print(f"unifi-exporter listening on :{LISTEN_PORT} (poll={INTERVAL}s)", flush=True)
    http.server.ThreadingHTTPServer(("", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
