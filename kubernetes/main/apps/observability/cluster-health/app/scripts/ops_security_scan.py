#!/usr/bin/env python3
"""Argus — weekly security posture scan.

Read-only checks across the cluster + repo. Findings are recorded as
events on a single posture-scan change record. High-severity findings
also open an incident so they can't be ignored.

Runs from /scripts inside cluster-health pod context. Clones the repo
to read ops/, gitleaks-scans the working tree, and queries kubectl for
RBAC + Services + Certificates.

Best-effort: any individual probe failing is logged but doesn't fail
the whole scan. The goal is a usable report, not a perfect one.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import datetime as dt
import urllib.request
import urllib.error
from pathlib import Path

sys.path.insert(0, "/scripts")
from git_push import mint_installation_token  # noqa: E402
from lib import log, today  # noqa: E402


def load_accepted_risks(workdir: Path) -> list[dict]:
    """Read ops/accepted_risks.yaml from the cloned repo. Returns the list
    of risks, or [] if the file is absent or unparseable. Used by
    apply_accepted_risks() to downgrade matching findings."""
    p = workdir / "ops" / "accepted_risks.yaml"
    if not p.exists():
        return []
    # Tiny YAML parser is fine — schema is flat.
    try:
        import yaml  # type: ignore
        with p.open() as f:
            data = yaml.safe_load(f) or {}
        return data.get("risks") or []
    except ImportError:
        # Fall back: parse by hand. Schema is intentionally simple — but
        # we MUST strip surrounding quotes from values, otherwise the
        # regex includes literal `"` characters and never matches.
        risks: list[dict] = []
        cur: dict | None = None
        def _unquote(s: str) -> str:
            s = s.strip()
            if len(s) >= 2 and ((s[0] == s[-1] == '"') or (s[0] == s[-1] == "'")):
                return s[1:-1]
            return s
        for raw in p.read_text().splitlines():
            line = raw.rstrip()
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.startswith("  - id:"):
                if cur:
                    risks.append(cur)
                cur = {"id": _unquote(line.split("id:", 1)[1])}
                continue
            if cur is None or not line.startswith("    "):
                continue
            k, _, v = line.strip().partition(":")
            cur[k.strip()] = _unquote(v)
        if cur:
            risks.append(cur)
        return risks


def apply_accepted_risks(findings: list[dict], risks: list[dict]) -> list[dict]:
    """For each finding that matches an accepted-risk entry (both
    finding_title AND target patterns), downgrade severity to `info` and
    attach an `accepted_risk` pointer. Returns the modified list (in place)."""
    if not risks:
        return findings
    compiled = []
    for r in risks:
        try:
            t = re.compile(r.get("finding_title", "") or ".*")
            g = re.compile(r.get("target", "") or ".*")
        except re.error as e:
            log(f"argus: bad regex in accepted_risk {r.get('id','?')}: {e}")
            continue
        compiled.append((r, t, g))
    for f in findings:
        for r, t_re, g_re in compiled:
            if t_re.search(f.get("title", "")) and g_re.search(f.get("target", "")):
                f["original_severity"] = f.get("severity")
                f["severity"] = "info"
                f["accepted_risk"] = r.get("id")
                f["accepted_risk_adr"] = r.get("adr")
                break
    return findings

GIT_REMOTE = os.environ.get("GIT_REMOTE", "https://github.com/vdhict/vdhinfra.git")
GIT_BRANCH = os.environ.get("GIT_BRANCH", "main")
HA_URL = os.environ.get("HA_URL", "")
HA_TOKEN = os.environ.get("HA_TOKEN", "")


def run(cmd, **kw):
    """subprocess.run wrapper. Forwards env, cwd, etc. — earlier version
    silently dropped these which is why the post-scan commit-back
    appeared to succeed but never actually pushed."""
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    kw.setdefault("timeout", 60)
    return subprocess.run(cmd, **kw)


def clone(workdir: Path) -> bool:
    tok = mint_installation_token()
    if not tok:
        log("argus: no token; cannot scan repo for secrets")
        return False
    remote = GIT_REMOTE.removeprefix("https://")
    res = run(["git", "clone", "--quiet", "--depth", "50", "--branch", GIT_BRANCH,
              f"https://x-access-token:{tok}@{remote}", str(workdir)], timeout=120)
    if res.returncode != 0:
        log(f"argus: clone failed: {res.stderr[:300]}")
        return False
    return True


def ops_event(chg: str, event: str, payload: dict, repo: Path | None = None) -> None:
    """Append an event to ops/changes.jsonl in the cloned repo and via local CLI."""
    if not repo:
        return
    cli = repo / "ops" / "ops"
    if not cli.exists():
        log(f"argus: ops CLI missing at {cli}")
        return
    res = run(["python3", str(cli), "change", "event", chg, event,
               "--actor", "security-engineer",
               "--payload-json", json.dumps(payload)],
              cwd=str(repo), timeout=15)
    if res.returncode != 0:
        log(f"argus: ops event failed: {res.stderr[:200]}")


def ops_change_new(resource: str, risk: str, repo: Path, summary: str) -> str | None:
    cli = repo / "ops" / "ops"
    res = run(["python3", str(cli), "change", "new", resource, risk,
               "--actor", "security-engineer",
               "--summary", summary,
               "--reason", "weekly scheduled posture scan"],
              cwd=str(repo), timeout=15)
    if res.returncode != 0:
        log(f"argus: change new failed: {res.stderr[:200]}")
        return None
    return res.stdout.strip()


# ── individual checks ───────────────────────────────────────────────────

def check_gitleaks(repo: Path) -> list[dict]:
    """Run gitleaks against the working tree; flag any leaks."""
    findings = []
    res = run(["gitleaks", "detect", "--source", str(repo), "--no-banner",
               "--no-git", "--report-format=json", "--report-path=/tmp/gitleaks.json",
               "--exit-code=0"], timeout=120)
    if res.returncode not in (0, 1):
        log(f"argus: gitleaks unavailable or errored ({res.returncode}): {res.stderr[:200]}")
        return findings
    try:
        with open("/tmp/gitleaks.json") as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        log(f"argus: gitleaks report unreadable: {e}")
        return findings
    for leak in data or []:
        findings.append({
            "title": f"gitleaks: {leak.get('Description','potential secret')}",
            "severity": "high",
            "target": leak.get("File", "?"),
            "evidence": f"line {leak.get('StartLine','?')}: {leak.get('Match','')[:80]}",
            "remediation": "rotate secret + remove from history; if false positive, add to .gitleaksignore",
            "owner_agent": "infra-ops",
        })
    return findings


def check_admin_rbac() -> list[dict]:
    """List ClusterRoleBindings that grant cluster-admin or wildcard verbs."""
    findings = []
    res = run(["kubectl", "get", "clusterrolebinding", "-o", "json"], timeout=30)
    if res.returncode != 0:
        log(f"argus: kubectl crb failed: {res.stderr[:200]}")
        return findings
    try:
        data = json.loads(res.stdout)
    except Exception as e:  # noqa: BLE001
        log(f"argus: crb json: {e}")
        return findings
    for crb in data.get("items", []):
        role = crb.get("roleRef", {}).get("name", "")
        if role != "cluster-admin":
            continue
        for subj in crb.get("subjects") or []:
            kind = subj.get("kind", "?")
            name = subj.get("name", "?")
            ns = subj.get("namespace", "")
            # Allow the well-known system bindings + flux + the user account
            allow = {
                "system:masters", "system:nodes", "system:kube-scheduler",
                "system:kube-controller-manager", "kubeadm:cluster-admins",
            }
            if name in allow:
                continue
            findings.append({
                "title": "ClusterRoleBinding grants cluster-admin",
                "severity": "medium",
                "target": f'{crb["metadata"]["name"]} -> {kind}/{name}{"/"+ns if ns else ""}',
                "evidence": f"roleRef=cluster-admin",
                "remediation": "scope down to specific verbs/resources; cluster-admin is rarely actually needed",
                "owner_agent": "k8s-engineer",
            })
    return findings


def check_exposed_services() -> list[dict]:
    """LoadBalancer / NodePort services without a corresponding HTTPRoute or known internal-only purpose."""
    findings = []
    res = run(["kubectl", "get", "svc", "-A", "-o", "json"], timeout=30)
    if res.returncode != 0:
        return findings
    try:
        data = json.loads(res.stdout)
    except Exception:
        return findings
    # well-known LB IPs allowlist. Each line tagged with its purpose so a
    # future engineer can verify why an entry exists. New LBs added without
    # being added here will surface as low-severity findings — by design.
    expected_lb = {
        "172.16.2.243",  # envoy-external (cluster-wide ingress, Cloudflare tunnel target)
        "172.16.2.241",  # envoy-internal (LAN-only ingress)
        "172.16.2.246",  # synology NAS NFS
        "172.16.2.235",  # observability/promtail-syslog (syslog ingest)
        "172.16.2.236",  # media/plex (Plex direct LAN)
        "172.16.2.237",  # home-automation/home-assistant (direct LAN, HA cli)
        "172.16.2.238",  # home-automation/music-assistant
        "172.16.2.239",  # database/postgres-lb (CNPG read/write split-port)
        "172.16.2.244",  # home-automation/mosquitto (MQTT broker)
        "172.16.2.245",  # storage/minio-lb (offsite backup target)
        "172.16.2.247",  # home-automation/tesla-http-proxy
    }
    for s in data.get("items", []):
        st = s.get("spec", {}).get("type", "")
        if st not in ("LoadBalancer", "NodePort"):
            continue
        name = s["metadata"]["name"]
        ns = s["metadata"]["namespace"]
        ingress = s.get("status", {}).get("loadBalancer", {}).get("ingress", []) or [{}]
        ip = ingress[0].get("ip", "") if ingress else ""
        if st == "LoadBalancer" and ip and ip not in expected_lb:
            findings.append({
                "title": "LoadBalancer Service with non-allowlisted IP",
                "severity": "low",
                "target": f"{ns}/{name}",
                "evidence": f"type={st} ip={ip}",
                "remediation": "verify intentional; if internal-only, consider ClusterIP + HTTPRoute via envoy-internal",
                "owner_agent": "k8s-engineer",
            })
    return findings


def check_certs() -> list[dict]:
    """cert-manager Certificate resources nearing expiry or not Ready."""
    findings = []
    res = run(["kubectl", "get", "certificate", "-A", "-o", "json"], timeout=30)
    if res.returncode != 0:
        return findings
    try:
        items = json.loads(res.stdout).get("items", [])
    except Exception:
        return findings
    now = dt.datetime.now(dt.timezone.utc)
    for c in items:
        meta = c.get("metadata", {})
        st = c.get("status", {})
        not_after_s = st.get("notAfter")
        ready = "False"
        for cond in st.get("conditions") or []:
            if cond.get("type") == "Ready":
                ready = cond.get("status", "Unknown")
                break
        if ready != "True":
            findings.append({
                "title": "Certificate not Ready",
                "severity": "high" if ready == "False" else "medium",
                "target": f'{meta.get("namespace")}/{meta.get("name")}',
                "evidence": f"Ready={ready}",
                "remediation": "kubectl describe certificate; check cert-manager + DNS-01 challenge",
                "owner_agent": "k8s-engineer",
            })
        if not_after_s:
            try:
                not_after = dt.datetime.fromisoformat(not_after_s.replace("Z", "+00:00"))
                days = (not_after - now).days
                if days < 14:
                    findings.append({
                        "title": f"Certificate expires in {days}d",
                        "severity": "high" if days < 7 else "medium",
                        "target": f'{meta.get("namespace")}/{meta.get("name")}',
                        "evidence": f"notAfter={not_after_s}",
                        "remediation": "check renewer; force renewal if needed",
                        "owner_agent": "k8s-engineer",
                    })
            except Exception:
                pass
    return findings


def check_ha_tokens(repo: Path) -> list[dict]:
    """Inspect HA refresh tokens for stale/unknown clients."""
    findings = []
    res = run(["kubectl", "exec", "-n", "home-automation", "deploy/home-assistant", "-c", "app",
               "--", "cat", "/config/.storage/auth"], timeout=30)
    if res.returncode != 0:
        log(f"argus: HA auth read failed: {res.stderr[:200]}")
        return findings
    try:
        data = json.loads(res.stdout)
    except Exception:
        return findings
    tokens = data.get("data", {}).get("refresh_tokens", [])
    now = dt.datetime.now(dt.timezone.utc)
    llats = [t for t in tokens if t.get("token_type") == "long_lived_access_token"]
    findings.append({
        "title": f"HA: {len(tokens)} refresh tokens ({len(llats)} LLATs)",
        "severity": "info",
        "target": "ha.auth.storage",
        "evidence": ", ".join(sorted({t.get("client_name") or "(no-name)" for t in llats}))[:240],
        "remediation": "regular review — revoke unrecognised tokens",
        "owner_agent": "ha-engineer",
    })
    # Tokens unused > 180 days
    for t in tokens:
        lu = t.get("last_used_at")
        if not lu:
            continue
        try:
            d = dt.datetime.fromisoformat(lu.replace("Z", "+00:00"))
            age = (now - d).days
            if age > 180:
                findings.append({
                    "title": f"HA refresh token unused {age}d",
                    "severity": "low",
                    "target": f'ha.auth.storage:{t.get("id","?")[:8]}',
                    "evidence": f"client={t.get('client_name') or t.get('client_id','?')} user_id={t.get('user_id','?')[:8]}",
                    "remediation": "consider revoking via HA Profile → Long-Lived Access Tokens",
                    "owner_agent": "ha-engineer",
                })
        except Exception:
            pass
    return findings


# ── main ────────────────────────────────────────────────────────────────

def post_summary_to_ha(chg: str, findings_by_sev: dict, repo_url_base: str) -> None:
    if not (HA_URL and HA_TOKEN):
        return
    lines = [f"Posture scan **{chg}**:"]
    for sev in ("critical", "high", "medium", "low", "info"):
        n = findings_by_sev.get(sev, 0)
        if n:
            lines.append(f"- {sev}: {n}")
    if repo_url_base:
        lines.append(f"\n[Open ops portal]({repo_url_base}/ops.html)")
    body = {
        "title": f"Argus posture scan — {today()}",
        "message": "\n".join(lines),
        "notification_id": f"argus_scan_{today()}",
    }
    req = urllib.request.Request(
        f"{HA_URL}/api/services/persistent_notification/create",
        method="POST",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {HA_TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            log(f"argus: HA notify {r.status}")
    except Exception as e:  # noqa: BLE001
        log(f"argus: HA notify failed: {e}")


def main() -> int:
    workdir = Path(tempfile.mkdtemp(prefix="argus-"))
    try:
        if not clone(workdir):
            return 0
        chg = ops_change_new("sec.posture_scan", "low", workdir, "weekly posture scan")
        if not chg:
            return 0
        log(f"argus: opened {chg}")
        ops_event(chg, "planned", {
            "files": [],
            "rollback": "n/a (read-only)",
            "validation_plan": "findings appended as events; high-sev opens incidents",
        }, repo=workdir)

        all_findings: list[dict] = []
        for name, fn in [
            ("gitleaks", lambda: check_gitleaks(workdir)),
            ("admin_rbac", check_admin_rbac),
            ("exposed_services", check_exposed_services),
            ("certs", check_certs),
            ("ha_tokens", lambda: check_ha_tokens(workdir)),
        ]:
            log(f"argus: check {name}")
            try:
                results = fn()
                log(f"argus: {name} -> {len(results)} finding(s)")
                all_findings.extend(results)
            except Exception as e:  # noqa: BLE001
                log(f"argus: {name} crashed: {e}")
                all_findings.append({
                    "title": f"argus check {name} crashed",
                    "severity": "low",
                    "target": "argus",
                    "evidence": str(e)[:200],
                    "remediation": "inspect Argus logs",
                    "owner_agent": "k8s-engineer",
                })

        # Apply accepted-risk suppressions BEFORE counting and incident creation
        risks = load_accepted_risks(workdir)
        all_findings = apply_accepted_risks(all_findings, risks)

        by_sev: dict = {}
        suppressed = 0
        for f in all_findings:
            by_sev[f["severity"]] = by_sev.get(f["severity"], 0) + 1
            if f.get("accepted_risk"):
                suppressed += 1
        if suppressed:
            log(f"argus: {suppressed} finding(s) suppressed via accepted_risks.yaml")

        ops_event(chg, "validated", {
            "status": "pass",
            "findings_total": len(all_findings),
            "findings_by_severity": by_sev,
            "findings": all_findings[:50],  # cap to keep events readable
        }, repo=workdir)
        ops_event(chg, "closed", {"outcome": "success"}, repo=workdir)
        log(f"argus: closed {chg} with {len(all_findings)} finding(s)")

        # high/critical findings open incidents
        for f in all_findings:
            if f["severity"] in ("critical", "high"):
                inc_res = run(["python3", str(workdir / "ops" / "ops"), "incident", "new",
                               "sev3" if f["severity"] == "high" else "sev2",
                               "--actor", "security-engineer",
                               "--summary", f["title"][:80]],
                              cwd=str(workdir), timeout=10)
                if inc_res.returncode == 0:
                    log(f"argus: opened incident {inc_res.stdout.strip()} for: {f['title']}")

        # commit + push the new events back to the repo
        env = os.environ.copy()
        env["GIT_AUTHOR_NAME"] = env.get("GIT_AUTHOR_NAME", "argus-bot")
        env["GIT_AUTHOR_EMAIL"] = env.get("GIT_AUTHOR_EMAIL", "argus@bluejungle.net")
        env["GIT_COMMITTER_NAME"] = env["GIT_AUTHOR_NAME"]
        env["GIT_COMMITTER_EMAIL"] = env["GIT_AUTHOR_EMAIL"]
        # git needs user.name / user.email via config too on alpine
        run(["git", "-C", str(workdir), "config", "user.name", env["GIT_AUTHOR_NAME"]])
        run(["git", "-C", str(workdir), "config", "user.email", env["GIT_AUTHOR_EMAIL"]])
        tok = mint_installation_token()
        if tok:
            remote_path = GIT_REMOTE.removeprefix("https://")
            run(["git", "-C", str(workdir), "add", "ops/changes.jsonl", "ops/incidents.jsonl"], env=env)
            commit = run(["git", "-C", str(workdir), "commit", "-m",
                          f"chore(security): Argus posture scan {chg}"], env=env)
            if commit.returncode != 0:
                log(f"argus: nothing to commit or commit failed: {commit.stderr[:200]}")
            else:
                push = run(["git", "-C", str(workdir), "push",
                            f"https://x-access-token:{tok}@{remote_path}", GIT_BRANCH],
                           env=env, timeout=60)
                if push.returncode != 0:
                    log(f"argus: push failed: {push.stderr[:300]}")
                else:
                    log("argus: pushed posture-scan events back to repo")

        post_summary_to_ha(chg, by_sev, os.environ.get("REPORT_BASE_URL", ""))
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
