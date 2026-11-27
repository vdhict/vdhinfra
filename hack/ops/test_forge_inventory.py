#!/usr/bin/env python3
"""Offline tests for the K1 forge deploy-key inventory (chg-2026-11-13-002, Argus wq-140 delta section 3, wq-169):
forge_inventory.py (pure checks K1a-K1d) and its posture-scan wiring (CNPG exporter metrics via Prometheus).
Fixtures have the shape measured on forge-pg 2026-11-27 (ids public; no key material).

    python3 -I hack/ops/test_forge_inventory.py [-v]      # stdlib only
"""
import copy
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "kubernetes/main/apps/observability/cluster-health/app"
QUERIES = ROOT / "kubernetes/main/apps/devtools/forge-pg/app/oidc-links-queries.yaml"
sys.path.insert(0, str(APP / "scripts"))
_DATA = tempfile.TemporaryDirectory()          # lib.py makes its dirs under DATA_DIR at import time
os.environ["DATA_DIR"] = _DATA.name
import forge_inventory as inv  # noqa: E402
import ops_security_scan as scan  # noqa: E402

T19, T27 = 1795089983, 1795779384              # 2026-11-19 P1 rules, 2026-11-27 T1 "**" rules


def reg(active=()):
    keys = []
    for i, name in enumerate(["cluster-wires", "print3d", "secure-access-mobile-app"]):
        on = name in active
        keys.append({"repo": f"VDHICT/{name}", "status": "active" if on else "planned",
                     "public_key_id": 100 + i if on else None, "deploy_key_id": 200 + i if on else None,
                     "allow_branches": ["main"]})
    return {"keys": keys}


DK = [  # flux-ro read key on cluster-wires, and a write key on a repo outside the registry
    {"deploy_key_id": 5, "public_key_id": 6, "repo_id": 1, "repo": "vdhict/cluster-wires", "mode": 1},
    {"deploy_key_id": 9, "public_key_id": 40, "repo_id": 77, "repo": "vdhict/outside-repo", "mode": 2},
]


def rule(rid, repo_id, repo, name, dk=False, created=T19, can_push=True, wl=True):
    return {"rule_id": rid, "repo_id": repo_id, "repo": repo, "rule": name, "deploy_keys": dk, "can_push": can_push,
            "enable_whitelist": wl, "created": created}


RULES = [
    rule(13, 1, "vdhict/cluster-wires", "main", dk=True), rule(14, 1, "vdhict/cluster-wires", "runner/**"),
    rule(44, 1, "vdhict/cluster-wires", "**", created=T27),
    rule(45, 2, "vdhict/print3d", "main"), rule(46, 2, "vdhict/print3d", "**", created=T27),
    rule(55, 3, "vdhict/secure-access-mobile-app", "main"),
    rule(56, 3, "vdhict/secure-access-mobile-app", "**", created=T27),
    rule(60, 77, "vdhict/outside-repo", "main"),
]


def checks(fs):
    return sorted((f["check"], f["severity"]) for f in fs)


