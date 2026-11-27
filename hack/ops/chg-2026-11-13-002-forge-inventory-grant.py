#!/usr/bin/env python3
"""chg-2026-11-13-002 K1 (wq-169): column grants so the CNPG exporter (pg_monitor) on forge-pg can run the forge
deploy-key inventory queries in devtools/forge-pg-oidc-links-queries (forgejo_deploy_key, forgejo_protected_branch,
forgejo_inventory). Same route as the Argus C3 OIDC-links grant (chg-2026-11-04-004 grant_step).

Only ids, modes, flags, rule names and timestamps: no key content, fingerprint, deploy key name or user list.
Default is a dry run (prints the statement and the current grants). --execute writes on the primary (refused when it
is in recovery) and reads back. Run it once AFTER the ConfigMap is on main; until then the posture scan reports
"forge inventory unavailable".

    python3 hack/ops/chg-2026-11-13-002-forge-inventory-grant.py [--execute]
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
READBACK = ("SELECT table_name || '(' || string_agg(column_name, ',' ORDER BY column_name) || ')' "
            "FROM information_schema.column_privileges WHERE grantee='pg_monitor' AND table_name IN (%s) "
            "GROUP BY table_name ORDER BY 1" % ", ".join(fat.lit(t) for t in GRANTS))


def main(argv):
    print("statement: " + STMT)
    print("before: " + (fat.sql(READBACK).replace("\n", " ") or "none"))
    if "--execute" not in argv:
        print("DRY RUN: nothing written (add --execute)")
        return 0
    fat.sql(STMT, write=True)
    after = fat.sql(READBACK).replace("\n", " ")
    print("after: " + after)
    want = {t: sorted(c.strip() for c in cols.split(",")) for t, cols in GRANTS.items()}
    got = {}
    for part in after.split():
        t, _, cols = part.partition("(")
        got[t] = sorted(cols.rstrip(")").split(","))
    ok = all(set(want[t]) <= set(got.get(t, [])) for t in want)
    print("READBACK %s" % ("MATCH" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
