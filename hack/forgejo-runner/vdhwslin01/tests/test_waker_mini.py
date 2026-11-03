"""Tests for mini/vdhwslin01-waker.py (chg-2026-10-05-031 revive, 2026-11-03).
Pure decision logic + full ticks against a fake I/O (no network, no box, no forge, no HA).
Run: python3 tests/test_waker_mini.py   (also /usr/bin/python3, 3.9)"""
import importlib.util
import io as _io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="waker-test-")
os.environ["WAKER_CONF_DIR"] = os.path.join(TMP, "conf")
os.environ["WAKER_KNOWN_HOSTS"] = os.path.join(TMP, "no-known-hosts")      # forces no_host_key in RealIO
os.environ["AIOPS_ENV"] = os.path.join(TMP, "ntfy.env")
with open(os.environ["AIOPS_ENV"], "w") as _f:
    _f.write("NTFY_SERVER=https://ntfy.example.invalid\nNTFY_ALERT_TOPIC=topic-SENTINEL\n")
CURL_LOG = os.path.join(TMP, "curl.log")
STUB = os.path.join(TMP, "curl-stub")
with open(STUB, "w") as _f:   # records argv and stdin, answers like curl -w '%{http_code}'
    _f.write("#!/bin/sh\n{ echo \"ARGV: $*\"; printf 'STDIN: '; cat; echo; } >> '%s'\nprintf 200\n" % CURL_LOG)
os.chmod(STUB, 0o755)
os.environ["WAKER_TEST_CURL"] = STUB
os.makedirs(os.environ["WAKER_CONF_DIR"], exist_ok=True)
spec = importlib.util.spec_from_file_location("waker", os.path.join(HERE, "..", "mini", "vdhwslin01-waker.py"))
w = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(w)

DAY = int(datetime(2026, 11, 4, 14, 0, tzinfo=w.LOCAL_TZ).timestamp())      # 14:00 local
NIGHT = int(datetime(2026, 11, 4, 2, 0, tzinfo=w.LOCAL_TZ).timestamp())     # 02:00 local
SECRET = "S3NTINEL-PASSPHRASE-VALUE-never-printed"


def st(now=DAY, **kw):
    s = {"day": w.local_day(now), "wakes_today": 0}
    s.update(kw)
    return s


class FakeIO:
    """Scripted box: ports is a function of fake time; records every side effect."""

    def __init__(self, now=DAY, jobs=None, ports=None, host_key=True, webhook=200,
                 unlock_out="vdh-teamboot: started_by=team boot_id=0b5e1d2c-1111-2222-3333-444455556666\n",
                 query_error=False):
        self.t = now
        self.jobs = jobs if jobs is not None else [(["docker"], now - 300, 5)]
        self.ports = ports or (lambda io, p: False)
        self.host_key = host_key
        self.webhook = webhook
        self.unlock_out = unlock_out
        self.query_error = query_error
        self.events, self.notes, self.webhooks, self.unlocks, self.persisted = [], [], [], 0, 0
        self.unlocked_at = None

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def persist(self, state):
        self.persisted += 1

    def port_open(self, p):
        return self.ports(self, p)

    def has_host_key(self):
        return self.host_key

    def query_jobs(self):
        if self.query_error:
            raise RuntimeError("psql rc=2")
        return self.jobs

    def post_webhook(self, n):
        self.webhooks.append(n)
        self.woke_at = self.t
        return self.webhook

    def unlock(self):
        self.unlocks += 1
        self.unlocked_at = self.t
        return 0, self.unlock_out

    def event(self, ev, payload):
        self.events.append((ev, payload))

    def notify(self, title, body, night):
        self.notes.append((title, body, night))


def box_boots(prompt_after=60, ssh_after_unlock=20):
    """Box off until our webhook; 2222 after prompt_after s; 22 ssh_after_unlock s after unlock."""
    def ports(io, p):
        woke = getattr(io, "woke_at", None)
        if p == 22:
            return io.unlocked_at is not None and io.t >= io.unlocked_at + ssh_after_unlock
        if p == w.UNLOCK_PORT:
            return woke is not None and io.t >= woke + prompt_after and io.unlocked_at is None
        return False
    return ports


def run(io, state, dry=False):
    buf = _io.StringIO()
    with redirect_stdout(buf):
        a = w.tick(io, state, dry=dry)
    return a, buf.getvalue()


