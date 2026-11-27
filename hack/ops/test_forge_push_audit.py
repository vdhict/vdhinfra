#!/usr/bin/env python3
"""Offline tests for the posture-scan forge push audit (chg-2026-11-13-002 L5) and the pin-guard alert route
(Argus wq-103 C3 G5/G6). Log lines have the real Forgejo 15 router format (devtools/forgejo, 2026-11-27).

    python3 -I hack/ops/test_forge_push_audit.py [-v]      # stdlib only
"""
import datetime as dt
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "kubernetes/main/apps/observability/cluster-health/app"
sys.path.insert(0, str(APP / "scripts"))
_DATA = tempfile.TemporaryDirectory()          # lib.py makes its dirs under DATA_DIR at import time
os.environ["DATA_DIR"] = _DATA.name
import ops_security_scan as scan  # noqa: E402

T0 = dt.datetime(2026, 11, 27, 10, 0, tzinfo=dt.timezone.utc).timestamp()
REG = {"keys": [{"repo": "VDHICT/cluster-wires", "status": "active", "public_key_id": 31},
                {"repo": "VDHICT/print3d", "status": "planned", "public_key_id": None}]}


def serv(t, key, repo, status=200, verb="git-receive-pack", mode=2):
    return (T0 + t, f"2026/11/27 10:00:00 ...eb/routing/logger.go:109:func1() [I] router: completed GET "
                    f"/api/internal/serv/command/{key}/{repo}?mode={mode}&verb={verb} for 127.0.0.1:0, "
                    f"{status} OK in 1.7ms @ private/serv.go:110(private.ServCommand)")


def hook(t, kind, repo, status=200):
    return (T0 + t, f"2026/11/27 10:00:00 ...eb/routing/logger.go:109:func1() [I] router: completed POST "
                    f"/api/internal/hook/{kind}-receive/{repo} for 127.0.0.1:0, {status} OK in 1.3ms @ x")


