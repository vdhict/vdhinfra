"""Unit tests for the waker's pure logic (kubernetes/main/apps/devtools/vdhwslin01-waker/app/controller.py).
Run: python3 tests/test_controller.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..",
                                "kubernetes", "main", "apps", "devtools", "vdhwslin01-waker", "app"))
import controller as c  # noqa: E402

NOW = 2_000_000_000


def st(**kw):
    s = {"day": c.local_day(NOW), "wakes_today": 0}
    s.update(kw)
    return s


class Decide(unittest.TestCase):
    def d(self, state, jobs=1, box="off", key=True, cap=4):
        return c.decide(NOW, state, jobs, box, key, cap)[0]

    def test_wake_when_jobs_and_box_off(self):
        self.assertEqual(self.d(st()), "wake")

    def test_no_jobs_no_wake(self):
        self.assertEqual(self.d(st(), jobs=0), "none")

    def test_box_up_never_touched(self):
        self.assertEqual(self.d(st(), box="up"), "none")

    def test_sander_boot_at_unlock_prompt_left_alone(self):
        self.assertEqual(self.d(st(), box="unlock"), "none")

    def test_our_wake_at_unlock_prompt_gets_unlocked(self):
        self.assertEqual(self.d(st(pending_wake_ts=NOW - 120), box="unlock"), "unlock")

    def test_unlock_attempts_bounded(self):
        self.assertEqual(self.d(st(pending_wake_ts=NOW - 120, unlock_attempts=2), box="unlock"), "none")

    def test_stale_pending_at_unlock_prompt_left_alone(self):
        self.assertEqual(self.d(st(pending_wake_ts=NOW - c.PENDING_TTL_S - 1), box="unlock"), "none")

    def test_no_rewake_within_10_min(self):
        self.assertEqual(self.d(st(pending_wake_ts=NOW - 300)), "none")

    def test_pending_expires_into_one_event(self):
        self.assertEqual(self.d(st(pending_wake_ts=NOW - c.PENDING_TTL_S)), "expire")

    def test_refuse_without_pinned_host_key(self):
        self.assertEqual(self.d(st(), key=False), "refuse")

    def test_cap_hit_once_per_day(self):
        s = st(wakes_today=4)
        self.assertEqual(self.d(s), "cap_hit")
        s["cap_notified_day"] = s["day"]
        self.assertEqual(self.d(s), "none")

    def test_box_up_after_our_wake_completes(self):
        self.assertEqual(self.d(st(pending_wake_ts=NOW - 400), box="up"), "complete")


class TokenExpiry(unittest.TestCase):
    def day(self, n):
        from datetime import datetime, timedelta
        return (datetime.fromtimestamp(NOW, c.LOCAL_TZ).date() + timedelta(days=n)).strftime("%Y-%m-%d")

    def test_ok(self):
        self.assertEqual(c.token_status(NOW, self.day(90)), ("ok", 90))

    def test_expiring_within_14_days(self):
        self.assertEqual(c.token_status(NOW, self.day(14))[0], "expiring")

    def test_expires_on_the_day_after(self):
        self.assertEqual(c.token_status(NOW, self.day(0))[0], "expiring")
        self.assertEqual(c.token_status(NOW, self.day(-1))[0], "expired")

    def test_missing_or_garbled_is_expired(self):
        self.assertEqual(c.token_status(NOW, None)[0], "expired")
        self.assertEqual(c.token_status(NOW, "soon")[0], "expired")


class Helpers(unittest.TestCase):
    def test_roll_day_resets_count(self):
        s = c.roll_day({"day": "2000-01-01", "wakes_today": 4}, NOW)
        self.assertEqual(s["wakes_today"], 0)
        self.assertEqual(s["day"], c.local_day(NOW))

    def test_roll_day_keeps_count_same_day(self):
        s = c.roll_day(st(wakes_today=3), NOW)
        self.assertEqual(s["wakes_today"], 3)

    def test_matching_jobs_label_subset_only(self):
        jobs = [{"status": "waiting", "runs_on": ["docker"]},
                {"status": "waiting", "runs_on": ["macos-arm64"]},
                {"status": "running", "runs_on": ["docker"]},
                {"status": "waiting", "runs_on": ["docker", "x86-linux"]},
                {"status": "waiting", "runs_on": []}]
        self.assertEqual(len(c.matching_jobs(jobs, ["docker", "x86-linux"])), 2)

    def test_parse_boot_id(self):
        out = "Enter passphrase:\nvdh-teamboot: started_by=team boot_id=0b5e1d2c-1111-2222-3333-444455556666\n"
        self.assertEqual(c.parse_boot_id(out), "0b5e1d2c-1111-2222-3333-444455556666")
        self.assertIsNone(c.parse_boot_id("No key available with this passphrase."))

    def test_events_bounded(self):
        s = {}
        for i in range(c.MAX_EVENTS + 5):
            c.add_event(s, {"i": i})
        self.assertEqual(len(s["events"]), c.MAX_EVENTS)
        self.assertEqual(s["events"][0]["i"], 5)


if __name__ == "__main__":
    unittest.main()
