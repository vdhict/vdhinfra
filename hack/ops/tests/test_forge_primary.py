"""wq-115: forge-pg primary is resolved at run time (CNPG status.currentPrimary), fails closed, writes prove
pg_is_in_recovery()=f. Offline: a stub kubectl answers from env vars; nothing touches a cluster.
Run: python3 hack/ops/tests/test_forge_primary.py"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib")
TMP = tempfile.mkdtemp(prefix="forge-primary-test-")
STUB = os.path.join(TMP, "kubectl")
with open(STUB, "w") as f:  # STUB_STATUS = "<current>|<target>", STUB_RECOVERY = f|t; logs exec pod names
    f.write('#!/bin/sh\ncase "$*" in\n'
            '  *cluster.postgresql.cnpg.io*) printf %s "$STUB_STATUS";;\n'
            '  *exec*) echo "$*" | sed -n "s/.*exec \\([^ ]*\\) .*/\\1/p" >> "$STUB_LOG"\n'
            '          printf "%s\\n" "$@" > "$STUB_LOG.argv"\n'
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


def last_argv():
    with open(os.environ["STUB_LOG"] + ".argv") as f:
        return f.read().split("\n")


class ReadOnlyGuard(unittest.TestCase):
    """R1 (Argus wq-169): the read-only SET must be its own -c, before the statement; never prefixed into it."""

    def check(self, argv, statement):
        i = argv.index(statement)
        self.assertEqual(argv[i - 1], "-c")
        self.assertEqual(argv[i - 3:i - 1], ["-c", "SET default_transaction_read_only=on"])
        self.assertFalse(any("read_only" in a and a != "SET default_transaction_read_only=on" for a in argv))

    def test_py_read_is_separate_c(self):
        env("forge-pg-2|forge-pg-2")
        fat.sql("SELECT 1")
        self.check(last_argv(), "SELECT 1")

    def test_py_write_has_no_read_only_set(self):
        env("forge-pg-2|forge-pg-2", "f")
        fat.sql("UPDATE x SET y=1", write=True)
        self.assertNotIn("SET default_transaction_read_only=on", last_argv())

    def test_sh_read_is_separate_c(self):
        env("forge-pg-2|forge-pg-2")
        e = dict(os.environ, PATH=TMP + ":" + os.environ["PATH"])
        r = subprocess.run(["bash", "-c", 'source "%s/forge_admin_token.sh"; fat_sql "SELECT 1"' % LIB],
                           env=e, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.check(last_argv(), "SELECT 1")


@unittest.skipUnless(os.environ.get("FORGE_PG_LIVE") == "1", "live probe: FORGE_PG_LIVE=1 (read-only, needs kubectl)")
class ReadOnlyGuardLive(unittest.TestCase):
    """R1 proof on the real forge-pg primary: the guard is on inside the statement's transaction."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("fat_live", os.path.join(LIB, "forge_admin_token.py"))
        self.live = importlib.util.module_from_spec(spec)
        with unittest.mock.patch.dict(os.environ, {"KUBECTL": os.environ.get("FORGE_PG_KUBECTL", "kubectl")}):
            spec.loader.exec_module(self.live)

    def test_show_transaction_read_only_is_on(self):
        self.assertEqual(self.live.sql("SHOW transaction_read_only"), "on")

    def test_write_attempt_is_refused_by_postgres(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.live.sql("CREATE TEMP TABLE r1_probe (x int)")    # temp table: harmless even if it ran

    def test_sh_show_transaction_read_only_is_on(self):
        r = subprocess.run(["bash", "-c", 'source "%s/forge_admin_token.sh"; fat_sql "SHOW transaction_read_only"'
                            % LIB], env=dict(os.environ, PATH=os.environ.get("FORGE_PG_PATH", os.environ["PATH"])),
                           capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "on"), r.stderr)


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
