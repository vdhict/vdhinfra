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
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = pathlib.Path(os.environ.get("FORGE_PUSH_PATH", HERE.parent / "forge-deploy-key-push.py"))  # old build: red check
REPO_ROOT = HERE.parents[3]
spec = importlib.util.spec_from_file_location("fpush", SCRIPT)
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)

G = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main",
     "-c", "commit.gpgsign=false"]
FP = "SHA256:testfingerprintnotarealkey"
RULES_T1 = [  # cluster-wires as measured 2026-11-27: P1 rules created 19-11, T1 "**" created 27-11 (newest)
    {"name": "main", "can_push": True, "enable_whitelist": True, "whitelist_deploy_keys": True, "created": 1795089983, "id": 13},
    {"name": "runner/**", "can_push": True, "enable_whitelist": True, "whitelist_deploy_keys": False, "created": 1795089983, "id": 14},
    {"name": "**", "can_push": True, "enable_whitelist": True, "whitelist_deploy_keys": False, "created": 1795779384, "id": 44},
]
FAKE_FILTER = '''
import os
class FenceError(RuntimeError):
    pass
def load_terms(path):
    if not path or not os.path.isfile(path):
        raise FenceError("no terms")
    return {"x"}
def hits(text, terms):
    return "ZORBACLIENT" in text
'''


