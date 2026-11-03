#!/usr/bin/env python3
"""vdhwslin01 waker on vdhmini01 (chg-2026-10-05-031, revived 2026-11-03; AGR-114/115).

launchd (net.vdhict.vdhwslin01-waker) runs this every 2 minutes. It only WAKES and
UNLOCKS. It never powers the box off: the box's own idle-poweroff.timer does that,
and only for a boot that this waker started.

  waiting forge jobs for our labels in org vdhict AND box off (22 + 2222 closed)
    -> POST the local-only HA webhook (HA presses WoL, HA enforces 4/day)
    -> wait for the initramfs ssh server on 2222 (ssh alias vdhwslin01-unlock:
       pinned host key, StrictHostKeyChecking yes)
    -> send the passphrase as ssh stdin (never argv, never printed); the box's
       vdh-teamboot wrapper writes /run/team-boot and echoes the boot_id
    -> wait for sshd on 22 -> one change-log line.
  box at the unlock prompt that we did not cause -> never unlocked.
  box up -> never touched.

A FAILED WAKE IS NEVER SILENT. Each of these writes one change-log line
(`executed`, result wake_failed) and one ntfy message:
  no_unlock_prompt, passphrase_rejected, no_ssh_after_unlock, cap_reached,
  no_host_key, webhook_error, queue_unreadable, foreign_prompt_jobs_waiting,
  jobs_stuck_box_up.
The ntfy message is silent 23:00-07:00 (AGR-074: priority 1, "[night]").
While the same reason persists and jobs still wait, it repeats at most once an hour.

Queue source: a read-only SQL query on the forge-pg primary through the Mini's
existing kubectl access (default_transaction_read_only=on). It adds no new forge
credential, because every forge API route that lists jobs needs org-owner rights
(Argus D2).

Secrets:
  ~/.config/vdhwslin01/ha-webhook-id     0600, HA webhook id (sent to curl via -K -)
  ~/.config/vdhwslin01/team-luks.key     0400, the TEAM LUKS keyslot passphrase (B5 = a, owner
                                         2026-11-03); never the owner's own passphrase
Both are only read as bytes and handed to a child process's stdin. They are
never logged, printed or placed on a command line.

Installed (Argus B4) by mini/install-waker.sh from a commit on origin/main to
~/.local/libexec/vdhwslin01-waker/ (never run from a working tree). launchd calls:

  vdhwslin01-waker.py --expect-sha256 <sha of this file> --kubectl </abs/kubectl>
                      --changes-log </abs/.../ops/changes.jsonl> [--dry-run]

  --expect-sha256  self-check at start: a mismatch (or a missing pin) refuses to
                   act and writes ONE wake_failed line (reason self_check_failed).
  --kubectl        absolute path; every call also pins --context admin@vdhinfra-local (C6).
  --changes-log    absolute path of ops/changes.jsonl. The waker appends its lines
                   itself in the exact ops/ops format (sorted keys, compact JSON):
                   no code from a working tree is executed.
  --dry-run        probe + query + decide, print the decision. No webhook, no unlock,
                   no change-log line, no ntfy, no state write.
Stdlib only, Python 3.9 (/usr/bin/python3 on macOS).
"""
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

try:
    from zoneinfo import ZoneInfo
    LOCAL_TZ = ZoneInfo("Europe/Amsterdam")
except Exception:  # pragma: no cover - tzdata missing
    LOCAL_TZ = timezone.utc

CHG = "chg-2026-10-05-031"
ACTOR = "k8s-engineer"
BOX_IP = "172.16.3.205"
UNLOCK_PORT = 2222
ORG = "vdhict"
LABELS = ("docker", "x86-linux")
DAILY_CAP = 4                # HA enforces it too; this one makes the cap visible
PENDING_TTL_S = 900          # a wake we sent is "ours" for 15 min
MAX_UNLOCK_ATTEMPTS = 2      # per wake; never hammer the unlock server
WAIT_UNLOCK_PORT_S = 360
WAIT_SSH_S = 300
NOTIFY_EVERY_S = 3600        # same failure reason: at most one line + ntfy per hour
STUCK_AFTER_S = 1800         # box up but a job has waited this long -> report
QUERY_FAIL_GRACE_S = 600     # one blip is not a failure; 10 min of them is

