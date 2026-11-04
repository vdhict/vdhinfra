#!/usr/bin/env python3
"""chg-2026-11-04-004: Authelia OIDC login for the forge. Two one-off steps outside Git.

  secrets  Generate the forgejo OIDC client secret (48 alphanumeric) in-process and write it, via stdin only, as
           devtools/forgejo-oauth-authelia (key=forgejo, secret=<plaintext>, read by the Forgejo chart) and
           security/authelia-oidc-forgejo (FORGEJO_OAUTH_CLIENT_DIGEST=<bcrypt cost 10>, envFrom in Authelia).
           Not in 1Password: the cluster's Connect token is read-only (POST item -> 403, 2026-11-04), and the only
           write-capable 1P route is myPKA's service account. Existing secrets are never overwritten; to rotate,
           move both Secrets aside, rerun, and restart Authelia and Forgejo.
  link     Pre-link the owner's Authelia subject to forge user `sheijden` (id 10) in external_login_user, so the first
           OIDC login signs straight in (registration and auto-registration are off; without the link Forgejo would
           ask for the local password, which nobody knows). The subject is read from Authelia's user_opaque_identifier
           (service openid, sector '') and never printed.
Nothing secret is printed.
"""
import base64
import json
import secrets
import string
import subprocess
import sys

FORGE_SECRET = ("devtools", "forgejo-oauth-authelia")
AUTHELIA_SECRET = ("security", "authelia-oidc-forgejo")
LABELS = {"app.kubernetes.io/managed-by": "atlas-chg-2026-11-04-004"}


def kubectl(*args, stdin=None, check=True):
    return subprocess.run(["kubectl", *args], input=stdin, capture_output=True, check=check)


def exists(ns, name):
    return kubectl("-n", ns, "get", "secret", name, check=False).returncode == 0


def apply_secret(ns, name, data):
    doc = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": name, "namespace": ns, "labels": LABELS},
           "data": {k: base64.b64encode(v.encode()).decode() for k, v in data.items()}}
    kubectl("create", "-f", "-", stdin=json.dumps(doc).encode())


def secrets_step():
    have = [exists(*FORGE_SECRET), exists(*AUTHELIA_SECRET)]
    print("before: %s exists %s; %s exists %s" % ("/".join(FORGE_SECRET), have[0], "/".join(AUTHELIA_SECRET), have[1]))
    if any(have):
        sys.exit("refusing: a secret already exists; nothing written")
    value = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(48))
    digest = subprocess.run(["/usr/sbin/htpasswd", "-niBC", "10", "forgejo"], input=value.encode(), capture_output=True,
                            check=True).stdout.decode().strip().split(":", 1)[1]
    apply_secret(*FORGE_SECRET, {"key": "forgejo", "secret": value})
    apply_secret(*AUTHELIA_SECRET, {"FORGEJO_OAUTH_CLIENT_DIGEST": digest})
    value = digest = None
    # readback: shapes only
    f = json.loads(kubectl("-n", FORGE_SECRET[0], "get", "secret", FORGE_SECRET[1], "-o", "json").stdout)["data"]
    a = json.loads(kubectl("-n", AUTHELIA_SECRET[0], "get", "secret", AUTHELIA_SECRET[1], "-o", "json").stdout)["data"]
    s = base64.b64decode(f["secret"]).decode()
    d = base64.b64decode(a["FORGEJO_OAUTH_CLIENT_DIGEST"]).decode()
    print("readback: forge key=%s secret len %d alnum %s; authelia digest prefix %s len %d" % (
        base64.b64decode(f["key"]).decode(), len(s), s.isalnum(), d[:7], len(d)))


def psql(pod, db, statement, ns):
    return kubectl("-n", ns, "exec", pod, "-c", "postgres", "--", "psql", "-U", "postgres", "-d", db, "-At", "-q",
                   "-c", statement).stdout.decode().strip()


def link_step():
    src = psql("forge-pg-1", "forgejo", "SELECT id FROM login_source WHERE name='authelia' AND type=6", "devtools")
    uid = psql("forge-pg-1", "forgejo", "SELECT id FROM \"user\" WHERE lower_name='sheijden'", "devtools")
    sub = psql("postgres16-2", "authelia", "SELECT identifier FROM user_opaque_identifier WHERE service='openid' AND "
               "sector_id='' AND username='sheijden'", "database")
    print("login source authelia id %s; forge user sheijden id %s; subject present %s" % (src or "-", uid or "-", bool(sub)))
    if not (src and uid == "10" and len(sub) == 36):
        sys.exit("refusing: source, user or subject missing")
    have = psql("forge-pg-1", "forgejo", "SELECT count(*) FROM external_login_user WHERE login_source_id=%s" % src, "devtools")
    if have != "0":
        sys.exit("refusing: source %s already has %s linked identities" % (src, have))
    # sub is a UUID from Authelia's own table; checked above for length, quoted as a literal.
    assert all(c in "0123456789abcdef-" for c in sub)
    stmt = ("INSERT INTO external_login_user (external_id, user_id, login_source_id, provider, email, name) "
            "VALUES ('%s', %s, %s, 'openidConnect', '', '')" % (sub, uid, src))
    kubectl("-n", "devtools", "exec", "-i", "forge-pg-1", "-c", "postgres", "--", "psql", "-U", "postgres", "-d",
            "forgejo", "-At", "-q", "-v", "ON_ERROR_STOP=1", stdin=stmt.encode())
    print("readback: linked identities for source %s: %s (user %s)" % (src, psql(
        "forge-pg-1", "forgejo", "SELECT count(*) FROM external_login_user WHERE login_source_id=%s AND user_id=%s" % (src, uid),
        "devtools"), uid))


def grant_step():
    """Argus C3: column grants so the CNPG exporter (pg_monitor) can count links per source. No subject column."""
    stmt = ("GRANT SELECT (id, name, type) ON login_source TO pg_monitor; "
            "GRANT SELECT (login_source_id) ON external_login_user TO pg_monitor;")
    kubectl("-n", "devtools", "exec", "-i", "forge-pg-1", "-c", "postgres", "--", "psql", "-U", "postgres", "-d",
            "forgejo", "-At", "-q", "-v", "ON_ERROR_STOP=1", stdin=stmt.encode())
    print("readback: pg_monitor column grants: %s" % psql("forge-pg-1", "forgejo", (
        "SELECT string_agg(table_name||'.'||column_name, ',' ORDER BY 1) FROM information_schema.column_privileges "
        "WHERE grantee='pg_monitor' AND table_name IN ('login_source','external_login_user')"), "devtools"))


if __name__ == "__main__":
    {"secrets": secrets_step, "link": link_step, "grant": grant_step}[sys.argv[1] if len(sys.argv) > 1 else ""]()
