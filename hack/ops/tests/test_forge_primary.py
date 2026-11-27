"""wq-115: forge-pg primary is resolved at run time (CNPG status.currentPrimary), fails closed, writes prove
pg_is_in_recovery()=f. Offline: a stub kubectl answers from env vars; nothing touches a cluster.
Run: python3 hack/ops/tests/test_forge_primary.py"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib")
TMP = tempfile.mkdtemp(prefix="forge-primary-test-")
STUB = os.path.join(TMP, "kubectl")
with open(STUB, "w") as f:  # STUB_STATUS = "<current>|<target>", STUB_RECOVERY = f|t; logs exec pod names
    f.write('#!/bin/sh\ncase "$*" in\n'
            '  *cluster.postgresql.cnpg.io*) printf %s "$STUB_STATUS";;\n'
            '  *exec*) echo "$*" | sed -n "s/.*exec \\([^ ]*\\) .*/\\1/p" >> "$STUB_LOG"\n'
            '          case "$*" in *pg_is_in_recovery*) printf %s "$STUB_RECOVERY";; *) printf ok;; esac;;\n'
            'esac\n')
os.chmod(STUB, 0o755)
os.environ["KUBECTL"] = STUB
os.environ["STUB_LOG"] = os.path.join(TMP, "exec.log")
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fat", os.path.join(LIB, "forge_admin_token.py"))
fat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fat)


def env(status, recovery="f"):
    os.environ["STUB_STATUS"], os.environ["STUB_RECOVERY"] = status, recovery
    open(os.environ["STUB_LOG"], "w").close()


def execs():
    return open(os.environ["STUB_LOG"]).read().split()


class PyLib(unittest.TestCase):
    def test_resolves_current_primary(self):
        env("forge-pg-2|forge-pg-2")
        self.assertEqual(fat.pg_pod(), "forge-pg-2")

    def test_empty_fails_closed(self):
        env("|")
        with self.assertRaises(RuntimeError):
            fat.pg_pod()

    def test_switchover_in_flight_fails_closed(self):
        env("forge-pg-2|forge-pg-1")
        with self.assertRaises(RuntimeError):
            fat.pg_pod()

    def test_write_on_primary_runs(self):
        env("forge-pg-2|forge-pg-2", "f")
        fat.sql("UPDATE x SET y=1", write=True)
        self.assertEqual(set(execs()), {"forge-pg-2"})
        self.assertEqual(len(execs()), 2)  # recovery probe + the statement

    def test_write_refused_when_in_recovery(self):
        env("forge-pg-2|forge-pg-2", "t")
        with self.assertRaises(RuntimeError):
            fat.sql("UPDATE x SET y=1", write=True)
        self.assertEqual(len(execs()), 1)  # only the probe ran

    def test_no_hardcoded_instance(self):
        for rel in ("chg-2026-11-04-004-forge-oidc-k8s-secrets.py", "chg-2026-10-01-001-c5-bot-harden.py"):
            src = open(os.path.join(HERE, "..", rel)).read()
            self.assertNotIn("forge-pg-1", src, rel)
            self.assertNotIn("forge-pg-2", src, rel)


class ShLib(unittest.TestCase):
    def run_sh(self, code):
        e = dict(os.environ, PATH=TMP + ":" + os.environ["PATH"])
        return subprocess.run(["bash", "-c", 'source "%s/forge_admin_token.sh"; %s' % (LIB, code)],
                              env=e, capture_output=True, text=True)

    def test_resolves(self):
        env("forge-pg-2|forge-pg-2")
        r = self.run_sh("fat_pg_pod")
        self.assertEqual((r.returncode, r.stdout), (0, "forge-pg-2"))

    def test_empty_fails_closed(self):
        env("|")
        self.assertNotEqual(self.run_sh("fat_pg_pod").returncode, 0)

    def test_write_refused_in_recovery(self):
        env("forge-pg-2|forge-pg-2", "t")
        self.assertNotEqual(self.run_sh("fat_sql 'UPDATE x SET y=1' rw").returncode, 0)
        self.assertEqual(len(execs()), 1)

    def test_write_on_primary(self):
        env("forge-pg-2|forge-pg-2", "f")
        self.assertEqual(self.run_sh("fat_sql 'UPDATE x SET y=1' rw").returncode, 0)
        self.assertEqual(set(execs()), {"forge-pg-2"})


if __name__ == "__main__":
    unittest.main()