class K1Checks(unittest.TestCase):
    def test_live_shape_is_clean(self):
        self.assertEqual(inv.inventory_findings(reg(), DK, RULES), [])

    def test_active_key_registered_is_clean(self):
        dk = DK + [{"deploy_key_id": 201, "public_key_id": 101, "repo_id": 2, "repo": "vdhict/print3d", "mode": 2}]
        self.assertEqual(inv.inventory_findings(reg(active=["print3d"]), dk, RULES), [])

    def test_k1a_unregistered_write_key_is_high(self):
        dk = DK + [{"deploy_key_id": 300, "public_key_id": 300, "repo_id": 2, "repo": "vdhict/print3d", "mode": 2}]
        fs = inv.inventory_findings(reg(), dk, RULES)
        self.assertEqual(checks(fs), [("K1a", "high")])
        self.assertIn(inv.REVOKE_RUNBOOK, fs[0]["remediation"])

    def test_k1a_read_key_is_not_a_write_key(self):
        dk = DK + [{"deploy_key_id": 301, "public_key_id": 301, "repo_id": 2, "repo": "vdhict/print3d", "mode": 1}]
        self.assertEqual(inv.inventory_findings(reg(), dk, RULES), [])

    def test_k1a_active_key_missing_or_wrong_deploy_key_id_is_high(self):
        self.assertEqual(checks(inv.key_findings(reg(active=["print3d"]), DK)), [("K1a", "high"), ("K1b", "high")])
        dk = DK + [{"deploy_key_id": 999, "public_key_id": 101, "repo_id": 2, "repo": "vdhict/print3d", "mode": 2}]
        fs = inv.key_findings(reg(active=["print3d"]), dk)
        self.assertEqual(checks(fs), [("K1a", "high")])
        self.assertIn("registry says 201", fs[0]["evidence"])

    def test_k1b_key_reused_across_repos_is_high_and_outside_repo_by_id(self):
        dk = DK + [{"deploy_key_id": 201, "public_key_id": 101, "repo_id": 2, "repo": "vdhict/print3d", "mode": 2},
                   {"deploy_key_id": 202, "public_key_id": 101, "repo_id": 77, "repo": "vdhict/outside-repo",
                    "mode": 1}]
        fs = inv.inventory_findings(reg(active=["print3d"]), dk, RULES)
        self.assertEqual(checks(fs), [("K1b", "high")])
        self.assertIn("repo_id 77", fs[0]["evidence"])
        self.assertNotIn("outside-repo", json.dumps(fs))

    def test_k1b_reuse_as_write_key_on_other_registry_repo(self):
        dk = DK + [{"deploy_key_id": 201, "public_key_id": 101, "repo_id": 2, "repo": "vdhict/print3d", "mode": 2},
                   {"deploy_key_id": 203, "public_key_id": 101, "repo_id": 3,
                    "repo": "vdhict/secure-access-mobile-app", "mode": 2}]
        self.assertEqual(checks(inv.inventory_findings(reg(active=["print3d"]), dk, RULES)),
                         [("K1a", "high"), ("K1b", "high")])

    def test_k1c_deploy_keys_on_rule_outside_registry_is_high(self):
        rs = [dict(r, deploy_keys=True) if r["rule_id"] == 60 else r for r in RULES]
        fs = inv.inventory_findings(reg(), DK, rs)
        self.assertEqual(checks(fs), [("K1c", "high")])
        self.assertEqual(fs[0]["target"], "repo_id 77")
        self.assertNotIn("outside-repo", json.dumps(fs))

    def test_k1c_deploy_keys_on_registry_repo_rule_not_allowed_is_high(self):
        for rid in (14, 44):                     # runner/** and the "**" rule ("never flip a ** rule", K2)
            with self.subTest(rule=rid):
                rs = [dict(r, deploy_keys=True) if r["rule_id"] == rid else r for r in RULES]
                self.assertEqual(checks(inv.inventory_findings(reg(), DK, rs)), [("K1c", "high")])

    def test_k1c_main_rule_flip_on_registry_repo_is_allowed(self):
        rs = [dict(r, deploy_keys=True) if r["rule_id"] == 45 else r for r in RULES]
        self.assertEqual(inv.inventory_findings(reg(), DK, rs), [])

    def test_k1d_glob_newer_than_star_is_flagged(self):
        newer = rule(70, 2, "vdhict/print3d", "release/*", created=T27 + 60, can_push=False)      # stricter than **
        self.assertEqual(checks(inv.inventory_findings(reg(), DK, RULES + [newer])), [("K1d", "high")])
        loose = dict(newer, can_push=True, rule_id=71)                                           # same as **
        self.assertEqual(checks(inv.inventory_findings(reg(), DK, RULES + [loose])), [("K1d", "medium")])

    def test_k1d_older_glob_and_plain_newer_rule_are_fine(self):
        plain = rule(72, 2, "vdhict/print3d", "develop", created=T27 + 60)
        older = rule(73, 2, "vdhict/print3d", "runner/**", created=T19)
        self.assertEqual(inv.inventory_findings(reg(), DK, RULES + [plain, older]), [])

    def test_k1d_tie_on_created_is_flagged(self):
        tie = rule(74, 2, "vdhict/print3d", "runner/**", created=T27)
        self.assertEqual([f["check"] for f in inv.inventory_findings(reg(), DK, RULES + [tie])], ["K1d"])

    def test_k1d_special_chars_count_as_glob(self):
        for name in ("ma[i]n", "ma]n", "!main", "ma\\in", "x}", "x{a"):
            with self.subTest(name=name):
                odd = rule(75, 2, "vdhict/print3d", name, created=T27 + 1)
                self.assertEqual([f["check"] for f in inv.inventory_findings(reg(), DK, RULES + [odd])], ["K1d"])

    def test_k1d_missing_star_rule_is_medium(self):
        rs = [r for r in RULES if r["rule_id"] != 46]
        self.assertEqual(checks(inv.inventory_findings(reg(), DK, rs)), [("K1d", "medium")])

    def test_real_registry_is_clean_against_live_shape(self):
        real = json.loads((ROOT / scan.FORGE_PUSH_REGISTRY).read_text())
        rs = []
        for i, k in enumerate(real["keys"]):
            r = k["repo"].lower()
            rs += [rule(100 + 2 * i, i + 1, r, "main", dk=r == "vdhict/cluster-wires"),
                   rule(101 + 2 * i, i + 1, r, "**", created=T27)]
        self.assertEqual(inv.inventory_findings(real, DK[:1], rs), [])