class Decide(unittest.TestCase):
    def d(self, state, n=1, age=60, box="off", key=True):
        return w.decide(DAY, state, n, age, box, key)[0]

    def test_wake_when_jobs_and_box_off(self):
        self.assertEqual(self.d(st()), "wake")

    def test_no_jobs_no_wake(self):
        self.assertEqual(self.d(st(), n=0), "none")

    def test_box_up_never_touched(self):
        self.assertEqual(self.d(st(), box="up"), "none")

    def test_box_up_jobs_stuck_reported(self):
        self.assertEqual(self.d(st(), box="up", age=w.STUCK_AFTER_S), "stuck")

    def test_queued_behind_a_running_job_is_not_stuck(self):
        self.assertEqual(w.decide(DAY, st(), 1, w.STUCK_AFTER_S, "up", True, n_running=1)[0], "none")

    def test_foreign_prompt_left_alone_but_reported_if_jobs(self):
        self.assertEqual(self.d(st(), box="unlock"), "foreign_prompt")
        self.assertEqual(self.d(st(), box="unlock", n=0), "none")

    def test_our_prompt_unlocked(self):
        self.assertEqual(self.d(st(pending_wake_ts=DAY - 120), box="unlock"), "unlock")

    def test_unlock_attempts_bounded(self):
        self.assertEqual(self.d(st(pending_wake_ts=DAY - 120, unlock_attempts=2), box="unlock"), "none")

    def test_expired_wake_at_prompt_is_expire_not_foreign(self):
        self.assertEqual(self.d(st(pending_wake_ts=DAY - w.PENDING_TTL_S), box="unlock"), "expire")

    def test_no_second_wake_while_pending(self):
        self.assertEqual(self.d(st(pending_wake_ts=DAY - 300)), "none")

    def test_expire(self):
        self.assertEqual(self.d(st(pending_wake_ts=DAY - w.PENDING_TTL_S)), "expire")

    def test_refuse_without_host_key(self):
        self.assertEqual(self.d(st(), key=False), "refuse")

    def test_cap(self):
        self.assertEqual(self.d(st(wakes_today=4)), "cap_hit")

    def test_complete(self):
        self.assertEqual(self.d(st(pending_wake_ts=DAY - 400), box="up"), "complete")


class Helpers(unittest.TestCase):
    def test_labels_subset_only(self):
        rows = [(["docker"], 1, 5), (["macos-arm64"], 2, 5), (["docker", "x86-linux"], 3, 5), ([], 4, 5),
                (["docker", "gpu"], 5, 5), (["docker"], 6, 6)]
        self.assertEqual(w.matching_jobs(rows), [1, 3])
        self.assertEqual(w.matching_jobs(rows, status=6), [6])

    def test_parse_rows_psql_output(self):
        self.assertEqual(w.parse_rows('["docker"]\t1762094664\t5\n\n["x86-linux"]\t1762094700\t6\n'),
                         [(["docker"], 1762094664, 5), (["x86-linux"], 1762094700, 6)])

    def test_night_window(self):
        self.assertTrue(w.is_night(NIGHT))
        self.assertFalse(w.is_night(DAY))
        self.assertTrue(w.is_night(int(datetime(2026, 11, 4, 23, 0, tzinfo=w.LOCAL_TZ).timestamp())))
        self.assertFalse(w.is_night(int(datetime(2026, 11, 4, 7, 0, tzinfo=w.LOCAL_TZ).timestamp())))
        self.assertFalse(w.is_night(int(datetime(2026, 11, 4, 22, 59, tzinfo=w.LOCAL_TZ).timestamp())))
        self.assertTrue(w.is_night(int(datetime(2026, 11, 4, 6, 59, tzinfo=w.LOCAL_TZ).timestamp())))

    def test_roll_day(self):
        self.assertEqual(w.roll_day({"day": "2000-01-01", "wakes_today": 4}, DAY)["wakes_today"], 0)

    def test_query_is_read_only_and_org_scoped(self):
        self.assertTrue(w.QUERY_SQL.lstrip().upper().startswith("SELECT"))
        self.assertIn("lower_name = 'vdhict'", w.QUERY_SQL)
        self.assertIn("status IN (5, 6)", w.QUERY_SQL)


