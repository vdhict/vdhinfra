#!/usr/bin/env python3
"""chg-2026-10-28-002 Argus F-T3: per-rule Cloudflare Access check for the cursus-gast cloudflared config.

T3 (2026-10-29) proved cloudflared does NOT apply a top-level `originRequest.access` block to the ingress rules:
a hostname without its own block served 200. So every rule must carry its own block.

    access-rules.py rules (--cm-yaml F | --cm-json F) [--expect-from-cm-yaml F]
    access-rules.py fresh --cm-json F --pods-json F

F may be '-' for stdin (at most one of them).

rules   Parses config.yaml out of the ConfigMap (a manifest from git: --cm-yaml; `kubectl get -o json
        --show-managed-fields`: --cm-json). FAIL unless every ingress rule with a `hostname` has
        originRequest.access with required: true (a YAML boolean), teamName == bluejungle and an audTag list
        EQUAL to the expected AUD list. Expected = the top-level originRequest.access.audTag of
        --expect-from-cm-yaml (e.g. the git copy, to catch live drift) or else of the same config; it must be a
        non-empty list of non-placeholder strings. A rule WITHOUT hostname is a catch-all: it must be an
        http_status:* service or carry the same block, otherwise FAIL (a catch-all to the origin bypasses every
        hostname check). A top-level block alone is not enough and fails.
fresh   FAIL unless there is >= 1 pod and every pod's status.startTime >= the ConfigMap's last change (max
        metadata.managedFields[].time; else creationTimestamp). cloudflared reads config.yaml (subPath mount)
        only at start, so a pod older than the ConfigMap runs a stale config. Second resolution: a pod started
        in the same second as the change passes (Reloader restarts after the write).

Output: one OK/FAIL line per rule with the FIRST hostname label only, then RESULT PASS|FAIL. Never prints the
AUD, the team name of a failing rule, the domain, or any other value. Exit 0 PASS, 1 FAIL, 64 usage.

The YAML reader is a deliberately strict block-style subset (mappings, sequences, plain/quoted scalars,
comments). Anything else (flow style, anchors/aliases, tags, block scalars, duplicate keys, tabs, multi-doc)
is a parse error and therefore FAIL: fail-closed, never a silent PASS. Stdlib only, Python >= 3.9.
No rm/unlink (AGR-121).
"""
from __future__ import annotations

import datetime as dt
import json
import re
import sys

TEAM = "bluejungle"
PLACEHOLDER = re.compile(r"replace-|^0+$|^x+$", re.I)


class ParseError(Exception):
    pass


# ---------------------------------------------------------------- strict YAML subset
def _strip_comment(s: str) -> str:
    q = None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
            continue
        if c in "\"'" and (i == 0 or s[i - 1] in " -:[{,"):
            q = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip()
    if q:
        raise ParseError("unterminated quote")
    return s.rstrip()


def _lines(text: str):
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        body = raw.lstrip(" ")
        if body.startswith("\t") or "\t" in raw[: len(raw) - len(body)]:
            raise ParseError("tab indent line %d" % n)
        body = _strip_comment(body)
        if not body:
            continue
        if body in ("---", "...") or body.startswith("%"):
            raise ParseError("document marker/directive line %d" % n)
        out.append([len(raw) - len(raw.lstrip(" ")), body, n])
    return out


_BAD_START = tuple("&*!{[|>?@`%")


def _scalar(s: str, n: int):
    s = s.strip()
    if s.startswith(_BAD_START):
        raise ParseError("unsupported YAML construct line %d" % n)
    if s[:1] == '"':
        if not s.endswith('"') or len(s) < 2 or "\\" in s:
            raise ParseError("unsupported double-quoted scalar line %d" % n)
        return s[1:-1]
    if s[:1] == "'":
        if not s.endswith("'") or len(s) < 2:
            raise ParseError("bad single-quoted scalar line %d" % n)
        inner = s[1:-1]
        if re.search(r"(?<!')'(?!')", inner.replace("''", "")):
            raise ParseError("bad single-quoted scalar line %d" % n)
        return inner.replace("''", "'")
    if ": " in s or s.endswith(":") or " #" in s:
        raise ParseError("ambiguous plain scalar line %d" % n)
    if s in ("true", "True", "TRUE"):
        return True
    if s in ("false", "False", "FALSE"):
        return False
    if s in ("null", "Null", "NULL", "~"):
        return None
    if re.fullmatch(r"[-+]?[0-9]+", s):
        return int(s)
    return s


_KEY = re.compile(r"""^("[^"\\]*"|'[^']*'|[A-Za-z0-9_][A-Za-z0-9_.\-/]*)[ ]*:(?:[ ]+(.*))?$""")


def _parse(lines, i, indent):
    if i >= len(lines) or lines[i][0] != indent:
        raise ParseError("bad indentation")
    if lines[i][1] == "-" or lines[i][1].startswith("- "):
        return _seq(lines, i, indent)
    return _map(lines, i, indent)