HOME = os.path.expanduser("~")
CONF = os.environ.get("WAKER_CONF_DIR", os.path.join(HOME, ".config", "vdhwslin01"))
STATE_FILE = os.path.join(CONF, "waker-state.json")
LOCK_FILE = os.path.join(CONF, "waker.lock")
WEBHOOK_FILE = os.path.join(CONF, "ha-webhook-id")
PASS_FILE = os.path.join(CONF, "team-luks.key")   # team keyslot only (B5 = a)
KNOWN_HOSTS = os.environ.get("WAKER_KNOWN_HOSTS", os.path.join(HOME, ".ssh", "known_hosts_vdhwslin01"))
NTFY_ENV = os.environ.get("AIOPS_ENV", os.path.join(HOME, ".config", "aiops", "ntfy.env"))
KUBE_CONTEXT = "admin@vdhinfra-local"
CURL = os.environ.get("WAKER_TEST_CURL", "/usr/bin/curl")   # tests only: a stub that records calls
HA_URL = "http://172.16.2.237:8123"
UNLOCK_ALIAS = "vdhwslin01-unlock"

QUERY_SQL = (
    "SELECT j.runs_on, j.created, j.status FROM action_run_job j "
    "JOIN repository r ON r.id = j.repo_id JOIN \"user\" u ON u.id = r.owner_id "
    "WHERE u.lower_name = '%s' AND j.status IN (5, 6)" % ORG)  # 5 = waiting, 6 = running


# --------------------------------------------------------------------------
# Pure logic (unit-tested in tests/test_waker_mini.py)
# --------------------------------------------------------------------------
def utc(now):
    return datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_day(now):
    return datetime.fromtimestamp(now, LOCAL_TZ).strftime("%Y-%m-%d")


def is_night(now):
    h = datetime.fromtimestamp(now, LOCAL_TZ).hour
    return h >= 23 or h < 7


def roll_day(state, now):
    day = local_day(now)
    if state.get("day") != day:
        state["day"] = day
        state["wakes_today"] = 0
    return state


def matching_jobs(rows, labels=LABELS, status=5):
    """rows: [(runs_on list, created epoch, status)]. A job matches if its runs_on is
    a non-empty subset of our labels and it has the given status (5 waiting, 6 running)."""
    out = []
    for runs_on, created, st in rows or []:
        s = set(runs_on or [])
        if s and s <= set(labels) and int(st) == status:
            out.append(int(created))
    return out


def parse_rows(text):
    rows = []
    for line in (text or "").splitlines():
        if not line.strip():
            continue
        runs_on, created, status = line.rsplit("\t", 2)
        rows.append((json.loads(runs_on), int(created), int(status)))
    return rows


def parse_boot_id(text):
    m = re.search(r"vdh-teamboot: started_by=team boot_id=([0-9a-f-]{36})", text or "")
    return m.group(1) if m else None


def decide(now, state, n_jobs, oldest_age, box, has_host_key, cap=DAILY_CAP, n_running=0):
    """Return (action, reason). box: 'up' | 'unlock' | 'off'."""
    pending = state.get("pending_wake_ts")
    live = pending is not None and now - pending < PENDING_TTL_S
    if box == "up":
        if pending is not None:
            return "complete", "box up after our wake"
        if n_jobs and oldest_age >= STUCK_AFTER_S and n_running == 0:
            return "stuck", "box up but a job has waited %ds: runner not taking jobs" % oldest_age
        return "none", "box is up (never touch a running box)"
    if box == "unlock":
        if live and state.get("unlock_attempts", 0) < MAX_UNLOCK_ATTEMPTS:
            return "unlock", "box at unlock prompt after our wake"
        if live:
            return "none", "unlock attempts for this wake used up; waiting for expiry"
        if pending is not None:
            return "expire", "our wake did not reach a booted box within %ds" % PENDING_TTL_S
        if n_jobs:
            return "foreign_prompt", "box at unlock prompt NOT caused by us, %d job(s) waiting: leave it" % n_jobs
        return "none", "box at unlock prompt but NOT woken by us: leave it"
    # box off
    if pending is not None and not live:
        return "expire", "no unlock server within %ds of our wake" % PENDING_TTL_S
    if n_jobs == 0:
        return "none", "no waiting jobs"
    if pending is not None:
        return "none", "woke %ds ago, still waiting" % (now - pending)
    if not has_host_key:
        return "refuse", "no pinned host key for the unlock server: will not wake"
    if state.get("wakes_today", 0) >= cap:
        return "cap_hit", "daily cap %d reached" % cap
    return "wake", "%d waiting job(s), box off" % n_jobs


def should_report(state, reason, now):
    last = state.setdefault("last_fail", {}).get(reason)
    return last is None or now - last >= NOTIFY_EVERY_S


