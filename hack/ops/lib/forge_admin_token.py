"""Short-lived Forgejo tokens minted by the forge CLI, for ops scripts (chg-2026-11-20-001, tsk-2026-11-20-114).

Why: Secret devtools/forgejo-admin-secret holds a login that is not the site admin and gets 401 (inventory
ops/evidence/chg-2026-11-20-001/50-*), and admforgejo has security keys, so the API refuses its basic auth anyway.
Route (chg-2026-11-03-006, chg-2026-11-10-001, chg-2026-11-20-001 evidence 41):
  mint   `forgejo admin user generate-access-token --raw` inside the forge pod (no password needed);
  use    the value lives only in this process; API calls go to curl inside the forge pod, with the header in a
         curl config on STDIN (never argv, never printed);
  delete by SQL on the forge DB primary. Forgejo answers 401 to DELETE /users/{u}/tokens/{id} with token auth
         (it wants a password login, evidence 41) and the CLI has no delete command, so the DB row is the route.
         Proven gone: rows left 0 and the token gets 401.

    import sys, os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
    import forge_admin_token as fat
    with fat.temp_token("chg-x", "read:admin") as tok:
        code, body = fat.pod_api(tok, "GET", "/admin/users?limit=1")

Nothing here prints or writes a token value. Status lines go to stderr unless `log` is given.
"""
import contextlib
import datetime
import json
import os
import secrets
import subprocess
import sys

KUBECTL = os.environ.get("KUBECTL", "kubectl")
NS = "devtools"
ADMIN = "admforgejo"


def _log(msg):
    print(msg, file=sys.stderr, flush=True)


def kubectl(*args, stdin=None):
    return subprocess.run([KUBECTL, "-n", NS, *args], input=stdin, capture_output=True, check=True).stdout


