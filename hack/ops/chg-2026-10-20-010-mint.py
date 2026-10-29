#!/usr/bin/env python3
"""chg-2026-10-20-010 scoped GitHub App token for the go-live / rollback / cut-off pushes (Argus L1, G-b).

    TOK=$(python3 -I hack/ops/chg-2026-10-20-010-mint.py mint)    # token on stdout, nothing else
    printf %s "$TOK" | python3 -I hack/ops/chg-2026-10-20-010-mint.py revoke
    python3 -I hack/ops/chg-2026-10-20-010-mint.py revoke-all       # every unexpired ledger token

mint: signs an App JWT (RS256 via /usr/bin/openssl, straight from the 0600 key file, no temp copy) and asks for an
installation token restricted to repository vdhinfra and permission contents:write only; refuses (exit 1, no
token) if GitHub returns anything broader. revoke: DELETE /installation/token with the token itself (204).
Env: GITHUB_APP_ID | GH_APP_ID, GITHUB_APP_INSTALLATION_ID | GH_APP_INSTALLATION_ID,
GITHUB_APP_KEY_PATH | GH_APP_PRIVATE_KEY_FILE. Diagnostics go to stderr and never contain the token or the JWT.

Fail-closed (chg-2026-10-28-002, Argus, after tokens were minted into a pipe that discarded them and could not be
revoked):
- mint refuses (exit 2, nothing minted, no network call) when stdout is a TTY: the token must be captured.
- mint appends {minted, expires, token} as one JSON line to the ledger ~/.config/vdhinfra/gh-app-tokens.ledger
  (file 0600, directory 0700, flock) BEFORE the token goes to stdout. If the ledger cannot be written the token is
  revoked at once and mint fails; if stdout fails (closed pipe) the token is revoked and taken off the ledger.
  So every minted token is either revoked or on the ledger: a lost token is revocable with revoke-all.
- revoke (token on stdin) takes that token's line off the ledger when GitHub answers 204 (revoked) or 401 (already
  invalid/expired); on any other answer the line stays so revoke-all can retry. Exit 0 only on 204 (unchanged).
- revoke-all revokes every unexpired ledger entry, prints "entry N: http=<code>" per entry (never the token), and
  empties the ledger. An entry whose revoke fails with neither 204 nor 401 is kept (fail-closed) and the exit is 1.
The ledger is rewritten in place (seek, write, truncate), never deleted (AGR-121).
"""
import base64, datetime, fcntl, json, os, stat, subprocess, sys, time, urllib.error, urllib.request

API = "https://api.github.com"
REPO = "vdhinfra"
WANT = {"contents": "write"}
LEDGER_DIR = os.path.join(os.path.expanduser("~"), ".config", "vdhinfra")
LEDGER = os.path.join(LEDGER_DIR, "gh-app-tokens.ledger")


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


