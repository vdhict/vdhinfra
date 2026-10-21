#!/usr/bin/env python3
"""Offline tests for kubernetes/main/apps/family-ai/hermes/profiel-3/cloud-spend-init.py (Argus W6 + W2b).

    python3 -I hack/family-ai/test_cloud_spend_init.py [-v]

Each case runs the guard in a subprocess on a temp spend dir + temp settings.json (price_confirmed true).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = Path(os.environ.get("C010_GUARD") or ROOT / "kubernetes/main/apps/family-ai/hermes/profiel-3/cloud-spend-init.py")   # override: mutation runs only
SETTINGS = {"provider": "anthropic", "price_confirmed": True, "budget_usd": 200}


class Guard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name) / "spend"
        self.d.mkdir()
        self.settings = Path(self.tmp.name) / "settings.json"
        self.settings.write_text(json.dumps(SETTINGS, indent=2) + "\n")

    def run_guard(self, month):
        r = subprocess.run([sys.executable, "-I", str(GUARD), str(self.d), str(self.settings), month],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)    # never blocks the pod: Hermes still serves on the Studio
        self.assertEqual(r.stderr, "")
        return r.stdout

    def ledger(self):
        return json.loads((self.d / "month.json").read_text())

    def marker(self):
        return json.loads((self.d / ".ledger-marker").read_text())

    def cloud_on(self):
        return json.loads(self.settings.read_text())["price_confirmed"] is True

    def spend(self, usd):
        led = self.ledger()
        led["usd"] = usd
        led["person_usd"]["profiel-3"] = usd
        led["input_tokens"] = 1234
        (self.d / "month.json").write_text(json.dumps(led))

    def test_fresh_pvc_creates_ledger_and_marker(self):
        out = self.run_guard("2026-10")
        self.assertIn("created (fresh PVC)", out)
        self.assertEqual(self.ledger()["month"], "2026-10")
        self.assertEqual(self.ledger()["usd"], 0)
        self.assertEqual(self.marker(), {"month": "2026-10", "inits": 1})
        self.assertTrue(self.cloud_on())

    def test_restart_keeps_ledger_byte_equal(self):
        self.run_guard("2026-10")
        self.spend(12.5)
        before = (self.d / "month.json").read_bytes()
        out = self.run_guard("2026-10")
        self.assertIn("present, kept", out)
        self.assertEqual((self.d / "month.json").read_bytes(), before)
        self.assertEqual(self.marker(), {"month": "2026-10", "inits": 2})
        self.assertTrue(self.cloud_on())

    def test_mid_month_deletion_refuses(self):
        self.run_guard("2026-10")
        self.spend(150.0)
        os.unlink(self.d / "month.json")
        out = self.run_guard("2026-10")
        self.assertIn("REFUSED ledger-missing-mid-month", out)
        self.assertFalse((self.d / "month.json").exists(), "must not re-create mid-month")
        self.assertFalse(self.cloud_on(), "price_confirmed must be false")
        # and again on the next start (seed-once restores settings.json; the guard refuses again)
        self.settings.write_text(json.dumps(SETTINGS, indent=2) + "\n")
        self.assertIn("REFUSED ledger-missing-mid-month", self.run_guard("2026-10"))
        self.assertFalse(self.cloud_on())

    def test_month_change_recreates(self):
        self.run_guard("2026-10")
        os.unlink(self.d / "month.json")
        out = self.run_guard("2026-11")
        self.assertIn("created (month change)", out)
        self.assertEqual(self.ledger()["month"], "2026-11")
        self.assertEqual(self.marker(), {"month": "2026-11", "inits": 2})
        self.assertTrue(self.cloud_on())

    def test_corrupt_ledger_refuses_and_is_kept(self):
        self.run_guard("2026-10")
        (self.d / "month.json").write_text('{"month": "2026-10", "usd": ')
        before = (self.d / "month.json").read_bytes()
        out = self.run_guard("2026-10")
        self.assertIn("REFUSED ledger-corrupt", out)
        self.assertEqual((self.d / "month.json").read_bytes(), before, "never overwritten")
        self.assertFalse(self.cloud_on())

    def test_wrong_schema_ledger_refuses(self):
        self.run_guard("2026-10")
        led = self.ledger()
        led["usd"] = -1
        (self.d / "month.json").write_text(json.dumps(led))
        self.assertIn("REFUSED ledger-corrupt", self.run_guard("2026-10"))
        self.assertFalse(self.cloud_on())

    def test_corrupt_marker_refuses(self):
        self.run_guard("2026-10")
        (self.d / ".ledger-marker").write_text("not json")
        os.unlink(self.d / "month.json")
        self.assertIn("REFUSED marker-corrupt", self.run_guard("2026-10"))
        self.assertFalse((self.d / "month.json").exists())
        self.assertFalse(self.cloud_on())

    def test_future_marker_refuses(self):
        self.run_guard("2026-11")
        os.unlink(self.d / "month.json")
        self.assertIn("REFUSED marker-future", self.run_guard("2026-10"))
        self.assertFalse(self.cloud_on())

    def test_existing_ledger_without_marker_is_adopted(self):
        self.run_guard("2026-10")
        self.spend(3.0)
        os.unlink(self.d / ".ledger-marker")
        before = (self.d / "month.json").read_bytes()
        self.assertIn("present, kept", self.run_guard("2026-10"))
        self.assertEqual((self.d / "month.json").read_bytes(), before)
        self.assertEqual(self.marker(), {"month": "2026-10", "inits": 1})
        self.assertTrue(self.cloud_on())

    def test_log_lines_are_content_free(self):
        self.run_guard("2026-10")
        self.spend(42.0)
        os.unlink(self.d / "month.json")
        out = self.run_guard("2026-10") + self.run_guard("2026-11")
        for line in out.splitlines():
            self.assertTrue(line.startswith("cloud-spend-init: "))
            self.assertNotIn("42", line)
            self.assertNotIn("usd", line.lower())

    def test_create_never_overwrites_a_ledger_that_appeared_meanwhile(self):
        import importlib.util
        import contextlib
        import io
        led = self.d / "month.json"
        led.write_text('{"keep": "me"}')
        before = led.read_bytes()
        argv = sys.argv
        sys.argv = [str(GUARD), str(self.d), str(self.settings), "2026-10"]
        try:
            spec = importlib.util.spec_from_file_location("c010_guard", GUARD)
            g = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(g)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                g.create()
        finally:
            sys.argv = argv
        self.assertEqual(led.read_bytes(), before)
        self.assertIn("appeared meanwhile, kept", out.getvalue())
        self.assertFalse((self.d / "month.json.init").exists())

    def test_no_settings_file_still_refuses_safely(self):
        self.run_guard("2026-10")
        os.unlink(self.d / "month.json")
        os.unlink(self.settings)
        self.assertIn("cloud already off", self.run_guard("2026-10"))
        self.assertFalse((self.d / "month.json").exists())


if __name__ == "__main__":
    unittest.main()
