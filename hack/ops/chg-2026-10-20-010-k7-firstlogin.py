#!/usr/bin/env python3
"""chg-2026-10-20-010 K7 (Argus 30-10 09:04:20Z): synthetic FIRST LOGIN of a child account into Open WebUI.

Run by hack/ops/chg-2026-10-20-010-k7-firstlogin.sh (port-forwards + credentials in env, never argv, never printed).
  S1 the test user mirrors the real profiel-2 user's groups: lldap groups gezin + owui-profiel-2 (read first, the
     real user is checked to be in exactly those two of the family groups; usernames never printed).
  S2 after the first OIDC login through Authelia: OWUI role user (not pending/admin), group owui-profiel-2 only,
     the model list holds only hermes-agent-profiel-2 of the agents, a request naming another agent is refused
     (no model call is made for the own agent).
  S3 cleanup deletes the OWUI account and the lldap user, and reads both back as absent (also after a failure).
Synthetic only: user c010-k7-<rand>, email ...@acceptatie.invalid, random password. Prints PASS/FAIL lines, ids as
classes only. Exit 0 iff every check passed and cleanup read back clean.
env: LLDAP_URL (http://127.0.0.1:<pf>), LLDAP_LDAP (127.0.0.1:<pf>), LLDAP_BASE_DN, LLDAP_ADMIN, LLDAP_ADMIN_PASS,
     OWUI_ADMIN_KEY, CHAT (https://chat.bluejungle.net), AUTH (https://auth.bluejungle.net), K7_REAL_USER (the real
     profiel-2 username, matched in-process, never printed)
"""
import json
import os
import re
import secrets
import sys
from urllib.parse import urljoin, urlparse, parse_qs

import httpx
import ldap3

E = os.environ
CHAT, AUTH = E["CHAT"].rstrip("/"), E["AUTH"].rstrip("/")
fails = []


def ok(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg, flush=True)
    if not cond:
        fails.append(msg)
    return cond


def gql(tok, query, variables=None):
    r = httpx.post(E["LLDAP_URL"] + "/api/graphql", json={"query": query, "variables": variables or {}},
                   headers={"Authorization": "Bearer " + tok}, timeout=20)
    r.raise_for_status()
    d = r.json()
    if d.get("errors"):
        raise RuntimeError("graphql error: " + "; ".join(str(x.get("message", ""))[:80] for x in d["errors"]))
    return d["data"]


def owui(method, path, tok, **kw):
    return httpx.request(method, CHAT + path, headers={"Authorization": "Bearer " + tok}, timeout=60, **kw)


# LLDAP_ADMIN is the admin's DN (lldap-secret LLDAP_USER_DN): login with its uid, LDAP bind with the DN itself
ADMIN_DN = E["LLDAP_ADMIN"] if "=" in E["LLDAP_ADMIN"] else "uid=%s,ou=people,%s" % (E["LLDAP_ADMIN"], E["LLDAP_BASE_DN"])
ADMIN_UID = ADMIN_DN.split(",")[0].split("=", 1)[1]
uid = "c010-k7-" + secrets.token_hex(4)
pw = secrets.token_urlsafe(24)
mail = uid + "@acceptatie.invalid"
created_lldap, owui_uid = False, None
r = httpx.post(E["LLDAP_URL"] + "/auth/simple/login", json={"username": ADMIN_UID, "password": E["LLDAP_ADMIN_PASS"]}, timeout=20)
if r.status_code != 200:
    print("FAIL lldap admin login http %d (credential not printed)" % r.status_code); print("RESULT K7 RED (nothing created)"); sys.exit(1)