class Ticks(unittest.TestCase):
    def test_full_wake_unlock_up(self):
        io, s = FakeIO(ports=box_boots()), st()
        a, out = run(io, s)
        self.assertEqual(a, "wake")
        self.assertEqual(io.webhooks, [1])
        self.assertEqual(io.unlocks, 1)
        self.assertEqual(io.persisted, 1)
        evs = [(e, p.get("result")) for e, p in io.events]
        self.assertEqual(evs, [("executed", "wake_sent"), ("validated", "up")])
        self.assertEqual(io.events[1][1]["boot_id"], "0b5e1d2c-1111-2222-3333-444455556666")
        self.assertNotIn("pending_wake_ts", s)
        self.assertEqual(s["wakes_today"], 1)
        self.assertEqual(io.notes, [])

    def test_wol_fails_one_line_one_ntfy_then_hourly(self):
        io, s = FakeIO(), st()                      # box never answers
        run(io, s)
        self.assertEqual(io.webhooks, [1])
        self.assertIn("pending_wake_ts", s)
        io.t += w.PENDING_TTL_S                     # next ticks: expire
        run(io, s)
        fails = [p for e, p in io.events if p.get("result") == "wake_failed"]
        self.assertEqual([f["reason"] for f in fails], ["no_unlock_prompt"])
        self.assertEqual(len(io.notes), 1)
        self.assertFalse(io.notes[0][2])            # daytime: not silent
        # the job still waits -> new wake (count 2), fails again within the hour -> line suppressed
        run(io, s)
        io.t += w.PENDING_TTL_S
        run(io, s)
        self.assertEqual(len([p for e, p in io.events if p.get("result") == "wake_failed"]), 1)
        # an hour after the first report it is reported again
        io.t = s["last_fail"]["no_unlock_prompt"] + w.NOTIFY_EVERY_S
        s["pending_wake_ts"] = io.t - w.PENDING_TTL_S
        run(io, s)
        self.assertEqual(len([p for e, p in io.events if p.get("result") == "wake_failed"]), 2)
        self.assertEqual(len(io.notes), 2)

    def test_night_failure_is_silent_priority(self):
        io, s = FakeIO(now=NIGHT, host_key=False), st(NIGHT)
        run(io, s)
        self.assertEqual(io.notes[0][2], True)
        self.assertEqual(io.events[0][1]["reason"], "no_host_key")
        self.assertEqual(io.webhooks, [])

    def test_passphrase_rejected(self):
        io, s = FakeIO(ports=box_boots(), unlock_out="No key available with this passphrase.\n"), st()
        run(io, s)
        self.assertEqual([p["reason"] for e, p in io.events if p.get("result") == "wake_failed"],
                         ["passphrase_rejected"])
        self.assertNotIn("pending_wake_ts", s)

    def test_no_ssh_after_unlock_reported_once_not_twice(self):
        def ports(io, p):
            return p == w.UNLOCK_PORT and getattr(io, "woke_at", None) is not None   # prompt stays
        io, s = FakeIO(ports=ports, unlock_out=""), st()
        run(io, s)                                   # wake + unlock 1, 22 never up
        run(io, s)                                   # unlock 2 -> report
        io.t = s["pending_wake_ts"] + w.PENDING_TTL_S
        run(io, s)                                   # expire: already reported, quiet
        reasons = [p["reason"] for e, p in io.events if p.get("result") == "wake_failed"]
        self.assertEqual(reasons, ["no_ssh_after_unlock"])
        self.assertEqual(io.unlocks, 2)

    def test_cap_reached_reported(self):
        io, s = FakeIO(), st(wakes_today=4)
        run(io, s)
        self.assertEqual(io.events[0][1]["reason"], "cap_reached")
        self.assertEqual(io.webhooks, [])

    def test_webhook_error_reported(self):
        io, s = FakeIO(webhook=404), st()
        run(io, s)
        self.assertEqual(io.events[0][1]["reason"], "webhook_error")
        self.assertNotIn("pending_wake_ts", s)
        self.assertEqual(s["wakes_today"], 0)

    def test_running_box_never_touched(self):
        io, s = FakeIO(ports=lambda io, p: p == 22), st()
        a, _ = run(io, s)
        self.assertEqual((a, io.webhooks, io.unlocks, io.events), ("none", [], 0, []))

    def test_foreign_prompt_never_unlocked(self):
        io, s = FakeIO(ports=lambda io, p: p == w.UNLOCK_PORT), st()
        run(io, s)
        self.assertEqual(io.unlocks, 0)
        self.assertEqual(io.events[0][1]["reason"], "foreign_prompt_jobs_waiting")

    def test_stuck_jobs_with_box_up(self):
        io, s = FakeIO(ports=lambda io, p: p == 22, jobs=[(["docker"], DAY - 3600, 5)]), st()
        run(io, s)
        self.assertEqual(io.events[0][1]["reason"], "jobs_stuck_box_up")

    def test_query_failure_never_wakes_and_reports_after_grace(self):
        io, s = FakeIO(query_error=True), st()
        run(io, s)
        self.assertEqual((io.webhooks, io.events), ([], []))
        io.t += w.QUERY_FAIL_GRACE_S
        run(io, s)
        self.assertEqual(io.events[0][1]["reason"], "queue_unreadable")
        self.assertEqual(io.webhooks, [])

    def test_dry_run_has_no_side_effects(self):
        io, s = FakeIO(ports=box_boots()), st()
        a, _ = run(io, s, dry=True)
        self.assertEqual(a, "wake")
        self.assertEqual((io.webhooks, io.unlocks, io.events, io.notes, io.persisted), ([], 0, [], [], 0))

    def test_secret_never_in_output_or_events(self):
        # RealIO reads the passphrase itself; here we assert no code path echoes unlock output.
        io, s = FakeIO(ports=box_boots(), unlock_out=SECRET + "\nvdh-teamboot: started_by=team "
                       "boot_id=0b5e1d2c-1111-2222-3333-444455556666\n"), st()
        _, out = run(io, s)
        blob = out + json.dumps(io.events) + json.dumps(io.notes) + json.dumps(s)
        self.assertNotIn(SECRET, blob)


