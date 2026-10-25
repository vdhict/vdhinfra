#!/usr/bin/env python3
"""dispatcharr-bootstrap (chg-2026-10-25-006): configure Dispatcharr via its API.

Idempotent: every step reads first and writes only what differs. Endpoints
were read from the Dispatcharr v0.33.0 source, not guessed:

  1. admin       GET/POST /api/accounts/initialize-superuser/
                 (apps/accounts/api_views.py initialize_superuser; POST is
                 accepted only while no user_level>=10 exists, from a
                 private-range client; this pod is 10.42.x)
  2. login       POST /api/accounts/token/ -> JWT "access" (Bearer)
  3. network     CoreSettings key "network_access" via /api/core/settings/
                 value {UI, STREAMS, XC_API, M3U_EPG: "cidr,cidr"}
                 (core/models.py NETWORK_ACCESS_KEY, dispatcharr/utils.py
                 network_access_allowed)
  4. provider    only when PROVIDER_SERVER_URL is set, else
                 "provider: not configured" and exit 0:
                 /api/m3u/accounts/  account_type "XC", max_streams 1
                   (the account's max_streams is synced to its default
                   profile, which enforces the connection pool)
                 /api/epg/sources/   source_type "xmltv",
                   url <server>/xmltv.php?username=..&password=..

LOGGING RULE: only step names, HTTP status codes, counts and booleans. Never
a URL, username, password, token or response body. Exceptions are reported
by class name only (their messages can contain the URL).
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("DISPATCHARR_URL", "http://dispatcharr.dispatcharr.svc.cluster.local:9191").rstrip("/")
ACCESS_KEYS = ("UI", "STREAMS", "XC_API", "M3U_EPG")
ACCOUNT_NAME = "provider"
EPG_NAME = "provider"


class StepError(Exception):
    """A step failed. The message is a step name, never a value."""


def log(step, **fields):
    out = []
    for key, value in fields.items():
        if isinstance(value, (bool, int)) or value is None:
            out.append(f"{key}={value}")
        elif isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,40}", value):
            out.append(f"{key}={value}")
        else:
            out.append(f"{key}=<redacted>")
    print(f"[dispatcharr-bootstrap] {step} " + " ".join(out), flush=True)


def env(name, required=True):
    value = os.environ.get(name, "")
    if required and not value:
        raise StepError(f"missing-env-{name}")
    return value


def api(method, path, body=None, token=None, timeout=60):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw, status = response.read(), response.status
    except urllib.error.HTTPError as err:
        return err.code, None
    except Exception as err:  # noqa: BLE001 - class name only
        raise StepError(f"api-{type(err).__name__}") from None
    if not raw:
        return status, None
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, None


def as_list(data):
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("results"), list):
        return data["results"]
    return []


def wait_ready():
    deadline = time.time() + 900
    last = 0
    while time.time() < deadline:
        try:
            last, data = api("GET", "/api/core/version/", timeout=10)
            if last == 200 and isinstance(data, dict):
                log("wait", status=last, ready=True)
                return
        except StepError:
            last = 0
        time.sleep(10)
    log("wait", status=last, ready=False)
    raise StepError("wait")


def step_admin(user, password):
    status, data = api("GET", "/api/accounts/initialize-superuser/")
    exists = isinstance(data, dict) and data.get("superuser_exists") is True
    log("1.admin-state", status=status, exists=exists)
    if status != 200:
        raise StepError("1.admin-state")
    if exists:
        return
    status, data = api("POST", "/api/accounts/initialize-superuser/", {"username": user, "password": password})
    created = isinstance(data, dict) and data.get("superuser_exists") is True
    log("1.admin-create", status=status, created=created)
    if status != 200 or not created:
        raise StepError("1.admin-create")


def step_login(user, password):
    status, data = api("POST", "/api/accounts/token/", {"username": user, "password": password})
    token = data.get("access") if isinstance(data, dict) else None
    log("2.login", status=status, token=bool(token))
    if status != 200 or not token:
        # A pre-existing admin that is not ours lands here: fail, never reset.
        raise StepError("2.login")
    return token


def step_network(token, cidrs):
    status, data = api("GET", "/api/core/settings/", token=token)
    rows = [r for r in as_list(data) if isinstance(r, dict) and r.get("key") == "network_access"]
    log("3.network-read", status=status, rows=len(rows))
    if status != 200 or len(rows) > 1:
        raise StepError("3.network-read")
    desired = ",".join(cidrs)
    if rows:
        row = rows[0]
        value = row.get("value") if isinstance(row.get("value"), dict) else {}
        if all(value.get(k) == desired for k in ACCESS_KEYS):
            log("3.network", action="unchanged")
        else:
            value = dict(value)
            value.update({k: desired for k in ACCESS_KEYS})
            status, _ = api("PATCH", f"/api/core/settings/{row['id']}/", {"value": value}, token=token)
            log("3.network", action="updated", status=status)
            if status != 200:
                raise StepError("3.network")
    else:
        status, _ = api("POST", "/api/core/settings/", {
            "key": "network_access", "name": "Network Access",
            "value": {k: desired for k in ACCESS_KEYS}}, token=token)
        log("3.network", action="created", status=status)
        if status not in (200, 201):
            raise StepError("3.network")
    status, data = api("GET", "/api/core/settings/", token=token)
    rows = [r for r in as_list(data) if isinstance(r, dict) and r.get("key") == "network_access"]
    value = rows[0].get("value") if rows and isinstance(rows[0].get("value"), dict) else {}
    ok = all(value.get(k) == desired for k in ACCESS_KEYS)
    log("3.network-readback", status=status, ok=ok, keys=sum(1 for k in ACCESS_KEYS if value.get(k) == desired))
    if not ok:
        raise StepError("3.network-readback")
    # This pod is in-cluster (10.42.x): it must still be allowed on the UI
    # list after the change, or the lists were wrong.
    status, _ = api("GET", "/api/core/settings/", token=token)
    log("3.self-still-allowed", status=status, ok=status == 200)
    if status != 200:
        raise StepError("3.self-still-allowed")


def upsert(token, path, name, desired, compare_keys, step):
    status, data = api("GET", path, token=token)
    rows = [r for r in as_list(data) if isinstance(r, dict) and r.get("name") == name]
    log(f"{step}-existing", status=status, count=len(rows))
    if status != 200 or len(rows) > 1:
        raise StepError(f"{step}-read")
    if rows:
        row = rows[0]
        if all(row.get(k) == desired[k] for k in compare_keys):
            log(step, action="unchanged")
            return row.get("id")
        status, _ = api("PATCH", f"{path}{row['id']}/", desired, token=token, timeout=120)
        log(step, action="updated", status=status)
        if status != 200:
            raise StepError(step)
        return row.get("id")
    status, created = api("POST", path, desired, token=token, timeout=120)
    log(step, action="created", status=status)
    if status not in (200, 201) or not isinstance(created, dict):
        raise StepError(step)
    return created.get("id")


def step_provider(token):
    server = env("PROVIDER_SERVER_URL", required=False).strip().rstrip("/")
    if not server:
        log("provider: not configured", skipped=True)
        return False
    if not re.fullmatch(r"https?://[^\s/?#@]+(/[^\s?#]*)?", server):
        log("4.provider-server-url", valid=False)
        raise StepError("4.provider-server-url")
    user = env("PROVIDER_USERNAME")
    password = env("PROVIDER_PASSWORD")
    max_streams = int(env("PROVIDER_MAX_STREAMS"))
    account = {
        "name": ACCOUNT_NAME,
        "account_type": "XC",
        "server_url": server,
        "username": user,
        "password": password,
        "max_streams": max_streams,
        "is_active": True,
        "refresh_interval": 24,
    }
    # password is returned to admins (M3UAccountSerializer.to_representation),
    # so the comparison sees a changed password too.
    acc_id = upsert(token, "/api/m3u/accounts/", ACCOUNT_NAME, account,
                    ["account_type", "server_url", "username", "password", "max_streams", "is_active", "refresh_interval"],
                    "4.m3u-account")
    status, data = api("GET", f"/api/m3u/accounts/{acc_id}/", token=token)
    profiles = (data or {}).get("profiles") or [] if isinstance(data, dict) else []
    default = [p for p in profiles if isinstance(p, dict) and p.get("is_default")]
    log("4.m3u-account-readback", status=status,
        xc=isinstance(data, dict) and data.get("account_type") == "XC",
        max_streams_ok=isinstance(data, dict) and data.get("max_streams") == max_streams,
        default_profile_max_ok=bool(default) and default[0].get("max_streams") == max_streams)
    if status != 200 or not isinstance(data, dict) or data.get("max_streams") != max_streams:
        raise StepError("4.m3u-account-readback")

    epg_url = (f"{server}/xmltv.php?username={urllib.parse.quote(user, safe='')}"
               f"&password={urllib.parse.quote(password, safe='')}")
    epg = {"name": EPG_NAME, "source_type": "xmltv", "url": epg_url, "is_active": True, "refresh_interval": 24}
    upsert(token, "/api/epg/sources/", EPG_NAME, epg, ["source_type", "url", "is_active", "refresh_interval"], "4.epg-source")
    return True


def main():
    user = env("DISPATCHARR_ADMIN_USER")
    password = env("DISPATCHARR_ADMIN_PASS")
    cidrs = [c.strip() for c in env("NETWORK_CIDRS").split(",") if c.strip()]
    for cidr in cidrs:
        if not re.fullmatch(r"[0-9.]+/[0-9]{1,2}", cidr):
            raise StepError("network-cidrs-format")
    log("inputs", admin_pass_len=len(password), cidrs=len(cidrs),
        provider_configured=bool(os.environ.get("PROVIDER_SERVER_URL", "").strip()))
    wait_ready()
    step_admin(user, password)
    token = step_login(user, password)
    step_network(token, cidrs)
    configured = step_provider(token)
    log("done", ok=True, provider_configured=configured)


if __name__ == "__main__":
    try:
        main()
    except StepError as err:
        log("FAILED", failed_step=str(err)[:40])
        sys.exit(1)
    except BaseException as err:  # noqa: BLE001 - class name only, no message, no traceback
        log("FAILED", error=type(err).__name__)
        sys.exit(1)
