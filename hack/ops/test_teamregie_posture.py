#!/usr/bin/env python3
"""Offline tests for the Teamregie posture checks in the argus-posture-scan (chg-2026-10-30-002, Argus T3).

    python3 -I hack/ops/test_teamregie_posture.py [-v]      # needs PyYAML

Green on the real Authelia configuration.yaml of this checkout (with ${SECRET_DOMAIN} filled with a test domain);
red on a bypass/one_factor rule, wrong order, wrong subject, extra conditions, a missing deny, and on a 200 probe.
"""
import copy
import io
import os
import tempfile
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "kubernetes/main/apps/observability/cluster-health/app"
sys.path.insert(0, str(APP / "scripts"))
_DATA = tempfile.TemporaryDirectory()          # lib.py makes its dirs under DATA_DIR at import time
os.environ["DATA_DIR"] = _DATA.name
import ops_security_scan as scan  # noqa: E402

DOMAIN = "example.test"
HOST = f"mypka-teamregie.{DOMAIN}"
CONFIG = ROOT / "kubernetes/main/apps/security/authelia/app/config/configuration.yaml"


def real_config() -> dict:
    return yaml.safe_load(CONFIG.read_text().replace("${SECRET_DOMAIN}", DOMAIN))


def rules(cfg):
    return cfg["access_control"]["rules"]


def idx(cfg, policy):
    return next(i for i, r in enumerate(rules(cfg)) if HOST in (r.get("domain") or []) and r["policy"] == policy)


class Rules(unittest.TestCase):
    def ok(self, cfg):
        return scan.teamregie_rules_verdict(cfg)

    def test_green_on_the_repo_config(self):
        ok, why = self.ok(real_config())
        self.assertTrue(ok, why)
        self.assertNotIn(DOMAIN, why)

    def test_the_two_rules_sit_before_the_wildcard(self):
        cfg = real_config()
        wild = next(i for i, r in enumerate(rules(cfg)) if f"*.{DOMAIN}" in (r.get("domain") or []))
        self.assertLess(idx(cfg, "two_factor"), idx(cfg, "deny"))
        self.assertLess(idx(cfg, "deny"), wild)

    def test_red_on_a_bypass_rule_first(self):
        cfg = real_config()
        rules(cfg).insert(0, {"domain": [HOST], "policy": "bypass"})
        ok, why = self.ok(cfg)
        self.assertFalse(ok)
        self.assertIn("bypass", why)
        self.assertNotIn(DOMAIN, why)

    def test_red_on_a_bypass_rule_after_the_deny(self):
        cfg = real_config()
        rules(cfg).append({"domain": [HOST], "policy": "bypass", "resources": ["^/healthz$"]})
        self.assertFalse(self.ok(cfg)[0])

    def test_red_on_a_one_factor_rule(self):
        cfg = real_config()
        rules(cfg).insert(idx(cfg, "deny"), {"domain": HOST, "policy": "one_factor", "subject": ["group:users"]})
        self.assertFalse(self.ok(cfg)[0])

    def test_red_on_a_regex_bypass(self):
        cfg = real_config()
        rules(cfg).insert(0, {"domain_regex": [r"^mypka-.*\.example\.test$"], "policy": "bypass"})
        self.assertFalse(self.ok(cfg)[0])

    def test_red_when_the_wildcard_comes_first(self):
        cfg = real_config()
        r = rules(cfg)
        wild = next(i for i, x in enumerate(r) if f"*.{DOMAIN}" in (x.get("domain") or []))
        r.insert(0, r.pop(wild))
        self.assertFalse(self.ok(cfg)[0])

    def test_red_on_subject_admins(self):
        cfg = real_config()
        rules(cfg)[idx(cfg, "two_factor")]["subject"] = ["group:admins"]
        self.assertFalse(self.ok(cfg)[0])

    def test_red_on_an_extra_subject(self):
        cfg = real_config()
        rules(cfg)[idx(cfg, "two_factor")]["subject"] = ["group:teamregie", "group:users"]
        self.assertFalse(self.ok(cfg)[0])

    def test_red_on_extra_conditions(self):
        cfg = real_config()
        rules(cfg)[idx(cfg, "two_factor")]["networks"] = ["private"]
        self.assertFalse(self.ok(cfg)[0])
        cfg = real_config()
        rules(cfg)[idx(cfg, "deny")]["resources"] = ["^/x$"]
        self.assertFalse(self.ok(cfg)[0])

    def test_red_without_the_deny(self):
        cfg = real_config()
        del rules(cfg)[idx(cfg, "deny")]
        self.assertFalse(self.ok(cfg)[0])

    def test_red_without_the_rules(self):
        cfg = real_config()
        r = rules(cfg)
        cfg["access_control"]["rules"] = [x for x in r if HOST not in (x.get("domain") or [])]
        self.assertFalse(self.ok(cfg)[0])

    def test_check_reads_the_live_configmap(self):
        cm = {"data": {"configuration.yaml": CONFIG.read_text().replace("${SECRET_DOMAIN}", DOMAIN)}}
        done = mock.Mock(returncode=0, stdout=__import__("json").dumps(cm), stderr="")
        with mock.patch.object(scan, "run", return_value=done) as run:
            (f,) = scan.check_teamregie_authelia_rules()
        self.assertEqual(run.call_args[0][0][:6], ["kubectl", "-n", "security", "get", "configmap", "authelia-configmap"])
        self.assertEqual(f["severity"], "info")
        bad = copy.deepcopy(real_config())
        rules(bad).insert(0, {"domain": [HOST], "policy": "bypass"})
        done.stdout = __import__("json").dumps({"data": {"configuration.yaml": yaml.safe_dump(bad)}})
        with mock.patch.object(scan, "run", return_value=done):
            (f,) = scan.check_teamregie_authelia_rules()
        self.assertEqual(f["severity"], "high")