def fresh_changes():
    d = tempfile.mkdtemp(dir=TMP)
    os.makedirs(os.path.join(d, "ops"))
    p = os.path.join(d, "ops", "changes.jsonl")
    open(p, "w").close()
    return p


def curl_calls():
    try:
        with open(CURL_LOG) as f:
            return [l for l in f if l.startswith("ARGV: ")]
    except OSError:
        return []


class ScriptedRealIO(w.RealIO):
    """RealIO with the REAL change-log writer and REAL ntfy path (stub curl);
    only time, ports and the forge query are scripted."""
    def __init__(self, changes, t):
        super().__init__(False, "/usr/bin/true", changes)
        self.t = t

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def port_open(self, p):
        return False

    def query_jobs(self):
        return [(["docker"], self.t - 600, 5)]

    def persist(self, state):
        pass


class C7Readback(unittest.TestCase):
    """Argus C7: forced no_host_key -> exactly 1 change-log line + 1 ntfy, via the real writers."""
    def setUp(self):
        if os.path.exists(CURL_LOG):
            os.replace(CURL_LOG, CURL_LOG + ".%d" % id(self))

    def test_forced_no_host_key_one_line_one_ntfy(self):
        ch = fresh_changes()
        io, s = ScriptedRealIO(ch, DAY), st()
        for _ in range(3):                      # three ticks, 2 min apart, within the hour
            with redirect_stdout(_io.StringIO()):
                self.assertEqual(w.tick(io, s), "refuse")
            io.t += 120
        lines = open(ch).read().splitlines()
        self.assertEqual(len(lines), 1)
        ev = json.loads(lines[0])
        self.assertEqual((ev["chg"], ev["event"], ev["actor"]), (w.CHG, "executed", "k8s-engineer"))
        self.assertEqual((ev["payload"]["result"], ev["payload"]["reason"]), ("wake_failed", "no_host_key"))
        # byte-identical to ops/ops append_event formatting
        self.assertEqual(lines[0], json.dumps(ev, separators=(",", ":"), ensure_ascii=False, sort_keys=True))
        calls = curl_calls()
        self.assertEqual(len(calls), 1)
        self.assertIn("Priority: 3", calls[0])
        self.assertNotIn("topic-SENTINEL", calls[0])          # topic only via -K - on stdin
        self.assertIn("topic-SENTINEL", open(CURL_LOG).read())
        self.assertEqual(io_webhooks_of(io), 0)

    def test_after_an_hour_reported_again(self):
        ch = fresh_changes()
        io, s = ScriptedRealIO(ch, DAY), st()
        with redirect_stdout(_io.StringIO()):
            w.tick(io, s)
            io.t += w.NOTIFY_EVERY_S
            w.tick(io, s)
        self.assertEqual(len(open(ch).read().splitlines()), 2)
        self.assertEqual(len(curl_calls()), 2)


def io_webhooks_of(io):
    with open(CURL_LOG) as f:
        return sum("/api/webhook/" in l for l in f.read().splitlines() if l.startswith("STDIN"))


