#!/usr/bin/env python3
"""Tests for forge-deploy-key-push.py (chg-2026-11-13-002 L3/L4, Argus C2: ff accepted; non-ff, delete, tag and a
protected pattern refused locally; one change-log line per push).

Local bare repos only: never the forge, never a real key (the key file is a dummy and the fingerprint is stubbed).
Run: python3 -I hack/ops/forge-push/tests/test_forge_push.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "forge-deploy-key-push.py"
REPO_ROOT = HERE.parents[3]
spec = importlib.util.spec_from_file_location("fpush", SCRIPT)
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)

G = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main",
     "-c", "commit.gpgsign=false"]
FP = "SHA256:testfingerprintnotarealkey"
RULES_T1 = [  # cluster-wires today: main allows deploy keys; ** (T1) and the pinned patterns do not
    {"name": "main", "can_push": True, "enable_whitelist": True, "whitelist_deploy_keys": True},
    {"name": "runner/**", "can_push": True, "enable_whitelist": True, "whitelist_deploy_keys": False},
    {"name": "**", "can_push": True, "enable_whitelist": True, "whitelist_deploy_keys": False},
]
FAKE_FILTER = '''
class FenceError(RuntimeError):
    pass
def load_terms(path):
    if not path or "missing" in path:
        raise FenceError("no terms")
    return {"x"}
def hits(text, terms):
    return "ZORBACLIENT" in text
'''


def sh(*a, cwd=None):
    return subprocess.run(list(a), cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


class LocalForge(fp.Forge):
    rules_value = RULES_T1

    def url(self, repo):
        return str(self.reg["_local"][repo])

    def env(self):
        return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

    def rules(self, repo):
        return self.rules_value, ["*"]

    def readback(self, repo, branch, method):
        out = sh("git", "ls-remote", self.url(repo), "refs/heads/" + branch).split()
        return out[0] if out else None


class PushTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.t = pathlib.Path(self.tmp.name)
        self.remote = t / "remote.git"
        sh("git", "init", "-q", "--bare", "-b", "main", str(self.remote))
        self.work = t / "work"
        sh(*G, "init", "-q", "-b", "main", str(self.work))
        self.a = self.commit("a")
        sh(*G, "push", "-q", str(self.remote), "main", cwd=self.work)
        self.b = self.commit("b")                                  # ff of a
        sh(*G, "checkout", "-q", "-b", "side", self.a, cwd=self.work)
        self.c = self.commit("c")                                  # diverges from b
        sh(*G, "checkout", "-q", "main", cwd=self.work)
        self.key = t / "forge-test-push"
        self.key.write_text("dummy, not a key\n")
        os.chmod(self.key, 0o600)
        self.reg_path = t / "deploy-keys.json"
        self.reg = {"forge_ssh_host": "forge.invalid", "forge_ssh_port": 22, "control_repo": "VDHICT/control",
                    "keys": [{"repo": "VDHICT/target", "key_file": str(self.key), "status": "active",
                              "public_key_id": 99, "deploy_key_id": 7, "fingerprint": FP,
                              "allow_branches": ["main"], "readback": "push-key"}],
                    "_local": {"VDHICT/target": str(self.remote)}}
        self.reg_path.write_text(json.dumps(self.reg))
        (t / "ops").mkdir()
        shutil.copy(REPO_ROOT / "ops" / "ops", t / "ops" / "ops")
        self.changes = t / "ops" / "changes.jsonl"
        (t / "bin").mkdir()
        (t / "bin" / "client_filter.py").write_text(FAKE_FILTER)
        self.orig = (fp.key_fingerprint, fp.agent_fingerprints, fp.control_probe, fp.scan_gitleaks)
        fp.key_fingerprint = lambda p: FP
        fp.agent_fingerprints = lambda: ""
        fp.control_probe = lambda forge, reg, gitdir, sha, kid: "refused (key %s)" % kid
        fp.scan_gitleaks = lambda gitdir, opts, n: True
        LocalForge.rules_value = RULES_T1

    def tearDown(self):
        fp.key_fingerprint, fp.agent_fingerprints, fp.control_probe, fp.scan_gitleaks = self.orig
        self.tmp.cleanup()

    def commit(self, name, body=""):
        (self.work / name).write_text(name + body + "\n")
        sh(*G, "add", name, cwd=self.work)
        sh(*G, "commit", "-q", "-m", "add " + name, cwd=self.work)
        return sh("git", "rev-parse", "HEAD", cwd=self.work)

    def push(self, ref, *extra, chg="chg-2026-11-13-002"):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = fp.main([chg, "VDHICT/target", str(self.work), ref, "--key", str(self.key),
                          "--ops-cli", str(self.t / "ops" / "ops"), "--client-filter-bin", str(self.t / "bin"),
                          "--client-terms", str(self.t / "terms"), *extra],
                         forge_factory=LocalForge, registry_path=self.reg_path)
        self.out = buf.getvalue()
        return rc

    def lines(self):
        if not self.changes.exists():
            return []
        return [json.loads(x) for x in self.changes.read_text().splitlines() if x.strip()]

    def remote_main(self):
        return sh("git", "ls-remote", str(self.remote), "refs/heads/main").split()[0]

    # C2: ff accepted, read back, one line
    def test_ff_push_accepted_with_readback_and_one_line(self):
        self.assertEqual(self.push("main=" + self.b), 0, self.out)
        self.assertEqual(self.remote_main(), self.b)
        ls = self.lines()
        self.assertEqual(len(ls), 1)
        p = ls[0]["payload"]
        self.assertEqual((ls[0]["chg"], ls[0]["event"]), ("chg-2026-11-13-002", "executed"))
        self.assertEqual((p["result"], p["readback"], p["old"], p["new"], p["key_fp"], p["public_key_id"]),
                         ("PUSHED", "MATCH", self.a, self.b, FP, 99))
        self.assertEqual((p["checks"]["client_terms"], p["checks"]["gitleaks"]), ("clean", "clean"))

    def test_non_ff_refused(self):
        self.assertEqual(self.push("main=" + self.b), 0, self.out)
        self.assertEqual(self.push("main=" + self.c), 1)              # c does not descend from b
        self.assertIn("non-fast-forward", self.lines()[1]["payload"]["reason"])
        self.assertEqual(self.remote_main(), self.b)

    def test_delete_refused(self):
        self.assertEqual(self.push("main=" + "0" * 40), 1)
        self.assertIn("deletions are refused", self.lines()[0]["payload"]["reason"])
        self.assertEqual(self.push("main="), 1)
        self.assertEqual(self.remote_main(), self.a)

    def test_tag_refused(self):
        self.assertEqual(self.push("refs/tags/v1=" + self.b), 1)
        self.assertIn("tags are refused", self.lines()[0]["payload"]["reason"])
        self.assertEqual(sh("git", "ls-remote", "--tags", str(self.remote)), "")

    def test_refspec_force_syntax_refused(self):
        self.assertEqual(self.push("+main=" + self.c), 1)
        self.assertEqual(self.push("main:main=" + self.c), 1)
        self.assertEqual(self.remote_main(), self.a)

    def test_protected_pattern_refused_even_if_registry_allows(self):
        self.reg["keys"][0]["allow_branches"] = ["main", "runner/**", "mack/**"]
        self.reg_path.write_text(json.dumps(self.reg))
        self.assertEqual(self.push("runner/x=" + self.b), 1)
        self.assertIn("does not allow deploy keys", self.lines()[0]["payload"]["reason"])
        LocalForge.rules_value = [r for r in RULES_T1 if r["name"] != "**"]
        self.assertEqual(self.push("runner/x=" + self.b), 1)
        self.assertIn("rule 'runner/**'", self.lines()[1]["payload"]["reason"])
        LocalForge.rules_value = RULES_T1
        self.assertEqual(self.push("mack/x=" + self.b), 1)          # caught by T1 "**"
        self.assertIn("rule '**'", self.lines()[2]["payload"]["reason"])

    def test_branch_not_in_registry_refused(self):
        LocalForge.rules_value = []
        self.assertEqual(self.push("feature=" + self.b), 1)
        self.assertIn("not in allow_branches", self.lines()[0]["payload"]["reason"])

    def test_main_refused_when_forge_rule_excludes_deploy_keys(self):
        LocalForge.rules_value = [dict(RULES_T1[0], whitelist_deploy_keys=False), RULES_T1[2]]
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("does not allow deploy keys", self.lines()[0]["payload"]["reason"])

    def test_chg_required_and_no_line_without_it(self):
        self.assertEqual(self.push("main=" + self.b, chg="tsk-2026-11-05-106"), 1)
        self.assertEqual(self.lines(), [])
        self.assertEqual(self.remote_main(), self.a)

    def test_inactive_key_refused(self):
        self.reg["keys"][0]["status"] = "planned"
        self.reg_path.write_text(json.dumps(self.reg))
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("not active", self.lines()[0]["payload"]["reason"])

    def test_key_mode_and_agent_refused(self):
        os.chmod(self.key, 0o644)
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("mode", self.lines()[-1]["payload"]["reason"])
        os.chmod(self.key, 0o600)
        fp.agent_fingerprints = lambda: "256 %s x (ED25519)" % FP
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("ssh-agent", self.lines()[-1]["payload"]["reason"])

    def test_wrong_key_file_and_fingerprint_refused(self):
        other = self.t / "other"
        other.write_text("x")
        os.chmod(other, 0o600)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = fp.main(["chg-2026-11-13-002", "VDHICT/target", str(self.work), "main=" + self.b, "--key", str(other),
                          "--ops-cli", str(self.t / "ops" / "ops")], forge_factory=LocalForge,
                         registry_path=self.reg_path)
        self.assertEqual(rc, 1)
        self.assertIn("registered key_file", self.lines()[-1]["payload"]["reason"])
        fp.key_fingerprint = lambda p: "SHA256:other"
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("fingerprint", self.lines()[-1]["payload"]["reason"])

    def test_client_term_hit_refused_boolean_only(self):
        sha = self.commit("d", body=" ZORBACLIENT")
        self.assertEqual(self.push("main=" + sha), 1)
        p = self.lines()[0]["payload"]
        self.assertEqual(p["checks"]["client_terms"], "HIT")
        self.assertNotIn("ZORBA", json.dumps(p) + self.out)
        self.assertEqual(self.remote_main(), self.a)

    def test_client_fence_missing_fails_closed(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = fp.main(["chg-2026-11-13-002", "VDHICT/target", str(self.work), "main=" + self.b, "--key",
                          str(self.key), "--ops-cli", str(self.t / "ops" / "ops"), "--client-filter-bin",
                          str(self.t / "bin"), "--client-terms", str(self.t / "missing")],
                         forge_factory=LocalForge, registry_path=self.reg_path)
        self.assertEqual(rc, 1)
        self.assertIn("fail closed", self.lines()[0]["payload"]["reason"])

    def test_gitleaks_hit_refused(self):
        fp.scan_gitleaks = lambda gitdir, opts, n: False
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertEqual(self.lines()[0]["payload"]["checks"]["gitleaks"], "LEAK")
        self.assertEqual(self.remote_main(), self.a)

    def test_control_probe_failure_stops_push(self):
        def accepted(*a):
            raise fp.Refused("CONTROL PROBE ACCEPTED: the key can write VDHICT/control; L7 revoke trigger")
        fp.control_probe = accepted
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("L7 revoke", self.lines()[0]["payload"]["reason"])
        self.assertEqual(self.remote_main(), self.a)

    def test_dry_run_writes_nothing_to_remote(self):
        self.assertEqual(self.push("main=" + self.b, "--dry-run"), 0, self.out)
        self.assertEqual(self.lines()[0]["payload"]["result"], "DRY-RUN-OK")
        self.assertEqual(self.remote_main(), self.a)

    def test_insteadof_rewrite_refused(self):
        sh("git", "-C", str(self.work), "config", "url.file:///elsewhere/.insteadOf", "file:///x/")
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("insteadOf", self.lines()[0]["payload"]["reason"])


@unittest.skipUnless(shutil.which("gitleaks"), "gitleaks not installed")
class GitleaksReal(unittest.TestCase):
    """Real gitleaks: a broken git log must not read as clean (8.30 exits 0 with 0 commits scanned)."""

    def test_clean_range_counts_match(self):
        self.assertTrue(fp.scan_gitleaks(REPO_ROOT, "HEAD~2..HEAD", 2))

    def test_bad_log_opts_fail_closed(self):
        with self.assertRaisesRegex(fp.Refused, "fail closed"):
            fp.scan_gitleaks(REPO_ROOT, "--bogus-opt-xyz", 0)

    def test_count_mismatch_fails_closed(self):
        with self.assertRaisesRegex(fp.Refused, "fail closed"):
            fp.scan_gitleaks(REPO_ROOT, "HEAD~2..HEAD", 5)


class ProbeTests(unittest.TestCase):
    """The control-repo write probe itself (fp.control_probe), with git stubbed."""

    def setUp(self):
        self.orig = fp.git
        self.reg = {"forge_ssh_host": "forge.invalid", "forge_ssh_port": 22, "control_repo": "VDHICT/control"}
        self.forge = fp.Forge(self.reg, "/nonexistent")

    def tearDown(self):
        fp.git = self.orig

    def stub(self, rc, stderr):
        fp.git = lambda *a, **k: SimpleNamespace(returncode=rc, stderr=stderr, stdout="")

    def test_refused_with_our_key_id_passes(self):
        self.stub(128, "Forgejo: Public (Deploy) Key: 99:vdhmini01 x push is not authorized to write to "
                       "VDHICT/control.\nfatal: Could not read from remote repository.\n")
        self.assertEqual(fp.control_probe(self.forge, self.reg, ".", "a" * 40, 99), "refused (key 99)")

    def test_accepted_is_revoke_trigger(self):
        self.stub(0, "")
        with self.assertRaisesRegex(fp.Refused, "L7 revoke"):
            fp.control_probe(self.forge, self.reg, ".", "a" * 40, 99)

    def test_network_error_fails_closed(self):
        self.stub(128, "ssh: connect to host forge.invalid port 22: Connection refused\n")
        with self.assertRaisesRegex(fp.Refused, "fail closed"):
            fp.control_probe(self.forge, self.reg, ".", "a" * 40, 99)

    def test_other_key_id_refused(self):
        self.stub(128, "Forgejo: Public (Deploy) Key: 12:other is not authorized to write to VDHICT/control.\n")
        with self.assertRaisesRegex(fp.Refused, "L2 mismatch"):
            fp.control_probe(self.forge, self.reg, ".", "a" * 40, 99)


class RuleMatching(unittest.TestCase):
    def test_forgejo_order_plain_first_then_glob(self):
        self.assertEqual(fp.first_rule(RULES_T1, "main")["name"], "main")
        # Forgejo 15 has no rule priority: globs sort by name, so T1 "**" shadows "runner/**"
        self.assertEqual(fp.first_rule(RULES_T1, "runner/2026-11-05-fence-v4")["name"], "**")
        self.assertEqual(fp.first_rule(RULES_T1[:2], "runner/2026-11-05-fence-v4")["name"], "runner/**")
        self.assertEqual(fp.first_rule(RULES_T1, "mack/mini/x")["name"], "**")
        self.assertIsNone(fp.first_rule([{"name": "main-pre-*"}], "main"))
        self.assertTrue(fp.glob_re("main-pre-*").match("main-pre-v10-2026-10-28"))
        self.assertFalse(fp.glob_re("runner/*").match("runner/a/b"))

    def test_registry_is_public_data_and_one_key_per_repo(self):
        reg = json.loads((HERE.parent / "deploy-keys.json").read_text())
        repos = [k["repo"].lower() for k in reg["keys"]]
        self.assertEqual(len(repos), len(set(repos)))
        self.assertEqual(len({k["key_file"] for k in reg["keys"]}), len(repos))
        self.assertNotIn(reg["control_repo"].lower(), repos)
        for k in reg["keys"]:
            self.assertEqual(k["allow_branches"], ["main"])
            self.assertTrue(k["key_file"].startswith("~/.ssh/forge-") and k["key_file"].endswith("-push"))
        text = (HERE.parent / "deploy-keys.json").read_text()
        self.assertNotIn("PRIVATE KEY", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