def _seq(lines, i, indent):
    out = []
    while i < len(lines) and lines[i][0] == indent:
        ind, body, n = lines[i]
        if not (body == "-" or body.startswith("- ")):
            raise ParseError("mapping key inside sequence line %d" % n)
        rest = body[1:].lstrip(" ")
        if not rest:
            if i + 1 >= len(lines) or lines[i + 1][0] <= indent:
                out.append(None)
                i += 1
                continue
            v, i = _parse(lines, i + 1, lines[i + 1][0])
            out.append(v)
            continue
        if rest.startswith("- ") or rest == "-" or _KEY.match(rest):
            sub = ind + (len(body) - len(rest))
            lines[i] = [sub, rest, n]
            v, i = _parse(lines, i, sub)
            out.append(v)
            continue
        out.append(_scalar(rest, n))
        i += 1
    if i < len(lines) and lines[i][0] > indent:
        raise ParseError("bad indentation line %d" % lines[i][2])
    return out, i


def _map(lines, i, indent):
    out = {}
    while i < len(lines) and lines[i][0] == indent:
        _, body, n = lines[i]
        if body == "-" or body.startswith("- "):
            break
        m = _KEY.match(body)
        if not m:
            raise ParseError("not a key: value line %d" % n)
        k = m.group(1)
        if k[:1] in "\"'":
            k = k[1:-1]
        if k in out:
            raise ParseError("duplicate key line %d" % n)
        if m.group(2) is not None and m.group(2).strip():
            out[k] = _scalar(m.group(2), n)
            i += 1
            continue
        i += 1
        if i < len(lines) and lines[i][0] > indent:
            out[k], i = _parse(lines, i, lines[i][0])
        elif i < len(lines) and lines[i][0] == indent and (lines[i][1] == "-" or lines[i][1].startswith("- ")):
            out[k], i = _seq(lines, i, indent)
        else:
            out[k] = None
    if i < len(lines) and lines[i][0] > indent:
        raise ParseError("bad indentation line %d" % lines[i][2])
    return out, i


def load_yaml(text: str):
    lines = _lines(text)
    if not lines:
        raise ParseError("empty document")
    v, i = _parse(lines, 0, lines[0][0])
    if i != len(lines):
        raise ParseError("trailing content line %d" % lines[i][2])
    return v