class SelfCheck(unittest.TestCase):
    """Argus B4: sha256 pin, absolute kubectl, pinned change log; refuse + one line on mismatch."""
    SRC = os.path.join(HERE, "..", "mini", "vdhwslin01-waker.py")

    def args(self, **kw):
        a = {"dry": False, "expect": w.file_sha256(self.SRC), "kubectl": "/usr/bin/true", "changes": fresh_changes()}
        a.update(kw)
        return a

    def test_valid_pin_passes(self):
        self.assertIsNone(w.self_check(self.args(), self.SRC))

    def test_wrong_or_missing_pin_refused(self):
        self.assertIn("!= pin", w.self_check(self.args(expect="0" * 64), self.SRC))
        self.assertIn("no valid", w.self_check(self.args(expect=None), self.SRC))
        self.assertIn("no valid", w.self_check(self.args(expect="abc"), self.SRC))

    def test_relative_kubectl_refused(self):
        self.assertIn("--kubectl", w.self_check(self.args(kubectl="kubectl"), self.SRC))

    def test_changes_log_must_be_ops_changes_jsonl(self):
        self.assertIn("--changes-log", w.self_check(self.args(changes=os.path.join(TMP, "x.jsonl")), self.SRC))
        self.assertIn("--changes-log", w.self_check(self.args(changes="ops/changes.jsonl"), self.SRC))

    def test_main_with_bad_pin_refuses_one_line_one_ntfy(self):
        if os.path.exists(CURL_LOG):
            os.replace(CURL_LOG, CURL_LOG + ".sc")
        ch = fresh_changes()
        argv = ["--expect-sha256", "0" * 64, "--kubectl", "/usr/bin/true", "--changes-log", ch]
        with redirect_stdout(_io.StringIO()):
            self.assertEqual(w.main(argv), 3)
            self.assertEqual(w.main(argv), 3)              # second start within the hour: no new line
        lines = open(ch).read().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0])["payload"]["reason"], "self_check_failed")
        self.assertEqual(len(curl_calls()), 1)


class HACapModel(unittest.TestCase):
    """The HA package's cap logic, read from ha/vdhwslin01_wake.yaml (no PyYAML on macOS python):
    the 5th POST in a day must be refused. The LIVE proof is mini/ha-cap-readback.sh after install."""
    src = open(os.path.join(HERE, "..", "ha", "vdhwslin01_wake.yaml")).read()

    def test_structure(self):
        self.assertIn("local_only: true", self.src)
        self.assertIn("allowed_methods: [POST]", self.src)
        self.assertIn("int(99) < 4", self.src)               # unknown/unavailable counter -> 99 -> refuse
        self.assertLess(self.src.index("counter.increment"), self.src.index("button.press"))
        self.assertIn("team wake refused: daily cap 4 reached", self.src)
        self.assertIn('at: "00:00:00"', self.src)
        self.assertIn("counter.reset", self.src)

    def test_fifth_post_refused(self):
        import re as _re
        cap = int(_re.search(r"int\(99\) < (\d+)", self.src).group(1))
        counter, presses, refused = 0, 0, 0
        for _ in range(5):                                    # the automation's choose/default, step by step
            if counter < cap:
                counter += 1
                presses += 1
            else:
                refused += 1
        self.assertEqual((counter, presses, refused), (4, 4, 1))


class RealIOStatic(unittest.TestCase):
    """Static guarantees of the real I/O layer (no execution against anything)."""
    src = open(os.path.join(HERE, "..", "mini", "vdhwslin01-waker.py")).read()

    def test_secrets_only_via_stdin(self):
        self.assertIn('"-K", "-"]', self.src)                 # webhook URL + ntfy topic via curl config on stdin
        self.assertIn("input=secret + b\"\\n\"", self.src)     # passphrase as ssh stdin
        self.assertNotIn("print(secret", self.src)
        self.assertNotIn("log(secret", self.src)

    def test_unlock_uses_pinned_alias(self):
        self.assertIn('UNLOCK_ALIAS = "vdhwslin01-unlock"', self.src)
        self.assertNotIn("StrictHostKeyChecking=no", self.src)

    def test_night_ntfy_is_priority_1(self):
        # AGR-074: 23:00-07:00 no sound/vibration -> ntfy priority 1 + "[night]" title
        self.assertIn('prio = "1" if night else "3"', self.src)
        self.assertIn('title = "[night] " + title', self.src)

    def test_no_working_tree_code_and_pinned_context(self):
        self.assertNotIn('"ops", "ops"', self.src)            # never executes ops/ops from a checkout
        self.assertIn('KUBE_CONTEXT = "admin@vdhinfra-local"', self.src)
        self.assertIn('[self.kubectl, "--context", KUBE_CONTEXT]', self.src)
        self.assertNotIn("glob", self.src)                    # no kubectl discovery at run time

    def test_read_only_transaction(self):
        self.assertIn("SET default_transaction_read_only = on", self.src)


if __name__ == "__main__":
    unittest.main()
