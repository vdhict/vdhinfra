#!/usr/bin/env python3
"""Ceph OSD SSD wear exporter.

Polls `ceph device ls` and `ceph device get-health-metrics` by exec'ing into
the rook-ceph-tools pod, then exposes the extracted SMART attributes as
Prometheus gauge metrics on /metrics.

Metrics exposed:
  ceph_device_wear_level            - wear fraction 0.0-1.0 (from `ceph device info`)
  ceph_device_smart_attr_raw        - raw value of selected SMART attributes
  ceph_device_smart_reallocated_sector_ct_raw  - attr 5 raw (convenience)
  ceph_device_smart_power_on_hours  - attr 9 raw
  ceph_device_exporter_up           - 1 if last poll succeeded
  ceph_device_exporter_last_poll_timestamp_seconds

Labels on device metrics:
  device_id  - PNY_1TB_SATA_SSD_...
  osd        - osd.0 / osd.1 / osd.2
  host       - vdhclu01node0X
  device     - sda

Runs a background poll thread; HTTP server just reads the cached text.
"""
import http.server
import json
import os
import subprocess
import sys
import threading
import time

NAMESPACE = os.environ.get("CEPH_NAMESPACE", "rook-ceph")
TOOLS_LABEL = os.environ.get("CEPH_TOOLS_LABEL", "app=rook-ceph-tools")
INTERVAL = int(os.environ.get("POLL_INTERVAL", "120"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))
KUBECTL = os.environ.get("KUBECTL_BIN", "kubectl")

# SMART attribute IDs to export (id -> short_name)
SMART_ATTRS = {
    5: "reallocated_sector_ct",
    9: "power_on_hours",
    231: "ssd_life_left",       # PNY vendor-specific; normalized value = % life remaining
    233: "media_wearout_indicator",
    241: "total_lbas_written",
}

_state = {"text": "# ceph-smart-exporter starting\nceph_device_exporter_up 0\n"}
_lock = threading.Lock()


