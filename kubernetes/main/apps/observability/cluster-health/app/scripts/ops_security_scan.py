#!/usr/bin/env python3
"""Argus — daily security posture scan (weekly until chg-2026-10-28-002).

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


def check_cursus_gast_access(repo: Path) -> list[dict]:
    """chg-2026-10-28-002 Argus F-T3 posture: the LIVE cursus-gast cloudflared
    config must carry originRequest.access on EVERY hostname rule (T3 proved
    the top-level block is not applied), with the AUD list of the git copy on
    main, and every cloudflared pod must have started after the ConfigMap's
    last change. Runs the repo's own golive-check --live (read-only: get on
    the ConfigMap, list pods in cursus-gast; the cluster-health ClusterRole
    already grants both). Its output holds OK/FAIL lines with the first
    hostname label only, never the AUD or the domain."""
    script = repo / "hack" / "ops" / "chg-2026-10-28-002-golive-check.sh"
    if not script.exists():
        return [{
            "title": "cursus-gast Access posture check missing from the repo",
            "severity": "low",
            "target": "cursus-gast/cloudflared-config",
            "evidence": "hack/ops/chg-2026-10-28-002-golive-check.sh not on main",
            "remediation": "restore the check (chg-2026-10-28-002 F-T3)",
            "owner_agent": "k8s-engineer",
        }]
    env = os.environ.copy()
    env["PYTHON"] = sys.executable
    res = run(["bash", str(script), "--live", "--ref", "HEAD"], cwd=str(repo), env=env, timeout=60)
    lines = [l for l in (res.stdout or "").splitlines() if l.strip()]
    log(f"argus: cursus-gast access rc={res.returncode} ({len(lines)} lines)")
    if res.returncode == 0:
        return [{
            "title": "cursus-gast: Access block on every rule, pods fresh",
            "severity": "info",
            "target": "cursus-gast/cloudflared-config",
            "evidence": next((l for l in lines if "RESULT" in l and "LIVE" in l), "LIVE OK")[:240],
            "remediation": "none",
            "owner_agent": "k8s-engineer",
        }]
    bad = [l.replace("golive-check: ", "") for l in lines if " FAIL" in l or l.startswith("golive-check: FAIL")]
    return [{
        "title": "cursus-gast: cloudflared Access check per rule FAILED (guest site may be open)",
        "severity": "high",
        "target": "cursus-gast/cloudflared-config",
        "evidence": ("; ".join(bad) or f"rc={res.returncode}")[:400],
        "remediation": "golive-check.sh --live; put originRequest.access on every hostname rule; "
                       "restart cloudflared after a config change (chg-2026-10-28-002 F-T3)",
        "owner_agent": "k8s-engineer",
    }]


# ── Teamregie (chg-2026-10-30-002, Argus T3) ─────────────────────────────
# The page mypka-teamregie.<domain> is behind Authelia through an Envoy
# SecurityPolicy (extAuth) and must stay ONE person only. (a) the LIVE
# Authelia access_control must hit, for this host, first a two_factor rule
# with subject group:teamregie and nothing else, then a bare deny, both
# before any wildcard, and no rule naming the host may bypass or one_factor;
# (b) a request without a session but with forged Remote-User/Remote-Groups
# must still get 302 to auth.<domain>; a 200 is critical (sev2 incident).
# Findings name the host label only, never the domain (public repo).
TEAMREGIE_LABEL = "mypka-teamregie"
TEAMREGIE_GROUP = "group:teamregie"


def _as_list(v) -> list:
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


# Minimal, stdlib-only reader for the two sections of Authelia's configuration.yaml these checks need
# (session, access_control). The cluster-health image has no PyYAML and no yq. It understands block
# mappings, block sequences (also "- key: value" items), flow lists [a, b], quoted and plain scalars and
# comments, which is all those two sections use. Anything else raises ValueError, and the callers turn
# that into a red finding, never a green one (fail closed).
class _MiniYamlError(ValueError):
    pass


def _strip_comment(line: str) -> str:
    out, q = [], None
    for i, ch in enumerate(line):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def _scalar(v: str):
    v = v.strip()
    if v and v[0] in "|>&*!":
        raise _MiniYamlError("unsupported YAML construct")
    if v.startswith("["):
        if not v.endswith("]") or "[" in v[1:-1] or "{" in v:
            raise _MiniYamlError("unsupported flow sequence")
        inner = v[1:-1].strip()
        return [] if not inner else [_scalar(x) for x in inner.split(",")]
    if v.startswith("{"):
        raise _MiniYamlError("unsupported flow mapping")
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    if re.fullmatch(r"[-+]?[0-9]+", v):
        return int(v)
    low = v.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~"):
        return None
    return v


def _split_key(text: str):
    if text[:1] in "\"'":
        q = text[0]; end = text.find(q, 1)
        if end < 0 or text[end + 1:end + 2] != ":":
            return None
        return text[1:end], text[end + 2:]
    i = text.find(": ")
    if text.endswith(":") and (i < 0 or i == len(text) - 2):
        return text[:-1], ""
    if i < 0:
        return None
    return text[:i], text[i + 2:]


def _mini_yaml(text: str):
    lines = []
    for raw in text.split("\n"):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise _MiniYamlError("tab indentation")
        t = _strip_comment(raw)
        if t.strip():
            lines.append([len(t) - len(t.lstrip(" ")), t.strip()])

    def block(i, ind):
        if lines[i][1].startswith("- ") or lines[i][1] == "-":
            return seq(i, ind)
        return mapping(i, ind)

    def seq(i, ind):
        out = []
        while i < len(lines) and lines[i][0] == ind and (lines[i][1].startswith("- ") or lines[i][1] == "-"):
            item = lines[i][1][1:].strip()
            if not item:
                if i + 1 < len(lines) and lines[i + 1][0] > ind:
                    v, i = block(i + 1, lines[i + 1][0])
                else:
                    v, i = None, i + 1
            elif not item.startswith("[") and _split_key(item) is not None:
                lines[i] = [ind + 2, item]
                v, i = mapping(i, ind + 2)
            else:
                v, i = _scalar(item), i + 1
            out.append(v)
        return out, i

    def mapping(i, ind):
        out = {}
        while i < len(lines) and lines[i][0] == ind:
            kv = _split_key(lines[i][1])
            if kv is None or lines[i][1].startswith("- "):
                raise _MiniYamlError("expected a mapping key")
            k, rest = kv
            if rest.strip():
                out[k], i = _scalar(rest), i + 1
            elif i + 1 < len(lines) and (lines[i + 1][0] > ind or (
                    lines[i + 1][0] == ind and lines[i + 1][1].startswith("- "))):
                out[k], i = block(i + 1, lines[i + 1][0])
            else:
                out[k], i = None, i + 1
        if i < len(lines) and lines[i][0] > ind:
            raise _MiniYamlError("bad indentation")
        return out, i

    if not lines:
        return {}
    v, i = block(0, lines[0][0])
    if i != len(lines):
        raise _MiniYamlError("trailing content")
    return v


def parse_authelia_sections(text: str, keys=("session", "access_control")) -> dict:
    """Cut the named top-level sections out of the full file and parse each with _mini_yaml."""
    out, cur, buf = {}, None, []
    for raw in text.split("\n") + ["__end__:"]:
        top = re.match(r"^([A-Za-z_][\w-]*):(.*)$", raw)
        if top:
            if cur is not None:
                out[cur] = (_mini_yaml("\n".join(buf)) if any(l.strip() for l in buf) else None)
            cur, buf = (top.group(1) if top.group(1) in keys else None), []
            if cur is not None and _strip_comment(top.group(2)).strip():
                raise _MiniYamlError("inline value for a section")
        elif cur is not None:
            buf.append(raw)
    return out


def _teamregie_live_cfg():
    """(cfg, error) for the LIVE Authelia ConfigMap; error is a short string without the domain."""
    res = run(["kubectl", "-n", "security", "get", "configmap", "authelia-configmap", "-o", "json"], timeout=30)
    if res.returncode != 0:
        return None, "ConfigMap unreadable: " + (res.stderr or "")[:160]
    try:
        return parse_authelia_sections(json.loads(res.stdout)["data"]["configuration.yaml"]), None
    except (ValueError, KeyError) as e:
        return None, "Authelia config not parseable by the stdlib reader: " + str(e)[:120]


def teamregie_rules_verdict(cfg: dict) -> tuple[bool, str]:
    """Pure: judge a parsed Authelia configuration. Returns (ok, reason); reason has no domain."""
    cookies = ((cfg.get("session") or {}).get("cookies") or [])
    domain = (cookies[0].get("domain") if cookies else None) or ""
    if not domain:
        return False, "no session cookie domain in the Authelia config"
    host = f"{TEAMREGIE_LABEL}.{domain}"
    rules = (cfg.get("access_control") or {}).get("rules") or []

    def explicit(r: dict) -> bool:
        if host in _as_list(r.get("domain")):
            return True
        return any(re.fullmatch(rx, host) for rx in _as_list(r.get("domain_regex")))

    def matches(r: dict) -> bool:
        if explicit(r):
            return True
        for d in _as_list(r.get("domain")):
            if d == "*" or (d.startswith("*.") and host.endswith(d[1:])):
                return True
        return False

    for i, r in enumerate(rules):
        if explicit(r) and r.get("policy") in ("bypass", "one_factor"):
            return False, f"rule {i} names {TEAMREGIE_LABEL} with policy {r.get('policy')}"
    hit = [(i, r) for i, r in enumerate(rules) if matches(r)]
    if len(hit) < 2:
        return False, f"only {len(hit)} rule(s) match {TEAMREGIE_LABEL}; expected two_factor then deny"
    (i1, r1), (i2, r2) = hit[0], hit[1]
    want1 = {"domain": [host], "policy": "two_factor", "subject": [TEAMREGIE_GROUP]}
    got1 = {k: (_as_list(v) if k in ("domain", "subject") else v) for k, v in r1.items()}
    if got1 != want1:
        return False, (f"first rule matching {TEAMREGIE_LABEL} (#{i1}) is not exactly two_factor for "
                       f"{TEAMREGIE_GROUP} on that host (policy {r1.get('policy')}, keys {sorted(r1)})")
    got2 = {k: (_as_list(v) if k == "domain" else v) for k, v in r2.items()}
    if got2 != {"domain": [host], "policy": "deny"}:
        return False, (f"second rule matching {TEAMREGIE_LABEL} (#{i2}) is not a bare deny on that host "
                       f"(policy {r2.get('policy')}, keys {sorted(r2)})")
    return True, f"rules #{i1} two_factor {TEAMREGIE_GROUP}, #{i2} deny, before any wildcard"


def check_teamregie_authelia_rules() -> list[dict]:
    target = "security/authelia-configmap"
    cfg, err = _teamregie_live_cfg()
    if err:
        return [{"title": "teamregie: Authelia rules could not be checked", "severity": "high", "target": target,
                 "evidence": err, "remediation": "check cluster-health RBAC / the config layout (chg-2026-10-30-002 T3)",
                 "owner_agent": "k8s-engineer"}]
    ok, why = teamregie_rules_verdict(cfg)
    log(f"argus: teamregie authelia rules ok={ok}")
    if ok:
        return [{"title": "teamregie: Authelia rules two_factor group then deny", "severity": "info",
                 "target": target, "evidence": why, "remediation": "none", "owner_agent": "k8s-engineer"}]
    return [{"title": "teamregie: Authelia rules for the page are not two_factor group then deny",
             "severity": "high", "target": target, "evidence": why[:400],
             "remediation": "restore the two mypka-teamregie rules before *.domain (chg-2026-10-30-002 T1/T3)",
             "owner_agent": "k8s-engineer"}]


def teamregie_probe_verdict(status: int | None, location: str, domain: str) -> tuple[str, str]:
    """Pure: (severity, evidence) for the forged-header probe. Evidence has no domain."""
    if status == 200:
        return "critical", "200 without a session but with forged Remote-User/Remote-Groups: page OPEN"
    if status in (301, 302, 303, 307, 308):
        if location.startswith(f"https://auth.{domain}/"):
            return "info", f"{status} to the Authelia portal (forged headers ignored)"
        return "high", f"{status} but not to the Authelia portal"
    if status in (401, 403):
        return "info", f"{status} (refused, no page)"
    return "low", f"probe got {status if status is not None else 'no response'}; could not prove the page is closed"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):  # noqa: D401 - never follow
        return None


def check_teamregie_forged_header() -> list[dict]:
    cfg, _err = _teamregie_live_cfg()
    domain = ""
    if cfg:
        cookies = ((cfg.get("session") or {}).get("cookies") or [])
        domain = (cookies[0].get("domain") if cookies else "") or ""
    if not domain:
        return [{"title": "teamregie: forged-header probe could not find the domain", "severity": "low",
                 "target": TEAMREGIE_LABEL, "evidence": "no session cookie domain", "remediation": "inspect",
                 "owner_agent": "k8s-engineer"}]
    req = urllib.request.Request(f"https://{TEAMREGIE_LABEL}.{domain}/", method="GET", headers={
        "Remote-User": "argus-forged", "Remote-Groups": "admins,teamregie", "User-Agent": "argus-posture-scan"})
    status, location = None, ""
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=15) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status, location = e.code, e.headers.get("Location", "") or ""
    except Exception as e:  # noqa: BLE001
        log(f"argus: teamregie probe error {type(e).__name__}")
    sev, ev = teamregie_probe_verdict(status, location, domain)
    log(f"argus: teamregie forged-header probe -> {status} ({sev})")
    title = ("teamregie: page answers 200 to forged headers without a session (AUTH BYPASS)"
             if sev == "critical" else "teamregie: forged-header probe")
    return [{"title": title, "severity": sev, "target": TEAMREGIE_LABEL, "evidence": ev,
             "remediation": "none" if sev == "info" else
             "pull the route (pin cluster-wires back) and check SecurityPolicy mypka/teamregie-authelia",
             "owner_agent": "k8s-engineer"}]


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
        chg = ops_change_new("sec.posture_scan", "low", workdir, "daily posture scan")
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
            ("cursus_gast_access", lambda: check_cursus_gast_access(workdir)),
            ("teamregie_authelia_rules", check_teamregie_authelia_rules),
            ("teamregie_forged_header", check_teamregie_forged_header),
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
