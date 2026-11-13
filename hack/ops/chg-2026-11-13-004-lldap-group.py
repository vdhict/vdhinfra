#!/usr/bin/env python3
"""chg-2026-11-13-004: lldap group owui-profiel-4 with the owner's account as its ONLY member.

Open WebUI syncs group membership from the OIDC groups claim on every login (ENABLE_OAUTH_GROUP_MANAGEMENT, creation
off), so the OWUI group owui-profiel-4 keeps the owner only while lldap says so too.
  mode dry | apply | verify | rollback   (rollback: owner removed from the group, group deleted)
env: LLDAP_URL (http://127.0.0.1:<port-forward>), LLDAP_ADMIN (uid or DN), LLDAP_ADMIN_PASS, OWNER_EMAIL.
The owner's uid/email are matched in-process and never printed; neither is the credential. Prints booleans and counts.
"""
import os
import sys

import httpx

E = os.environ
MODE = sys.argv[1]
assert MODE in ("dry", "apply", "verify", "rollback"), MODE
GROUP = "owui-profiel-4"
FAMILY = ("gezin", "owui-profiel-1", "owui-profiel-2", "owui-profiel-3", "owui-keuken")


def gql(tok, query, variables=None):
    r = httpx.post(E["LLDAP_URL"] + "/api/graphql", json={"query": query, "variables": variables or {}},
                   headers={"Authorization": "Bearer " + tok}, timeout=20)
    r.raise_for_status()
    d = r.json()
    if d.get("errors"):
        raise SystemExit("graphql error (%d), message withheld: it can carry user ids" % len(d["errors"]))
    return d["data"]


admin = E["LLDAP_ADMIN"].split(",")[0].split("=", 1)[-1]
r = httpx.post(E["LLDAP_URL"] + "/auth/simple/login", json={"username": admin, "password": E["LLDAP_ADMIN_PASS"]}, timeout=20)
if r.status_code != 200:
    raise SystemExit("lldap admin login http %d (credential not printed)" % r.status_code)
tok = r.json()["token"]
# the owner is found by email (matched in-process, never printed); exactly one account must carry it
hits = [u for u in gql(tok, "{ users { id email } }")["users"] if (u.get("email") or "").lower() == E["OWNER_EMAIL"].lower()]
print("owner accounts with the Open WebUI owner email:", len(hits))
assert len(hits) == 1, "owner account not found exactly once"
owner = gql(tok, "query($id: String!) { user(userId: $id) { id email groups { displayName } } }", {"id": hits[0]["id"]})["user"]
og = sorted(g["displayName"] for g in owner["groups"])
print("owner in admins:", "admins" in og, "owner in family groups:", [g for g in og if g in FAMILY])

groups = {g["displayName"]: g["id"] for g in gql(tok, "{ groups { id displayName } }")["groups"]}
print("group exists:", GROUP in groups)
if MODE == "apply":
    if GROUP not in groups:
        gql(tok, "mutation($n: String!) { createGroup(name: $n) { id } }", {"n": GROUP})
        groups = {g["displayName"]: g["id"] for g in gql(tok, "{ groups { id displayName } }")["groups"]}
    if GROUP not in og:
        gql(tok, "mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }",
            {"u": owner["id"], "g": groups[GROUP]})
if MODE == "rollback" and GROUP in groups:
    if GROUP in og:
        gql(tok, "mutation($u: String!, $g: Int!) { removeUserFromGroup(userId: $u, groupId: $g) { ok } }",
            {"u": owner["id"], "g": groups[GROUP]})
    gql(tok, "mutation($g: Int!) { deleteGroup(groupId: $g) { ok } }", {"g": groups[GROUP]})

groups = {g["displayName"]: g["id"] for g in gql(tok, "{ groups { id displayName } }")["groups"]}
err = []
if MODE in ("apply", "verify"):
    if GROUP not in groups:
        err.append("group missing")
    else:
        mem = gql(tok, "query($g: Int!) { group(groupId: $g) { users { id } } }", {"g": groups[GROUP]})["group"]["users"]
        only = [u["id"] for u in mem] == [owner["id"]]
        print("group members:", len(mem), "owner only:", only)
        if not only:
            err.append("group members")
if MODE == "rollback" and GROUP in groups:
    err.append("group still present")
print("VERIFY", "0 fouten" if not err else err)
