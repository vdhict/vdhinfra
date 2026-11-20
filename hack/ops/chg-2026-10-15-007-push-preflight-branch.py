#!/usr/bin/env python3
"""chg-2026-10-15-007: push branch feat/platform-preflight to VDHICT/passkey-point with a short-lived token.

Larry allowed the push to our forge (relayed by Atlas, 2026-10-16). Pattern of
hack/forgejo-runner/vdhwslin01/mint-waker-forge-token.py; admin reads use a short-lived admforgejo CLI token (hack/ops/lib/forge_admin_token.py; chg-2026-11-20-001: the old admin Secret
gets 401), via curl inside the forge pod with a curl config on STDIN (never in argv). The push token is minted by
the forge CLI too and restricted to the repository by DB row (the token API wants a password login).
The token is for user palamedes, scope write:repository, RESTRICTED to the one repository VDHICT/passkey-point.
It lives only in this process and in the environment of the one `git push` child, read back by a GIT_ASKPASS
script that holds no secret. It is deleted in a finally block, and the script proves it is gone: the token gets
401 from the forge and is absent from the user's token list. Nothing secret is printed or written to disk.

Usage: chg-2026-10-15-007-push-preflight-branch.py <worktree> <expected-head> <scratch-dir> [--check-only]
"""
import json
import os
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import forge_admin_token as fat  # noqa: E402

KUBECTL = os.environ.get("KUBECTL", "kubectl")
NS = "devtools"
USER = "palamedes"
OWNER, REPO = "VDHICT", "passkey-point"
BRANCH = "feat/platform-preflight"
FORGE = "https://forge.bluejungle.net"
TOK = None  # admforgejo CLI token (read:repository), held only inside main()


def kubectl(*args, stdin=None):
    return subprocess.run([KUBECTL, "-n", NS, *args], input=stdin, capture_output=True, check=True).stdout


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def forge(method, path, body=None):
    return fat.pod_api(TOK, method, path, body)


def token_status(tok):
    """HTTP status the public forge gives this token on GET /api/v1/user (header via curl config on stdin)."""
    cfg = "url = %s\nheader = %s\n" % (q(FORGE + "/api/v1/user"), q("Authorization: token " + tok))
    out = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", "-K", "-"],
                         input=cfg.encode(), capture_output=True).stdout.decode()
    return out.strip()


def remote_head():
    code, text = forge("GET", "/repos/%s/%s/branches/%s" % (OWNER, REPO, BRANCH.replace("/", "%2F")))
    return code, (json.loads(text).get("commit", {}).get("id") if code == 200 else None)


def main():
    global TOK
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    with fat.temp_token("palamedes-push-preflight-read", "read:repository", log=print) as TOK:
        _main()
    TOK = None


def _main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    wt, expected, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
    head = subprocess.run(["git", "-C", wt, "rev-parse", BRANCH], capture_output=True, check=True, text=True).stdout.strip()
    if head != expected:
        sys.exit("local %s is %s, expected %s; refusing" % (BRANCH, head, expected))
    code, text = forge("GET", "/repos/%s/%s/collaborators/%s/permission" % (OWNER, REPO, USER))
    perm = json.loads(text).get("permission") if code == 200 else None
    print("permission %s on %s/%s: HTTP %d %s" % (USER, OWNER, REPO, code, perm))
    print("remote %s before: HTTP %d %s" % ((BRANCH,) + remote_head()))
    if perm not in ("write", "admin", "owner"):
        sys.exit("%s may not push to %s/%s; refusing" % (USER, OWNER, REPO))
    if "--check-only" in sys.argv:
        return

    adir = tempfile.mkdtemp(prefix="askpass-", dir=scratch)
    askpass = os.path.join(adir, "askpass.sh")
    held = fat.temp_token("palamedes-push-preflight", "write:repository", username=USER, repo="%s/%s" % (OWNER, REPO), log=print)
    tok = held.__enter__()  # deleted in the finally below (rows left 0 + HTTP 401 proven by the helper)
    rc = 1
    try:
        with open(askpass, "w") as f:  # holds no secret: the token comes from the child's environment
            f.write('#!/bin/sh\ncase "$1" in Username*) echo %s;; *) printf \'%%s\\n\' "$PP_PUSH_TOKEN";; esac\n' % USER)
        os.chmod(askpass, stat.S_IRWXU)
        env = dict(os.environ, GIT_ASKPASS=askpass, GIT_TERMINAL_PROMPT="0", PP_PUSH_TOKEN=tok)
        p = subprocess.run(["git", "-C", wt, "-c", "credential.helper=", "push", "origin", "%s:refs/heads/%s" % (BRANCH, BRANCH)],
                           env=env, capture_output=True, text=True)
        rc = p.returncode
        print("git push exit %d" % rc)
        for line in (p.stdout + p.stderr).splitlines():
            print("  " + line.replace(tok, "[token]"))
    finally:
        os.unlink(askpass)
        os.rmdir(adir)
        held.__exit__(None, None, None)
        print("token after delete: GET /api/v1/user -> HTTP %s" % token_status(tok))
        tok = None
    c, rh = remote_head()
    print("remote %s after: HTTP %d %s (expected %s) %s" % (BRANCH, c, rh, expected, "MATCH" if rh == expected else "MISMATCH"))
    sys.exit(0 if rc == 0 and rh == expected else 1)


if __name__ == "__main__":
    main()
