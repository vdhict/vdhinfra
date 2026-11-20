#!/usr/bin/env python3
"""chg-2026-10-01-001 I4 step C5 option (b): harden Forgejo user mypka-bot (Mack's go, AGR-120 team choice).

Admin API via a short-lived admforgejo CLI token (hack/ops/lib/forge_admin_token.py; chg-2026-11-20-001: the old
admin Secret gets 401), handed to curl inside the forge pod as a curl config on STDIN (never in argv), deleted
afterwards. Token list as admin with Sudo; token revoke by DB row (the API refuses token auth there).
Token created/last-used dates come from the forge DB (read-only transaction, no hash/salt columns printed).

Steps:
  1. capture: user state + token list (id, name, scopes, created, last used); pull-secret auth check (before).
  2. token rule: keep the pull token and the token whose last use matches the bot's last push to
     mypka-bot/passkey-point-dotnet; revoke the rest UNLESS used in the last 24h or the match is ambiguous.
  3. password reset to a random value generated in-process, never printed, never stored; must_change_password=false.
     Read-back: password hash changed, new value accepted once by basic auth in-process, then dropped.
  4. read-back: user exists, token list, pull-secret auth check (after).

Prints names, dates, HTTP codes and booleans only. Never a password, token or hash.
Usage: chg-2026-10-01-001-c5-bot-harden.py [--apply]   (without --apply: capture + plan only)
"""
import base64
import datetime as dt
import json
import os
import secrets
import string
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import forge_admin_token as fat  # noqa: E402

KUBECTL = "kubectl"
BOT = "mypka-bot"
DOTNET_REPO = "passkey-point-dotnet"
PULL_TOKEN = "cluster-wires-pull-1791097190"
FORGE = "https://forge.bluejungle.net"
PULL_IMAGE = ("vdhict/cluster-wires", "sha256:651085462e57effe6e9a2d0f8d6ad8b09bdbdf1acf85e98df8290fa1b3464884")
MATCH_SLACK = 300  # seconds between a token's last use and the bot's last push to count as a match
TOK = None  # admforgejo CLI token, held only inside main()


def run(args, stdin=None):
    return subprocess.run(args, input=stdin, capture_output=True, check=True).stdout


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def admin_forge(method, path, body=None, sudo=None):
    return fat.pod_api(TOK, method, path, body, sudo=sudo)


def basic_status(user, pw, path="/api/v1/user"):
    """Public forge, basic auth via curl config on stdin. Returns HTTP code only."""
    cfg = "user = %s\nurl = %s\n" % (q(user + ":" + pw), q(FORGE + path))
    return subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", "-K", "-"],
                          input=cfg.encode(), capture_output=True).stdout.decode().strip()


def sql(query):
    """Read-only query on the forge DB primary; returns rows as lists of strings."""
    out = run([KUBECTL, "-n", "devtools", "exec", "forge-pg-1", "-c", "postgres", "--", "psql", "-d", "forgejo",
               "-v", "ON_ERROR_STOP=1", "-AtX", "-F", "\t",
               "-c", "set default_transaction_read_only=on", "-c", query]).decode()
    return [line.split("\t") for line in out.splitlines() if line and line != "SET"]


