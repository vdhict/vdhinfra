#!/usr/bin/env python3
"""Export Home Assistant config-entry states as Prometheus metrics.

Source: GET /api/config/config_entries/entry (read-only, same bearer token the
HA ServiceMonitor already uses). Only domain, entry_id and state are exported:
no entry titles, so no personal names reach Prometheus. Disabled entries
(disabled_by set) are skipped: a switched-off entry is not a fault.
"""
import json, os, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

HA = os.environ.get("HA_URL", "http://home-assistant.home-automation.svc.cluster.local:8123")
TOKEN = os.environ["HA_TOKEN"]
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
PORT = int(os.environ.get("LISTEN_PORT", "9102"))
STATES = ["loaded", "setup_error", "setup_retry", "migration_error", "failed_unload",
          "not_loaded", "setup_in_progress"]
lock = threading.Lock()
body = "# no data yet\n"


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def poll():
    req = urllib.request.Request(HA + "/api/config/config_entries/entry",
                                 headers={"Authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(req, timeout=20) as r:
        entries = json.load(r)
    out = ["# HELP ha_config_entry_state 1 for the current state of each enabled HA config entry",
           "# TYPE ha_config_entry_state gauge"]
    n = 0
    for e in entries:
        if e.get("disabled_by"):
            continue
        n += 1
        st = e.get("state", "unknown")
        out.append('ha_config_entry_state{domain="%s",entry_id="%s",state="%s"} 1'
                   % (esc(e["domain"]), esc(e["entry_id"]), esc(st)))
    out += ["# TYPE ha_config_entries_enabled gauge", "ha_config_entries_enabled %d" % n,
            "# TYPE ha_config_entry_scrape_timestamp_seconds gauge",
            "ha_config_entry_scrape_timestamp_seconds %d" % time.time()]
    return "\n".join(out) + "\n"


def loop():
    global body
    while True:
        try:
            b = poll()
            ok = 1
        except Exception as ex:  # keep serving; the success gauge tells Prometheus
            b = None
            ok = 0
            print("poll failed: %s" % type(ex).__name__, flush=True)
        with lock:
            if b is not None:
                body = b
            body = "\n".join(l for l in body.split("\n") if not l.startswith("ha_config_entry_poll_success")
                             and "poll_success" not in l) + "\n"
            body += "# TYPE ha_config_entry_poll_success gauge\nha_config_entry_poll_success %d\n" % ok
        time.sleep(INTERVAL)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with lock:
            b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(b)


threading.Thread(target=loop, daemon=True).start()
HTTPServer(("", PORT), H).serve_forever()
