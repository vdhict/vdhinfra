#!/usr/bin/env python3
"""Create the Home Assistant team account `mypka-team` (admin) and mint ONE long-lived access token for it.

Owner decision 13-11 (Larry handoff 110256, AGR-126 addendum "HA: team alles"). Run with the toolchain venv (websockets,
httpx). env: HA_BASE (http://172.16.2.237:8123), HA_ADMIN_TOKEN (Atlas's existing admin token, from its file).
The new token goes to STDOUT ONLY (meant to be piped straight into `kubectl create secret ... --from-file=/dev/stdin`);
every status line goes to stderr and never carries a token or the throwaway password. The password is random, used
once for the login flow that mints the token, and never stored: the account is usable through its token only.
Refuses if a user named mypka-team already exists (no second account, no silent token rotation).
"""
import asyncio
import json
import os
import secrets
import sys

import httpx
import websockets

BASE = os.environ["HA_BASE"].rstrip("/")
NAME = "mypka-team"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


async def ws_session(token):
    ws = await websockets.connect(BASE.replace("http", "ws", 1) + "/api/websocket", max_size=2**24)
    assert json.loads(await ws.recv())["type"] == "auth_required"
    await ws.send(json.dumps({"type": "auth", "access_token": token}))
    assert json.loads(await ws.recv())["type"] == "auth_ok", "ws auth failed"
    n = [0]

    async def call(msg):
        n[0] += 1
        await ws.send(json.dumps({"id": n[0], **msg}))
        while True:
            r = json.loads(await ws.recv())
            if r.get("id") == n[0]:
                if not r.get("success"):
                    raise SystemExit(f"ws {msg['type']} failed: {(r.get('error') or {}).get('code')}")
                return r.get("result")
    return ws, call


async def main():
    ws, call = await ws_session(os.environ["HA_ADMIN_TOKEN"])
    users = await call({"type": "config/auth/list"})
    if any(u.get("name") == NAME or any(c.get("data", {}).get("username") == NAME for c in u.get("credentials") or []) for u in users):
        raise SystemExit(f"REFUSED: a user {NAME} already exists")
    u = await call({"type": "config/auth/create", "name": NAME, "group_ids": ["system-admin"], "local_only": False})
    uid = u["user"]["id"]
    pw = secrets.token_urlsafe(32)
    await call({"type": "config/auth_provider/homeassistant/create", "user_id": uid, "username": NAME, "password": pw})
    await ws.close()
    log("user created: admin group, local_only False")
    cid = BASE + "/"
    async with httpx.AsyncClient(timeout=20) as h:
        f = (await h.post(BASE + "/auth/login_flow", json={"client_id": cid, "handler": ["homeassistant", None], "redirect_uri": cid})).json()
        r = (await h.post(f"{BASE}/auth/login_flow/{f['flow_id']}", json={"client_id": cid, "username": NAME, "password": pw})).json()
        assert r.get("type") == "create_entry", "login flow did not finish"
        t = (await h.post(BASE + "/auth/token", data={"grant_type": "authorization_code", "code": r["result"], "client_id": cid})).json()
    pw = None
    ws, call = await ws_session(t["access_token"])
    me = await call({"type": "auth/current_user"})
    llat = await call({"type": "auth/long_lived_access_token", "client_name": "mypka-team (AGR-126, 13-11)", "lifespan": 3650})
    await ws.close()
    async with httpx.AsyncClient(timeout=20) as h:
        code = (await h.get(BASE + "/api/", headers={"Authorization": "Bearer " + llat})).status_code
    log(f"token minted: is_admin {me.get('is_admin')}, is_owner {me.get('is_owner')}, GET /api/ with it -> {code}, length {len(llat)}")
    assert me.get("is_admin") is True and code == 200
    sys.stdout.write(llat)


asyncio.run(main())
