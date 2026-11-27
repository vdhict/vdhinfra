"""Forge deploy-key inventory, K1 (chg-2026-11-13-002, Argus wq-140 delta section 3 / K1 a-d; wq-169).

Pure and stdlib-only. Two callers read the same forge rows by different routes:
  - the daily posture scan (ops_security_scan.py, L5), via the CNPG exporter custom queries on forge-pg
    (devtools/forge-pg-oidc-links-queries, run as pg_monitor with column grants; nobody needs exec);
  - forge-deploy-key-push.py at push time, via read-only SQL on the forge-pg primary (K1 a+b, refuse on mismatch).

Rows:
  deploy key  {"deploy_key_id", "public_key_id", "repo_id", "repo" (lower owner/name or ""), "mode"}  mode >= 2 = write
  rule        {"rule_id", "repo_id", "repo", "rule", "deploy_keys", "can_push", "enable_whitelist", "created"}

Checks:
  K1a per registry repo, the write deploy keys are exactly {registered public_key_id} (none while status != active),
      and an active entry's deploy_key_id is the row's id.
  K1b each registered public_key_id appears in exactly one deploy_key row site-wide (Forgejo reuses one public_key
      row across repos; the control probe cannot see that).
  K1c every protection rule with whitelist_deploy_keys on is a registry (repo, allow_branches entry).
  K1d on each registry repo, a glob rule created at or after that repo's "**" rule is outranked by "**" (Forgejo
      15.0.9 orders globs by CreatedUnix, oldest first): high when it is stricter than "**", else medium.
      Remedy for humans: delete and re-create "**" after the new rule, then read back the order.
A mismatch in K1a-K1c is high and names the revoke runbook. Repos outside the registry are named by id only (the
findings land in the public change log).
"""
from __future__ import annotations

REVOKE_RUNBOOK = "docs/runbooks/forge-deploy-key-revoke.md"
GLOB_SPECIAL = "*?[]{}\\!"      # gobwas syntax.Special: any of these makes a Forgejo rule name a glob
WRITE_MODE = 2                   # Forgejo perm.AccessModeWrite; deploy_key.mode 1 = read


def is_glob(name: str) -> bool:
    return any(c in name for c in GLOB_SPECIAL)


def _f(check: str, severity: str, target: str, evidence: str, remediation: str) -> dict:
    return {"check": check, "severity": severity, "target": target, "evidence": evidence, "remediation": remediation}


def _entries(registry: dict) -> dict:
    return {k["repo"].lower(): k for k in registry.get("keys", [])}


def _is_active(e: dict) -> bool:
    return e.get("status") == "active" and bool(e.get("public_key_id"))


def key_findings(registry: dict, deploy_keys: list[dict]) -> list[dict]:
    """K1a + K1b."""
    out: list[dict] = []
    revoke = f"revoke the unexpected key per {REVOKE_RUNBOOK}, or record it in deploy-keys.json after review"
    for repo, e in sorted(_entries(registry).items()):
        rows = [d for d in deploy_keys if (d.get("repo") or "").lower() == repo and int(d["mode"]) >= WRITE_MODE]
        got = sorted({int(d["public_key_id"]) for d in rows})
        want = [int(e["public_key_id"])] if _is_active(e) else []
        if got != want:
            out.append(_f("K1a", "high", e["repo"],
                          f"write deploy keys on {e['repo']}: public_key_id {got or 'none'}, registry expects "
                          f"{want or 'none'} (status {e.get('status')})", revoke))
        elif want and e.get("deploy_key_id") and \
                {int(d["deploy_key_id"]) for d in rows} != {int(e["deploy_key_id"])}:
            out.append(_f("K1a", "high", e["repo"],
                          f"deploy_key id on {e['repo']} is {sorted(int(d['deploy_key_id']) for d in rows)}, "
                          f"registry says {e['deploy_key_id']}", revoke))
    for repo, e in sorted(_entries(registry).items()):
        if not _is_active(e):
            continue
        pk = int(e["public_key_id"])
        rows = [d for d in deploy_keys if int(d["public_key_id"]) == pk]
        if len(rows) != 1:
            where = sorted((d.get("repo") or "").lower() if (d.get("repo") or "").lower() in _entries(registry)
                           else f"repo_id {d.get('repo_id')}" for d in rows)
            out.append(_f("K1b", "high", e["repo"],
                          f"public_key_id {pk} of {e['repo']} is on {len(rows)} deploy_key row(s): {where}",
                          f"one key per repo (K7): revoke per {REVOKE_RUNBOOK}"))
    return out


def rule_findings(registry: dict, rules: list[dict]) -> list[dict]:
    """K1c + K1d."""
    out: list[dict] = []
    ents = _entries(registry)
    for r in sorted(rules, key=lambda r: int(r["rule_id"])):
        if not r.get("deploy_keys"):
            continue
        repo = (r.get("repo") or "").lower()
        e = ents.get(repo)
        if e is None or r["rule"] not in e.get("allow_branches", []):
            target = e["repo"] if e else f"repo_id {r.get('repo_id')}"
            out.append(_f("K1c", "high", target,
                          f"protection rule {r['rule_id']} on {target} lets deploy keys push "
                          f"({'rule not in allow_branches' if e else 'repo not in deploy-keys.json'})",
                          f"set whitelist_deploy_keys off on rule {r['rule_id']}, then check the keys per "
                          f"{REVOKE_RUNBOOK}"))
    for repo, e in sorted(ents.items()):
        mine = [r for r in rules if (r.get("repo") or "").lower() == repo]
        stars = [r for r in mine if r["rule"] == "**"]
        if not stars:
            out.append(_f("K1d", "medium", e["repo"], f"{e['repo']} has no '**' protection rule (T1)",
                          "create the '**' rule last and read back the order"))
            continue
        star = min(stars, key=lambda r: (int(r["created"]), int(r["rule_id"])))
        for g in sorted(mine, key=lambda r: int(r["rule_id"])):
            if g is star or g["rule"] == "**" or not is_glob(g["rule"]):
                continue
            if int(g["created"]) < int(star["created"]):
                continue          # older glob: Forgejo evaluates it before "**" (ties sort unstably: flagged)
            stricter = (star.get("can_push") and not g.get("can_push")) or \
                (g.get("enable_whitelist") and not star.get("enable_whitelist")) or \
                (star.get("deploy_keys") and not g.get("deploy_keys"))
            out.append(_f("K1d", "high" if stricter else "medium", e["repo"],
                          f"glob rule {g['rule_id']} '{g['rule']}' on {e['repo']} is not older than the '**' rule "
                          f"{star['rule_id']}: '**' outranks it{' and it is stricter' if stricter else ''}",
                          "delete and re-create '**' after it, then read back the order (rule-order hazard)"))
    return out


def inventory_findings(registry: dict, deploy_keys: list[dict], rules: list[dict]) -> list[dict]:
    return key_findings(registry, deploy_keys) + rule_findings(registry, rules)