class Ledger:
    """Open + flock the ledger, enforcing 0700 dir / 0600 file owned by us. Use as a context manager."""

    def __enter__(self):
        os.makedirs(LEDGER_DIR, mode=0o700, exist_ok=True)
        st = os.lstat(LEDGER_DIR)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            raise OSError("ledger directory is not a directory owned by this user")
        if stat.S_IMODE(st.st_mode) != 0o700:
            os.chmod(LEDGER_DIR, 0o700)
        fd = os.open(LEDGER, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            os.close(fd)
            raise OSError("ledger is not a regular file owned by this user")
        if stat.S_IMODE(st.st_mode) != 0o600:
            os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.f = os.fdopen(fd, "r+", encoding="utf-8")
        return self

    def __exit__(self, *exc):
        self.f.close()   # releases the flock

    def entries(self):
        self.f.seek(0)
        out = []
        for line in self.f.read().splitlines():
            if not line.strip():
                continue
            try:
                e = json.loads(line)
            except ValueError:
                e = None
            out.append(e if isinstance(e, dict) and isinstance(e.get("token"), str) else {"bad": line})
        return out

    def append(self, entry):
        self.f.seek(0, os.SEEK_END)
        self.f.write(json.dumps(entry, separators=(",", ":")) + "\n")
        self.f.flush()
        os.fsync(self.f.fileno())

    def rewrite(self, entries):
        self.f.seek(0)
        for e in entries:
            self.f.write((e["bad"] if "bad" in e else json.dumps(e, separators=(",", ":"))) + "\n")
        self.f.truncate()
        self.f.flush()
        os.fsync(self.f.fileno())


def drop_from_ledger(tok):
    with Ledger() as L:
        es = L.entries()
        keep = [e for e in es if e.get("token") != tok]
        L.rewrite(keep)
        return len(es) - len(keep)


def expired(e):
    try:
        t = datetime.datetime.strptime(e.get("expires") or "", "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return False   # unknown expiry: treat as live, revoke it
    return t <= datetime.datetime.now(datetime.timezone.utc)


def mint():
    if sys.stdout.isatty():
        print("mint: refusing: stdout is a terminal; capture it, e.g. TOK=$(python3 -I %s mint)" % sys.argv[0],
              file=sys.stderr)
        sys.exit(2)
    try:   # ledger must be writable before anything is minted
        with Ledger():
            pass
    except OSError as e:
        sys.exit("mint: refusing: ledger %s unusable (%s)" % (LEDGER, e.strerror or e))
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
    entry = {"minted": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "expires": d.get("expires_at") or "",
             "token": tok}
    try:
        with Ledger() as L:
            L.append(entry)
    except OSError as e:
        code, _ = call("DELETE", API + "/installation/token", "token " + tok)
        sys.exit("mint: ledger write failed (%s): token revoked http=%d, refusing" % (e.strerror or e, code))
    try:
        sys.stdout.write(tok)
        sys.stdout.flush()
    except (OSError, ValueError):
        code, _ = call("DELETE", API + "/installation/token", "token " + tok)
        if code in (204, 401):
            drop_from_ledger(tok)
        try:
            sys.stdout = open(os.devnull, "w")   # keep interpreter shutdown from re-raising on the closed pipe
        except OSError:
            pass
        print("mint: stdout not writable: token revoked http=%d%s" % (code, "" if code in (204, 401) else
              " (kept on the ledger; run revoke-all)"), file=sys.stderr)
        sys.exit(1)
    print("mint: scoped token contents:write on %s, expires %s; on the ledger" % (REPO, d.get("expires_at")),
          file=sys.stderr)


def revoke():
    tok = sys.stdin.read().strip()
    if not tok:
        sys.exit("revoke: no token on stdin")
    code, _ = call("DELETE", API + "/installation/token", "token " + tok)
    n = 0
    if code in (204, 401):
        try:
            n = drop_from_ledger(tok)
        except OSError as e:
            print("revoke: ledger update failed (%s)" % (e.strerror or e), file=sys.stderr)
    print("revoke: http=%d ledger_removed=%d" % (code, n), file=sys.stderr)
    sys.exit(0 if code == 204 else 1)


def revoke_all():
    bad = 0
    with Ledger() as L:   # held for the whole run: no mint can slip in between read and rewrite
        es = L.entries()
        keep = []
        for i, e in enumerate(es, 1):
            if "bad" in e:
                print("revoke-all: entry %d: unparseable line, kept" % i, file=sys.stderr)
                keep.append(e)
                bad += 1
                continue
            if expired(e):
                print("revoke-all: entry %d: minted %s expired %s, dropped" % (i, e.get("minted"), e.get("expires")),
                      file=sys.stderr)
                continue
            code, _ = call("DELETE", API + "/installation/token", "token " + e["token"])
            ok = code in (204, 401)
            print("revoke-all: entry %d: minted %s http=%d%s" % (i, e.get("minted"), code, "" if ok else " KEPT"),
                  file=sys.stderr)
            if not ok:
                keep.append(e)
                bad += 1
        L.rewrite(keep)
    print("revoke-all: %d entries, %d kept" % (len(es), len(keep)), file=sys.stderr)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    {"mint": mint, "revoke": revoke, "revoke-all": revoke_all}.get(
        sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit("usage: mint|revoke|revoke-all"))()
