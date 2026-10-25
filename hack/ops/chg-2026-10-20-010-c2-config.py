#!/usr/bin/env python3
"""chg-2026-10-20-010 C2 check of the DEPLOYED config.yaml on profiel-3 (Argus 25-10 11:58:52Z ruling_c2, option c).

Hermes v0.22.5 (docker/stage2-hook.sh -> scripts/docker_config_migrate.py on every boot) rewrites /opt/data/config.yaml
after the seed; measured on all three live profiles and reproduced offline by Argus: pod bytes == bundle bytes +
"_config_version: 51\\n", no path removed or changed. golive keeps byte equality for the other 17 files; config.yaml
must pass BOTH checks of `gate`:

  gate     <bundle config.yaml> <pod config.yaml> <allow file> <reference file>
           (1) posthash: sha256(bundle bytes + STAMP) computed now == the committed reference == sha256(pod bytes);
           (2) keys: every key path of the bundle in the pod with an identical value; additions only from the allow
               file, which must be exactly [["_config_version"], 51] (integer) and nothing else.
  keys / posthash / derive   the two halves and the reference maker, for tests and diagnosis.

Key paths are JSON-encoded tuples (Argus E1: a key containing "/" can no longer alias another path). YAML is read
with `yq -o=json` (on PATH). Prints key paths and verdicts only, never values. Exit 0 = pass.
"""
import hashlib, json, subprocess, sys

STAMP = "_config_version: 51"
ALLOWED = {json.dumps(["_config_version"]): json.dumps(51)}   # the ruling: exactly this, integer 51


def load(path):
    p = subprocess.run(["yq", "-o=json", ".", path], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("FAIL cannot parse %s as YAML" % path)
    return json.loads(p.stdout or "null")


def paths(o, p=()):
    out = {}
    if isinstance(o, dict) and o:
        for k, v in o.items():
            out.update(paths(v, p + (str(k),)))
    else:
        out[json.dumps(list(p))] = json.dumps(o, sort_keys=True)
    return out


def read_allow(allow_file):
    allow = {}
    for line in open(allow_file):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        path, sep, val = line.partition("\t")
        try:
            pl = json.loads(path)
            assert sep and isinstance(pl, list) and all(isinstance(x, str) for x in pl)
            allow[json.dumps(pl)] = json.dumps(json.loads(val), sort_keys=True)
        except Exception:
            sys.exit("FAIL allow file line is not <JSON path list><TAB><JSON value>: %r" % line[:60])
    return allow


def keys(bundle, pod, allow_file, strict_allow=False):
    allow = read_allow(allow_file)
    if strict_allow and allow != ALLOWED:
        sys.exit("FAIL C2 keys: allow file must be exactly [\"_config_version\"] = 51 (Argus ruling), found %s" % sorted(allow))
    a, b = paths(load(bundle)), paths(load(pod))
    removed = sorted(set(a) - set(b))
    changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    added = sorted(set(b) - set(a))
    not_allowed = [k for k in added if k not in allow]
    wrong_value = [k for k in added if k in allow and allow[k] != b[k]]
    print("keys: bundle %d paths, pod %d; removed %s; changed %s; added %s" % (len(a), len(b), removed, changed, added))
    bad = []
    if removed: bad.append("bundle keys missing in the pod: %s" % removed)
    if changed: bad.append("bundle keys with a different value in the pod: %s" % changed)
    if not_allowed: bad.append("pod adds keys not on the allow-list: %s" % not_allowed)
    if wrong_value: bad.append("allowed keys with a value other than allowed: %s" % wrong_value)
    if bad:
        sys.exit("FAIL C2 keys: " + "; ".join(bad))
    print("PASS C2 keys: every bundle key identical in the pod; additions only %s (allow-listed)" % added)


def ref_of(ref_file):
    for line in open(ref_file):
        line = line.split("#", 1)[0].strip()
        if line:
            r = line.split()[0]
            if len(r) == 64 and all(c in "0123456789abcdef" for c in r):
                return r
            break
    sys.exit("FAIL C2 posthash: no sha256 in %s" % ref_file)


def derive_hash(bundle):
    return hashlib.sha256(open(bundle, "rb").read() + STAMP.encode() + b"\n").hexdigest()


def posthash(pod, ref_file):
    ref = ref_of(ref_file)
    got = hashlib.sha256(open(pod, "rb").read()).hexdigest()
    if got != ref:
        sys.exit("FAIL C2 posthash: pod config.yaml %s != reference %s" % (got[:16], ref[:16]))
    print("PASS C2 posthash: pod config.yaml == post-seed reference %s" % ref[:16])


def gate(bundle, pod, allow_file, ref_file):
    ref, now = ref_of(ref_file), derive_hash(bundle)
    if now != ref:
        sys.exit("FAIL C2 posthash: reference computed now from the bundle %s != committed %s" % (now[:16], ref[:16]))
    print("ok   C2 posthash reference: computed from this bundle == committed %s" % ref[:16])
    posthash(pod, ref_file)
    keys(bundle, pod, allow_file, strict_allow=True)
    print("PASS C2 gate: posthash AND keys")


if __name__ == "__main__":
    mode, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    if mode == "gate" and len(args) == 4: gate(*args)
    elif mode == "keys" and len(args) == 3: keys(*args)
    elif mode == "posthash" and len(args) == 2: posthash(*args)
    elif mode == "derive" and len(args) == 1: print(derive_hash(args[0]))
    else: sys.exit("usage: gate <bundle> <pod> <allow> <ref> | keys <bundle> <pod> <allow> | posthash <pod> <ref> | derive <bundle>")