def ts(u):
    u = int(u)
    return "never" if u == 0 else dt.datetime.fromtimestamp(u, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def user_state():
    r = sql("select id, is_active, prohibit_login, must_change_password, is_admin, last_login_unix, updated_unix, "
            "md5(passwd||salt) from \"user\" where lower_name='%s'" % BOT)
    if len(r) != 1:
        return None
    i, act, pro, mcp, adm, ll, upd, pwfp = r[0]
    return {"id": i, "is_active": act, "prohibit_login": pro, "must_change_password": mcp, "is_admin": adm,
            "last_login": ts(ll), "updated": ts(upd), "_pwfp": pwfp}  # _pwfp: compared in-process, never printed


def tokens():
    rows = sql("select t.id, t.name, t.scope, t.resource_all_repos, t.created_unix, t.updated_unix, "
               "md5(t.token_hash||t.token_salt) from access_token t join \"user\" u on u.id=t.uid "
               "where u.lower_name='%s' order by t.id" % BOT)
    return [{"id": int(a), "name": b, "scopes": c, "all_repos": d, "created": ts(e), "last_used": ts(f),
             "_upd": int(f), "_fp": g} for a, b, c, d, e, f, g in rows]


def last_bot_push():
    r = sql("select coalesce(max(a.created_unix),0) from action a join repository r on r.id=a.repo_id "
            "join \"user\" u on u.id=a.act_user_id where r.owner_name='%s' and r.lower_name='%s' "
            "and a.op_type=5 and u.lower_name='%s'" % (BOT, DOTNET_REPO, BOT))
    return int(r[0][0])


def pull_check():
    """Auth-check with Secret mypka/cluster-wires-registry: registry token + manifest HEAD of the deployed digest."""
    dcj = json.loads(run([KUBECTL, "-n", "mypka", "get", "secret", "cluster-wires-registry", "-o", "json"]))
    cfg = json.loads(base64.b64decode(dcj["data"][".dockerconfigjson"]))
    entry = cfg["auths"].get("forge.bluejungle.net") or cfg["auths"].get("https://forge.bluejungle.net")
    cred = base64.b64decode(entry["auth"]).decode() if "auth" in entry else entry["username"] + ":" + entry["password"]
    user = cred.split(":", 1)[0]
    repo, digest = PULL_IMAGE
    c1 = "user = %s\nurl = %s\n" % (q(cred), q(FORGE + "/v2/token?service=container_registry&scope=repository:%s:pull" % repo))
    out = subprocess.run(["curl", "-sS", "--max-time", "20", "-w", "\n%{http_code}", "-K", "-"],
                         input=c1.encode(), capture_output=True).stdout.decode()
    body, _, code1 = out.rpartition("\n")
    bearer = json.loads(body).get("token") if code1 == "200" else None
    code2 = "skipped"
    if bearer:
        c2 = ("url = %s\nhead\nheader = %s\nheader = \"Accept: application/vnd.oci.image.index.v1+json, "
              "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, "
              "application/vnd.docker.distribution.manifest.list.v2+json\"\n") % (
            q(FORGE + "/v2/%s/manifests/%s" % (repo, digest)), q("Authorization: Bearer " + bearer))
        code2 = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", "-K", "-"],
                               input=c2.encode(), capture_output=True).stdout.decode().strip()
    return "secret user=%s /v2/token pull %s -> HTTP %s; HEAD manifest %s -> HTTP %s" % (user, repo, code1, digest[:19], code2), \
        code1 == "200" and code2 == "200"


def gen_password():
    alphabet = string.ascii_letters + string.digits + "-_.~!@%^*+="
    while True:
        p = "".join(secrets.choice(alphabet) for _ in range(48))
        if (any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p)
                and any(not c.isalnum() for c in p)):
            return p


def show(label, u, toks):
    print("%s user %s: %s" % (label, BOT, {k: v for k, v in u.items() if not k.startswith("_")}))
    for t in toks:
        print("%s token id=%d name=%s scopes=%s all_repos=%s created=%s last_used=%s" % (
            label, t["id"], t["name"], t["scopes"], t["all_repos"], t["created"], t["last_used"]))


def main():
    global TOK
    scopes = "write:admin,read:user" if "--apply" in sys.argv else "read:user"
    with fat.temp_token("chg-2026-10-01-001-c5", scopes, log=print) as TOK:
        _main()
    TOK = None


