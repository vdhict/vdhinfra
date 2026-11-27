"""chg-2026-11-13-002 wq-169: grant script --execute / --revoke against a fake forge DB (no cluster).
Run: python3 -I hack/ops/tests/test_forge_inventory_grant.py"""
import contextlib
import importlib.util
import io
import os
import re
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.modules["forge_admin_token"] = types.SimpleNamespace(lit=lambda v: "'" + str(v).replace("'", "''") + "'",
                                                         sql=None)
spec = importlib.util.spec_from_file_location("grant", os.path.join(HERE, "..",
                                                                     "chg-2026-11-13-002-forge-inventory-grant.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


class FakeDb:
    """pg_monitor column privileges; understands the script's GRANT/REVOKE and readback only."""

    def __init__(self, cols=None):
        self.cols = {t: set(c) for t, c in (cols or {}).items()}
        self.writes = []

    def __call__(self, stmt, write=False):
        if stmt == g.READBACK:
            return "\n".join("%s(%s)" % (t, ",".join(sorted(c))) for t, c in sorted(self.cols.items()) if c)
        self.writes.append((stmt, write))
        for verb, cols, table in re.findall(r"(GRANT|REVOKE) SELECT \(([^)]*)\) ON (\w+)", stmt):
            s = self.cols.setdefault(table, set())
            for c in (x.strip() for x in cols.split(",")):
                (s.add if verb == "GRANT" else s.discard)(c)
        return ""


def run(argv, db):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = g.main(argv, sql=db)
    return rc, buf.getvalue()


class GrantScript(unittest.TestCase):
    def test_dry_run_writes_nothing(self):
        for argv in ([], ["--revoke"]):
            db = FakeDb()
            self.assertEqual(run(argv, db)[0], 0)
            self.assertEqual(db.writes, [])

    def test_execute_grants_and_matches(self):
        db = FakeDb()
        rc, out = run(["--execute"], db)
        self.assertEqual(rc, 0)
        self.assertIn("READBACK MATCH", out)
        self.assertEqual(db.writes, [(g.STMT, True)])

    def test_revoke_removes_exactly_ours(self):
        db = FakeDb({"login_source": {"id", "name", "type"}})          # C3 grant on another table stays
        run(["--execute"], db)
        rc, out = run(["--revoke", "--execute"], db)
        self.assertEqual(rc, 0, out)
        self.assertIn("READBACK MATCH", out)
        self.assertEqual(db.cols["login_source"], {"id", "name", "type"})
        self.assertFalse(any(db.cols.get(t) for t in g.GRANTS))
        self.assertEqual(db.writes[-1], (g.REVOKE, True))

    def test_revoke_mirrors_grant(self):
        self.assertEqual(g.REVOKE, g.STMT.replace("GRANT", "REVOKE").replace(" TO pg_monitor", " FROM pg_monitor"))

    def test_revoke_left_over_column_is_mismatch(self):
        self.assertFalse(g.verdict("deploy_key(mode)", revoke=True))
        self.assertTrue(g.verdict("login_source(id)", revoke=True))
        self.assertFalse(g.verdict("deploy_key(id,key_id,repo_id)", revoke=False))


if __name__ == "__main__":
    unittest.main()
