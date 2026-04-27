#!/usr/bin/env python3
"""Tightly-scoped UniFi Prometheus exporter.

Polls the UniFi controller's legacy /api endpoint (still served behind the
integration API key) and exposes per-port metrics for a curated allowlist
of critical wired devices. Stdlib-only, runs in the cluster-health image.

Why a custom exporter instead of unpoller: unpoller uses local-admin
username/password auth that breaks on firmware updates; this exporter
uses the integration API key (X-API-KEY) which is the modern auth path
and aligns with the daily collect_network.py collector.
"""
from __future__ import annotations

import json
import logging
import os
import ssl
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("unifi-exporter")

UNIFI_BASE_URL = os.environ.get("UNIFI_BASE_URL", "https://172.16.2.1/proxy/network").rstrip("/")
UNIFI_API_KEY = os.environ.get("UNIFI_API_KEY", "")
UNIFI_SITE = os.environ.get("UNIFI_SITE", "default")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "30"))
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9100"))

# Curated allowlist — keep tight. Anything here gets metrics + alerts.
WATCH_MACS = {
    "14:2b:2f:db:ab:17": "slzb-06",
    "00:11:32:91:af:61": "synology-nas",
    "e4:5f:01:4a:2d:a9": "pikvm",
    "78:55:36:03:d3:ab": "vdhclu01master01",
    "78:55:36:04:90:19": "vdhclu01master02",
    "78:55:36:04:97:ce": "vdhclu01master03",
    "88:ae:dd:62:1b:3c": "vdhclu01node01",
    "88:ae:dd:62:29:bf": "vdhclu01node02",
    "88:ae:dd:62:17:a6": "vdhclu01node03",
}

# Cached metrics text + scrape stats. Updated by the polling thread,
# read by the HTTP handler. A single string is cheap to swap atomically.
_metrics_lock = threading.Lock()
_metrics_text = "# unifi-exporter starting up\n"
_last_poll_ok = 0  # epoch seconds; 0 == never
_last_poll_err = ""

_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE


