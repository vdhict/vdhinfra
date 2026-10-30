"""chg-2026-10-20-010 W2c: guard the ONE shared family-cloud spend ledger before Hermes starts (all three profiles).

Runs as the init container cloud-spend-init of every hermes-profiel-N pod, AFTER seed-once (which rewrites
settings.json on every start), as UID 10000, no capabilities, no env, no secret. Numbers only; content-free log lines.

  /cloud-spend/month.json       the shared ledger family-cloud reads and writes (month, usd, token counters, person_usd)
  /cloud-spend/month.lock       the lock family-cloud takes (Path(month.json).with_suffix('.lock')); this guard takes
                                the same exclusive flock, so three pods on three nodes never race (CephFS flock)
  /cloud-spend/.ledger-marker   {"month": "YYYY-MM", "inits": N}: updated on every start of any profile
  /cloud-spend/.ledger-seeded   {"source": "migrated", "usd": x, "month": m, "ts": ...}: written once, by the move of
                                profiel-3's ledger from its own PVC; without it no ledger is ever created

Rules (W2b + W2c: losing, re-creating or splitting the ledger must never reset the spend; Argus 09:42Z/08:29Z):
  * month.json present and valid, seed present   -> keep it byte-for-byte; marker month := now, inits + 1;
  * month.json missing, seed present             -> REFUSE (never re-created: the cap counts the total since the
                                                     27-10 baseline, so a missing ledger is lost spend, not a new month);
  * no seed, no marker, no month.json, and an old per-profile ledger at OLD_DIR (profiel-3 only mounts it) that is
    valid -> MOVE: copy month.json and the sticky-*.json stores, marker from the old marker (inits + 1), then the seed;
  * no seed otherwise (profiel-1/-2 before the move, a fresh volume, a corrupt old ledger) -> REFUSE;
  * month.json or marker corrupt, marker month in the future, month.json present without a seed -> REFUSE.
REFUSE = fail closed: price_confirmed=false in this pod's family-cloud settings.json (the router answers on the Studio
only), the ledger is NOT created or overwritten, exit 0 so Hermes still serves locally. A refusal holds until the
condition is cleared by a recorded manual step.

argv (offline tests only): [spend_dir] [settings_path] [YYYY-MM] [old_dir or -]
"""
import datetime as dt
import fcntl
import json
import math
import os
import re
import sys

D = sys.argv[1] if len(sys.argv) > 1 else "/cloud-spend"
SETTINGS = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/plugins/model-providers/family-cloud/settings.json"
NOW = sys.argv[3] if len(sys.argv) > 3 else dt.datetime.now(dt.timezone.utc).strftime("%Y-%m")   # router clock: UTC
OLD = sys.argv[4] if len(sys.argv) > 4 else "/cloud-spend-old"
OLD = None if OLD == "-" or not os.path.isdir(OLD) else OLD
LEDGER, MARKER, SEED = (os.path.join(D, n) for n in ("month.json", ".ledger-marker", ".ledger-seeded"))
LOCK = os.path.join(D, "month.lock")
MONTH = re.compile(r"[0-9]{4}-(0[1-9]|1[0-2])")
KEYS = {"person_usd", "month", "usd", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"}
PEOPLE = {"profiel-1", "profiel-2", "profiel-3"}
STICKY = re.compile(r"sticky-profiel-[123]\.json")


def say(msg):
    print("cloud-spend-init: " + msg, flush=True)


def atomic_write(path, text):
    tmp = path + ".new"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def write_new(path, data):
    """Create path atomically, never over an existing file (link of a fsynced temp file)."""
    tmp = path + ".init"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    try:
        os.link(tmp, path)
        return True
    except FileExistsError:
        return False
    finally:
        os.unlink(tmp)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return "corrupt"


def ledger_ok(d):
    num = lambda v: type(v) in (int, float) and math.isfinite(v) and v >= 0
    return (isinstance(d, dict) and set(d) == KEYS and isinstance(d["month"], str) and MONTH.fullmatch(d["month"])
            and d["month"] <= NOW and num(d["usd"])
            and all(type(d[k]) is int and d[k] >= 0 for k in KEYS - {"month", "usd", "person_usd"})
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
    say(f"REFUSED {code}; ledger left as is; {state}")
    return 0


def move_old():
    """profiel-3's own ledger -> the shared volume, once. Every byte validated before anything is written."""
    old_ledger = read_json(os.path.join(OLD, "month.json"))
    old_marker = read_json(os.path.join(OLD, ".ledger-marker"))
    if not ledger_ok(old_ledger) or not marker_ok(old_marker) or old_marker["month"] > NOW:
        return refuse("old-ledger-invalid")
    stickies = []
    for name in sorted(os.listdir(OLD)):
        if STICKY.fullmatch(name):
            raw = open(os.path.join(OLD, name), "rb").read()
            if not isinstance(read_json(os.path.join(OLD, name)), dict):
                return refuse("old-sticky-invalid")
            stickies.append((name, raw))
    raw_ledger = open(os.path.join(OLD, "month.json"), "rb").read()
    for name, raw in stickies:
        if not write_new(os.path.join(D, name), raw):
            return refuse("sticky-exists")
    if not write_new(LEDGER, raw_ledger):
        return refuse("ledger-appeared")
    atomic_write(MARKER, json.dumps({"month": NOW, "inits": old_marker["inits"] + 1}) + "\n")
    seed = {"source": "migrated", "usd": old_ledger["usd"], "month": old_ledger["month"],
            "ts": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    write_new(SEED, (json.dumps(seed) + "\n").encode())
    say(f"moved: month.json (month {old_ledger['month']}, usd {old_ledger['usd']:.6f}) and {len(stickies)} sticky "
        f"store(s) from the old profile ledger; marker {NOW} inits {old_marker['inits'] + 1}; seeded")
    return 0


def guarded():
    if not MONTH.fullmatch(NOW):
        return refuse("clock")
    seeded = os.path.lexists(SEED)
    if seeded and not (isinstance(read_json(SEED), dict) and read_json(SEED).get("source") == "migrated"):
        return refuse("seed-corrupt")
    marker = None
    if os.path.lexists(MARKER):
        marker = read_json(MARKER)
        if not marker_ok(marker):
            return refuse("marker-corrupt")
        if marker["month"] > NOW:
            return refuse("marker-future")
    if os.path.lexists(LEDGER):
        if not seeded:
            return refuse("ledger-without-seed")
        if not ledger_ok(read_json(LEDGER)):
            return refuse("ledger-corrupt")
        inits = (marker["inits"] + 1) if marker else 1
        atomic_write(MARKER, json.dumps({"month": NOW, "inits": inits}) + "\n")
        say(f"shared month.json present, kept; marker {NOW} inits {inits}")
        return 0
    if seeded:
        return refuse("ledger-missing")
    if marker is None and OLD is not None:
        return move_old()
    return refuse("not-seeded")


def main():
    try:
        os.makedirs(D, exist_ok=True)
        lock = open(LOCK, "a")
    except Exception:
        return refuse("lock-unavailable")
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX)   # the same lock family-cloud holds while it reserves and settles
        return guarded()


if __name__ == "__main__":
    sys.exit(main())