class Probe(unittest.TestCase):
    def test_verdicts(self):
        auth = f"https://auth.{DOMAIN}/?rd=https%3A%2F%2F{HOST}%2F"
        self.assertEqual(scan.teamregie_probe_verdict(200, "", DOMAIN)[0], "critical")
        self.assertEqual(scan.teamregie_probe_verdict(302, auth, DOMAIN)[0], "info")
        self.assertEqual(scan.teamregie_probe_verdict(302, "https://evil.test/", DOMAIN)[0], "high")
        self.assertEqual(scan.teamregie_probe_verdict(403, "", DOMAIN)[0], "info")
        self.assertEqual(scan.teamregie_probe_verdict(None, "", DOMAIN)[0], "low")
        self.assertEqual(scan.teamregie_probe_verdict(503, "", DOMAIN)[0], "low")
        for s in (200, 302, None):
            self.assertNotIn(DOMAIN, scan.teamregie_probe_verdict(s, auth, DOMAIN)[1])

    def probe(self, outcome):
        cm = {"data": {"configuration.yaml": CONFIG.read_text().replace("${SECRET_DOMAIN}", DOMAIN)}}
        done = mock.Mock(returncode=0, stdout=__import__("json").dumps(cm), stderr="")
        seen = {}

        class Opener:
            def open(self, req, timeout):
                seen["url"], seen["headers"] = req.full_url, dict(req.header_items())
                if isinstance(outcome, Exception):
                    raise outcome
                resp = mock.MagicMock(status=outcome)
                resp.__enter__.return_value = resp
                return resp

        with mock.patch.object(scan, "run", return_value=done), \
             mock.patch.object(scan.urllib.request, "build_opener", return_value=Opener()):
            (f,) = scan.check_teamregie_forged_header()
        return f, seen

    def test_a_200_is_critical_so_a_sev2_incident(self):
        f, seen = self.probe(200)
        self.assertEqual(f["severity"], "critical")
        self.assertIn("AUTH BYPASS", f["title"])
        self.assertEqual(seen["url"], f"https://{HOST}/")
        self.assertEqual(seen["headers"].get("Remote-user"), "argus-forged")
        self.assertIn("admins", seen["headers"].get("Remote-groups"))
        self.assertNotIn("Cookie", seen["headers"])

    def test_a_302_to_the_portal_is_green(self):
        loc = f"https://auth.{DOMAIN}/?rd=x"
        err = urllib.error.HTTPError(f"https://{HOST}/", 302, "Found", {"Location": loc}, io.BytesIO(b""))
        f, _ = self.probe(err)
        self.assertEqual(f["severity"], "info")
        self.assertNotIn(DOMAIN, f["evidence"])

    def test_no_answer_is_low_not_green(self):
        f, _ = self.probe(OSError("unreachable"))
        self.assertEqual(f["severity"], "low")


