#!/usr/bin/env python3
"""Push one ref to one forge repo with that repo's own write deploy key (chg-2026-11-13-002 L3 + L4, wq-140).

HONEST RECORD (P2): this script is hygiene, not containment. Any uid-501 process (myPKA included) can read the key
file and push without this script. The load-bearing controls are forge-side: branch/tag protection (P1/T1), the
commit pin with reviewed pin moves (P3/L6), and the forge-side audit in the daily posture scan (L5).

Usage:
  forge-deploy-key-push.py <chg-id> <owner/repo> <git-dir> <ref>=<sha> --key ~/.ssh/forge-<repo>-push [--dry-run]

Steps (any failure refuses, fail closed; exactly one changes.jsonl line per invocation, written by the script, L4):
  1 registry   the repo has an ACTIVE entry in deploy-keys.json, and --key is that entry's key_file.
  2 key (L1)   regular file, not a symlink, owned by this uid, mode 0600 or tighter, SHA256 fingerprint equal to
               the registry, and NOT loaded in ssh-agent.
  3 ref        refs/heads/<branch> only, full 40-hex sha present locally; deletions refused; tags refused (Forgejo
               protected tags have no deploy-key allowlist, T5); the branch must match the entry's allow_branches
               AND the first matching live forge protection rule must allow deploy keys (read-only SQL on forge-pg).
  4 fetch      the remote branches are fetched with the same key into refs/forge-push/<owner>/<repo>/*.
  5 ff         an existing branch must be an ancestor of <sha> (merge-base --is-ancestor); never a force push.
  3b inventory K1 a+b (Argus wq-140 delta): per registry repo the write deploy keys are exactly the registered one,
               and each registered key is on one repo only (read-only SQL); any mismatch refuses.
  6 scans      over the commits new to the forge: client terms 0 (AGR-073, boolean only, fail closed; the v2 keyed term
               file ~/.config/pka-chase/v2/client-terms.sha256 via client_filter.load_terms, as the handoff prescan;
               PKA_CHASE_TERMS_SCAN or --client-terms override) and gitleaks clean.
  7 probe      control-repo write probe: `git push --dry-run` with the key to the control repo (holds none of our
               keys) MUST be refused by Forgejo with "Public (Deploy) Key: <id>" equal to the registered id.
               Accepted = the key writes outside its repo = L7 revoke trigger.
  8 push       plain `git push <sha>:refs/heads/<branch>` (no +, no tags). --dry-run stops at `git push --dry-run`.
  9 readback   ls-remote (forge-read alias, else the push key) must show <sha>: MATCH; and (K4) an independent
               read-only SQL readback of branch.commit_id on forge-pg must show <sha> too (all repos; it is the only
               independent route for the push-key repos print3d and secure-access-mobile-app).
SSH: ssh -F none, -i <key>, IdentitiesOnly, IdentityAgent none, pinned known_hosts (this directory), StrictHostKeyChecking.
Nothing secret is printed: the key path, the public fingerprint and forge ids are public; a client hit is a boolean.
Exit 0 = pushed (or dry run passed) and read back, 1 = refused or failed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import pathlib
import re
import shlex
import stat
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
REGISTRY = HERE / "deploy-keys.json"
KNOWN_HOSTS = HERE / "known_hosts"
OPS_CLI = ROOT / "ops" / "ops"
CHG_RE = re.compile(r"^chg-\d{4}-\d{2}-\d{2}-\d{3}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
PROBE_RE = re.compile(r"Forgejo: Public \(Deploy\) Key: (\d+):.* is not authorized to")
ZERO = "0" * 40
DEFAULT_CLIENT_TERMS = "~/.config/pka-chase/v2/client-terms.sha256"   # F1: same file as the handoff prescan
INVENTORY = ROOT / "kubernetes/main/apps/observability/cluster-health/app/scripts/forge_inventory.py"
GLOB_REFUSE = "[]\\!{}"   # F2: gobwas classes, escapes, negation and braces: refuse instead of guessing


class Refused(Exception):
    """A check said no. The message is safe to print and goes into the change-log line."""


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def glob_re(pattern: str) -> re.Pattern:
    """Forgejo protected-branch glob (gobwas/glob, separator '/'): ** any, * and ? within one path segment.
    F2: a pattern with [ ] \\ ! { } uses gobwas syntax this parser does not model: Refused (fail closed)."""
    bad = sorted({c for c in pattern if c in GLOB_REFUSE})
    if bad:
        raise Refused("glob %r uses %s, which this script does not parse; refusing instead of guessing"
                      % (pattern, " ".join(bad)))
    out, i = "", 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            out, i = out + ".*", i + 2
            continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    return re.compile("^" + out + "$")


def is_glob(name: str) -> bool:
    """gobwas syntax.Special, as Forgejo IsRuleNameSpecial: any of * ? [ ] { } \\ ! makes the name a glob."""
    return any(ch in name for ch in "*?[]{}\\!")


def first_rule(rules: list[dict], branch: str) -> dict | None:
    """Forgejo 15.0.9 order (models/git/protected_branch_list.go:27-35): plain names first (matched with EqualFold),
    then globs by CreatedUnix, oldest first. Ties are broken by id here (sort.Slice is not stable)."""
    for r in rules:
        if not is_glob(r["name"]) and r["name"].lower() == branch.lower():
            return r
    for r in sorted((r for r in rules if is_glob(r["name"])), key=lambda r: (r.get("created", 0), r.get("id", 0))):
        if glob_re(r["name"]).match(branch):
            return r
    return None


def rule_allows_deploy_key(rule: dict | None) -> bool:
    if rule is None:
        return True
    return bool(rule["can_push"]) and (not rule["enable_whitelist"] or bool(rule["whitelist_deploy_keys"]))


class Forge:
    """Everything that talks to the forge or the cluster. Tests replace it with local bare repos."""

    def __init__(self, registry: dict, key_path: str):
        self.reg = registry
        self.key = key_path

    def url(self, repo: str) -> str:
        return "ssh://git@%s:%d/%s.git" % (self.reg["forge_ssh_host"], self.reg["forge_ssh_port"], repo)

    def env(self) -> dict:
        ssh = ["ssh", "-F", "none", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
               "-o", "UserKnownHostsFile=%s" % KNOWN_HOSTS, "-o", "GlobalKnownHostsFile=/dev/null",
               "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=%s" % self.reg["forge_ssh_host"],
               "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "PasswordAuthentication=no",
               "-o", "KbdInteractiveAuthentication=no", "-o", "UpdateHostKeys=no"]
        env = {k: v for k, v in os.environ.items() if k not in ("GIT_ASKPASS", "SSH_ASKPASS", "GIT_SSH")}
        env.update(GIT_SSH_COMMAND=" ".join(shlex.quote(a) for a in ssh), GIT_TERMINAL_PROMPT="0",
                   GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        return env

    @staticmethod
    def _fat():
        sys.path.insert(0, str(HERE.parent / "lib"))
        import forge_admin_token as fat  # noqa: PLC0415 - read-only SQL on the forge-pg primary (fails closed)
        return fat

    def rules(self, repo: str) -> tuple[list[dict], list[str]]:
        """Live protection rules, read-only SQL (default_transaction_read_only=on) on a forge-pg instance."""
        fat = self._fat()
        owner, name = (p.lower() for p in repo.split("/", 1))
        rid = "(select r.id from repository r join \"user\" u on u.id=r.owner_id where u.lower_name=%s " \
              "and r.lower_name=%s)" % (fat.lit(owner), fat.lit(name))
        if not fat.sql("select count(*) from repository where id = " + rid).strip() == "1":
            raise Refused("repo %s not found on the forge" % repo)
        rows = fat.sql("select branch_name, can_push, enable_whitelist, whitelist_deploy_keys, created_unix, id "
                       "from protected_branch where repo_id = " + rid).splitlines()
        tags = fat.sql("select name_pattern from protected_tag where repo_id = " + rid).splitlines()
        rules = []
        for line in rows:
            n, cp, ew, wd, cu, i = line.split("|")
            rules.append({"name": n, "can_push": cp == "t", "enable_whitelist": ew == "t",
                          "whitelist_deploy_keys": wd == "t", "created": int(cu), "id": int(i)})
        return rules, [t for t in tags if t]

    def deploy_keys(self) -> list[dict]:
        """K1 a+b: every deploy_key row site-wide (ids, repo, mode; no key material). Read-only SQL."""
        fat = self._fat()
        out = []
        for line in fat.sql("select dk.id, dk.key_id, dk.repo_id, coalesce(lower(r.owner_name) || '/' || "
                            "r.lower_name, ''), dk.mode from deploy_key dk left join repository r on "
                            "r.id = dk.repo_id").splitlines():
            if line.strip():
                d, k, rid, repo, mode = line.split("|")
                out.append({"deploy_key_id": int(d), "public_key_id": int(k), "repo_id": int(rid), "repo": repo,
                            "mode": int(mode)})
        return out

    def branch_commit(self, repo: str, branch: str) -> str | None:
        """K4: independent readback, branch.commit_id on forge-pg (read-only SQL, not the push credential)."""
        fat = self._fat()
        owner, name = (p.lower() for p in repo.split("/", 1))
        out = fat.sql("select b.commit_id from branch b join repository r on r.id = b.repo_id where "
                      "lower(r.owner_name) = %s and r.lower_name = %s and b.name = %s and not b.is_deleted"
                      % (fat.lit(owner), fat.lit(name), fat.lit(branch))).split()
        return out[0] if len(out) == 1 else None

    def readback(self, repo: str, branch: str, method: str) -> str | None:
        if method == "forge-read":
            url, env = "ssh://forge-read/%s.git" % repo, dict(os.environ, GIT_TERMINAL_PROMPT="0")
        else:
            url, env = self.url(repo), self.env()
        out = subprocess.run(["git", "ls-remote", url, "refs/heads/" + branch], capture_output=True, text=True,
                             env=env, timeout=60).stdout.split()
        return out[0] if out else None


def git(gitdir, *args, env=None, check=True, timeout=300):
    return subprocess.run(["git", "-C", str(gitdir), *args], capture_output=True, text=True, env=env, check=check,
                          timeout=timeout)


def load_registry(path=REGISTRY) -> dict:
    return json.loads(pathlib.Path(path).read_text())


def entry_for(reg: dict, repo: str) -> dict:
    matches = [k for k in reg["keys"] if k["repo"].lower() == repo.lower()]
    if len(matches) != 1:
        raise Refused("repo %s has no single entry in deploy-keys.json" % repo)
    e = matches[0]
    if e.get("status") != "active" or not e.get("fingerprint") or not e.get("public_key_id"):
        raise Refused("key for %s is not active in deploy-keys.json (status %s): record the L2 readback first"
                      % (repo, e.get("status")))
    if reg["control_repo"].lower() in {k["repo"].lower() for k in reg["keys"]}:
        raise Refused("control repo %s holds one of our keys; the probe would prove nothing" % reg["control_repo"])
    return e


def key_fingerprint(path: str) -> str:
    out = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", path], capture_output=True, text=True,
                         timeout=15).stdout.split()
    if len(out) < 2 or not out[1].startswith("SHA256:"):
        raise Refused("cannot read the key fingerprint")
    return out[1]


def agent_fingerprints() -> str:
    return subprocess.run(["ssh-add", "-l", "-E", "sha256"], capture_output=True, text=True, timeout=15).stdout


def check_key(path: str, entry: dict) -> str:
    """L1 hygiene. Returns the public SHA256 fingerprint."""
    if os.path.abspath(os.path.expanduser(path)) != os.path.abspath(os.path.expanduser(entry["key_file"])):
        raise Refused("--key is not the registered key_file for %s" % entry["repo"])
    try:
        st = os.lstat(path)
    except OSError:
        raise Refused("key file missing") from None
    if not stat.S_ISREG(st.st_mode):
        raise Refused("key file is not a regular file (symlink or other)")
    if st.st_uid != os.getuid():
        raise Refused("key file is not owned by this uid")
    if st.st_mode & 0o077:
        raise Refused("key file mode is %o; must be 0600 or tighter" % stat.S_IMODE(st.st_mode))
    fp = key_fingerprint(path)
    if fp != entry["fingerprint"]:
        raise Refused("key fingerprint does not match the registry (L2)")
    if fp in agent_fingerprints():
        raise Refused("key is loaded in ssh-agent (L1 forbids it)")
    return fp


def parse_ref(spec: str) -> tuple[str, str, str]:
    """<ref>=<sha> -> (kind, name, sha). Refuses deletions, tags and other ref namespaces."""
    if "=" not in spec:
        raise Refused("ref must be <ref>=<sha>")
    ref, sha = spec.split("=", 1)
    if ref.startswith("+") or ref.startswith(":") or ":" in ref:
        raise Refused("refspec syntax (+, :) is not accepted; give <branch>=<sha>")
    if sha in ("", ZERO) or set(sha) == {"0"}:
        raise Refused("deletions are refused")
    if not SHA_RE.match(sha):
        raise Refused("sha must be a full 40-hex commit id")
    if ref.startswith("refs/tags/") or ref.startswith("tag:"):
        raise Refused("tags are refused (protected tags have no deploy-key allowlist, T5)")
    if ref.startswith("refs/heads/"):
        ref = ref[len("refs/heads/"):]
    elif ref.startswith("refs/"):
        raise Refused("only refs/heads/* may be pushed")
    if subprocess.run(["git", "check-ref-format", "refs/heads/" + ref], capture_output=True).returncode != 0:
        raise Refused("invalid branch name")
    return "branch", ref, sha


def check_branch_policy(entry: dict, branch: str, rules: list[dict], tag_patterns: list[str]) -> str:
    if not any(glob_re(p).match(branch) for p in entry.get("allow_branches", [])):
        raise Refused("branch %s is not in allow_branches for %s" % (branch, entry["repo"]))
    rule = first_rule(rules, branch)
    if not rule_allows_deploy_key(rule):
        raise Refused("forge rule %r on %s does not allow deploy keys to push %s" % (rule["name"], entry["repo"], branch))
    return "rule %s allows deploy keys" % (rule["name"] if rule else "none (unprotected)")


def load_inventory():
    spec = importlib.util.spec_from_file_location("forge_inventory", INVENTORY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check_inventory(forge: Forge, reg: dict) -> str:
    """K1 a+b at push time: refuse on any unexpected write key on a registry repo or a key reused across repos."""
    found = load_inventory().key_findings(reg, forge.deploy_keys())
    if found:
        raise Refused("forge inventory %s: %s (revoke runbook docs/runbooks/forge-deploy-key-revoke.md)"
                      % (found[0]["check"], found[0]["evidence"][:200]))
    return "K1a+K1b clean (%d registry repos)" % len(reg["keys"])


def sql_readback(forge: Forge, repo: str, branch: str, sha: str, tries: int = 10, wait: float = 3) -> str:
    """K4: after a push, branch.commit_id on forge-pg must equal sha (Forgejo updates the row from post-receive,
    so it is retried). Returns MATCH, MISMATCH (<sha|absent>) or ERROR (<class>)."""
    got = None
    for n in range(tries):
        try:
            got = forge.branch_commit(repo, branch)
        except Exception as e:  # noqa: BLE001 - an unread row is not a match
            return "ERROR (%s)" % e.__class__.__name__
        if got == sha:
            return "MATCH"
        if n + 1 < tries:
            time.sleep(wait)
    return "MISMATCH (%s)" % (got or "absent")


def scan_client_terms(text: str, filter_bin: str, terms_path: str) -> bool:
    """True when clean. Raises Refused (fail closed) when the fence cannot load. Never says which term."""
    p = pathlib.Path(filter_bin) / "client_filter.py"
    if not p.is_file():
        raise Refused("client filter missing (fail closed)")
    spec = importlib.util.spec_from_file_location("client_filter", p)
    cf = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cf)
    try:
        terms = cf.load_terms(terms_path)
        return not cf.hits(text, terms)
    except cf.FenceError:
        raise Refused("client term fence did not load (fail closed)") from None


def scan_gitleaks(gitdir, log_opts: str, expected_commits: int) -> bool:
    """True when clean. gitleaks 8.30 exits 0 with "0 commits scanned" when git log fails (measured 2026-11-27),
    so the scanned count must equal the range size and any ERR line refuses (fail closed)."""
    r = subprocess.run(["gitleaks", "git", "--no-banner", "--no-color", "--redact", "--log-level", "info",
                        "--exit-code", "1", "--log-opts", log_opts, str(gitdir)],
                       capture_output=True, text=True, timeout=600)
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    if r.returncode == 1:
        return False
    if r.returncode != 0 or re.search(r"\bERR\b", out):
        raise Refused("gitleaks errored (exit %d; fail closed)" % r.returncode)
    m = re.search(r"(\d+) commits? scanned", out)
    if not m or int(m.group(1)) != expected_commits:
        raise Refused("gitleaks scanned %s commits, range has %d (fail closed)" % (m.group(1) if m else "?",
                                                                                  expected_commits))
    return True


def control_probe(forge: Forge, reg: dict, gitdir, sha: str, public_key_id) -> str:
    """Write probe with the key against the control repo; must be refused by Forgejo naming our key id."""
    r = git(gitdir, "push", "--dry-run", "--porcelain", "--no-follow-tags", forge.url(reg["control_repo"]),
            "%s:refs/heads/forge-push-probe" % sha, env=forge.env(), check=False, timeout=60)
    if r.returncode == 0:
        raise Refused("CONTROL PROBE ACCEPTED: the key can write %s; L7 revoke trigger, revoke now "
                      "(docs/runbooks/forge-deploy-key-revoke.md)" % reg["control_repo"])
    m = PROBE_RE.search(r.stderr)
    if not m:
        raise Refused("control probe gave no Forgejo refusal (network or host key?); fail closed")
    if str(m.group(1)) != str(public_key_id):
        raise Refused("control probe names key id %s, registry says %s (L2 mismatch)" % (m.group(1), public_key_id))
    return "refused (key %s)" % m.group(1)


def write_line(ops_cli, chg: str, actor: str, payload: dict) -> None:
    """L4: exactly one change-log line per invocation, written by this script."""
    r = subprocess.run([sys.executable, str(ops_cli), "change", "event", chg, "executed", "--actor", actor,
                        "--payload-json", json.dumps(payload, sort_keys=True)], capture_output=True, text=True,
                       timeout=30)
    if r.returncode != 0:
        print("L4 LINE NOT WRITTEN: %s" % r.stderr.strip()[:200])
        raise SystemExit(1)
    print("L4 line written to %s" % pathlib.Path(ops_cli).resolve().parent.joinpath("changes.jsonl"))


def run(a, forge_factory=Forge, registry_path=REGISTRY) -> tuple[dict, int]:
    payload = {"kind": "forge-deploy-key-push", "regime": "AGR-109: tests are the gate", "repo": a.repo,
               "ref": a.ref, "dry_run": bool(a.dry_run), "checks": {}, "ts_start": now()}
    c = payload["checks"]
    try:
        reg = load_registry(registry_path)
        entry = entry_for(reg, a.repo)
        payload["public_key_id"] = entry["public_key_id"]
        payload["deploy_key_id"] = entry.get("deploy_key_id")
        forge = forge_factory(reg, os.path.expanduser(a.key))
        payload["key_fp"] = c["key"] = check_key(os.path.expanduser(a.key), entry)
        _, branch, sha = parse_ref(a.ref)
        payload.update(branch=branch, new=sha)
        if git(a.gitdir, "cat-file", "-e", sha + "^{commit}", check=False).returncode != 0:
            raise Refused("commit %s is not in %s" % (sha, a.gitdir))
        if git(a.gitdir, "config", "--get-regexp", r"^url\.", check=False).stdout.strip():
            raise Refused("git dir has url.*.insteadOf rewrites; refusing (the push URL must be the forge)")
        rules, tag_patterns = forge.rules(a.repo)
        c["rules"] = check_branch_policy(entry, branch, rules, tag_patterns)
        c["inventory"] = check_inventory(forge, reg)
        ns = "refs/forge-push/%s" % a.repo.lower()
        f = git(a.gitdir, "fetch", "--no-tags", "--quiet", forge.url(a.repo), "+refs/heads/*:%s/*" % ns,
                env=forge.env(), check=False, timeout=300)
        if f.returncode != 0:
            raise Refused("fetch with the key failed: %s" % (f.stderr.strip().splitlines() or ["?"])[-1][:160])
        old = git(a.gitdir, "rev-parse", "--verify", "--quiet", "%s/%s" % (ns, branch), check=False).stdout.strip()
        payload["old"] = old or None
        if old == sha:
            raise Refused("remote %s is already at %s; nothing to push" % (branch, sha[:12]))
        if old and git(a.gitdir, "merge-base", "--is-ancestor", old, sha, check=False).returncode != 0:
            raise Refused("non-fast-forward: %s is not an ancestor of %s; force pushes are refused" % (old[:12], sha[:12]))
        c["ff"] = "fast-forward" if old else "new branch"
        rng = [sha, "--not", "--glob=%s/*" % ns]
        commits = git(a.gitdir, "rev-list", *rng).stdout.split()
        payload["commits"] = len(commits)
        text = branch + "\n" + git(a.gitdir, "log", "-p", "--no-color", "--no-ext-diff",
                                   "--format=%H%n%an <%ae>%n%cn <%ce>%n%B", *rng).stdout
        if not scan_client_terms(text, a.client_filter_bin, a.client_terms):
            c["client_terms"] = "HIT"
            raise Refused("client term filter hit (AGR-073; boolean only, nothing pushed)")
        c["client_terms"] = "clean"
        if not scan_gitleaks(a.gitdir, " ".join(rng), len(commits)):
            c["gitleaks"] = "LEAK"
            raise Refused("gitleaks found a leak in the range (nothing pushed)")
        c["gitleaks"] = "clean"
        c["control_probe"] = control_probe(forge, reg, a.gitdir, sha, entry["public_key_id"])
        refspec = "%s:refs/heads/%s" % (sha, branch)
        p = git(a.gitdir, "push", "--porcelain", "--no-follow-tags", *(["--dry-run"] if a.dry_run else []),
                forge.url(a.repo), refspec, env=forge.env(), check=False, timeout=300)
        payload["push_exit"] = p.returncode
        payload["push_line"] = next((ln for ln in p.stdout.splitlines() if ln.startswith(("=", " ", "*", "!", "+", "-"))
                                     and "refs/heads/" in ln), "")[:200]
        if p.returncode != 0:
            last = (p.stderr.strip().splitlines() or ["?"])[-1][:200]
            raise Refused("push refused by the forge: %s" % last)
        if a.dry_run:
            payload["result"] = "DRY-RUN-OK"
            return payload, 0
        payload["ts_push"] = now()
        got = None
        for _ in range(10):
            got = forge.readback(a.repo, branch, entry.get("readback", "push-key"))
            if got == sha:
                break
            time.sleep(3)
        payload["readback"] = "MATCH" if got == sha else "MISMATCH (%s)" % (got or "absent")
        payload["readback_via"] = entry.get("readback", "push-key")
        payload["readback_sql"] = sql_readback(forge, a.repo, branch, sha)
        ok = got == sha and payload["readback_sql"] == "MATCH"
        payload["result"] = "PUSHED" if ok else "PUSHED-READBACK-MISMATCH"
        return payload, 0 if ok else 1
    except Refused as e:
        payload["result"] = "REFUSED"
        payload["reason"] = str(e)
        return payload, 1
    except Exception as e:  # noqa: BLE001 - any failure is FAILED, still one line
        payload["result"] = "FAILED"
        payload["reason"] = "%s: %s" % (e.__class__.__name__, str(e)[:160])
        return payload, 1


def main(argv=None, forge_factory=Forge, registry_path=REGISTRY) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("chg")
    ap.add_argument("repo")
    ap.add_argument("gitdir")
    ap.add_argument("ref", help="<branch>=<40-hex sha>")
    ap.add_argument("--key", required=True, help="private key file of this repo's deploy key (registry key_file)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--actor", default="k8s-engineer")
    ap.add_argument("--ops-cli", default=str(OPS_CLI))
    ap.add_argument("--client-filter-bin", default=os.path.expanduser("~/pka-chase/bin"))
    ap.add_argument("--client-terms", default=None,
                    help="v2 keyed term file (default $PKA_CHASE_TERMS_SCAN, else %s)" % DEFAULT_CLIENT_TERMS)
    a = ap.parse_args(argv)
    if not a.client_terms:
        a.client_terms = os.environ.get("PKA_CHASE_TERMS_SCAN") or os.path.expanduser(DEFAULT_CLIENT_TERMS)
    if not CHG_RE.match(a.chg):
        print("REFUSED: chg id required (chg-YYYY-MM-DD-NNN); no line written")
        return 1
    if "/" not in a.repo or not all(NAME_RE.match(p) for p in a.repo.split("/", 1)):
        print("REFUSED: repo must be <owner>/<repo>; no line written")
        return 1
    payload, rc = run(a, forge_factory, registry_path)
    payload["ts_end"] = now()
    print("%s %s %s %s" % (payload.get("result"), a.repo, payload.get("branch", a.ref),
                           payload.get("reason") or ("%s sql %s" % (payload["readback"], payload["readback_sql"])
                                                     if "readback_sql" in payload else "")))
    for k, v in payload["checks"].items():
        print("  %-14s %s" % (k, v))
    write_line(a.ops_cli, a.chg, a.actor, payload)
    return rc


if __name__ == "__main__":
    sys.exit(main())