# ---------------------------------------------------------------- inputs
def read(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as f:
        return f.read()


def config_from_cm_yaml(text: str) -> str:
    """The `config.yaml: |` block scalar out of a ConfigMap manifest (no general YAML needed)."""
    lines = text.splitlines()
    for idx, l in enumerate(lines):
        m = re.match(r"^( *)config\.yaml:[ ]*\|-?[ ]*$", l)
        if not m:
            continue
        base = len(m.group(1))
        body, ind = [], None
        for l2 in lines[idx + 1:]:
            if not l2.strip():
                body.append("")
                continue
            li = len(l2) - len(l2.lstrip(" "))
            if li <= base:
                break
            if ind is None:
                ind = li
            if li < ind:
                raise ParseError("block scalar dedent")
            body.append(l2[ind:])
        if ind is None:
            raise ParseError("empty config.yaml block")
        return "\n".join(body) + "\n"
    raise ParseError("no `config.yaml: |` block in the ConfigMap manifest")


def config_from_cm_json(obj: dict) -> str:
    v = (obj.get("data") or {}).get("config.yaml")
    if not isinstance(v, str) or not v.strip():
        raise ParseError("ConfigMap has no data.config.yaml")
    return v


# ---------------------------------------------------------------- checks
def _access(node):
    if not isinstance(node, dict):
        return None
    o = node.get("originRequest")
    if not isinstance(o, dict):
        return None
    a = o.get("access")
    return a if isinstance(a, dict) else None


def expected_aud(cfg) -> list | None:
    a = _access(cfg)
    aud = a.get("audTag") if a else None
    if not isinstance(aud, list) or not aud:
        return None
    if not all(isinstance(x, str) and x and not PLACEHOLDER.search(x) for x in aud):
        return None
    return aud


def rule_ok(rule, aud) -> list[str]:
    """Reasons a rule's access block is not acceptable (empty = OK). Reasons never contain values."""
    a = _access(rule)
    if a is None:
        return ["no originRequest.access on the rule"]
    why = []
    if a.get("required") is not True:
        why.append("required is not boolean true")
    if a.get("teamName") != TEAM:
        why.append("teamName is not the expected team")
    if a.get("audTag") != aud:
        why.append("audTag differs from the expected AUD list")
    return why


def label(host) -> str:
    if not isinstance(host, str) or not host:
        return "<bad hostname>"
    first = host.split(".", 1)[0]
    return first if re.fullmatch(r"[A-Za-z0-9*\-]{1,63}", first) else "<odd hostname>"


def check_rules(cfg_text: str, expect_cfg_text: str | None) -> bool:
    try:
        cfg = load_yaml(cfg_text)
        exp_cfg = load_yaml(expect_cfg_text) if expect_cfg_text is not None else cfg
    except ParseError as e:
        print("access-rules: FAIL config not parseable by the strict reader (%s)" % e)
        return False
    if not isinstance(cfg, dict):
        print("access-rules: FAIL config is not a mapping")
        return False
    aud = expected_aud(exp_cfg)
    if aud is None:
        print("access-rules: FAIL no usable expected AUD list (top-level originRequest.access.audTag of the %s)"
              % ("expected-from manifest" if expect_cfg_text is not None else "config"))
        return False
    rules = cfg.get("ingress")
    if not isinstance(rules, list) or not rules:
        print("access-rules: FAIL no ingress rules")
        return False
    ok = True
    hosts = 0
    for i, r in enumerate(rules):
        if not isinstance(r, dict):
            print("access-rules: FAIL rule[%d] is not a mapping" % i)
            ok = False
            continue
        if "hostname" in r:
            hosts += 1
            why = rule_ok(r, aud)
            name = label(r.get("hostname"))
        else:
            svc = r.get("service")
            if isinstance(svc, str) and svc.startswith("http_status:"):
                print("access-rules: OK   rule[%d] catch-all http_status (no origin)" % i)
                continue
            why = rule_ok(r, aud)
            name = "<catch-all to an origin>"
        if why:
            ok = False
            print("access-rules: FAIL rule[%d] %s: %s" % (i, name, "; ".join(why)))
        else:
            print("access-rules: OK   rule[%d] %s" % (i, name))
    if hosts == 0:
        print("access-rules: FAIL no rule with a hostname")
        ok = False
    return ok


def _ts(s) -> dt.datetime | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def check_fresh(cm: dict, pods: dict) -> bool:
    md = cm.get("metadata") or {}
    times = [t for t in (_ts(m.get("time")) for m in md.get("managedFields") or []) if t]
    src = "managedFields"
    if not times:
        c = _ts(md.get("creationTimestamp"))
        if not c:
            print("access-rules: FAIL ConfigMap has no managedFields time or creationTimestamp")
            return False
        times, src = [c], "creationTimestamp (no managedFields: use --show-managed-fields)"
    changed = max(times)
    items = pods.get("items")
    if not isinstance(items, list) or not items:
        print("access-rules: FAIL no cloudflared pods")
        return False
    print("access-rules: ConfigMap last change %s (%s)" % (changed.strftime("%Y-%m-%dT%H:%M:%SZ"), src))
    ok = True
    for p in items:
        name = (p.get("metadata") or {}).get("name", "?")
        st = _ts((p.get("status") or {}).get("startTime"))
        if st is None:
            print("access-rules: FAIL pod %s has no startTime" % name)
            ok = False
        elif st < changed:
            print("access-rules: FAIL pod %s started %s, BEFORE the ConfigMap change (stale config)"
                  % (name, st.strftime("%Y-%m-%dT%H:%M:%SZ")))
            ok = False
        else:
            print("access-rules: OK   pod %s started %s" % (name, st.strftime("%Y-%m-%dT%H:%M:%SZ")))
    return ok


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("rules", "fresh"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 64
    mode, opts, args = argv[0], {}, argv[1:]
    known = {"rules": {"--cm-yaml", "--cm-json", "--expect-from-cm-yaml"}, "fresh": {"--cm-json", "--pods-json"}}
    while args:
        if args[0] not in known[mode] or len(args) < 2 or args[0] in opts:
            print("access-rules: usage error near %s" % args[0], file=sys.stderr)
            return 64
        opts[args[0]] = args[1]
        args = args[2:]
    if list(opts.values()).count("-") > 1:
        print("access-rules: at most one input may be stdin", file=sys.stderr)
        return 64
    try:
        if mode == "rules":
            if ("--cm-yaml" in opts) == ("--cm-json" in opts):
                print("access-rules: need exactly one of --cm-yaml / --cm-json", file=sys.stderr)
                return 64
            try:
                if "--cm-yaml" in opts:
                    cfg = config_from_cm_yaml(read(opts["--cm-yaml"]))
                else:
                    cfg = config_from_cm_json(json.loads(read(opts["--cm-json"])))
                exp = config_from_cm_yaml(read(opts["--expect-from-cm-yaml"])) \
                    if "--expect-from-cm-yaml" in opts else None
            except (ParseError, ValueError) as e:
                print("access-rules: FAIL input (%s)" % e)
                print("access-rules: RESULT FAIL")
                return 1
            ok = check_rules(cfg, exp)
        else:
            if set(opts) != {"--cm-json", "--pods-json"}:
                print("access-rules: fresh needs --cm-json and --pods-json", file=sys.stderr)
                return 64
            try:
                cm, pods = json.loads(read(opts["--cm-json"])), json.loads(read(opts["--pods-json"]))
            except ValueError:
                print("access-rules: FAIL input is not JSON")
                print("access-rules: RESULT FAIL")
                return 1
            ok = check_fresh(cm, pods)
    except OSError as e:
        print("access-rules: FAIL cannot read input (%s)" % e.strerror)
        ok = False
    print("access-rules: RESULT %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
