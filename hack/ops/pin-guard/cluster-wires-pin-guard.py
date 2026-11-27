#!/usr/bin/env python3
"""cluster-wires commit-pin guard (chg-2026-11-13-002, Argus precondition P3, hardened for C3 G1-G6 in wq-140).

P3: "A check that fails when mypka/wires/source/gitrepository.yaml has no
ref.commit, or when any other consumer follows a cluster-wires branch head.
It runs in vdhinfra CI or the daily posture scan. It must stay true while the
key exists." A red guard is a revoke trigger for the forge push deploy keys (L7):
docs/runbooks/forge-deploy-key-revoke.md.

Repo matching (G2, G3): a URL points at cluster-wires when its repository path,
after YAML/percent/backslash escapes are decoded and case is folded, is exactly
<owner>/cluster-wires[.git]. "cluster-wires-exchange" is a different repository.

Repo mode (default, used by CI):
  R1 kubernetes/main/apps/mypka/wires/source/gitrepository.yaml exists and holds
     GitRepository cluster-wires with a 40-hex spec.ref.commit.
  R2 every GitRepository in any parseable manifest (.yaml/.yml/.json) under
     kubernetes/ whose PARSED spec.url points at cluster-wires carries a 40-hex
     spec.ref.commit (G3: no raw-text prefilter).
  R3 no other Flux source kind (OCIRepository, Bucket, HelmRepository) points
     at cluster-wires.
  R4 no non-comment line in ANY regular file under kubernetes/ names a
     cluster-wires repository (scheme URL or owner/repo path, escapes and case
     folded), except the url line of a pinned GitRepository (G4).
  R5 no kustomize patch (patches, patchesJson6902, patchesStrategicMerge) and no
     Flux Kustomization spec.patches entry targets kind GitRepository or edits
     /spec/ref without naming a kind (G1, static).
  R6 the rendered output (kustomize build) of the wires source directory still
     holds GitRepository cluster-wires with a 40-hex spec.ref.commit (G1, rendered).
     No renderer available = red (fail closed); --no-render skips R6 for tests only.
  Any manifest that mentions cluster-wires and does not parse is red (fail closed).

Live mode (--live, or --live-json FILE with `kubectl get gitrepositories -A -o json`):
  V1 at least one GitRepository points at cluster-wires.
  V2 each such object has a 40-hex spec.ref.commit.
  V3 its status.artifact.revision ends in sha1:<that commit> (serving the pin).
  Live mode needs no PyYAML (it runs in the daily posture scan, G5).

Exit 0 = GREEN, 1 = RED, 2 = guard error (treat as red).
"""
from __future__ import annotations

import argparse
import codecs
import json
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.parse
import warnings

PRIMARY = "kubernetes/main/apps/mypka/wires/source/gitrepository.yaml"
PRIMARY_DIR = "kubernetes/main/apps/mypka/wires/source"
REPO_NAME = "cluster-wires"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
OTHER_SOURCE_KINDS = {"OCIRepository", "Bucket", "HelmRepository"}
MANIFEST_SUFFIXES = (".yaml", ".yml", ".json")
REVOKE = "docs/runbooks/forge-deploy-key-revoke.md"

# A hyphen as written raw, as a YAML/JSON/shell escape, or percent-encoded (G3).
_DASH = r"(?:-|\\x2d|\\u002d|\\U0000002d|%2d)"
_SLASH = r"(?:/|%2f|\\x2f|\\u002f)"
# R4 text match (G2/G4): a scheme URL ending in the repo, or an owner/repo path. Not followed by a name character,
# so cluster-wires-exchange and cluster-wires2 are other repositories.
WIRES_TEXT_RE = re.compile(
    r"(?:(?:ssh|https?|git|file)://[^\s\"'#]*?" + _SLASH + r"|git@[^\s\"'#:]+:|[a-z0-9_.-]+" + _SLASH + r")"
    r"cluster" + _DASH + r"wires(?![a-z0-9_-]|\\x2d|\\u002d|%2d)",
    re.IGNORECASE)


def _decode(s: str) -> str:
    """Fold escapes a manifest can use to hide the name: percent-encoding and backslash escapes, then case."""
    s = urllib.parse.unquote(s)
    if "\\" in s:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                s = codecs.decode(s, "unicode_escape")
        except (UnicodeDecodeError, ValueError):
            pass
    return s.lower()


