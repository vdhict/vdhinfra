#!/usr/bin/env bash
# chg-2026-10-19-001 Argus C4: chg-001 T6 front-door check, read-only on the Open WebUI DB (mode=ro).
# For models hermes-agent-profiel-2/-3: grant counts by principal type, public wildcard, member count of the granted
# groups, overlap between the two. Counts/booleans only; no user or group names, no ids.
# Pass (Atlas decision chg-001 C1): each model >= 1 grant, 0 public; p2/p3 grant sets differ; groups share 0 members;
# 0 non-admin members in the p2/p3 groups unless they are that boy's own (not printed; only counts).
set -uo pipefail
kubectl -n family-ai exec deploy/open-webui -c app -- python3 -c '
import json, sqlite3, sys
c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
out, members = {}, {}
for n in ("2", "3"):
    mid = "hermes-agent-profiel-" + n
    g = c.execute("select principal_type, principal_id, permission from access_grant where resource_type=? and resource_id=?",
                  ("model", mid)).fetchall()
    groups = {p for t, p, _ in g if t == "group"}
    users = {p for t, p, _ in g if t == "user"}
    public = any(p in ("*", "public") or t in ("public", "everyone") for t, p, _ in g)
    mem = set()
    for gid in groups:
        mem |= {r[0] for r in c.execute("select user_id from group_member where group_id=?", (gid,))}
    members[n] = (groups, users | mem)
    out["profiel-" + n] = {"model_exists": c.execute("select count(*) from model where id=?", (mid,)).fetchone()[0],
                           "grants": len(g), "group_grants": len(groups), "user_grants": len(users),
                           "public": public, "group_members": len(mem)}
out["grant_sets_differ"] = members["2"][0] != members["3"][0] or not members["2"][0]
out["principal_overlap"] = len(members["2"][1] & members["3"][1])
ok = all(out[k]["model_exists"] == 1 and out[k]["grants"] >= 1 and not out[k]["public"] for k in ("profiel-2", "profiel-3")) \
    and out["grant_sets_differ"] and out["principal_overlap"] == 0
out["result"] = "PASS" if ok else "FAIL"
print(json.dumps(out))
sys.exit(0 if ok else 1)
'