def l4(t, repo="VDHICT/cluster-wires", key=31, result="PUSHED"):
    ts = dt.datetime.fromtimestamp(T0 + t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return json.dumps({"chg": "chg-2026-11-13-002", "event": "executed", "ts": ts, "actor": "k8s-engineer",
                       "payload": {"kind": "forge-deploy-key-push", "repo": repo, "public_key_id": key,
                                   "result": result, "ts_push": ts, "new": "a" * 40}})


def audit(entries, lines=()):
    events = scan.parse_forge_log(entries)
    return scan.reconcile_forge_pushes(events, scan._l4_pushes("\n".join(lines)), REG, T0 - 3600, T0 + 3600)


def sev(findings, s):
    return [f for f in findings if f["severity"] == s]


class ForgePushAudit(unittest.TestCase):
    def test_parse_real_format(self):
        ev = scan.parse_forge_log([serv(0, 31, "VDHICT/Cluster-Wires"), hook(1, "post", "VDHICT/cluster-wires")])
        self.assertEqual((ev[0]["kind"], ev[0]["key_id"], ev[0]["repo"], ev[0]["mode"], ev[0]["status"]),
                         ("serv", 31, "vdhict/cluster-wires", 2, 200))
        self.assertEqual((ev[1]["kind"], ev[1]["repo"]), ("post", "vdhict/cluster-wires"))

    def test_push_with_l4_line_is_clean(self):
        f = audit([serv(0, 31, "VDHICT/cluster-wires"), hook(1, "pre", "VDHICT/cluster-wires"),
                   hook(2, "post", "VDHICT/cluster-wires")], [l4(30)])
        self.assertEqual(f, [])

    def test_push_without_l4_line_is_high(self):
        f = audit([serv(0, 31, "VDHICT/cluster-wires"), hook(1, "pre", "VDHICT/cluster-wires"),
                   hook(2, "post", "VDHICT/cluster-wires")])
        self.assertEqual(len(sev(f, "high")), 1)
        self.assertIn("without an L4 line", f[0]["title"])
        self.assertIn("forge-deploy-key-revoke.md", f[0]["remediation"])

    def test_l4_line_for_other_key_does_not_match(self):
        f = audit([serv(0, 31, "VDHICT/cluster-wires"), hook(2, "post", "VDHICT/cluster-wires")], [l4(30, key=32)])
        self.assertEqual(len(sev(f, "high")), 1)

    def test_refused_force_or_delete_is_high(self):
        f = audit([serv(0, 31, "VDHICT/cluster-wires"), hook(1, "pre", "VDHICT/cluster-wires", status=403)])
        self.assertEqual(len(sev(f, "high")), 1)
        self.assertIn("refused push", f[0]["title"])

    def test_write_outside_own_repo_is_high(self):
        f = audit([serv(0, 31, "VDHICT/ortho-sync", status=200)])
        self.assertIn("outside its repo", sev(f, "high")[0]["title"])

    def test_refused_control_probe_is_info(self):
        f = audit([serv(0, 31, "VDHICT/ortho-sync", status=404)])
        self.assertEqual([x["severity"] for x in f], ["info"])

    def test_fetch_and_noop_sessions_are_ignored(self):
        f = audit([serv(0, 31, "VDHICT/cluster-wires", verb="git-upload-pack", mode=1),
                   serv(10, 31, "VDHICT/cluster-wires")])            # receive-pack without hooks = up to date
        self.assertEqual(f, [])

    def test_other_keys_and_http_pushes_ignored(self):
        f = audit([serv(0, 21, "VDHICT/cluster-wires"), hook(1, "post", "VDHICT/cluster-wires"),
                   hook(50, "post", "VDHICT/cluster-wires")])
        self.assertEqual(f, [])

    def test_l4_line_without_forge_push_is_medium(self):
        f = audit([], [l4(30)])
        self.assertEqual([x["severity"] for x in f], ["medium"])

    def test_no_active_key_means_no_findings(self):
        reg = {"keys": [{"repo": "VDHICT/cluster-wires", "status": "planned", "public_key_id": None}]}
        ev = scan.parse_forge_log([serv(0, 31, "VDHICT/cluster-wires"), hook(1, "post", "VDHICT/cluster-wires")])
        self.assertEqual(scan.reconcile_forge_pushes(ev, [], reg, T0 - 60, T0 + 60), [])

    def test_loki_unreachable_is_high(self):
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / "hack/ops/forge-push").mkdir(parents=True)
            (repo / "ops").mkdir()
            (repo / "ops/changes.jsonl").write_text("")
            (repo / scan.FORGE_PUSH_REGISTRY).write_text(json.dumps(REG))
            with mock.patch.object(scan, "loki_forge_entries", side_effect=OSError("connection refused")):
                f = scan.check_forge_push_audit(repo)
            self.assertEqual(sev(f, "high")[0]["title"], "forge push audit could not read the forge log (L5 not run)")
            with mock.patch.object(scan, "loki_forge_entries", return_value=([], True)):
                f = scan.check_forge_push_audit(repo)
            self.assertIn("log gap", sev(f, "high")[0]["title"])

    def test_registry_in_repo_is_wired(self):
        self.assertTrue((ROOT / scan.FORGE_PUSH_REGISTRY).is_file())
        self.assertTrue((ROOT / scan.REVOKE_RUNBOOK).is_file())
        self.assertTrue((ROOT / scan.PIN_GUARD).is_file())


class PinGuardRoute(unittest.TestCase):
    """G6: a red guard (live or CI) becomes a high finding (sev3 incident) naming the L7 revoke; G5: stale cron."""

    def test_red_and_error_are_high_with_revoke(self):
        for rc in (1, 2):
            f = scan.pin_guard_findings(rc, "RED V2 live flux-system/cluster-wires", "live")
            self.assertEqual(f[0]["severity"], "high")
            self.assertIn(scan.REVOKE_RUNBOOK, f[0]["remediation"])
        self.assertEqual(scan.pin_guard_findings(0, "PIN-GUARD GREEN (live)", "live"), [])

    def test_ci_failure_is_high_and_stale_schedule_medium(self):
        now = dt.datetime(2026, 11, 27, 12, tzinfo=dt.timezone.utc)
        latest = {"conclusion": "failure", "html_url": "https://github.com/x/runs/1", "head_sha": "8" * 40}
        sched = {"created_at": "2026-11-24T05:17:00Z"}
        f = scan.ci_pin_guard_findings(latest, sched, now)
        self.assertEqual(sorted(x["severity"] for x in f), ["high", "medium"])
        f = scan.ci_pin_guard_findings({"conclusion": "success"}, {"created_at": "2026-11-27T05:17:00Z"}, now)
        self.assertEqual(f, [])

    def test_live_guard_runs_in_scan(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(scan.check_pin_guard_live(Path(d))[0]["severity"], "high")   # guard missing = red
            with mock.patch.object(scan, "run", return_value=mock.Mock(returncode=0, stdout="GREEN", stderr="")):
                self.assertEqual(scan.check_pin_guard_live(ROOT), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