def _points_at_wires(url: object) -> bool:
    """True when the repository path of url is <owner>/cluster-wires[.git] (case, escapes and slashes folded)."""
    if not isinstance(url, str):
        return False
    u = _decode(url.strip())
    if re.match(r"^[a-z][a-z0-9+.-]*://", u):
        path = urllib.parse.urlsplit(u).path
    elif "@" in u.split("/")[0] and ":" in u:  # scp-like git@host:owner/repo
        path = u.split(":", 1)[1]
    else:
        path = u
    last = [p for p in path.split("/") if p]
    if not last:
        return False
    name = last[-1]
    if name.endswith(".git"):
        name = name[:-4]
    return name == REPO_NAME


def _commit(doc: dict) -> str:
    ref = (doc.get("spec") or {}).get("ref") or {}
    c = ref.get("commit") if isinstance(ref, dict) else None
    return c if isinstance(c, str) else ""


def _name(doc: dict) -> str:
    md = doc.get("metadata") or {}
    return f"{md.get('namespace', '-')}/{md.get('name', '?')}"


def _yaml():
    try:
        import yaml  # noqa: PLC0415 - repo mode only; live mode must run without PyYAML (G5)
    except ImportError:
        print("PIN-GUARD ERROR: PyYAML missing (pip install pyyaml)")
        sys.exit(2)

    class _Loader(yaml.SafeLoader):
        """SafeLoader that tolerates unknown tags (e.g. !!binary in odd files)."""

    _Loader.add_multi_constructor("", lambda loader, suffix, node: None)
    return yaml, _Loader


def _load_docs(text: str) -> list[dict]:
    yaml, loader = _yaml()
    return [d for d in yaml.load_all(text, Loader=loader) if isinstance(d, dict)]


def _mentions(text: str) -> bool:
    return bool(re.search(r"cluster" + _DASH + r"wires", text, re.IGNORECASE))


def _patch_entries(doc: dict) -> list:
    """Patch entries of a kustomize Kustomization (top level) or a Flux Kustomization (spec.patches)."""
    out: list = []
    for key in ("patches", "patchesJson6902", "patchesStrategicMerge"):
        v = doc.get(key)
        if isinstance(v, list):
            out.extend(v)
    spec = doc.get("spec")
    if isinstance(spec, dict) and str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io"):
        for key in ("patches", "patchesJson6902", "patchesStrategicMerge"):
            v = spec.get(key)
            if isinstance(v, list):
                out.extend(v)
    return out


def _patch_red(entry, base: pathlib.Path) -> bool:
    """R5: the patch targets kind GitRepository, or edits /spec/ref without naming a kind."""
    yaml, _ = _yaml()
    if isinstance(entry, str):  # patchesStrategicMerge: a path or an inline patch
        p = (base / entry)
        text = p.read_text(errors="replace") if p.is_file() else entry
        target_kind = None
    elif isinstance(entry, dict):
        target = entry.get("target") or {}
        target_kind = target.get("kind") if isinstance(target, dict) else None
        text = yaml.safe_dump(entry, default_flow_style=False)
        path = entry.get("path")
        if isinstance(path, str) and (base / path).is_file():
            text += "\n" + (base / path).read_text(errors="replace")
    else:
        return False
    low = _decode(text)
    if isinstance(target_kind, str) and target_kind.lower() == "gitrepository":
        return True
    if "gitrepository" in low:
        return True
    return not target_kind and bool(re.search(r"/spec/ref\b|\bref\s*:", low))


def _is_pinned_url_line(line: str, pinned_urls: set[str]) -> bool:
    s = line.strip().lstrip("-").strip()
    if not s.lower().startswith("url:") or not pinned_urls:
        return False
    try:
        yaml, _ = _yaml()
        v = yaml.safe_load(s)
    except Exception:  # noqa: BLE001
        return False
    return isinstance(v, dict) and _decode(str(v.get("url", ""))) in pinned_urls


def render_dir(path: pathlib.Path) -> str:
    """kustomize build of one directory: kustomize if present, else kubectl kustomize. No renderer = error."""
    if shutil.which("kustomize"):
        cmd = ["kustomize", "build", str(path)]
    elif shutil.which("kubectl"):
        cmd = ["kubectl", "kustomize", str(path)]
    else:
        raise RuntimeError("no kustomize or kubectl to render the wires source (R6, fail closed)")
    return subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=60).stdout


def check_rendered(text: str) -> list[str]:
    docs = _load_docs(text)
    wires = [d for d in docs if d.get("kind") == "GitRepository" and _points_at_wires((d.get("spec") or {}).get("url"))]
    if not wires:
        return [f"R6 {PRIMARY_DIR}: rendered output has no GitRepository pointing at cluster-wires"]
    return [f"R6 {PRIMARY_DIR}: rendered GitRepository {_name(d)} has no 40-hex spec.ref.commit"
            for d in wires if not SHA_RE.match(_commit(d))]