def vec(metric, value):
    return {"metric": metric, "value": [1795779384.0, str(value)]}


def prom_fixture(dk=DK, rules=RULES):
    out = {scan.INV_DK_QUERY: [vec({k: str(d[k]) for k in ("deploy_key_id", "public_key_id", "repo_id", "repo")},
                                   d["mode"]) for d in dk],
           scan.INV_COUNT_QUERY.format(col="deploy_keys"): [vec({}, len(dk))],
           scan.INV_COUNT_QUERY.format(col="protected_branches"): [vec({}, len(rules))]}
    for col in scan.INV_RULE_COLS:
        key = "created" if col == "created_unix" else col
        out[scan.INV_RULE_QUERY.format(col=col)] = [
            vec({"rule_id": str(r["rule_id"]), "repo_id": str(r["repo_id"]), "repo": r["repo"], "rule": r["rule"]},
                int(r[key])) for r in rules]
    return out


class ScanWiring(unittest.TestCase):
    def run_check(self, fixture, registry):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / scan.FORGE_PUSH_REGISTRY
            p.parent.mkdir(parents=True)
            p.write_text(json.dumps(registry))
            with mock.patch.object(scan, "prom_query", side_effect=lambda q: copy.deepcopy(fixture.get(q, []))):
                return scan.check_forge_inventory(Path(d))

    def test_prom_round_trip_clean(self):
        self.assertEqual(self.run_check(prom_fixture(), reg()), [])

    def test_prom_round_trip_finds_k1a(self):
        dk = DK + [{"deploy_key_id": 300, "public_key_id": 300, "repo_id": 2, "repo": "vdhict/print3d", "mode": 2}]
        fs = self.run_check(prom_fixture(dk=dk), reg())
        self.assertEqual([(f["severity"], f["owner_agent"]) for f in fs], [("high", "k8s-engineer")])
        self.assertTrue(fs[0]["title"].startswith("forge inventory K1a"))

    def test_metrics_absent_is_medium_then_high_once_a_key_is_active(self):
        fs = self.run_check({}, reg())
        self.assertEqual([(f["severity"], f["title"]) for f in fs], [("medium", "forge inventory unavailable (K1 not "
                                                                               "run)")])
        self.assertEqual(self.run_check({}, reg(active=["print3d"]))[0]["severity"], "high")

    def test_incomplete_vectors_fail_closed(self):
        fx = prom_fixture()
        fx[scan.INV_DK_QUERY] = fx[scan.INV_DK_QUERY][:1]                       # a series lost
        self.assertIn("deploy_key series", self.run_check(fx, reg())[0]["evidence"])
        fx = prom_fixture()
        fx[scan.INV_RULE_QUERY.format(col="deploy_keys")].pop()
        self.assertIn("protected_branch deploy_keys", self.run_check(fx, reg())[0]["evidence"])
        fx = prom_fixture()
        fx[scan.INV_RULE_QUERY.format(col="can_push")][0]["metric"]["rule_id"] = "999"   # rules do not line up
        self.assertIn("line up", self.run_check(fx, reg())[0]["evidence"])
        fx = prom_fixture()
        for c in scan.INV_RULE_COLS:                                            # two rows collapse onto one id
            fx[scan.INV_RULE_QUERY.format(col=c)][1]["metric"]["rule_id"] = "13"
        self.assertIn("line up", self.run_check(fx, reg())[0]["evidence"])

    def test_check_is_wired_and_shipped(self):
        src = (APP / "scripts/ops_security_scan.py").read_text()
        self.assertIn('("forge_inventory", lambda: check_forge_inventory(workdir))', src)
        self.assertIn("- scripts/forge_inventory.py", (APP / "kustomization.yaml").read_text())

    def test_exporter_queries_match_the_scan(self):
        text = QUERIES.read_text()
        for name, cols in (("forgejo_deploy_key", ["mode"]), ("forgejo_protected_branch", scan.INV_RULE_COLS),
                           ("forgejo_inventory", ["deploy_keys", "protected_branches"])):
            block = re.search(r"\n    %s:\n(.*?)(?=\n    \w+:\n|\Z)" % name, text, re.S)
            self.assertIsNotNone(block, name)
            self.assertIn("primary: true", block.group(1))
            for c in cols:
                self.assertRegex(block.group(1), r"- %s:\n\s+usage: \"GAUGE\"" % c)
        for q in [scan.INV_DK_QUERY] + [scan.INV_RULE_QUERY.format(col=c) for c in scan.INV_RULE_COLS]:
            self.assertRegex(q, r"cnpg_forgejo_(deploy_key_mode|protected_branch_\w+)")
        for secret_col in ("content", "fingerprint", "dk.name", "whitelist_user"):
            self.assertNotIn(secret_col, text.split("forgejo_deploy_key:")[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
