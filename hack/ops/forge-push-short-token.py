#!/usr/bin/env python3
"""Push refs from a local git dir to one forge repository with a short-lived, one-repo token.

Generalised from chg-2026-10-15-007-push-preflight-branch.py (same credential handling): admin reads use a
short-lived admforgejo CLI token (hack/ops/lib/forge_admin_token.py; chg-2026-11-20-001: the old admin Secret
gets 401), via curl inside the forge pod with a curl config on STDIN (never in argv). The push token is minted by
the forge CLI too and restricted to the repository by DB row (the token API wants a password login).
The token is for <user>, scope write:repository, RESTRICTED to the one target repository.
It lives only in this process and in the environment of the one `git push` child, read back by a GIT_ASKPASS
script that holds no secret. It is deleted in a finally block, and the script proves it is gone: the token gets
401 from the forge and is absent from the user's token list. Nothing secret is printed or written to disk.
No write key or token stays on the machine (forge-push-route: no forge write credential on the Mini).

Usage: forge-push-short-token.py <chg> <user> <owner/repo> <git-dir> <scratch-dir> <branch>=<sha> [...] [--check-only]
Every <branch> must point at <sha> locally; the push is refused otherwise. Pushes are fast-forward only (no --force).
"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import forge_admin_token as fat  # noqa: E402

KUBECTL = os.environ.get("KUBECTL", "kubectl")
NS = "devtools"
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


def remote_head(owner, repo, branch):
    code, text = forge("GET", "/repos/%s/%s/branches/%s" % (owner, repo, branch.replace("/", "%2F")))
    return code, (json.loads(text).get("commit", {}).get("id") if code == 200 else None)


def main():
    global TOK
    if len([a for a in sys.argv[1:] if a != "--check-only"]) < 6:
        sys.exit(__doc__)
    with fat.temp_token("%s-push-read" % sys.argv[1], "read:repository", log=print) as TOK:
        _main()
    TOK = None


def _main():
    args = [a for a in sys.argv[1:] if a != "--check-only"]
    if len(args) < 6:
        sys.exit(__doc__)
    chg, user, target, gitdir, scratch = args[:5]
    owner, repo = target.split("/", 1)
    refs = dict(a.split("=", 1) for a in args[5:])
    for branch, expected in refs.items():
        head = subprocess.run(["git", "-C", gitdir, "rev-parse", "refs/heads/" + branch],
                              capture_output=True, check=True, text=True).stdout.strip()
        if head != expected:
            sys.exit("local %s is %s, expected %s; refusing" % (branch, head, expected))
    code, text = forge("GET", "/repos/%s/%s/collaborators/%s/permission" % (owner, repo, user))
    perm = json.loads(text).get("permission") if code == 200 else None
    print("permission %s on %s: HTTP %d %s" % (user, target, code, perm))
    for branch in refs:
        print("remote %s before: HTTP %d %s" % ((branch,) + remote_head(owner, repo, branch)))
    if perm not in ("write", "admin", "owner"):
        sys.exit("%s may not push to %s; refusing" % (user, target))
    if "--check-only" in sys.argv:
        return

    adir = tempfile.mkdtemp(prefix="askpass-", dir=scratch)
    askpass = os.path.join(adir, "askpass.sh")
    held = fat.temp_token("%s-push" % sys.argv[1], "write:repository", username=user, repo=target, log=print)
    tok = held.__enter__()  # deleted in the finally below (rows left 0 + HTTP 401 proven by the helper)
    rc = 1
    try:
        with open(askpass, "w") as f:  # holds no secret: the token comes from the child's environment
            f.write('#!/bin/sh\ncase "$1" in Username*) echo %s;; *) printf \'%%s\\n\' "$FORGE_PUSH_TOKEN";; esac\n' % user)
        os.chmod(askpass, stat.S_IRWXU)
        env = dict(os.environ, GIT_ASKPASS=askpass, GIT_TERMINAL_PROMPT="0", FORGE_PUSH_TOKEN=tok)
        url = "%s/%s/%s.git" % (FORGE, owner, repo)
        p = subprocess.run(["git", "-C", gitdir, "-c", "credential.helper=", "push", url,
                            *["refs/heads/%s:refs/heads/%s" % (b, b) for b in refs]],
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
    ok = rc == 0
    for branch, expected in refs.items():
        for _ in range(10):  # the first push into an empty repo shows up in the API a few seconds later
            c, rh = remote_head(owner, repo, branch)
            if rh == expected:
                break
            time.sleep(3)
        print("remote %s after: HTTP %d %s (expected %s) %s" % (branch, c, rh, expected, "MATCH" if rh == expected else "MISMATCH"))
        ok = ok and rh == expected
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