def sh(*a, cwd=None):
    return subprocess.run(list(a), cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


DEPLOY_KEYS = [  # the flux-ro read key on another repo, and our write key 99 (deploy_key 7) on the target
    {"deploy_key_id": 5, "public_key_id": 6, "repo_id": 1, "repo": "vdhict/cluster-wires", "mode": 1},
    {"deploy_key_id": 7, "public_key_id": 99, "repo_id": 2, "repo": "vdhict/target", "mode": 2},
]


class LocalForge(fp.Forge):
    rules_value = RULES_T1
    keys_value = DEPLOY_KEYS
    db_commit = None          # None = the DB row follows the remote; else this value (stale row, or an exception)

    def deploy_keys(self):
        return self.keys_value

    def branch_commit(self, repo, branch):
        if isinstance(self.db_commit, Exception):
            raise self.db_commit
        return self.db_commit if self.db_commit is not None else self.readback(repo, branch, "push-key")

    def url(self, repo):
        return str(self.reg["_local"][repo])

    def env(self):
        return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

    def rules(self, repo):
        return self.rules_value, ["*"]

    def readback(self, repo, branch, method):
        out = sh("git", "ls-remote", self.url(repo), "refs/heads/" + branch).split()
        return out[0] if out else None


class PushBase(unittest.TestCase):
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
        (t / "terms").write_text("fake term file\n")
        self.orig = (fp.key_fingerprint, fp.agent_fingerprints, fp.control_probe, fp.scan_gitleaks)
        self.sleep = mock.patch.object(fp.time, "sleep", lambda s: None)
        self.sleep.start()
        fp.key_fingerprint = lambda p: FP
        fp.agent_fingerprints = lambda: ""
        fp.control_probe = lambda forge, reg, gitdir, sha, kid: "refused (key %s)" % kid
        fp.scan_gitleaks = lambda gitdir, opts, n: True
        LocalForge.rules_value = RULES_T1
        LocalForge.keys_value = DEPLOY_KEYS
        LocalForge.db_commit = None

    def tearDown(self):
        self.sleep.stop()
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

    def push_default_terms(self, home):
        buf = io.StringIO()
        env = {k: v for k, v in os.environ.items() if k not in ("PKA_CHASE_TERMS_SCAN", "PKA_CHASE_CLIENT_TERMS")}
        env["HOME"] = str(home)
        with mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(buf):
            rc = fp.main(["chg-2026-11-13-002", "VDHICT/target", str(self.work), "main=" + self.b, "--key",
                          str(self.key), "--ops-cli", str(self.t / "ops" / "ops"), "--client-filter-bin",
                          str(self.t / "bin")], forge_factory=LocalForge, registry_path=self.reg_path)
        self.out = buf.getvalue()
        return rc


class PushTests(PushBase):
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
        self.assertEqual(p["readback_sql"], "MATCH")
        self.assertIn("K1a+K1b clean", p["checks"]["inventory"])

    # K4 (wq-169): the independent SQL readback of branch.commit_id is required after every push
    def test_k4_sql_readback_stale_row_is_mismatch(self):
        LocalForge.db_commit = self.a                       # the DB still shows the old commit
        self.assertEqual(self.push("main=" + self.b), 1, self.out)
        p = self.lines()[0]["payload"]
        self.assertEqual((p["readback"], p["readback_sql"], p["result"]),
                         ("MATCH", "MISMATCH (%s)" % self.a, "PUSHED-READBACK-MISMATCH"))

    def test_k4_sql_readback_error_is_not_a_match(self):
        LocalForge.db_commit = RuntimeError("forge-pg switchover in flight")
        self.assertEqual(self.push("main=" + self.b), 1, self.out)
        p = self.lines()[0]["payload"]
        self.assertEqual((p["readback_sql"], p["result"]), ("ERROR (RuntimeError)", "PUSHED-READBACK-MISMATCH"))

    def test_k4_dry_run_does_not_read_back(self):
        self.assertEqual(self.push("main=" + self.b, "--dry-run"), 0, self.out)
        self.assertNotIn("readback_sql", self.lines()[0]["payload"])

    # K1 a+b at push time (wq-169)
    def test_k1a_unregistered_write_key_on_repo_refused(self):
        LocalForge.keys_value = DEPLOY_KEYS + [{"deploy_key_id": 8, "public_key_id": 120, "repo_id": 2,
                                                "repo": "vdhict/target", "mode": 2}]
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("forge inventory K1a", self.lines()[0]["payload"]["reason"])
        self.assertEqual(self.remote_main(), self.a)

    def test_k1b_key_reused_on_other_repo_refused(self):
        LocalForge.keys_value = DEPLOY_KEYS + [{"deploy_key_id": 9, "public_key_id": 99, "repo_id": 3,
                                                "repo": "vdhict/elsewhere", "mode": 1}]
        self.assertEqual(self.push("main=" + self.b), 1)
        reason = self.lines()[0]["payload"]["reason"]
        self.assertIn("forge inventory K1b", reason)
        self.assertNotIn("elsewhere", reason)              # repos outside the registry are named by id only
        self.assertEqual(self.remote_main(), self.a)

    def test_k1a_registered_key_missing_refused(self):
        LocalForge.keys_value = DEPLOY_KEYS[:1]
        self.assertEqual(self.push("main=" + self.b), 1)
        self.assertIn("forge inventory K1a", self.lines()[0]["payload"]["reason"])

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
        self.assertEqual(self.push("runner/x=" + self.b), 1)                 # older runner/** wins over **
        self.assertIn("rule 'runner/**'", self.lines()[0]["payload"]["reason"])
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

    # F1 (wq-169): the default term file is the v2 keyed file, the same as the handoff prescan
    def test_f1_default_terms_path_is_v2(self):
        self.assertEqual(fp.DEFAULT_CLIENT_TERMS, "~/.config/pka-chase/v2/client-terms.sha256")

    def test_f1_default_v2_file_present_allows_push(self):
        home = self.t / "home"
        (home / ".config/pka-chase/v2").mkdir(parents=True)
        (home / ".config/pka-chase/v2/client-terms.sha256").write_text("fake\n")
        self.assertEqual(self.push_default_terms(home), 0, self.out)
        self.assertEqual(self.lines()[0]["payload"]["checks"]["client_terms"], "clean")

    def test_f1_default_v2_file_missing_refused(self):
        home = self.t / "home"
        (home / ".config/pka-chase").mkdir(parents=True)
        (home / ".config/pka-chase/client-terms.sha256").write_text("old path only\n")
        self.assertEqual(self.push_default_terms(home), 1)
        self.assertIn("fail closed", self.lines()[0]["payload"]["reason"])
        self.assertEqual(self.remote_main(), self.a)

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
        # Forgejo 15.0.9 protected_branch_list.go:34: globs by CreatedUnix, oldest first; ** (27-11) is newest
        self.assertEqual(fp.first_rule(RULES_T1, "runner/2026-11-05-fence-v4")["name"], "runner/**")
        newer = dict(RULES_T1[1], created=RULES_T1[2]["created"] + 1, id=45)
        self.assertEqual(fp.first_rule([RULES_T1[2], newer], "runner/x")["name"], "**")   # a newer glob loses to **
        self.assertEqual(fp.first_rule(RULES_T1, "MAIN")["name"], "main")                 # plain match is EqualFold
        self.assertEqual(fp.first_rule(RULES_T1, "mack/mini/x")["name"], "**")
        self.assertIsNone(fp.first_rule([{"name": "main-pre-*"}], "main"))
        self.assertTrue(fp.glob_re("main-pre-*").match("main-pre-v10-2026-10-28"))
        self.assertFalse(fp.glob_re("runner/*").match("runner/a/b"))

    # F2 (wq-169): gobwas syntax this parser does not model is refused, not guessed
    def test_f2_special_glob_chars_refused(self):
        for name in ("ma[i]n", "release/[!x]*", "a\\*b", "!main", "release/{a,b}", "x}", "x{"):
            with self.subTest(name=name):
                self.assertTrue(fp.is_glob(name))
                with self.assertRaisesRegex(fp.Refused, "refusing instead of guessing"):
                    fp.glob_re(name)

    def test_f2_special_rule_reached_in_order_refuses(self):
        odd = {"name": "ma[i]n", "can_push": True, "enable_whitelist": False, "whitelist_deploy_keys": True,
               "created": 1, "id": 2}
        self.assertEqual(fp.first_rule(RULES_T1 + [odd], "main")["name"], "main")    # plain rule wins first
        with self.assertRaises(fp.Refused):
            fp.first_rule([RULES_T1[2], odd], "main")                                # older odd glob is reached
        self.assertEqual(fp.first_rule([RULES_T1[1], dict(odd, created=2 * 10**9)], "runner/x")["name"],
                         "runner/**")                                                # matched before it is reached

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


class ForgeSql(unittest.TestCase):
    """Forge.deploy_keys / branch_commit compose read-only SQL (write flag never set) and parse the rows."""

    def setUp(self):
        self.calls = []
        calls = self.calls

        def sql(stmt, write=False, role="primary"):
            calls.append((stmt, write))
            if "from branch" in stmt:
                return "a" * 40
            return "5|6|1|vdhict/cluster-wires|1\n7|99|2|vdhict/target|2\n"
        fake = SimpleNamespace(sql=sql, lit=lambda v: "'" + str(v).replace("'", "''") + "'")
        self.mod = mock.patch.dict(sys.modules, {"forge_admin_token": fake})
        self.mod.start()
        self.forge = fp.Forge({"forge_ssh_host": "forge.invalid", "forge_ssh_port": 22}, "/nonexistent")

    def tearDown(self):
        self.mod.stop()

    def test_deploy_keys_parse(self):
        self.assertEqual(self.forge.deploy_keys()[1], {"deploy_key_id": 7, "public_key_id": 99, "repo_id": 2,
                                                       "repo": "vdhict/target", "mode": 2})
        self.assertFalse(any(w for _, w in self.calls))

    def test_branch_commit_scoped_and_read_only(self):
        self.assertEqual(self.forge.branch_commit("VDHICT/Print3d", "main"), "a" * 40)
        stmt, write = self.calls[-1]
        self.assertFalse(write)
        for part in ("lower(r.owner_name) = 'vdhict'", "r.lower_name = 'print3d'", "b.name = 'main'",
                     "not b.is_deleted"):
            self.assertIn(part, stmt)

    def test_sql_readback_retries_until_match(self):
        seq = iter([None, "b" * 40, "a" * 40])
        f = SimpleNamespace(branch_commit=lambda r, b: next(seq))
        with mock.patch.object(fp.time, "sleep", lambda s: None):
            self.assertEqual(fp.sql_readback(f, "VDHICT/print3d", "main", "a" * 40, tries=3), "MATCH")
            self.assertEqual(fp.sql_readback(SimpleNamespace(branch_commit=lambda r, b: None), "x/y", "main",
                                             "a" * 40, tries=2), "MISMATCH (absent)")


@unittest.skipUnless(any(pathlib.Path(p, "client_filter.py").is_file() for p in (
    os.environ.get("PKA_CHASE_BIN", "/nonexistent"), os.path.expanduser("~/pka-chase/bin"),
    os.path.expanduser("~/Code/pka-wires/chase/bin"))), "real client_filter.py not on this host")
class RealClientFilter(PushBase):
    """F1 with the real client_filter loader and a synthetic v2 keyed term file (random key, invented terms; the real
    term list is never read)."""

    def setUp(self):
        super().setUp()
        src = next(pathlib.Path(p) for p in (os.environ.get("PKA_CHASE_BIN", "/nonexistent"),
                                             os.path.expanduser("~/pka-chase/bin"),
                                             os.path.expanduser("~/Code/pka-wires/chase/bin"))
                   if pathlib.Path(p, "client_filter.py").is_file())
        shutil.copy(src / "client_filter.py", self.t / "bin" / "client_filter.py")
        spec = importlib.util.spec_from_file_location("cf_real", self.t / "bin" / "client_filter.py")
        cf = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cf)
        self.home = self.t / "home"
        v2 = self.home / ".config/pka-chase/v2"
        v2.mkdir(parents=True)
        key_hex = cf.new_key()
        key = bytes.fromhex(key_hex)
        sentinel = cf.digest(cf.words("Quuxbarvendor"), key)
        digests = {sentinel} | cf.term_digests(cf.words("Zorbaclient"), key)
        (v2 / "hmac-key").write_text(key_hex + "\n")
        (v2 / "sentinel").write_text(sentinel + "\n")
        (v2 / "client-terms.sha256").write_text(cf.render(digests))
        self.v2 = v2

    def test_real_present_no_hits_allows(self):
        self.assertEqual(self.push_default_terms(self.home), 0, self.out)
        self.assertEqual(self.lines()[0]["payload"]["checks"]["client_terms"], "clean")
        self.assertEqual(self.remote_main(), self.b)

    def test_real_missing_refuses(self):
        os.rename(self.v2 / "client-terms.sha256", self.t / "moved-away")
        self.assertEqual(self.push_default_terms(self.home), 1)
        self.assertIn("fail closed", self.lines()[0]["payload"]["reason"])
        self.assertEqual(self.remote_main(), self.a)

    def test_real_hit_refuses_boolean_only(self):
        sha = self.commit("d", body=" Zorbaclient")
        self.b = sha
        self.assertEqual(self.push_default_terms(self.home), 1)
        p = self.lines()[0]["payload"]
        self.assertEqual(p["checks"]["client_terms"], "HIT")
        self.assertNotIn("orbaclient", json.dumps(p).lower() + self.out.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