ltok = r.json()["token"]
try:
    groups = {g["displayName"]: g["id"] for g in gql(ltok, "{ groups { id displayName } }")["groups"]}
    fam = ("gezin", "owui-profiel-1", "owui-profiel-2", "owui-profiel-3", "owui-keuken", "admins")
    real = gql(ltok, "query($id: String!) { user(userId: $id) { groups { displayName } } }", {"id": E["K7_REAL_USER"]})["user"]
    real_groups = sorted(g["displayName"] for g in real["groups"] if g["displayName"] in fam)
    ok(real_groups == ["gezin", "owui-profiel-2"], "S1 the real profiel-2 user is in exactly gezin + owui-profiel-2 of the family groups")
    # create the synthetic user with the same two groups
    gql(ltok, "mutation($u: CreateUserInput!) { createUser(user: $u) { id } }",
        {"u": {"id": uid, "email": mail, "displayName": "c010 K7 synthetic"}})
    created_lldap = True
    for g in ("gezin", "owui-profiel-2"):
        gql(ltok, "mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }", {"u": uid, "g": groups[g]})
    host, port = E["LLDAP_LDAP"].rsplit(":", 1)
    base = E["LLDAP_BASE_DN"]
    conn = ldap3.Connection(ldap3.Server(host, port=int(port)), user=ADMIN_DN,
                            password=E["LLDAP_ADMIN_PASS"], auto_bind=True)
    ok(conn.extend.standard.modify_password("uid=%s,ou=people,%s" % (uid, base), new_password=pw) is not False,
       "setup synthetic lldap user: groups gezin + owui-profiel-2, password set (LDAP password modify)")
    conn.unbind()
    mine = sorted(g["displayName"] for g in gql(ltok, "query($id: String!) { user(userId: $id) { groups { displayName } } }", {"id": uid})["user"]["groups"])
    ok(mine == ["gezin", "owui-profiel-2"], "S1 synthetic user groups == the real user's family groups")

    counts0 = {x["name"]: x.get("member_count") for x in owui("GET", "/api/v1/groups/", E["OWUI_ADMIN_KEY"]).json()}
    # first login: chat -> Authelia (first factor, consent) -> OIDC callback -> OWUI token
    c = httpx.Client(follow_redirects=False, timeout=30)
    def hop(r):   # trace: host + path + status only (never a query string: it carries codes/state)
        u = urlparse(str(r.url)); print("  hop %s %s%s -> %d" % (r.request.method, u.netloc, u.path, r.status_code), flush=True)
        return r
    def follow(r, n=0):
        hop(r)
        while r.is_redirect and n < 12:
            r = hop(c.get(urljoin(str(r.url), r.headers["location"]))); n += 1
        return r
    r = follow(c.get(CHAT + "/oauth/oidc/login"))
    portal = urlparse(str(r.url)); q = parse_qs(portal.query)
    flow, flow_id = q.get("flow", [None])[0], q.get("flow_id", [None])[0]
    ok(portal.netloc == urlparse(AUTH).netloc and bool(flow_id), "login redirected to the Authelia portal with an OIDC flow")
    r = c.post(AUTH + "/api/firstfactor", json={"username": uid, "password": pw, "keepMeLoggedIn": False,
                                                "flow": flow, "flowID": flow_id})
    ok(r.status_code == 200 and r.json().get("status") == "OK", "Authelia first factor accepted (one_factor policy for gezin)")
    nxt = (r.json().get("data") or {}).get("redirect")
    u = urlparse(nxt or ""); print("  firstfactor -> %s%s" % (u.netloc, u.path), flush=True)
    g = c.get(AUTH + "/api/oidc/consent", params={"flow_id": flow_id})
    gd = g.json().get("data") or {}
    print("  consent GET -> %d keys %s" % (g.status_code, sorted(gd)), flush=True)
    if g.status_code == 200 and gd.get("client_id"):
        pr = c.post(AUTH + "/api/oidc/consent", json={"flow_id": flow_id, "client_id": gd["client_id"], "consent": True, "pre_configure": False})
        pd = pr.json().get("data") or {}
        ok(pr.status_code == 200 and bool(pd.get("redirect_uri")), "Authelia consent given (first login)")
        nxt = pd.get("redirect_uri") or nxt
    r = follow(c.get(urljoin(AUTH, nxt))) if nxt else r
    tok = c.cookies.get("token") or (re.search(r"token=([A-Za-z0-9._-]+)", str(r.url)) or [None, None])[1]
    ok(bool(tok), "OIDC callback gave an Open WebUI session for the synthetic user")
    if tok:
        me = owui("GET", "/api/v1/auths/", tok).json()
        owui_uid = me.get("id")
        ok(me.get("role") == "user", "S2 role is user (not pending, not admin): got class %s" % me.get("role"))
        own = owui("GET", "/api/v1/groups/", tok)
        gs = sorted(x["name"] for x in own.json()) if own.status_code == 200 else None
        ok(gs == ["owui-profiel-2"], "S2 the user's own OWUI groups == [owui-profiel-2] (got %s group(s))" % (len(gs) if gs is not None else "no list"))
        counts1 = {x["name"]: x.get("member_count") for x in owui("GET", "/api/v1/groups/", E["OWUI_ADMIN_KEY"]).json()}
        delta = {k: (counts1.get(k) or 0) - (counts0.get(k) or 0) for k in set(counts0) | set(counts1)}
        ok({k: v for k, v in delta.items() if v} == {"owui-profiel-2": 1}, "S2 admin view: member_count +1 on owui-profiel-2 only")
        ids = sorted(m["id"] for m in owui("GET", "/api/models", tok).json().get("data", []) if m["id"].startswith("hermes-agent"))
        ok(ids == ["hermes-agent-profiel-2"], "S2 only hermes-agent-profiel-2 of the agents is listed")
        for other in ("hermes-agent-profiel-1", "hermes-agent-profiel-3"):
            rr = owui("POST", "/api/chat/completions", tok, json={"model": other, "stream": False,
                                                                     "messages": [{"role": "user", "content": "k7 synthetic"}]})
            ok(rr.status_code >= 400, "S2 a request naming %s is refused (http %d)" % (other, rr.status_code))
except Exception as e:
    ok(False, "run aborted: %s" % type(e).__name__)
finally:
    # S3 cleanup, always
    try:
        if owui_uid is None:   # login may have created the account even if a later step failed: find it by email
            for u in owui("GET", "/api/v1/users/all", E["OWUI_ADMIN_KEY"]).json().get("users", []):
                if u.get("email") == mail:
                    owui_uid = u["id"]
        if owui_uid:
            owui("DELETE", "/api/v1/users/" + owui_uid, E["OWUI_ADMIN_KEY"])
        left = [u for u in owui("GET", "/api/v1/users/all", E["OWUI_ADMIN_KEY"]).json().get("users", []) if u.get("email") == mail]
        ok(not left, "S3 OWUI account deleted and read back absent")
    except Exception as e:
        ok(False, "S3 OWUI cleanup failed: %s" % type(e).__name__)
    try:
        if created_lldap:
            gql(ltok, "mutation($u: String!) { deleteUser(userId: $u) { ok } }", {"u": uid})
        users = [u["id"] for u in gql(ltok, "{ users { id } }")["users"]]
        ok(uid not in users, "S3 lldap test user deleted and read back absent")
    except Exception as e:
        ok(False, "S3 lldap cleanup failed: %s" % type(e).__name__)
print("RESULT K7 %s (%d failed)" % ("GREEN" if not fails else "RED", len(fails)))
sys.exit(1 if fails else 0)