def unifi_get(path: str) -> dict | None:
    if not UNIFI_API_KEY:
        return None
    req = urllib.request.Request(
        f"{UNIFI_BASE_URL}{path}",
        headers={"X-API-KEY": UNIFI_API_KEY, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15, context=_ssl_ctx) as r:
            return json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001
        log.warning("UniFi GET %s failed: %s", path, e)
        return None


def labelize(d: dict[str, str]) -> str:
    """Render a label dict to a Prometheus label string. Keys are emitted
    in sorted order so the output is stable across polls (eases diffing)."""
    parts = []
    for k in sorted(d.keys()):
        v = str(d[k]).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
        parts.append(f'{k}="{v}"')
    return "{" + ",".join(parts) + "}"


def collect_metrics() -> str:
    j = unifi_get(f"/api/s/{UNIFI_SITE}/stat/device")
    lines: list[str] = []
    now = int(time.time())

    # Always emit health metrics so Prometheus knows the exporter is alive.
    lines.append("# HELP unifi_exporter_up 1 if the last poll succeeded.")
    lines.append("# TYPE unifi_exporter_up gauge")
    lines.append(f"unifi_exporter_up {1 if j else 0}")
    lines.append("# HELP unifi_exporter_last_poll_timestamp_seconds Unix timestamp of last successful poll.")
    lines.append("# TYPE unifi_exporter_last_poll_timestamp_seconds gauge")
    lines.append(f"unifi_exporter_last_poll_timestamp_seconds {_last_poll_ok}")

    if not j:
        return "\n".join(lines) + "\n"

    devices = j.get("data", []) or []
    switches = [d for d in devices if d.get("type") in ("usw", "udm")]

    # Header blocks (HELP/TYPE) — emit once.
    headers = [
        ("unifi_port_up", "gauge", "1 if the switch port is up at L2."),
        ("unifi_port_speed_mbps", "gauge", "Negotiated link speed in Mbps."),
        ("unifi_port_link_down_count", "counter", "Cumulative link-down events on this port."),
        ("unifi_port_rx_errors_total", "counter", "Cumulative RX errors on this port."),
        ("unifi_port_tx_errors_total", "counter", "Cumulative TX errors on this port."),
        ("unifi_port_poe_power_watts", "gauge", "Current PoE draw in watts."),
        ("unifi_port_poe_good", "gauge", "1 if the PoE module reports the powered device as healthy."),
        ("unifi_client_last_seen_seconds_ago", "gauge", "Seconds since the controller last saw L2 frames from this client."),
    ]
    for name, typ, helptext in headers:
        lines.append(f"# HELP {name} {helptext}")
        lines.append(f"# TYPE {name} {typ}")

    for sw in switches:
        sw_name = sw.get("name") or sw.get("model") or "?"
        sw_mac = sw.get("mac")
        for p in sw.get("port_table", []) or []:
            lc = p.get("last_connection") or {}
            client_mac = (lc.get("mac") or "").lower()
            if client_mac not in WATCH_MACS:
                continue
            # UniFi keeps last_connection history per port even after the
            # device moves elsewhere. Skip stale entries — otherwise the
            # 'last_seen_seconds_ago' alert fires forever on old ports.
            if not lc.get("connected"):
                continue
            labels = {
                "sw_name": sw_name,
                "sw_mac": sw_mac or "",
                "port_idx": str(p.get("port_idx", "")),
                "port_name": p.get("name", ""),
                "client_mac": client_mac,
                "client_ip": lc.get("ip") or "",
                "friendly": WATCH_MACS[client_mac],
            }
            lbl = labelize(labels)
            up = 1 if p.get("up") else 0
            speed = p.get("speed", 0) or 0
            ld_count = p.get("link_down_count", 0) or 0
            rx_err = p.get("rx_errors", 0) or 0
            tx_err = p.get("tx_errors", 0) or 0
            try:
                poe_power = float(p.get("poe_power") or 0.0)
            except (TypeError, ValueError):
                poe_power = 0.0
            poe_good = 1 if p.get("poe_good") else 0
            last_seen = lc.get("last_seen") or 0
            age = max(0, now - int(last_seen)) if last_seen else 0

            lines.append(f"unifi_port_up{lbl} {up}")
            lines.append(f"unifi_port_speed_mbps{lbl} {speed}")
            lines.append(f"unifi_port_link_down_count{lbl} {ld_count}")
            lines.append(f"unifi_port_rx_errors_total{lbl} {rx_err}")
            lines.append(f"unifi_port_tx_errors_total{lbl} {tx_err}")
            lines.append(f"unifi_port_poe_power_watts{lbl} {poe_power}")
            lines.append(f"unifi_port_poe_good{lbl} {poe_good}")
            lines.append(f"unifi_client_last_seen_seconds_ago{lbl} {age}")

    return "\n".join(lines) + "\n"


def poll_loop() -> None:
    global _metrics_text, _last_poll_ok, _last_poll_err
    while True:
        try:
            text = collect_metrics()
            with _metrics_lock:
                _metrics_text = text
                _last_poll_ok = int(time.time())
                _last_poll_err = ""
        except Exception as e:  # noqa: BLE001
            log.exception("poll failed")
            with _metrics_lock:
                _last_poll_err = str(e)
        time.sleep(POLL_INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/metrics", "/"):
            with _metrics_lock:
                body = _metrics_text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/healthz":
            ok = (int(time.time()) - _last_poll_ok) < (POLL_INTERVAL * 4) if _last_poll_ok else False
            self.send_response(200 if ok else 503)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok" if ok else b"stale")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt: str, *args) -> None:  # noqa: ARG002
        # Quiet stdout — let Python logging carry meaningful events.
        return


def main() -> int:
    if not UNIFI_API_KEY:
        log.error("UNIFI_API_KEY not set")
        return 1
    log.info("starting; base=%s site=%s poll=%ss listen=%s:%d watching=%d devices",
             UNIFI_BASE_URL, UNIFI_SITE, POLL_INTERVAL, LISTEN_ADDR, LISTEN_PORT, len(WATCH_MACS))
    threading.Thread(target=poll_loop, daemon=True).start()
    HTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
