#!/usr/bin/env python3
"""chg-2026-10-20-010 scoped GitHub App token for the go-live / rollback / cut-off pushes (Argus L1, G-b).

    python3 -I hack/ops/chg-2026-10-20-010-mint.py mint     # token on stdout, nothing else
    printf %s "$TOKEN" | python3 -I hack/ops/chg-2026-10-20-010-mint.py revoke

mint: signs an App JWT (RS256 via /usr/bin/openssl, straight from the 0600 key file, no temp copy) and asks for an
installation token restricted to repository vdhinfra and permission contents:write only; refuses (exit 1, no
token) if GitHub returns anything broader. revoke: DELETE /installation/token with the token itself (204).
Env: GITHUB_APP_ID | GH_APP_ID, GITHUB_APP_INSTALLATION_ID | GH_APP_INSTALLATION_ID,
GITHUB_APP_KEY_PATH | GH_APP_PRIVATE_KEY_FILE. Diagnostics go to stderr and never contain the token or the JWT.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

API = "https://api.github.com"
REPO = "vdhinfra"
WANT = {"contents": "write"}


def env(*names):
    for n in names:
        if os.environ.get(n):
            return os.environ[n]
    return ""


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def call(method, url, auth, body=None):
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": auth, "Accept": "application/vnd.github+json",
                                          "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {}


def mint():
    app, inst, key = env("GITHUB_APP_ID", "GH_APP_ID"), env("GITHUB_APP_INSTALLATION_ID", "GH_APP_INSTALLATION_ID"), \
        env("GITHUB_APP_KEY_PATH", "GH_APP_PRIVATE_KEY_FILE")
    if not (app and inst and key and os.path.isfile(key)):
        sys.exit("mint: GitHub App id / installation id / key file missing")
    now = int(time.time())
    si = "%s.%s" % (b64u(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode()),
                    b64u(json.dumps({"iat": now - 30, "exp": now + 540, "iss": app}, separators=(",", ":")).encode()))
    p = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", key], input=si.encode(), capture_output=True)
    if p.returncode != 0 or not p.stdout:
        sys.exit("mint: openssl sign failed rc=%d" % p.returncode)
    code, d = call("POST", "%s/app/installations/%s/access_tokens" % (API, inst), "Bearer %s.%s" % (si, b64u(p.stdout)),
                   {"repositories": [REPO], "permissions": WANT})
    tok = d.get("token") if code == 201 else None
    if not tok:
        sys.exit("mint: token request refused http=%d" % code)
    perms = {k: v for k, v in (d.get("permissions") or {}).items() if k != "metadata"}   # metadata:read is implicit
    repos = [r.get("name") for r in d.get("repositories") or []]
    if perms != WANT or repos != [REPO]:
        call("DELETE", API + "/installation/token", "token " + tok)
        sys.exit("mint: GitHub granted more than asked (perms=%s repos=%d): revoked, refusing" % (sorted(perms), len(repos)))
    print("mint: scoped token contents:write on %s, expires %s" % (REPO, d.get("expires_at")), file=sys.stderr)
    sys.stdout.write(tok)


def revoke():
    tok = sys.stdin.read().strip()
    if not tok:
        sys.exit("revoke: no token on stdin")
    code, _ = call("DELETE", API + "/installation/token", "token " + tok)
    print("revoke: http=%d" % code, file=sys.stderr)
    sys.exit(0 if code == 204 else 1)


if __name__ == "__main__":
    {"mint": mint, "revoke": revoke}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit("usage: mint|revoke"))()
