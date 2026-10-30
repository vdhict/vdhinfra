#!/usr/bin/env python3
"""Offline tests for kubernetes/main/apps/family-ai/hermes/cloud-spend/cloud-spend-init.py (chg-2026-10-20-010 W2c).

    python3 -I hack/family-ai/test_cloud_spend_shared.py [-v]

Each case runs the guard in a subprocess on a temp shared dir, a temp "old" (profiel-3 per-pod) dir and a temp
settings.json (price_confirmed true). No family data: synthetic numbers only.
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = Path(os.environ.get("C010_GUARD") or ROOT / "kubernetes/main/apps/family-ai/hermes/cloud-spend/cloud-spend-init.py")
SETTINGS = {"provider": "anthropic", "price_confirmed": True, "budget_usd": 99}
P3 = {"month": "2026-10", "usd": 0.441624, "input_tokens": 112882, "output_tokens": 1106, "cache_read_tokens": 0,
      "cache_write_tokens": 0, "person_usd": {"profiel-1": 0, "profiel-2": 0, "profiel-3": 0.441624}}
STICKY = {"v": 1, "salt": "a" * 64, "sessions": {}, "private": {}}


class Shared(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory()
        self.addCleanup(t.cleanup)
        base = Path(t.name)
        self.d, self.old = base / "shared", base / "old"
        self.d.mkdir()
        self.old.mkdir()
        self.settings = base / "settings.json"
        self.reset_settings()

    def reset_settings(self):
        self.settings.write_text(json.dumps(SETTINGS, indent=2) + "\n")

    def put_old(self, ledger=P3, marker={"month": "2026-10", "inits": 24}, sticky=True):
        (self.old / "month.json").write_text(json.dumps(ledger))
        (self.old / ".ledger-marker").write_text(json.dumps(marker) + "\n")
        if sticky:
            (self.old / "sticky-profiel-3.json").write_text(json.dumps(STICKY))

    def guard(self, month="2026-10", old=True, settings=None):
        r = subprocess.run([sys.executable, "-I", str(GUARD), str(self.d), str(settings or self.settings), month,
                            str(self.old) if old else "-"], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)    # never blocks the pod
        self.assertEqual(r.stderr, "")
        return r.stdout

    def on(self):
        return json.loads(self.settings.read_text())["price_confirmed"] is True

    def ledger(self):
        return json.loads((self.d / "month.json").read_text())

    def marker(self):
        return json.loads((self.d / ".ledger-marker").read_text())

    def move(self):
        self.put_old()
        out = self.guard()
        self.assertIn("moved:", out)
        return out

    # --- the move -------------------------------------------------------------------------------------------
    def test_p1_or_p2_before_the_move_refuses_and_creates_nothing(self):
        out = self.guard(old=False)
        self.assertIn("REFUSED not-seeded", out)
        self.assertFalse(self.on())
        self.assertFalse((self.d / "month.json").exists())
        self.assertFalse((self.d / ".ledger-seeded").exists())

    def test_move_copies_ledger_bytes_sticky_and_seeds(self):
        self.move()
        self.assertEqual((self.d / "month.json").read_bytes(), (self.old / "month.json").read_bytes())
        self.assertEqual((self.d / "sticky-profiel-3.json").read_bytes(), (self.old / "sticky-profiel-3.json").read_bytes())
        self.assertEqual(self.marker(), {"month": "2026-10", "inits": 25})
        seed = json.loads((self.d / ".ledger-seeded").read_text())
        self.assertEqual((seed["source"], seed["usd"], seed["month"]), ("migrated", 0.441624, "2026-10"))
        self.assertTrue(self.on())
        self.assertEqual(oct(os.stat(self.d / "month.json").st_mode & 0o777), "0o600")

    def test_move_never_touches_the_old_ledger(self):
        self.put_old()
        before = {p.name: p.read_bytes() for p in self.old.iterdir()}
        self.guard()
        self.assertEqual({p.name: p.read_bytes() for p in self.old.iterdir()}, before)

    def test_after_move_every_profile_keeps_the_shared_ledger(self):
        self.move()
        raw = (self.d / "month.json").read_bytes()
        for _ in ("profiel-1", "profiel-2", "profiel-3"):
            self.reset_settings()
            out = self.guard(old=False)
            self.assertIn("present, kept", out)
            self.assertTrue(self.on())
        self.assertEqual((self.d / "month.json").read_bytes(), raw)
        self.assertEqual(self.marker()["inits"], 28)

    def test_second_start_of_p3_does_not_move_again(self):
        self.move()
        led = self.ledger()
        led["usd"] = 5.5
        (self.d / "month.json").write_text(json.dumps(led))   # spend after the move
        self.reset_settings()
        out = self.guard()                                     # old dir still mounted
        self.assertIn("present, kept", out)
        self.assertEqual(self.ledger()["usd"], 5.5)

    def test_old_ledger_invalid_refuses(self):
        for bad in ({"month": "2026-10"}, dict(P3, usd=-1), dict(P3, month="2026-12"),
                    dict(P3, person_usd={"profiel-3": 1})):
            with self.subTest(bad=bad):
                self.setUp()
                self.put_old(ledger=bad)
                out = self.guard()
                self.assertIn("REFUSED old-ledger-invalid", out)
                self.assertFalse(self.on())
                self.assertFalse((self.d / "month.json").exists())

    def test_old_marker_missing_or_future_refuses(self):
        self.put_old()
        (self.old / ".ledger-marker").unlink()
        self.assertIn("REFUSED old-ledger-invalid", self.guard())
        self.setUp()
        self.put_old(marker={"month": "2026-12", "inits": 3})
        self.assertIn("REFUSED old-ledger-invalid", self.guard())

    def test_marker_without_seed_never_moves(self):
        """A marker is only written after the seed: a marker without one is a damaged volume, not a fresh one."""
        self.put_old()
        (self.d / ".ledger-marker").write_text(json.dumps({"month": "2026-10", "inits": 3}) + "\n")
        self.assertIn("REFUSED not-seeded", self.guard())
        self.assertFalse((self.d / "month.json").exists())

    def test_old_sticky_corrupt_refuses(self):
        self.put_old(sticky=False)
        (self.old / "sticky-profiel-3.json").write_text("{not json")
        self.assertIn("REFUSED old-sticky-invalid", self.guard())
        self.assertFalse((self.d / "month.json").exists())

    # --- after the seed -----------------------------------------------------------------------------------
    def test_ledger_missing_after_seed_is_never_recreated(self):
        self.move()
        (self.d / "month.json").unlink()
        for month in ("2026-10", "2026-11"):
            self.reset_settings()
            out = self.guard(month=month)
            self.assertIn("REFUSED ledger-missing", out)
            self.assertFalse(self.on())
            self.assertFalse((self.d / "month.json").exists())

    def test_ledger_without_seed_refuses(self):
        (self.d / "month.json").write_text(json.dumps(P3))
        self.assertIn("REFUSED ledger-without-seed", self.guard(old=False))
        self.assertFalse(self.on())

    def test_corrupt_ledger_marker_seed_refuse(self):
        self.move()
        for name, text, code in (("month.json", "{x", "ledger-corrupt"), (".ledger-marker", "[]", "marker-corrupt"),
                                 (".ledger-seeded", "{}", "seed-corrupt")):
            with self.subTest(name=name):
                keep = (self.d / name).read_text()
                (self.d / name).write_text(text)
                self.reset_settings()
                self.assertIn("REFUSED " + code, self.guard(old=False))
                self.assertFalse(self.on())
                (self.d / name).write_text(keep)

    def test_future_marker_and_bad_clock_refuse(self):
        self.move()
        (self.d / ".ledger-marker").write_text(json.dumps({"month": "2026-12", "inits": 3}))
        self.reset_settings()
        self.assertIn("REFUSED marker-future", self.guard(old=False))
        self.reset_settings()
        self.assertIn("REFUSED clock", self.guard(month="2026-13", old=False))

    def test_month_rollover_keeps_the_total(self):
        """2026-10 -> 2026-11: the guard keeps the ledger byte-for-byte (no reset, no new ledger)."""
        self.move()
        led = self.ledger()
        led["usd"] = 98.5
        (self.d / "month.json").write_text(json.dumps(led))
        raw = (self.d / "month.json").read_bytes()
        self.reset_settings()
        out = self.guard(month="2026-11", old=False)
        self.assertIn("present, kept", out)
        self.assertEqual((self.d / "month.json").read_bytes(), raw)
        self.assertEqual(self.marker()["month"], "2026-11")

    # --- concurrency ----------------------------------------------------------------------------------------
    def test_waits_for_the_plugin_lock(self):
        self.move()
        with open(self.d / "month.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            p = subprocess.Popen([sys.executable, "-I", str(GUARD), str(self.d), str(self.settings), "2026-10", "-"],
                                 stdout=subprocess.PIPE, text=True)
            time.sleep(1.0)
            self.assertIsNone(p.poll(), "guard did not wait for the lock")
            before = self.marker()["inits"]
        out, _ = p.communicate(timeout=30)
        self.assertIn("present, kept", out)
        self.assertEqual(self.marker()["inits"], before + 1)

    def test_three_profiles_start_at_once(self):
        self.put_old()
        settings = []
        procs = []
        for n, old in ((1, False), (2, False), (3, True)):
            s = self.d.parent / f"settings-{n}.json"
            s.write_text(json.dumps(SETTINGS, indent=2) + "\n")
            settings.append(s)
            procs.append(subprocess.Popen([sys.executable, "-I", str(GUARD), str(self.d), str(s), "2026-10",
                                           str(self.old) if old else "-"], stdout=subprocess.PIPE, text=True))
        outs = [p.communicate(timeout=30)[0] for p in procs]
        self.assertEqual(sum("moved:" in o for o in outs), 1)
        self.assertIn("moved:", outs[2])
        self.assertEqual((self.d / "month.json").read_bytes(), (self.old / "month.json").read_bytes())
        for o, s in zip(outs[:2], settings[:2]):   # p1/p2: kept if after the move, refused (cloud off) if before
            on = json.loads(s.read_text())["price_confirmed"]
            self.assertTrue(("present, kept" in o and on) or ("REFUSED not-seeded" in o and not on), o)
        self.assertFalse(list(self.d.glob("*.new")) + list(self.d.glob("*.init")))


if __name__ == "__main__":
    unittest.main()
