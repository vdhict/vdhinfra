"""chg-2026-10-20-010 land 2, Argus W6 + W2b: guard the family-cloud spend ledger before Hermes starts.

Runs as the init container cloud-spend-init AFTER seed-once (which rewrites settings.json on every start), as UID
10000, no capabilities, no env, no secret. Numbers only; every log line is content-free.

  /cloud-spend/month.json      the ledger family-cloud reads and writes (month, usd, token counters, person_usd)
  /cloud-spend/.ledger-marker  {"month": "YYYY-MM", "inits": N}: written at the first init, updated on every start

Rules (W2b: losing or re-creating the ledger must never reset the month's spend):
  * no marker and no month.json          -> fresh PVC: create month.json (zeros) and the marker;
  * month.json present and valid          -> keep it byte-for-byte; marker month := now, inits + 1;
  * month.json missing, marker month < now -> month change: create month.json, update the marker;
  * month.json missing, marker month == now -> REFUSE (mid-month deletion);
  * month.json corrupt, marker corrupt or marker month in the future -> REFUSE.
REFUSE = fail closed: price_confirmed=false in family-cloud settings.json (so the router answers on the Studio only),
month.json is NOT created or overwritten, exit 0 so Hermes still serves locally. seed-once restores settings.json on
the next start and this guard refuses again for as long as the condition holds (until the month changes).

argv (offline tests only): [spend_dir] [settings_path] [YYYY-MM]
"""
import datetime as dt
import json
import math
import os
import re
import sys

D = sys.argv[1] if len(sys.argv) > 1 else "/cloud-spend"
SETTINGS = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/plugins/model-providers/family-cloud/settings.json"
NOW = sys.argv[3] if len(sys.argv) > 3 else dt.datetime.now(dt.timezone.utc).strftime("%Y-%m")   # router clock: UTC
LEDGER, MARKER = os.path.join(D, "month.json"), os.path.join(D, ".ledger-marker")
MONTH = re.compile(r"[0-9]{4}-(0[1-9]|1[0-2])")
KEYS = {"person_usd", "month", "usd", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"}
PEOPLE = {"profiel-1", "profiel-2", "profiel-3"}


def say(msg):
    print("cloud-spend-init: " + msg, flush=True)


def atomic_write(path, text):
    tmp = path + ".new"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def ledger_ok(d):
    num = lambda v: type(v) in (int, float) and math.isfinite(v) and v >= 0
    return (isinstance(d, dict) and set(d) == KEYS and isinstance(d["month"], str) and MONTH.fullmatch(d["month"])
            and num(d["usd"]) and all(type(d[k]) is int and d[k] >= 0 for k in KEYS - {"month", "usd", "person_usd"})
            and isinstance(d["person_usd"], dict) and set(d["person_usd"]) == PEOPLE
            and all(num(v) for v in d["person_usd"].values()))


def marker_ok(m):
    return (isinstance(m, dict) and set(m) == {"month", "inits"} and isinstance(m["month"], str)
            and MONTH.fullmatch(m["month"]) and type(m["inits"]) is int and m["inits"] >= 1)


def refuse(code):
    try:
        with open(SETTINGS) as f:
            s = json.load(f)
        s["price_confirmed"] = False
        atomic_write(SETTINGS, json.dumps(s, indent=2) + "\n")
        state = "cloud off (price_confirmed=false)"
    except FileNotFoundError:
        state = "no family-cloud settings (cloud already off)"
    except Exception:
        state = "settings unreadable; family-cloud fails closed on its own"
    say(f"REFUSED {code}; month.json left as is; {state}")
    return 0


def create():
    zero = {"month": NOW, "usd": 0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0,
            "cache_write_tokens": 0, "person_usd": {p: 0 for p in sorted(PEOPLE)}}
    tmp = LEDGER + ".init"
    with open(tmp, "w") as f:
        f.write(json.dumps(zero) + "\n")
        f.flush()
        os.fsync(f.fileno())
    try:
        os.link(tmp, LEDGER)          # atomic and never overwrites an existing ledger
    except FileExistsError:
        say("month.json appeared meanwhile, kept")
    finally:
        os.unlink(tmp)


def main():
    if not MONTH.fullmatch(NOW):
        return refuse("clock")
    marker = None
    if os.path.lexists(MARKER):
        try:
            with open(MARKER) as f:
                marker = json.load(f)
        except Exception:
            marker = "corrupt"
        if not marker_ok(marker):
            return refuse("marker-corrupt")
        if marker["month"] > NOW:
            return refuse("marker-future")
    if os.path.lexists(LEDGER):
        try:
            with open(LEDGER) as f:
                ledger = json.load(f)
        except Exception:
            ledger = None
        if not ledger_ok(ledger):
            return refuse("ledger-corrupt")
        inits = (marker["inits"] + 1) if marker else 1
        atomic_write(MARKER, json.dumps({"month": NOW, "inits": inits}) + "\n")
        say(f"month.json present, kept; marker {NOW} inits {inits}")
        return 0
    if marker and marker["month"] == NOW:
        return refuse("ledger-missing-mid-month")
    create()
    inits = (marker["inits"] + 1) if marker else 1
    atomic_write(MARKER, json.dumps({"month": NOW, "inits": inits}) + "\n")
    say(f"month.json created ({'month change' if marker else 'fresh PVC'}); marker {NOW} inits {inits}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