def _main():
    apply = "--apply" in sys.argv
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    print("# chg-2026-10-01-001 C5(b) mypka-bot hardening %s mode=%s (k8s-engineer; admforgejo via in-pod curl, "
          "DB read-only; no secret values)" % (ts(now), "apply" if apply else "capture"))
    u0, t0 = user_state(), tokens()
    if not u0:
        sys.exit("STOP user %s not found" % BOT)
    show("pre", u0, t0)
    code, _ = admin_forge("GET", "/users/%s/tokens" % BOT, sudo=BOT)
    print("pre API GET /users/%s/tokens -> HTTP %d (API list has no dates; dates above are from the DB)" % (BOT, code))
    push = last_bot_push()
    print("pre last push by %s to %s/%s: %s" % (BOT, BOT, DOTNET_REPO, ts(push)))
    msg, ok0 = pull_check()
    print("pre pull-check: %s" % msg)

    # token rule
    keep, revoke, held = [], [], []
    matches = [t for t in t0 if t["name"] != PULL_TOKEN and push and abs(t["_upd"] - push) <= MATCH_SLACK]
    if len(matches) != 1:
        print("PLAN ambiguous push-token match: %d candidates %s -> revoke NOTHING" % (len(matches), [t["name"] for t in matches]))
    for t in t0:
        if t["name"] == PULL_TOKEN:
            keep.append((t, "pull token"))
        elif len(matches) == 1 and t is matches[0]:
            keep.append((t, "last use %s matches last bot push %s" % (t["last_used"], ts(push))))
        elif len(matches) != 1:
            held.append((t, "ambiguous push-token match"))
        elif now - t["_upd"] < 86400:
            held.append((t, "used in last 24h (%s)" % t["last_used"]))
        else:
            revoke.append(t)
    for t, why in keep:
        print("PLAN keep   id=%d %s: %s" % (t["id"], t["name"], why))
    for t, why in held:
        print("PLAN HOLD   id=%d %s: %s (not revoked, report)" % (t["id"], t["name"], why))
    for t in revoke:
        print("PLAN revoke id=%d %s (last used %s)" % (t["id"], t["name"], t["last_used"]))
    if not ok0:
        sys.exit("STOP pull-check failed BEFORE any change; nothing changed")
    if not apply:
        return

    for t in revoke:
        left = fat.delete_token(BOT, tid=t["id"])
        print("DELETE token id=%d %s by DB row -> rows left %s" % (t["id"], t["name"], left))

    pw = gen_password()
    code, _ = admin_forge("PATCH", "/admin/users/%s" % BOT, {"password": pw, "must_change_password": False})
    print("PATCH /admin/users/%s {password:<random 48, in-process>, must_change_password:false} -> HTTP %d" % (BOT, code))
    new_ok = basic_status(BOT, pw) if code == 200 else "skipped"
    pw = None
    del pw
    print("new password basic auth GET /api/v1/user -> HTTP %s (value then dropped; never printed or stored)" % new_ok)

    u1, t1 = user_state(), tokens()
    show("post", u1 or {}, t1)
    pw_changed = bool(u1) and u1["_pwfp"] != u0["_pwfp"]
    print("post password hash changed vs pre: %s => old password no longer valid" % pw_changed)
    print("post old-password basic-auth test: NOT RUN (old value not held; 1Password not read, per brief)")
    for t, _ in keep + held:
        a = next((x for x in t1 if x["id"] == t["id"]), None)
        print("post token id=%d %s still present=%s unchanged(hash fp in-process)=%s" % (
            t["id"], t["name"], a is not None, bool(a) and a["_fp"] == t["_fp"]))
    for t in revoke:
        print("post token id=%d %s absent=%s" % (t["id"], t["name"], all(x["id"] != t["id"] for x in t1)))
    code, text = admin_forge("GET", "/users/%s/tokens" % BOT, sudo=BOT)
    names = [x.get("name") for x in json.loads(text)] if code == 200 else None
    print("post API GET /users/%s/tokens -> HTTP %d names=%s" % (BOT, code, names))
    msg, ok1 = pull_check()
    print("post pull-check: %s" % msg)
    good = (pw_changed and new_ok == "200" and ok1 and u1 and u1["must_change_password"] == "f"
            and u1["is_active"] == "t" and all(any(x["id"] == t["id"] for x in t1) for t, _ in keep))
    print("RESULT %s" % ("PASS" if good else "FAIL"))
    sys.exit(0 if good else 1)


if __name__ == "__main__":
    main()
