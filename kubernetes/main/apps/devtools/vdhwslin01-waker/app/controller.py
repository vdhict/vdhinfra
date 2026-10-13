#!/usr/bin/env python3
"""vdhwslin01 waker (chg-2026-10-05-031, AGR-114/115, Argus R10/R12).

Runs every 2 minutes as a CronJob. It only WAKES and UNLOCKS; it never powers
the box off (the box's own idle-poweroff.timer does that, R10) and has no
login identity on the box.

  queued jobs for our labels on the forge AND box off (22 + 2222 closed)
    -> POST the local-only HA webhook (HA presses the WoL button and enforces
       4 boots/day itself, R12)
    -> wait for the initramfs ssh server on 2222 (host key pinned)
    -> send the controller keyslot passphrase over ssh; the box's vdh-teamboot
       wrapper writes /run/team-boot and echoes the boot_id back
    -> wait for sshd on 22, record ONE event for the wake.
  box at the unlock prompt but not woken by us -> leave it (Sander's boot).
  box up -> nothing (the runner picks up the job; a Sander boot is never
  touched).
  own daily count reaches the cap -> one cap_hit event per day (the Mini
  collector turns it into a line to Larry).

Events are appended to ConfigMap vdhwslin01-waker-state (last 100) and
printed as `OPS_EVENT {json}`. Secrets are read from mounted files and never
printed. Stdlib only (python:3.13 image).
"""
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

try:
    from zoneinfo import ZoneInfo
    LOCAL_TZ = ZoneInfo("Europe/Amsterdam")
except Exception:  # pragma: no cover - tzdata missing
    LOCAL_TZ = timezone.utc

CHG = "chg-2026-10-05-031"
PENDING_TTL_S = 900          # a wake we sent is "ours" for 15 min
MAX_UNLOCK_ATTEMPTS = 2      # per wake; never hammer the unlock server
REWAKE_AFTER_S = 600         # never send a second wake within 10 min
WAIT_UNLOCK_PORT_S = 360
WAIT_SSH_S = 300
MAX_EVENTS = 100


def cfg(name, default=None):
    v = os.environ.get(name, default)
    if v is None:
        raise SystemExit("missing env " + name)
    return v


# --------------------------------------------------------------------------
# Pure decision logic (unit-tested in test_controller.py)
# --------------------------------------------------------------------------
def local_day(now):
    return datetime.fromtimestamp(now, LOCAL_TZ).strftime("%Y-%m-%d")


def roll_day(state, now):
    day = local_day(now)
    if state.get("day") != day:
        state["day"] = day
        state["wakes_today"] = 0
        state["cap_notified_day"] = state.get("cap_notified_day", "")
    return state


def matching_jobs(jobs, labels):
    """Waiting jobs whose runs_on we can satisfy."""
    out = []
    for j in jobs or []:
        if j.get("status", "waiting") != "waiting":
            continue
        runs_on = set(j.get("runs_on") or [])
        if runs_on and runs_on <= set(labels):
            out.append(j)
    return out


def decide(now, state, n_jobs, box, has_host_key, cap):
    """Return (action, reason). box: 'up' | 'unlock' | 'off'."""
    pending = state.get("pending_wake_ts")
    pending_live = pending is not None and now - pending < PENDING_TTL_S
    if box == "up":
        if pending is not None:
            return "complete", "box up after our wake"
        return "none", "box is up (runner takes jobs; never touch a running box)"
    if box == "unlock":
        if pending_live and state.get("unlock_attempts", 0) < MAX_UNLOCK_ATTEMPTS:
            return "unlock", "box at unlock prompt after our wake"
        if pending_live:
            return "none", "unlock attempts for this wake used up: leave it"
        return "none", "box at unlock prompt but NOT woken by us (Sander's boot): leave it"
    # box off
    if pending is not None and not pending_live:
        return "expire", "our wake got no response within %ds" % PENDING_TTL_S
    if n_jobs == 0:
        return "none", "no queued jobs"
    if pending is not None and now - pending < REWAKE_AFTER_S:
        return "none", "woke %ds ago, still waiting" % (now - pending)
    if not has_host_key:
        return "refuse", "no pinned host key for the unlock server: will not wake"
    if state.get("wakes_today", 0) >= cap:
        if state.get("cap_notified_day") == state.get("day"):
            return "none", "daily cap %d reached (already reported)" % cap
        return "cap_hit", "daily cap %d reached" % cap
    return "wake", "%d queued job(s), box off" % n_jobs