class StdlibParser(unittest.TestCase):
    """The cluster-health image has no PyYAML (chg-2026-10-30-002 follow-up): the checks use a stdlib reader."""

    def sections(self, text):
        full = yaml.safe_load(text)
        return {k: full.get(k) for k in ("session", "access_control")}

    def test_equals_pyyaml_on_the_repo_config(self):
        text = CONFIG.read_text().replace("${SECRET_DOMAIN}", DOMAIN).replace("$${", "${")
        self.assertEqual(scan.parse_authelia_sections(text), self.sections(text))

    def test_equals_pyyaml_on_a_pyyaml_dump(self):
        text = yaml.safe_dump(real_config(), sort_keys=False)
        self.assertEqual(scan.parse_authelia_sections(text), self.sections(text))

    def test_checks_run_without_yaml_importable(self):
        cm = {"data": {"configuration.yaml": CONFIG.read_text().replace("${SECRET_DOMAIN}", DOMAIN)}}
        done = mock.Mock(returncode=0, stdout=__import__("json").dumps(cm), stderr="")
        with mock.patch.dict(sys.modules, {"yaml": None}), mock.patch.object(scan, "run", return_value=done):
            (f,) = scan.check_teamregie_authelia_rules()
            self.assertEqual(f["severity"], "info", f["evidence"])
            err = urllib.error.HTTPError(f"https://{HOST}/", 302, "Found", {"Location": f"https://auth.{DOMAIN}/?rd=x"},
                                         io.BytesIO(b""))
            opener = mock.Mock(); opener.open.side_effect = err
            with mock.patch.object(scan.urllib.request, "build_opener", return_value=opener):
                (g,) = scan.check_teamregie_forged_header()
            self.assertEqual(g["severity"], "info", g["evidence"])

    def test_unparseable_config_is_red_not_green(self):
        bad = CONFIG.read_text().replace("${SECRET_DOMAIN}", DOMAIN).replace(
            "access_control:\n", "access_control:\n  extra: |\n    block scalar\n", 1)
        done = mock.Mock(returncode=0, stdout=__import__("json").dumps({"data": {"configuration.yaml": bad}}), stderr="")
        with mock.patch.object(scan, "run", return_value=done):
            (f,) = scan.check_teamregie_authelia_rules()
        self.assertEqual(f["severity"], "high")
        self.assertNotIn(DOMAIN, f["evidence"])

    def test_wrong_order_via_the_stdlib_reader_is_red(self):
        cfg = real_config()
        r = rules(cfg)
        a, b = idx(cfg, "two_factor"), idx(cfg, "deny")
        r[a], r[b] = r[b], r[a]
        text = yaml.safe_dump(cfg, sort_keys=False)
        self.assertFalse(scan.teamregie_rules_verdict(scan.parse_authelia_sections(text))[0])

    def test_bypass_via_the_stdlib_reader_is_red(self):
        cfg = real_config()
        rules(cfg).insert(0, {"domain": [HOST], "policy": "bypass"})
        text = yaml.safe_dump(cfg, sort_keys=False)
        self.assertFalse(scan.teamregie_rules_verdict(scan.parse_authelia_sections(text))[0])


if __name__ == "__main__":
    unittest.main()