def q(s):
    """curl-config string quoting."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lit(s):
    """SQL string literal."""
    return "'" + str(s).replace("'", "''") + "'"


def pg_pod(role="primary"):
    """Pod name of the forge-pg primary (CNPG status.currentPrimary, wq-115) or of a replica (label).
    Fails closed: an empty answer, or a switchover in flight (target != current), raises."""
    if role == "primary":
        out = kubectl("get", "cluster.postgresql.cnpg.io", "forge-pg", "-o",
                      "jsonpath={.status.currentPrimary}|{.status.targetPrimary}").decode().strip()
        cur, _, tgt = out.partition("|")
        if not cur:
            raise RuntimeError("forge-pg currentPrimary is empty")
        if tgt and tgt != cur:
            raise RuntimeError("forge-pg switchover in flight (%s -> %s)" % (cur, tgt))
        return cur
    out = kubectl("get", "pod", "-l", "cnpg.io/cluster=forge-pg,cnpg.io/instanceRole=%s" % role,
                  "-o", "jsonpath={.items[0].metadata.name}").decode().strip()
    if not out:
        raise RuntimeError("no forge-pg %s pod" % role)
    return out


def _psql(pod, statement):
    return kubectl("exec", pod, "-c", "postgres", "--", "psql", "-U", "postgres", "-d", "forgejo",
                   "-v", "ON_ERROR_STOP=1", "-AtXq", "-c", statement).decode().strip()


def sql(statement, write=False, role="primary"):
    """One statement on the forge DB; read-only transaction unless write=True (primary only).
    A write first proves the resolved pod is not in recovery."""
    if write and role != "primary":
        raise ValueError("writes go to the primary")
    pod = pg_pod(role)
    if write and _psql(pod, "SELECT pg_is_in_recovery()") != "f":
        raise RuntimeError("refusing write: %s is in recovery" % pod)
    pre = "" if write else "SET default_transaction_read_only=on; "
    return _psql(pod, pre + statement)


def _uid_sql(username):
    return "(SELECT id FROM \"user\" WHERE lower_name=%s)" % lit(username.lower())


def unique_name(purpose):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return "%s-tmp-%s-%s" % (purpose, ts, secrets.token_hex(3))


def mint(username, scopes, name):
    """Mint a token for `username` with `scopes` (comma string or list). Returns the value; prints nothing."""
    if isinstance(scopes, (list, tuple)):
        scopes = ",".join(scopes)
    if not scopes or scopes == "all":
        raise ValueError("ask for explicit minimal scopes")
    tok = kubectl("exec", "deploy/forgejo", "-c", "forgejo", "--", "forgejo", "admin", "user",
                  "generate-access-token", "--username", username, "--token-name", name,
                  "--scopes", scopes, "--raw").decode().strip()
    if not tok or len(tok) < 20 or any(c.isspace() for c in tok):
        raise RuntimeError("generate-access-token returned no usable token for %s (value not shown)" % name)
    return tok


def token_id(name, username):
    return sql("SELECT id FROM access_token WHERE name=%s AND uid=%s" % (lit(name), _uid_sql(username)))


def restrict_to_repo(name, username, owner, repo):
    """Limit a token to one repository: the row the API's `repositories` option writes, and resource_all_repos
    false (the CLI sets it true, which makes the row ignored; forge-push-cli-token.py run 2)."""
    tid = token_id(name, username)
    rid = sql("SELECT id FROM repository WHERE lower(owner_name)=%s AND lower_name=%s" % (
        lit(owner.lower()), lit(repo.lower())))
    if not tid or not rid:
        raise RuntimeError("token %s or repo %s/%s not found" % (name, owner, repo))
    sql("INSERT INTO access_token_resource_repo (token_id, repo_id, created_unix) VALUES (%s, %s, "
        "extract(epoch from now())::bigint)" % (tid, rid), write=True)
    sql("UPDATE access_token SET resource_all_repos=false WHERE id=%s" % tid, write=True)
    return tid, rid


def delete_token(username, name=None, tid=None):
    """Delete a token row (and its repo-restriction rows) by name or id on the primary. Returns rows left (str)."""
    if (name is None) == (tid is None):
        raise ValueError("give exactly one of name / tid")
    where = ("name=%s" % lit(name)) if name is not None else ("id=%d" % int(tid))
    where += " AND uid=%s" % _uid_sql(username)
    sql("DELETE FROM access_token_resource_repo WHERE token_id IN (SELECT id FROM access_token WHERE %s)" % where,
        write=True)
    sql("DELETE FROM access_token WHERE %s" % where, write=True)
    return sql("SELECT count(*) FROM access_token WHERE %s" % where)


def pod_api(tok, method, path, body=None, sudo=None):
    """Forge API call with token auth via curl inside the forge pod; config (incl. header) on stdin.
    Returns (http_code:int, body:str)."""
    cfg = "request = %s\nurl = %s\nheader = %s\nheader = \"Content-Type: application/json\"\n" % (
        q(method), q("http://127.0.0.1:3000/api/v1" + path), q("Authorization: token " + tok))
    if sudo:
        cfg += "header = %s\n" % q("Sudo: " + sudo)
    if body is not None:
        cfg += "data = %s\n" % q(body if isinstance(body, str) else json.dumps(body))
    out = kubectl("exec", "-i", "deploy/forgejo", "-c", "forgejo", "--",
                  "curl", "-sS", "-w", "\n%{http_code}", "-K", "-", stdin=cfg.encode())
    cfg = None
    text, _, code = out.decode().rpartition("\n")
    return int(code or 0), text


@contextlib.contextmanager
def temp_token(purpose, scopes, username=ADMIN, repo=None, log=_log):
    """Yield a fresh token (value only) and always delete it afterwards, proving it is gone.
    repo="owner/name" restricts it to that one repository. The name carries purpose + UTC timestamp."""
    name = unique_name(purpose)
    tok = mint(username, scopes, name)
    log("minted %s token %s (%s)%s, value not shown" % (
        username, name, scopes if isinstance(scopes, str) else ",".join(scopes), " repo " + repo if repo else ""))
    try:
        if repo:
            o, r = repo.split("/", 1)
            tid, rid = restrict_to_repo(name, username, o, r)
            log("restricted token id %s to repo id %s" % (tid, rid))
        yield tok
    finally:
        left = delete_token(username, name=name)
        code, _ = pod_api(tok, "GET", "/user")
        tok = None
        log("deleted tmp token %s by SQL: rows left %s; GET /user with it -> HTTP %d" % (name, left, code))
        if left != "0" or code != 401:
            raise RuntimeError("tmp token %s NOT proven gone (rows %s, HTTP %d): delete it by hand" % (name, left, code))