def parse_boot_id(text):
    m = re.search(r"vdh-teamboot: started_by=team boot_id=([0-9a-f-]{36})", text or "")
    return m.group(1) if m else None


def add_event(state, ev):
    evs = state.setdefault("events", [])
    evs.append(ev)
    del evs[:-MAX_EVENTS]
    print("OPS_EVENT " + json.dumps(ev, sort_keys=True), flush=True)


# --------------------------------------------------------------------------
# I/O
# --------------------------------------------------------------------------
def log(msg):
    print("waker: " + msg, flush=True)


def port_open(ip, port, timeout=3.0):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def box_state(ip, unlock_port):
    if port_open(ip, 22):
        return "up"
    if port_open(ip, unlock_port):
        return "unlock"
    return "off"


def wait_port(ip, port, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if port_open(ip, port):
            return True
        time.sleep(5)
    return False


class Kube:
    SA = "/var/run/secrets/kubernetes.io/serviceaccount"

    def __init__(self, namespace, name):
        self.url = "https://kubernetes.default.svc/api/v1/namespaces/%s/configmaps/%s" % (namespace, name)
        self.ctx = ssl.create_default_context(cafile=self.SA + "/ca.crt")

    def _req(self, method, body=None, ctype="application/json"):
        with open(self.SA + "/token") as f:
            tok = f.read().strip()
        req = urllib.request.Request(self.url, method=method,
                                     data=None if body is None else json.dumps(body).encode())
        req.add_header("Authorization", "Bearer " + tok)
        req.add_header("Content-Type", ctype)
        with urllib.request.urlopen(req, context=self.ctx, timeout=15) as r:
            return json.load(r)

    def load(self):
        cm = self._req("GET")
        raw = (cm.get("data") or {}).get("state.json") or "{}"
        return json.loads(raw), cm["metadata"]["resourceVersion"]

    def save(self, state, rv):
        body = {"metadata": {"resourceVersion": rv},
                "data": {"state.json": json.dumps(state, sort_keys=True, indent=1)}}
        self._req("PATCH", body, "application/merge-patch+json")


def forge_waiting_jobs(api, repos, labels, token):
    jobs = []
    for repo in repos:
        url = "%s/repos/%s/actions/runners/jobs?labels=%s" % (api, repo, ",".join(labels))
        req = urllib.request.Request(url)
        req.add_header("Authorization", "token " + token)
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r) or []
        for j in data:
            j["_repo"] = repo
        jobs.extend(data)
    return jobs


def ha_wake(ha_url, webhook_id, n_jobs):
    req = urllib.request.Request("%s/api/webhook/%s" % (ha_url, webhook_id), method="POST",
                                 data=json.dumps({"source": "vdhwslin01-waker", "jobs": n_jobs}).encode())
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status


def unlock(ip, port, keyfile, known_hosts, passphrase):
    cmd = ["ssh", "-F", "/dev/null", "-T", "-i", keyfile, "-p", str(port),
           "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
           "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + known_hosts,
           "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR", "root@" + ip]
    p = subprocess.run(cmd, input=(passphrase + "\n").encode(), capture_output=True, timeout=120)
    out = (p.stdout + p.stderr).decode(errors="replace")
    return p.returncode, parse_boot_id(out)


def read_secret(path):
    with open(path) as f:
        return f.read().strip()


