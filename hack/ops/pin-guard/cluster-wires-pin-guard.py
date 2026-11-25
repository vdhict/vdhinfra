#!/usr/bin/env python3
"""cluster-wires commit-pin guard (chg-2026-11-13-002, Argus precondition P3).

P3: "A check that fails when mypka/wires/source/gitrepository.yaml has no
ref.commit, or when any other consumer follows a cluster-wires branch head.
It runs in vdhinfra CI or the daily posture scan. It must stay true while the
key exists." A red guard is a revoke trigger for the Mini deploy key (L7).

Repo mode (default, used by CI):
  R1 kubernetes/main/apps/mypka/wires/source/gitrepository.yaml exists and holds
     GitRepository cluster-wires with a 40-hex spec.ref.commit.
  R2 every GitRepository under kubernetes/ whose spec.url points at
     cluster-wires carries a 40-hex spec.ref.commit.
  R3 no other Flux source kind (OCIRepository, Bucket, HelmRepository) points
     at cluster-wires.
  R4 no non-comment line outside a GitRepository names a cluster-wires git URL
     (a git clone in a Job/script would follow a branch head).
  Any file that mentions cluster-wires and does not parse is red (fail closed).

Live mode (--live, or --live-json FILE with `kubectl get gitrepositories -A -o json`):
  V1 at least one GitRepository points at cluster-wires.
  V2 each such object has a 40-hex spec.ref.commit.
  V3 its status.artifact.revision ends in sha1:<that commit> (serving the pin).

Exit 0 = GREEN, 1 = RED, 2 = guard error (treat as red).
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PIN-GUARD ERROR: PyYAML missing (pip install pyyaml)")
    sys.exit(2)

PRIMARY = "kubernetes/main/apps/mypka/wires/source/gitrepository.yaml"
REPO_MARK = "cluster-wires"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
URL_RE = re.compile(r"""(ssh://|https?://|git@)[^\s"'#]*cluster-wires""")
OTHER_SOURCE_KINDS = {"OCIRepository", "Bucket", "HelmRepository"}


class _Loader(yaml.SafeLoader):
    """SafeLoader that tolerates unknown tags (e.g. !!binary in odd files)."""


_Loader.add_multi_constructor("", lambda loader, suffix, node: None)


def _points_at_wires(url: object) -> bool:
    return isinstance(url, str) and REPO_MARK in url


def _commit(doc: dict) -> str:
    ref = (doc.get("spec") or {}).get("ref") or {}
    c = ref.get("commit")
    return c if isinstance(c, str) else ""


def _name(doc: dict) -> str:
    md = doc.get("metadata") or {}
    return f"{md.get('namespace', '-')}/{md.get('name', '?')}"


def check_repo(root: pathlib.Path) -> list[str]:
    red: list[str] = []
    primary = root / PRIMARY
    if not primary.is_file():
        red.append(f"R1 {PRIMARY}: file missing")
    else:
        try:
            docs = [d for d in yaml.load_all(primary.read_text(), Loader=_Loader) if isinstance(d, dict)]
        except yaml.YAMLError as e:
            docs = []
            red.append(f"R1 {PRIMARY}: does not parse ({e.__class__.__name__})")
        wires = [d for d in docs if d.get("kind") == "GitRepository"
                 and (d.get("metadata") or {}).get("name") == "cluster-wires"]
        if not wires and not red:
            red.append(f"R1 {PRIMARY}: no GitRepository named cluster-wires")
        for d in wires:
            if not _points_at_wires((d.get("spec") or {}).get("url")):
                red.append(f"R1 {PRIMARY}: spec.url does not point at cluster-wires")
            if not SHA_RE.match(_commit(d)):
                red.append(f"R1 {PRIMARY}: spec.ref.commit missing or not a full 40-hex sha")

    kdir = root / "kubernetes"
    files = sorted(p for p in kdir.rglob("*") if p.is_file() and p.suffix in (".yaml", ".yml"))
    for path in files:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(errors="replace")
        if REPO_MARK not in text:
            continue
        try:
            docs = [d for d in yaml.load_all(text, Loader=_Loader) if isinstance(d, dict)]
        except yaml.YAMLError as e:
            red.append(f"R0 {rel}: mentions cluster-wires but does not parse ({e.__class__.__name__}); fail closed")
            continue
        gitrepo_urls = set()
        for d in docs:
            kind = d.get("kind")
            url = (d.get("spec") or {}).get("url")
            if kind == "GitRepository" and _points_at_wires(url):
                gitrepo_urls.add(url)
                if not SHA_RE.match(_commit(d)):
                    red.append(f"R2 {rel}: GitRepository {_name(d)} follows a branch head (no 40-hex spec.ref.commit)")
            elif kind in OTHER_SOURCE_KINDS and _points_at_wires(url):
                red.append(f"R3 {rel}: {kind} {_name(d)} points at cluster-wires (not commit-pinned by this guard)")
        for n, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if s.startswith("#"):
                continue
            m = URL_RE.search(s)
            if m and not any(u in s for u in gitrepo_urls):
                red.append(f"R4 {rel}:{n}: cluster-wires git URL outside a pinned GitRepository")
    return red


def check_live(data: dict) -> list[str]:
    red: list[str] = []
    items = [i for i in data.get("items", []) if _points_at_wires((i.get("spec") or {}).get("url"))]
    if not items:
        return ["V1 live: no GitRepository points at cluster-wires (pin object gone)"]
    for i in items:
        c = _commit(i)
        if not SHA_RE.match(c):
            red.append(f"V2 live {_name(i)}: spec.ref.commit missing or not a full 40-hex sha")
            continue
        rev = (((i.get("status") or {}).get("artifact") or {}).get("revision")) or ""
        if not rev.endswith(f"sha1:{c}"):
            red.append(f"V3 live {_name(i)}: artifact revision does not match the pinned commit")
    return red


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[3]))
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--live", action="store_true", help="read GitRepositories from the cluster via kubectl")
    g.add_argument("--live-json", help="file with kubectl get gitrepositories -A -o json")
    a = ap.parse_args(argv)
    try:
        if a.live or a.live_json:
            if a.live:
                out = subprocess.run(["kubectl", "get", "gitrepositories.source.toolkit.fluxcd.io", "-A", "-o", "json"],
                                     check=True, capture_output=True, text=True).stdout
            else:
                out = pathlib.Path(a.live_json).read_text()
            mode, red = "live", check_live(json.loads(out))
        else:
            mode, red = "repo", check_repo(pathlib.Path(a.root))
    except Exception as e:  # noqa: BLE001 - any guard failure is red
        print(f"PIN-GUARD ERROR: {e.__class__.__name__}: {e}")
        return 2
    if red:
        for r in red:
            print(f"RED {r}")
        print(f"PIN-GUARD RED ({mode}): {len(red)} violation(s); revoke trigger for the Mini deploy key (chg-2026-11-13-002 L7)")
        return 1
    print(f"PIN-GUARD GREEN ({mode}): cluster-wires consumed only via a commit pin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