def clear_pending(state):
    for k in ("pending_wake_ts", "pending_jobs", "unlock_attempts", "pending_failed"):
        state.pop(k, None)


# --------------------------------------------------------------------------
# I/O (replaced by a fake in the tests)
# --------------------------------------------------------------------------
def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, timeout=kw.pop("timeout", 60), **kw)


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_args(argv):
    a = {"dry": "--dry-run" in argv, "expect": None, "kubectl": None, "changes": None}
    for flag, key in (("--expect-sha256", "expect"), ("--kubectl", "kubectl"), ("--changes-log", "changes")):
        if flag in argv:
            i = argv.index(flag)
            a[key] = argv[i + 1] if i + 1 < len(argv) else None
    return a


def self_check(args, path):
    """Return None when ok, else the reason text. Fail closed on anything missing."""
    if not args["expect"] or not re.fullmatch(r"[0-9a-f]{64}", args["expect"]):
        return "no valid --expect-sha256 pin"
    have = file_sha256(path)
    if have != args["expect"]:
        return "sha256 %s != pin %s" % (have[:16], args["expect"][:16])
    k = args["kubectl"] or ""
    if not (os.path.isabs(k) and os.access(k, os.X_OK)):
        return "--kubectl is not an absolute executable path"
    c = args["changes"] or ""
    if not (os.path.isabs(c) and os.path.isfile(c) and c.endswith("/ops/changes.jsonl")):
        return "--changes-log is not an absolute path to an existing ops/changes.jsonl"
    return None


def append_change(path, event, payload, now):
    """Same line format as ops/ops append_event (sorted keys, compact, ensure_ascii False)."""
    evt = {"chg": CHG, "ts": utc(now), "event": event, "actor": ACTOR, "payload": payload}
    line = json.dumps(evt, separators=(",", ":"), ensure_ascii=False, sort_keys=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (line + "\n").encode())
    finally:
        os.close(fd)