def main():
    now = int(time.time())
    ip = cfg("BOX_IP")
    unlock_port = int(cfg("UNLOCK_PORT", "2222"))
    labels = cfg("RUNNER_LABELS").split(",")
    repos = cfg("FORGE_REPOS").split(",")
    cap = int(cfg("DAILY_CAP", "4"))
    dry = cfg("DRY_RUN", "false") == "true"
    known_hosts = cfg("KNOWN_HOSTS", "/config/known_hosts")
    unlock_dir = cfg("UNLOCK_SECRET_DIR", "/secrets/unlock")
    forge_token_file = cfg("FORGE_TOKEN_FILE", "/secrets/forge/token")

    kube = Kube(cfg("NAMESPACE"), cfg("STATE_CONFIGMAP"))
    state, rv = kube.load()
    roll_day(state, now)

    host_key = os.path.exists(known_hosts) and any(
        l.startswith("[%s]:%d " % (ip, unlock_port)) for l in open(known_hosts))

    box = box_state(ip, unlock_port)
    jobs = []
    if box == "off" and state.get("pending_wake_ts") is None:
        if not os.path.exists(forge_token_file):
            log("no forge token mounted; cannot see queued jobs")
        else:
            try:
                jobs = matching_jobs(forge_waiting_jobs(cfg("FORGE_API"), repos, labels,
                                                        read_secret(forge_token_file)), labels)
            except (urllib.error.URLError, ValueError) as e:
                log("forge query failed (%s); not waking on an error" % type(e).__name__)
                kube.save(state, rv)
                return 0

    action, reason = decide(now, state, len(jobs), box, host_key, cap)
    log("box=%s jobs=%d wakes_today=%d action=%s: %s"
        % (box, len(jobs), state.get("wakes_today", 0), action, reason))
    if dry and action in ("wake", "unlock"):
        log("DRY_RUN: not acting")
        kube.save(state, rv)
        return 0

    ev = {"chg": CHG, "ts": datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
          "event": "vdhwslin01_wake", "started_by": "team"}

    if action == "cap_hit":
        state["cap_notified_day"] = state["day"]
        add_event(state, dict(ev, event="vdhwslin01_wake_cap_hit", cap=cap,
                              queued_jobs=len(jobs), notify="larry"))
    elif action == "refuse":
        pass  # logged above; no change line until there is a host key
    elif action == "expire":
        add_event(state, dict(ev, result="no_response", woke_at=state.get("pending_wake_ts"),
                              note="no unlock server within %ds (HA cap refused, or WoL failed)" % PENDING_TTL_S))
        for k in ("pending_wake_ts", "pending_jobs", "pending_boot_id", "unlock_attempts"):
            state.pop(k, None)
    elif action == "complete":
        add_event(state, dict(ev, result="up_late", woke_at=state.get("pending_wake_ts"),
                              boot_id=state.get("pending_boot_id")))
        for k in ("pending_wake_ts", "pending_jobs", "pending_boot_id", "unlock_attempts"):
            state.pop(k, None)
    elif action in ("wake", "unlock"):
        if action == "wake":
            webhook_id = read_secret(unlock_dir + "/webhook_id")
            status = ha_wake(cfg("HA_URL"), webhook_id, len(jobs))
            state["wakes_today"] = state.get("wakes_today", 0) + 1
            state["pending_wake_ts"] = now
            state["unlock_attempts"] = 0
            state["pending_jobs"] = [{"repo": j["_repo"], "id": j.get("id"), "name": j.get("name")} for j in jobs]
            log("HA webhook answered %s; waiting for the unlock server" % status)
            kube.save(state, rv)
            state, rv = kube.load()
            if not wait_port(ip, unlock_port, WAIT_UNLOCK_PORT_S):
                log("no unlock server yet; a later run continues while the wake is ours")
                kube.save(state, rv)
                return 0
        keyfile = "/tmp/unlock_key"
        with open(os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            f.write(read_secret(unlock_dir + "/privateKey") + "\n")
        state["unlock_attempts"] = state.get("unlock_attempts", 0) + 1
        rc, boot_id = unlock(ip, unlock_port, keyfile, known_hosts,
                             read_secret(unlock_dir + "/luks_passphrase"))
        state["pending_boot_id"] = boot_id
        up = wait_port(ip, 22, WAIT_SSH_S)
        add_event(state, dict(ev, result="ok" if up and boot_id else ("unlock_failed" if rc else "no_ssh"),
                              ssh_rc=rc, boot_id=boot_id, woke_at=state.get("pending_wake_ts"),
                              jobs=state.get("pending_jobs", []), wakes_today=state.get("wakes_today")))
        if up:
            for k in ("pending_wake_ts", "pending_jobs", "pending_boot_id", "unlock_attempts"):
                state.pop(k, None)
    kube.save(state, rv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
