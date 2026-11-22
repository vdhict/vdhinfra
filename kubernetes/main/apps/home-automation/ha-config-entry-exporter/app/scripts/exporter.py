#!/usr/bin/env python3
"""Export Home Assistant config-entry states as Prometheus metrics.

Source: GET /api/config/config_entries/entry (read-only, same bearer token the
HA ServiceMonitor already uses). Only domain, entry_id and state are exported:
no entry titles, so no personal names reach Prometheus. Disabled entries
(disabled_by set) are skipped: a switched-off entry is not a fault.

Exception list (tsk-2026-11-22-103, team choice via Larry 12:31): /exceptions/exceptions.json, a list of
{"domain", "entry_id", "reden", "herzien": "YYYY-MM-DD"}. An entry is excepted only while today (UTC) <= herzien and
herzien is at most MAX_EXC_DAYS ahead. Expired or invalid exceptions are not honoured, so the entry alerts again:
nothing is ignored for ever. The reason text is never exported (free text), only domain, entry_id and herzien.
"""
import datetime, json, os, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

HA = os.environ.get("HA_URL", "http://home-assistant.home-automation.svc.cluster.local:8123")
TOKEN = os.environ["HA_TOKEN"]
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
PORT = int(os.environ.get("LISTEN_PORT", "9102"))
STATES = ["loaded", "setup_error", "setup_retry", "migration_error", "failed_unload",
          "not_loaded", "setup_in_progress"]
EXC_FILE = os.environ.get("EXCEPTIONS_FILE", "/exceptions/exceptions.json")
MAX_EXC_DAYS = int(os.environ.get("MAX_EXCEPTION_DAYS", "30"))
lock = threading.Lock()
body = "# no data yet\n"


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def exceptions(today):
    """Return metric lines for the exception list; a missing or broken file means no exceptions (fail-safe)."""
    out = ["# HELP ha_config_entry_exception_active 1 if the entry is on the exception list and its herzien date is valid",
           "# TYPE ha_config_entry_exception_active gauge"]
    bad = 0
    try:
        items = json.load(open(EXC_FILE))
        if not isinstance(items, list):
            raise ValueError("not a list")
    except FileNotFoundError:
        items = []
    except Exception:
        items, bad = [], 1
    for it in items:
        try:
            dom, eid = str(it["domain"]), str(it["entry_id"])
            herz = datetime.date.fromisoformat(str(it["herzien"]))
            if not str(it.get("reden", "")).strip():
                raise ValueError("no reden")
        except Exception:
            bad += 1
            continue
        ok = today <= herz <= today + datetime.timedelta(days=MAX_EXC_DAYS)
        out.append('ha_config_entry_exception_active{domain="%s",entry_id="%s",herzien="%s"} %d'
                   % (esc(dom), esc(eid), herz.isoformat(), 1 if ok else 0))
    out += ["# TYPE ha_config_entry_exceptions_invalid gauge", "ha_config_entry_exceptions_invalid %d" % bad]
    return out


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
    out += exceptions(datetime.datetime.now(datetime.timezone.utc).date())
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