class RealIO:
    def __init__(self, dry, kubectl=None, changes=None):
        self.dry = dry
        self.kubectl = kubectl
        self.changes = changes

    def now(self):
        return int(time.time())

    def persist(self, state):
        if not self.dry:
            save_state(state)

    def sleep(self, s):
        time.sleep(s)

    def port_open(self, port):
        # nc, not a Python socket: macOS Local Network Privacy can block python
        # from the LAN while nc works (memory: macos-local-network-privacy).
        try:
            return _run(["/usr/bin/nc", "-z", "-G", "3", BOX_IP, str(port)], timeout=10).returncode == 0
        except subprocess.TimeoutExpired:
            return False

    def has_host_key(self):
        try:
            with open(KNOWN_HOSTS) as f:
                return any(l.startswith("[%s]:%d " % (BOX_IP, UNLOCK_PORT)) for l in f)
        except OSError:
            return False

    def query_jobs(self):
        k = [self.kubectl, "--context", KUBE_CONTEXT]
        pod = _run(k + ["-n", "devtools", "get", "pod", "-l",
                    "cnpg.io/cluster=forge-pg,cnpg.io/instanceRole=primary",
                    "-o", "jsonpath={.items[0].metadata.name}"], timeout=30)
        name = pod.stdout.decode().strip()
        if pod.returncode != 0 or not name:
            raise RuntimeError("forge-pg primary not found")
        p = _run(k + ["-n", "devtools", "exec", name, "-c", "postgres", "--",
                  "psql", "-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "forgejo",
                  "-c", "SET default_transaction_read_only = on", "-c", QUERY_SQL], timeout=45)
        if p.returncode != 0:
            raise RuntimeError("psql rc=%d" % p.returncode)
        return parse_rows(p.stdout.decode())

    def post_webhook(self, n_jobs):
        with open(WEBHOOK_FILE, "rb") as f:
            wid = f.read().decode().strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{16,}", wid):
            raise RuntimeError("webhook id file malformed")
        # URL via curl config on stdin (-K -): the id never reaches argv.
        cfg = 'url = "%s/api/webhook/%s"\n' % (HA_URL, wid)
        wid = ""
        p = _run([CURL, "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15",
                  "-X", "POST", "-H", "Content-Type: application/json",
                  "--data", json.dumps({"source": "vdhwslin01-waker", "jobs": n_jobs}), "-K", "-"],
                 input=cfg.encode(), timeout=30)
        return int(p.stdout.decode() or 0)

    def unlock(self):
        with open(PASS_FILE, "rb") as f:
            secret = f.read().replace(b"\n", b"").replace(b"\r", b"")
        try:
            p = _run(["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                      "-o", "LogLevel=ERROR", UNLOCK_ALIAS], input=secret + b"\n", timeout=120)
            rc, out = p.returncode, (p.stdout + p.stderr).decode(errors="replace")
        except subprocess.TimeoutExpired:
            rc, out = 124, ""
        secret = b""
        return rc, out

    def event(self, event, payload):
        try:
            append_change(self.changes, event, payload, self.now())
        except OSError as e:
            log("change-log write failed (%s)" % type(e).__name__)

    def notify(self, title, body, night):
        env = {}
        try:
            with open(NTFY_ENV) as f:
                for l in f:
                    if "=" in l and not l.lstrip().startswith("#"):
                        k, v = l.strip().split("=", 1)
                        env[k] = v.strip('"')
        except OSError:
            log("ntfy env missing; change-log line only")
            return
        if not env.get("NTFY_SERVER") or not env.get("NTFY_ALERT_TOPIC"):
            log("ntfy env incomplete; change-log line only")
            return
        prio = "1" if night else "3"
        if night:
            title = "[night] " + title
        cfg = 'url = "%s/%s"\n' % (env["NTFY_SERVER"], env["NTFY_ALERT_TOPIC"])
        _run([CURL, "-fsS", "-o", "/dev/null", "--max-time", "15", "-H", "Title: " + title,
              "-H", "Priority: " + prio, "-H", "Tags: vdhwslin01", "--data-binary", body, "-K", "-"],
             input=cfg.encode(), timeout=30)


def log(msg):
    print("%s waker: %s" % (utc(time.time()), msg), flush=True)


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = STATE_FILE + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, sort_keys=True, indent=1)
    os.replace(tmp, STATE_FILE)


# --------------------------------------------------------------------------
# One tick
# --------------------------------------------------------------------------
def report_failure(io, state, now, reason, detail, extra=None):
    """The 'never silent' path: one line + one ntfy, at most hourly per reason."""
    if not should_report(state, reason, now):
        log("wake_failed %s (already reported within the hour)" % reason)
        return False
    state["last_fail"][reason] = now
    payload = {"step": "vdhwslin01 wake", "result": "wake_failed", "reason": reason, "detail": detail,
               "regime": "AGR-109: tests are the gate", "ts_measured": utc(now)}
    payload.update(extra or {})
    io.event("executed", payload)
    io.notify("vdhwslin01 wake failed: %s" % reason,
              "%s. Forge jobs for label docker (org VDHICT) are still waiting. %s" % (detail, CHG),
              is_night(now))
    log("wake_failed %s: %s" % (reason, detail))
    return True


def tick(io, state, dry=False):
    now = io.now()
    roll_day(state, now)
    if io.port_open(22):
        box = "up"
    elif io.port_open(UNLOCK_PORT):
        box = "unlock"
    else:
        box = "off"

    jobs, running, query_ok = [], [], True
    try:
        rows = io.query_jobs()
        jobs, running = matching_jobs(rows), matching_jobs(rows, status=6)
        state.pop("query_fail_since", None)
    except Exception as e:  # noqa: BLE001 - any failure means "unknown queue"
        query_ok = False
        state.setdefault("query_fail_since", now)
        log("queue query failed (%s)" % type(e).__name__)
    n = len(jobs)
    oldest = (now - min(jobs)) if jobs else 0

    if not query_ok:
        if now - state["query_fail_since"] >= QUERY_FAIL_GRACE_S and not dry:
            report_failure(io, state, now, "queue_unreadable",
                           "cannot read the forge queue for %ds; the waker cannot see waiting jobs"
                           % (now - state["query_fail_since"]))
        # never wake on an unknown queue, but finish a wake we already started
        if state.get("pending_wake_ts") is None:
            return "none"

    action, reason = decide(now, state, n, oldest, box, io.has_host_key(), n_running=len(running))
    log("box=%s jobs=%d oldest=%ds wakes_today=%d action=%s: %s"
        % (box, n, oldest, state.get("wakes_today", 0), action, reason))
    if dry:
        return action

    if action == "complete":
        io.event("validated", {"step": "vdhwslin01 wake", "result": "up", "woke_at": utc(state["pending_wake_ts"]),
                               "jobs": n, "note": "box up after our wake (unlock seen earlier or late sshd)"})
        clear_pending(state)
        state.get("last_fail", {}).clear()
    elif action == "expire" and state.get("pending_failed"):
        log("our failed wake expired (already reported)")
        clear_pending(state)
    elif action == "expire":
        report_failure(io, state, now, "no_unlock_prompt",
                       "woke at %s, no booted box within %ds (WoL failed, HA cap refused, or unlock failed)"
                       % (utc(state["pending_wake_ts"]), PENDING_TTL_S))
        clear_pending(state)
    elif action == "refuse":
        report_failure(io, state, now, "no_host_key", reason)
    elif action == "cap_hit":
        report_failure(io, state, now, "cap_reached", "%d team wakes today already" % DAILY_CAP)
    elif action == "foreign_prompt":
        report_failure(io, state, now, "foreign_prompt_jobs_waiting", reason)
    elif action == "stuck":
        report_failure(io, state, now, "jobs_stuck_box_up", reason)
    elif action in ("wake", "unlock"):
        if action == "wake":
            try:
                status = io.post_webhook(n)
            except Exception as e:  # noqa: BLE001
                status = 0
                log("webhook error (%s)" % type(e).__name__)
            if status != 200:
                report_failure(io, state, now, "webhook_error", "HA webhook answered %s" % (status or "no response"))
                return action
            state["wakes_today"] = state.get("wakes_today", 0) + 1
            state["pending_wake_ts"] = now
            state["unlock_attempts"] = 0
            io.event("executed", {"step": "vdhwslin01 wake", "result": "wake_sent", "jobs": n,
                                  "oldest_wait_s": oldest, "wakes_today": state["wakes_today"],
                                  "regime": "AGR-109: tests are the gate"})
            io.persist(state)  # the wake is recorded before we start waiting
            if not wait_port(io, UNLOCK_PORT, WAIT_UNLOCK_PORT_S):
                log("no unlock server yet; a later tick continues while the wake is ours")
                return action
        state["unlock_attempts"] = state.get("unlock_attempts", 0) + 1
        rc, out = io.unlock()
        boot_id = parse_boot_id(out)
        if "No key available" in out:
            report_failure(io, state, now, "passphrase_rejected",
                           "the unlock server rejected the passphrase (file on the Mini out of date?)")
            clear_pending(state)
            return action
        up = wait_port(io, 22, WAIT_SSH_S)
        if up:
            io.event("validated", {"step": "vdhwslin01 wake", "result": "up", "boot_id": boot_id,
                                   "team_boot_marker": bool(boot_id), "ssh_rc": rc,
                                   "woke_at": utc(state.get("pending_wake_ts", now)), "jobs": n})
            clear_pending(state)
            state.get("last_fail", {}).clear()
        elif state.get("unlock_attempts", 0) >= MAX_UNLOCK_ATTEMPTS:
            state["pending_failed"] = True
            report_failure(io, state, now, "no_ssh_after_unlock",
                           "unlock sent %d time(s) (ssh rc %d), sshd on 22 never came up"
                           % (state["unlock_attempts"], rc))
    return action


def wait_port(io, port, seconds):
    end = io.now() + seconds
    while io.now() < end:
        if io.port_open(port):
            return True
        io.sleep(5)
    return False


def main(argv):
    args = parse_args(argv)
    dry = args["dry"]
    os.makedirs(CONF, mode=0o700, exist_ok=True)
    lockfd = os.open(LOCK_FILE, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another waker run holds the lock; exiting")
        os.close(lockfd)
        return 0
    try:
        return run_locked(args, dry)
    finally:
        os.close(lockfd)   # releases the flock


def run_locked(args, dry):
    state = load_state()
    io = RealIO(dry, args["kubectl"], args["changes"])
    bad = self_check(args, os.path.abspath(__file__))
    if bad:
        # B4: refuse to act. One line (hourly) if the change log itself is usable.
        log("SELF-CHECK FAILED: %s; refusing to act" % bad)
        if not dry:
            now = io.now()
            if should_report(state, "self_check_failed", now):
                state["last_fail"]["self_check_failed"] = now
                c = args["changes"] or ""
                if os.path.isabs(c) and os.path.isfile(c):
                    io.changes = c
                    io.event("executed", {"step": "vdhwslin01 wake", "result": "wake_failed",
                                          "reason": "self_check_failed", "detail": bad,
                                          "regime": "AGR-109: tests are the gate", "ts_measured": utc(now)})
                io.notify("vdhwslin01 waker refused: self-check failed", bad + ". " + CHG, is_night(now))
            save_state(state)
        return 3
    tick(io, state, dry=dry)
    if not dry:
        save_state(state)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