def _files(root: pathlib.Path) -> list[pathlib.Path]:
    """Every regular file under kubernetes/ that Flux can see: the git-tracked files when root is a git checkout
    (untracked files such as __pycache__ never reach Flux), else every file (fixtures)."""
    r = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", "kubernetes"], capture_output=True)
    top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if r.returncode == 0 and top.returncode == 0 and pathlib.Path(top.stdout.strip()).resolve() == root.resolve():
        paths = [root / p for p in r.stdout.decode().split("\0") if p]
    else:
        paths = list((root / "kubernetes").rglob("*"))
    return sorted(p for p in paths if p.is_file() and not p.is_symlink())


def check_repo(root: pathlib.Path, render=render_dir) -> list[str]:
    red: list[str] = []
    primary = root / PRIMARY
    if not primary.is_file():
        red.append(f"R1 {PRIMARY}: file missing")
    else:
        yaml, _ = _yaml()
        try:
            docs = _load_docs(primary.read_text())
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

    yaml, _ = _yaml()
    files = _files(root)
    for path in files:
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_bytes().decode("utf-8", errors="replace")
        except OSError as e:
            red.append(f"R0 {rel}: unreadable ({e.__class__.__name__}); fail closed")
            continue
        pinned_urls: set[str] = set()
        if path.suffix.lower() in MANIFEST_SUFFIXES:
            try:
                docs = _load_docs(text)
            except yaml.YAMLError as e:
                if _mentions(text) or _mentions(_decode(text)):
                    red.append(f"R0 {rel}: mentions cluster-wires but does not parse ({e.__class__.__name__}); "
                               "fail closed")
                docs = []
            for d in docs:
                kind = d.get("kind")
                url = (d.get("spec") or {}).get("url") if isinstance(d.get("spec"), dict) else None
                if kind == "GitRepository" and _points_at_wires(url):
                    if SHA_RE.match(_commit(d)):
                        pinned_urls.add(_decode(url))
                    else:
                        red.append(f"R2 {rel}: GitRepository {_name(d)} follows a branch head "
                                   "(no 40-hex spec.ref.commit)")
                elif kind in OTHER_SOURCE_KINDS and _points_at_wires(url):
                    red.append(f"R3 {rel}: {kind} {_name(d)} points at cluster-wires (not commit-pinned by this guard)")
                for entry in _patch_entries(d):
                    if _patch_red(entry, path.parent):
                        red.append(f"R5 {rel}: {kind} {_name(d)} has a patch that targets GitRepository or /spec/ref")
        for n, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if s.startswith("#") or s.startswith("//"):
                continue
            if WIRES_TEXT_RE.search(s) and not _is_pinned_url_line(s, pinned_urls):
                red.append(f"R4 {rel}:{n}: cluster-wires repository named outside a pinned GitRepository url")

    if render is not None and (root / PRIMARY_DIR).is_dir():
        try:
            red.extend(check_rendered(render(root / PRIMARY_DIR)))
        except Exception as e:  # noqa: BLE001 - fail closed
            red.append(f"R6 {PRIMARY_DIR}: render failed ({e.__class__.__name__}); fail closed")
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
    ap.add_argument("--no-render", action="store_true", help="skip R6 (unit tests only; CI and the scan render)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--live", action="store_true", help="read GitRepositories from the cluster via kubectl")
    g.add_argument("--live-json", help="file with kubectl get gitrepositories -A -o json")
    a = ap.parse_args(argv)
    try:
        if a.live or a.live_json:
            if a.live:
                out = subprocess.run(["kubectl", "get", "gitrepositories.source.toolkit.fluxcd.io", "-A", "-o", "json"],
                                     check=True, capture_output=True, text=True, timeout=60).stdout
            else:
                out = pathlib.Path(a.live_json).read_text()
            mode, red = "live", check_live(json.loads(out))
        else:
            mode, red = "repo", check_repo(pathlib.Path(a.root), render=None if a.no_render else render_dir)
    except Exception as e:  # noqa: BLE001 - any guard failure is red
        print(f"PIN-GUARD ERROR: {e.__class__.__name__}: {e}")
        return 2
    if red:
        for r in red:
            print(f"RED {r}")
        print(f"PIN-GUARD RED ({mode}): {len(red)} violation(s); L7 revoke trigger for the forge push deploy keys "
              f"(chg-2026-11-13-002), see {REVOKE}")
        return 1
    print(f"PIN-GUARD GREEN ({mode}): cluster-wires consumed only via a commit pin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