def run_ceph(tools_pod: str, *args) -> str:
    cmd = [KUBECTL, "-n", NAMESPACE, "exec", tools_pod, "--", "ceph"] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise RuntimeError(f"ceph {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def get_tools_pod() -> str:
    result = subprocess.run(
        [KUBECTL, "-n", NAMESPACE, "get", "pod", "-l", TOOLS_LABEL,
         "-o", "jsonpath={.items[0].metadata.name}"],
        capture_output=True, text=True, timeout=10,
    )
    pod = result.stdout.strip()
    if not pod:
        raise RuntimeError("rook-ceph-tools pod not found")
    return pod


def parse_device_ls(raw: str) -> list[dict]:
    """Parse `ceph device ls` text output into a list of device dicts."""
    devices = []
    for line in raw.strip().splitlines():
        line = line.strip()
        if not line or line.startswith("DEVICE"):
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        dev_id = parts[0]
        host_dev = parts[1]          # e.g. vdhclu01node02:sda
        daemon = parts[2]            # e.g. osd.0
        wear = parts[3] if len(parts) > 3 else ""
        host, _, device = host_dev.partition(":")
        wear_frac = None
        if wear.endswith("%"):
            try:
                wear_frac = float(wear[:-1]) / 100.0
            except ValueError:
                pass
        devices.append({
            "device_id": dev_id,
            "host": host,
            "device": device,
            "osd": daemon,
            "wear_frac": wear_frac,
        })
    return devices


def get_smart_attrs(tools_pod: str, device_id: str) -> dict[int, tuple[int, int]]:
    """Return {attr_id: (normalized_value, raw_value)} for the specified device."""
    try:
        raw = run_ceph(tools_pod, "device", "get-health-metrics", device_id)
        data = json.loads(raw)
    except Exception as exc:
        print(f"  get-health-metrics {device_id}: {exc}", file=sys.stderr, flush=True)
        return {}

    latest_ts = sorted(data.keys())[-1] if data else None
    if not latest_ts:
        return {}

    metrics = data[latest_ts]
    ata = metrics.get("ata_smart_attributes", {})
    result: dict[int, tuple[int, int]] = {}
    for attr in ata.get("table", []):
        aid = attr.get("id")
        if aid in SMART_ATTRS:
            norm = attr.get("value", 0)
            raw_val = attr.get("raw", {}).get("value", 0)
            result[aid] = (norm, raw_val)
    return result


def render(devices: list[dict], smart_data: dict[str, dict], ok: bool) -> str:
    now = int(time.time())
    lines: list[str] = []

    lines.append("# HELP ceph_device_wear_level OSD device wear fraction (0=new, 1=fully worn)")
    lines.append("# TYPE ceph_device_wear_level gauge")
    for d in devices:
        if d["wear_frac"] is not None:
            lbl = f'device_id="{d["device_id"]}",osd="{d["osd"]}",host="{d["host"]}",device="{d["device"]}"'
            lines.append(f'ceph_device_wear_level{{{lbl}}} {d["wear_frac"]}')

    for attr_id, attr_name in SMART_ATTRS.items():
        lines.append(f"# HELP ceph_device_smart_{attr_name}_raw SMART attr {attr_id} raw value")
        lines.append(f"# TYPE ceph_device_smart_{attr_name}_raw gauge")
        for d in devices:
            dev_id = d["device_id"]
            attrs = smart_data.get(dev_id, {})
            if attr_id in attrs:
                _, raw_val = attrs[attr_id]
                lbl = f'device_id="{dev_id}",osd="{d["osd"]}",host="{d["host"]}",device="{d["device"]}"'
                lines.append(f'ceph_device_smart_{attr_name}_raw{{{lbl}}} {raw_val}')

    lines.append("# HELP ceph_device_exporter_up 1 if the last Ceph device poll succeeded")
    lines.append("# TYPE ceph_device_exporter_up gauge")
    lines.append(f"ceph_device_exporter_up {1 if ok else 0}")
    lines.append("# HELP ceph_device_exporter_last_poll_timestamp_seconds Unix timestamp of last successful poll")
    lines.append("# TYPE ceph_device_exporter_last_poll_timestamp_seconds gauge")
    lines.append(f"ceph_device_exporter_last_poll_timestamp_seconds {now if ok else 0}")

    return "\n".join(lines) + "\n"


def poll_once() -> str:
    tools_pod = get_tools_pod()
    raw_ls = run_ceph(tools_pod, "device", "ls")
    devices = parse_device_ls(raw_ls)
    if not devices:
        raise RuntimeError("ceph device ls returned no devices")

    smart_data: dict[str, dict] = {}
    for d in devices:
        smart_data[d["device_id"]] = get_smart_attrs(tools_pod, d["device_id"])

    return render(devices, smart_data, ok=True)


def poll_loop():
    backoff = INTERVAL
    while True:
        try:
            text = poll_once()
            with _lock:
                _state["text"] = text
            backoff = INTERVAL
            print("poll ok", file=sys.stderr, flush=True)
        except Exception as exc:
            print(f"poll failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            with _lock:
                # Keep last good metrics but flip exporter_up to 0
                old = _state["text"]
                lines = [l for l in old.splitlines()
                         if not l.startswith("ceph_device_exporter_up ")
                         and not l.startswith("ceph_device_exporter_last_poll")]
                lines.append("ceph_device_exporter_up 0")
                lines.append("ceph_device_exporter_last_poll_timestamp_seconds 0")
                _state["text"] = "\n".join(lines) + "\n"
            backoff = min(backoff * 2, 600)
        time.sleep(backoff)


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

    def log_message(self, *args, **kwargs):
        pass


def main():
    threading.Thread(target=poll_loop, daemon=True).start()
    print(f"ceph-smart-exporter listening on :{LISTEN_PORT} (poll={INTERVAL}s)", flush=True)
    http.server.ThreadingHTTPServer(("", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
