#!/usr/bin/env python3
"""chg-2026-11-13-002 K1 (wq-169): column grants so the CNPG exporter (pg_monitor) on forge-pg can run the forge
deploy-key inventory queries in devtools/forge-pg-oidc-links-queries (forgejo_deploy_key, forgejo_protected_branch,
forgejo_inventory). Same route as the Argus C3 OIDC-links grant (chg-2026-11-04-004 grant_step).

Only ids, modes, flags, rule names and timestamps: no key content, fingerprint, deploy key name or user list.
Default is a dry run (prints the statement and the current grants). --execute writes on the primary (refused when it
is in recovery) and reads back. Run it once AFTER the ConfigMap is on main; until then the posture scan reports
"forge inventory unavailable". --revoke undoes exactly these column grants (rollback, Argus wq-169 G-d); it is a dry
run too unless --execute is also given, and its readback must show none of these columns left.

    python3 hack/ops/chg-2026-11-13-002-forge-inventory-grant.py [--revoke] [--execute]
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import forge_admin_token as fat  # noqa: E402

GRANTS = {
    "deploy_key": "id, key_id, repo_id, mode",
    "repository": "id, owner_name, lower_name",
    "protected_branch": "id, repo_id, branch_name, can_push, enable_whitelist, whitelist_deploy_keys, created_unix",
}
STMT = " ".join("GRANT SELECT (%s) ON %s TO pg_monitor;" % (cols, t) for t, cols in GRANTS.items())
REVOKE = " ".join("REVOKE SELECT (%s) ON %s FROM pg_monitor;" % (cols, t) for t, cols in GRANTS.items())
READBACK = ("SELECT table_name || '(' || string_agg(column_name, ',' ORDER BY column_name) || ')' "
            "FROM information_schema.column_privileges WHERE grantee='pg_monitor' AND table_name IN (%s) "
            "GROUP BY table_name ORDER BY 1" % ", ".join(fat.lit(t) for t in GRANTS))


def parse_readback(text):
    got = {}
    for part in text.split():
        t, _, cols = part.partition("(")
        got[t] = set(cols.rstrip(")").split(","))
    return got


def verdict(after, revoke):
    """Grant: every column granted. Revoke: none of these columns left (other grants on the table are not ours)."""
    want = {t: {c.strip() for c in cols.split(",")} for t, cols in GRANTS.items()}
    got = parse_readback(after)
    if revoke:
        return not any(want[t] & got.get(t, set()) for t in want)
    return all(want[t] <= got.get(t, set()) for t in want)


def main(argv, sql=None):
    sql = sql or fat.sql
    revoke = "--revoke" in argv
    stmt = REVOKE if revoke else STMT
    print("statement: " + stmt)
    print("before: " + (sql(READBACK).replace("\n", " ") or "none"))
    if "--execute" not in argv:
        print("DRY RUN: nothing written (add --execute)")
        return 0
    sql(stmt, write=True)
    after = sql(READBACK).replace("\n", " ")
    print("after: " + (after or "none"))
    ok = verdict(after, revoke)
    print("READBACK %s" % ("MATCH" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
