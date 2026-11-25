#!/usr/bin/env python3
"""i9-chase-c1-export.py: C1, model-free. Runs Mack's export_changes.py (open-loop projection of ops/changes.jsonl,
client-term filtered, fail closed) and pushes ONLY atlas/ops/open-loop-changes.json to the chase exchange repo.
No model, no network except the git push. Silent on success; one log line per run. Stdlib only.

Env (all overridable by flags in tests):
  CHASE_BIN            dir with export_changes.py (default ~/pka-chase/bin)
  C1_CHANGES           ops/changes.jsonl                      C1_HOOK  vault hook atlas-changes-since.py
  C1_TERMS             client-terms.sha256                    C1_EXCHANGE_URL  exchange git URL (required)
  C1_KEY               ssh private key (write deploy key); empty = no ssh options (local/test transport)
  C1_KNOWN_HOSTS       known_hosts file (default ~/.ssh/known_hosts), C1_HOST_ALIAS optional HostKeyAlias
  C1_STATE             state dir (default ~/.local/state/pka-chase-c1)
  C1_DRY               1 = build and diff, never push
Exit: 0 ok/unchanged, 3 fence or input missing (nothing pushed; the old exchange file stays), 1 git failure.
"""
import datetime as dt, json, os, subprocess, sys, tempfile, shutil
from pathlib import Path

REL = "atlas/ops/open-loop-changes.json"
E = os.environ


def log(msg):
    sd = Path(E.get("C1_STATE", str(Path.home() / ".local/state/pka-chase-c1")))
    sd.mkdir(parents=True, exist_ok=True)
    line = "%s %s" % (dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), msg)
    with open(sd / "c1.log", "a") as f:
        f.write(line + "\n")
    print(line)
    if msg.startswith(("c1 pushed", "c1 unchanged")):    # success stamp: the pka-alert wire chase-c1 watches this mtime
        (sd / "c1.ok").write_text(line + "\n")


def git(env, *a, cwd=None):
    r = subprocess.run(["git", *a], cwd=cwd, env=env, capture_output=True, timeout=120)
    if r.returncode:
        raise RuntimeError("git %s: %s" % (a[0], r.stderr.decode(errors="replace").strip()[:200]))
    return r.stdout.decode()


def stable(doc_text):
    d = json.loads(doc_text)
    d.pop("generated", None)
    return json.dumps(d, sort_keys=True)


def main():
    bin_ = Path(E.get("CHASE_BIN", str(Path.home() / "pka-chase/bin")))
    url = E.get("C1_EXCHANGE_URL")
    changes, hook, terms = E.get("C1_CHANGES"), E.get("C1_HOOK"), E.get("C1_TERMS")
    if not (url and changes and hook and terms):
        log("c1 error: C1_EXCHANGE_URL, C1_CHANGES, C1_HOOK, C1_TERMS are required")
        return 3
    work = Path(tempfile.mkdtemp(prefix="c1."))
    try:
        out = work / "out" / "open-loop-changes.json"
        r = subprocess.run([sys.executable, "-I", str(bin_ / "export_changes.py"), "--changes", changes,
                            "--changes-script", hook, "--client-terms", terms, "--out", str(out)],
                           capture_output=True, timeout=600)  # HMAC matcher (chase 8bcf48a) needs ~120 s under launchd Background; interval is 900 s
        if r.returncode:
            log("c1 export refused rc=%d: %s" % (r.returncode, r.stderr.decode()[:160].strip()))
            return 3
        env = dict(E)
        env["GIT_TERMINAL_PROMPT"] = "0"
        if E.get("C1_KEY"):
            kh = E.get("C1_KNOWN_HOSTS", str(Path.home() / ".ssh/known_hosts"))
            alias = E.get("C1_HOST_ALIAS")
            env["GIT_SSH_COMMAND"] = ("ssh -i %s -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes "
                                      "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s -o ConnectTimeout=15%s"
                                      % (E["C1_KEY"], kh, " -o HostKeyAlias=" + alias if alias else ""))
        x = work / "x"
        git(env, "clone", "--depth", "1", "-q", url, str(x))
        dest = x / REL
        new = out.read_text()
        if dest.is_file() and stable(dest.read_text()) == stable(new):
            log("c1 unchanged")
            return 0
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(new)
        git(env, "add", "--", REL, cwd=x)
        staged = git(env, "diff", "--cached", "--name-only", cwd=x).split()
        if staged != [REL]:                       # the one-path guarantee, independent of forge ACLs
            log("c1 refuse: staged set is not exactly the export file: %r" % staged[:5])
            return 3
        if E.get("C1_DRY") == "1":
            log("c1 dry: would push %s (%d bytes)" % (REL, len(new)))
            return 0
        git(env, "-c", "user.name=atlas-c1", "-c", "user.email=atlas-c1@localhost", "commit", "-q", "-m",
            "atlas: open-loop change export", cwd=x)
        git(env, "push", "-q", "origin", "HEAD", cwd=x)
        log("c1 pushed %s" % REL)
        return 0
    except Exception as e:
        log("c1 failed: %s" % str(e)[:200])
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
