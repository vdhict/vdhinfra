#!/usr/bin/env python3
"""Minimal UniFi exporter — exposes WAN throughput, gateway uptime,
and per-AP health metrics (uptime, client counts, firmware, uplink speed).

Polls two endpoints every INTERVAL seconds:
  /stat/health  — WAN throughput + gateway uptime (lightweight, unchanged)
  /stat/device  — per-AP metrics (filter type==uap only)

Kindness to the UDM:
  - default 60s interval (same as before)
  - exponential backoff up to 10m on consecutive failures
  - AP failures are non-fatal: WAN metrics still serve if /stat/device errors
  - 5s jitter so restarts don't synchronize
  - NO per-client polling, NO /stat/event, NO /stat/anomalies
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

# Map UniFi radio band codes to human-readable labels.
RADIO_MAP = {"ng": "2g", "na": "5g", "6e": "6g"}

_state = {
    "wan_text": "# exporter starting\nunifi_exporter_up 0\n",
    "ap_text": "",
}
_lock = threading.Lock()


def _ssl_ctx() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def render_wan(rx_bps: int, tx_bps: int, uptime_s: int, ok: bool) -> str:
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


def render_ap_metrics(devices: list) -> str:
    """Render per-AP metric lines from /stat/device data (uap type only)."""
    if not devices:
        return ""

    lines = []

    # unifi_ap_uptime_seconds
    lines.append("# HELP unifi_ap_uptime_seconds AP uptime in seconds since last boot.")
    lines.append("# TYPE unifi_ap_uptime_seconds gauge")
    for d in devices:
        hostname = _esc(d.get("name") or d.get("hostname") or d.get("mac", "unknown"))
        mac = _esc(d.get("mac", ""))
        model = _esc(d.get("model", ""))
        uptime = int(d.get("uptime") or 0)
        lines.append(
            f'unifi_ap_uptime_seconds{{hostname="{hostname}",mac="{mac}",model="{model}"}} {uptime}'
        )

    # unifi_ap_clients (per-radio client count)
    lines.append("# HELP unifi_ap_clients Number of associated clients per AP radio.")
    lines.append("# TYPE unifi_ap_clients gauge")
    for d in devices:
        hostname = _esc(d.get("name") or d.get("hostname") or d.get("mac", "unknown"))
        radio_stats = d.get("radio_table_stats") or []
        for rs in radio_stats:
            radio_code = rs.get("radio", "")
            radio_label = RADIO_MAP.get(radio_code, radio_code)
            num_sta = int(rs.get("num_sta") or 0)
            lines.append(
                f'unifi_ap_clients{{hostname="{hostname}",radio="{radio_label}"}} {num_sta}'
            )

    # unifi_ap_firmware_info (info pattern — always 1)
    lines.append(
        "# HELP unifi_ap_firmware_info AP firmware version info (always 1, use labels for version)."
    )
    lines.append("# TYPE unifi_ap_firmware_info gauge")
    for d in devices:
        hostname = _esc(d.get("name") or d.get("hostname") or d.get("mac", "unknown"))
        mac = _esc(d.get("mac", ""))
        version = _esc(d.get("version") or "unknown")
        lines.append(
            f'unifi_ap_firmware_info{{hostname="{hostname}",mac="{mac}",version="{version}"}} 1'
        )

    # unifi_ap_uplink_speed_mbps
    lines.append(
        "# HELP unifi_ap_uplink_speed_mbps AP uplink port negotiated speed in Mbps (0 if unknown)."
    )
    lines.append("# TYPE unifi_ap_uplink_speed_mbps gauge")
    for d in devices:
        hostname = _esc(d.get("name") or d.get("hostname") or d.get("mac", "unknown"))
        uplink = d.get("uplink") or {}
        speed = int(uplink.get("speed") or 0)
        lines.append(f'unifi_ap_uplink_speed_mbps{{hostname="{hostname}"}} {speed}')

    # unifi_ap_temperature_celsius (optional — only if field present)
    temps = [
        (d.get("name") or d.get("hostname") or d.get("mac", "unknown"), d["temperature"])
        for d in devices
        if d.get("temperature") is not None
    ]
    if temps:
        lines.append(
            "# HELP unifi_ap_temperature_celsius AP board temperature in degrees Celsius."
        )
        lines.append("# TYPE unifi_ap_temperature_celsius gauge")
        for hostname_raw, temp in temps:
            hostname = _esc(hostname_raw)
            lines.append(f'unifi_ap_temperature_celsius{{hostname="{hostname}"}} {float(temp)}')

    lines.append("")
    return "\n".join(lines)


def _esc(value: str) -> str:
    """Escape label values for Prometheus text format."""
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def fetch_wan():
    """Poll /stat/health for WAN throughput and gateway uptime."""
    req = urllib.request.Request(
        f"{BASE_URL}/api/s/{SITE}/stat/health",
        headers={"X-API-KEY": API_KEY, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=TIMEOUT) as resp:
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


def fetch_devices() -> list:
    """Poll /stat/device and return UAP (access point) entries only."""
    req = urllib.request.Request(
        f"{BASE_URL}/api/s/{SITE}/stat/device",
        headers={"X-API-KEY": API_KEY, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=TIMEOUT) as resp:
        body = resp.read()
    payload = json.loads(body)
    data = payload.get("data") or []
    return [d for d in data if d.get("type") == "uap"]


def poll_loop():
    backoff = INTERVAL
    last_good_wan = None
    while True:
        # ── WAN / health poll ─────────────────────────────────────────────────
        wan_ok = False
        try:
            rx, tx, uptime = fetch_wan()
            wan_ok = True
            last_good_wan = (rx, tx, uptime)
            backoff = INTERVAL
        except (urllib.error.URLError, urllib.error.HTTPError,
                json.JSONDecodeError, KeyError, ValueError, OSError) as exc:
            print(f"wan poll failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            rx, tx, uptime = last_good_wan if last_good_wan else (0, 0, 0)
            backoff = min(backoff * 2, 600)

        # ── AP / device poll (non-fatal — WAN still serves on AP failure) ─────
        ap_text = ""
        try:
            devices = fetch_devices()
            ap_text = render_ap_metrics(devices)
            print(
                f"ap poll ok: {len(devices)} UAPs",
                file=sys.stderr,
                flush=True,
            )
        except (urllib.error.URLError, urllib.error.HTTPError,
                json.JSONDecodeError, KeyError, ValueError, OSError) as exc:
            print(f"ap poll failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            # Keep last ap_text if we had one, else leave empty.
            with _lock:
                ap_text = _state.get("ap_text", "")

        with _lock:
            _state["wan_text"] = render_wan(rx, tx, uptime, ok=wan_ok)
            _state["ap_text"] = ap_text

        time.sleep(backoff + random.uniform(0, 5))


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/metrics"):
            self.send_error(404)
            return
        with _lock:
            body = (_state["wan_text"] + _state["ap_text"]).encode()
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
