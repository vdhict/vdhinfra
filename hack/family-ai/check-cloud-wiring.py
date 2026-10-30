#!/usr/bin/env python3
"""chg-2026-10-20-010 land 2 + W2c: render checks for the family-cloud wiring (Argus C3, W3, W4, W5, W6, W2c).

    hack/family-ai/check-cloud-wiring.py [--cloud 3|2,3|1,2,3] [--egress-off N] [--plugin <family-cloud/__init__.py>] [--self-test]

--cloud names the profiles that are ON the cloud in this render (default 3; W2c stages: A = 3, B = 2,3, C = 1,2,3).
--egress-off N: profile N is fully wired but its cloud CNP must be ABSENT (stages B1/C1: the live fallback test).
Renders kubernetes/main/apps/family-ai/{hermes,network-policies/app,open-webui/app,gezinsdienst/app,
kennisdienst/app} with kustomize (+ yq for JSON) and checks, for every profile N:
  W5  cloud N: env HERMES_IMAGE == containers[app].image of the same pod spec (== PINNED_IMAGE of the plugin when
      --plugin is given), tag@sha256 pinned. Not-cloud N: no HERMES_IMAGE / CLOUD_* env anywhere in the pod.
  W4  the string CLOUD_API_KEY occurs ONLY in the ExternalSecrets of the cloud profiles (remoteRef
      hermes-antrophic-api-key/credential, template guard); in those Deployments only container `app` has
      envFrom/secret refs and its envFrom is its own Secret only.
  W2c PVC hermes-cloud-spend-shared (rook-ceph-filesystem, ReadWriteMany, prune disabled) is THE ledger: every cloud
      profile mounts it at /cloud-spend (app + cloud-spend-init) as a PVC, CLOUD_SPEND_PATH=/cloud-spend/month.json;
      not-cloud profiles mount no spend volume. profiel-3's own PVC hermes-profiel-cloud-spend-3 (rook-ceph-block,
      prune disabled) is mounted by profiel-3 only, read-only, in cloud-spend-init only (the one-time move).
      cloud-spend-init: no env/secret, runs the shared guard, after seed-once; ConfigMap hermes-cloud-spend-init-shared
      holds only cloud-spend-init.py byte-equal to hermes/cloud-spend/cloud-spend-init.py, substitution disabled.
  W3  per cloud profile exactly one CNP hermes-profiel-N-cloud selecting hermes + instance hermes-profiel-N; egress =
      toFQDNs [matchName api.anthropic.com] TCP 443 + kube-dns with dns [matchName api.anthropic.com]; no matchPattern,
      CIDR, entities or other ports; no other family-ai CNP mentions anthropic.
--self-test applies one mutation per rule (per cloud profile where it applies) and requires each to be caught.
Prints PASS/FAIL lines only (no Secret content: the bundle Secrets are SOPS-encrypted and skipped).
"""
from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
APPS = ROOT / "kubernetes/main/apps/family-ai"
TREES = ["hermes", "network-policies/app", "open-webui/app", "gezinsdienst/app", "kennisdienst/app"]
HOST = "api.anthropic.com"
SHARED, OLD3, GUARD_CM = "hermes-cloud-spend-shared", "hermes-profiel-cloud-spend-3", "hermes-cloud-spend-init-shared"
GUARD_SRC = APPS / "hermes/cloud-spend/cloud-spend-init.py"
CLOUD_ENV = {"HERMES_IMAGE", "CLOUD_SPEND_PATH", "CLOUD_API_KEY"}


def render():
    docs = []
    for t in TREES:
        y = subprocess.run(["kustomize", "build", str(APPS / t)], check=True, capture_output=True, text=True).stdout
        j = subprocess.run(["yq", "-o=json", "-I=0", "."], input=y, check=True, capture_output=True, text=True).stdout
        for line in j.splitlines():
            if line.strip() and line.strip() != "null":
                d = json.loads(line)
                d["_tree"] = t
                docs.append(d)
    return docs


def find(docs, kind, name):
    return [d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name]


def pod(dep):
    return dep["spec"]["template"]["spec"]


def env_of(c):
    return {e["name"]: e for e in c.get("env") or []}


def claims(p):
    return {v["name"]: (v.get("persistentVolumeClaim") or {}) for v in p.get("volumes") or []}


def check(docs, cloud, pinned_image=None, egress_off=frozenset()):
    fails = []

    def need(cond, msg):
        if not cond:
            fails.append(msg)

    deps = {n: (find(docs, "Deployment", f"hermes-profiel-{n}") or [None])[0] for n in (1, 2, 3)}
    need(all(deps.values()), "hermes-profiel-1/2/3 Deployments rendered")
    if not all(deps.values()):
        return fails
    # W2c shared PVC + guard ConfigMap
    pvc = find(docs, "PersistentVolumeClaim", SHARED)
    need(len(pvc) == 1, f"W2c PVC {SHARED} rendered")
    if pvc:
        sp = pvc[0]["spec"]
        need(sp.get("storageClassName") == "rook-ceph-filesystem" and sp.get("accessModes") == ["ReadWriteMany"],
             "W2c shared PVC on rook-ceph-filesystem, ReadWriteMany")
        need(pvc[0]["metadata"].get("labels", {}).get("kustomize.toolkit.fluxcd.io/prune") == "disabled",
             "W2c shared PVC prune disabled (a revert keeps the total)")
    old = find(docs, "PersistentVolumeClaim", OLD3)
    need(len(old) == 1 and old[0]["spec"].get("storageClassName") == "rook-ceph-block"
         and old[0]["metadata"].get("labels", {}).get("kustomize.toolkit.fluxcd.io/prune") == "disabled",
         f"W6 profiel-3's own PVC {OLD3} kept (rook-ceph-block, prune disabled)")
    cm = find(docs, "ConfigMap", GUARD_CM)
    need(len(cm) == 1 and set(cm[0].get("data", {})) == {"cloud-spend-init.py"}
         and cm[0]["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/substitute") == "disabled",
         "W2c guard ConfigMap holds only cloud-spend-init.py, substitution disabled")
    if cm:
        need(cm[0]["data"].get("cloud-spend-init.py") == GUARD_SRC.read_text(), "W2c guard ConfigMap == the reviewed source")
    need(not [d for d in docs if d.get("kind") == "ConfigMap" and re.fullmatch(r"hermes-cloud-spend-init-[123]", d["metadata"]["name"])],
         "W2c no per-profile guard ConfigMap left")
    other = [d["metadata"]["name"] for d in docs if d.get("kind") in ("Deployment", "StatefulSet", "CronJob", "Job")
             and not re.fullmatch(r"hermes-profiel-[123]", d["metadata"]["name"])
             and ("cloud-spend" in json.dumps(d.get("spec", {})))]
    need(not other, "W2c no other workload mounts a spend PVC (found: %s)" % other)

    holders = sorted(f'{d["_tree"]}:{d["kind"]}/{d["metadata"]["name"]}' for d in docs
                     if "CLOUD_API_KEY" in json.dumps({k: v for k, v in d.items() if k != "_tree"}))
    need(holders == sorted(f"hermes:ExternalSecret/family-ai-hermes-profiel-{n}" for n in cloud),
         "W4 CLOUD_API_KEY only in the ExternalSecrets of profiles %s (found: %s)" % (sorted(cloud), holders))

    for n in (1, 2, 3):
        p = pod(deps[n])
        allc = p["containers"] + (p.get("initContainers") or [])
        cl = claims(p)
        if n not in cloud:
            pe = {k for c in allc for k in env_of(c)}
            need(not (CLOUD_ENV & pe), f"C3 profiel-{n} (not cloud) has no cloud env")
            need(not any(v.get("claimName") in (SHARED, OLD3) for v in cl.values()) and "cloud-spend" not in cl,
                 f"W2c profiel-{n} (not cloud) mounts no spend volume")
            need(f"hermes-profiel-{n}-cloud" not in {d["metadata"]["name"] for d in docs if d.get("kind") == "CiliumNetworkPolicy"},
                 f"W3 profiel-{n} (not cloud) has no cloud CNP")
            continue
        app = [c for c in p["containers"] if c["name"] == "app"]
        need(len(app) == 1 and len(p["containers"]) == 1, f"W5 profiel-{n} has exactly one container `app`")
        app = app[0] if app else {}
        e = env_of(app)
        need("HERMES_IMAGE" in e and e["HERMES_IMAGE"].get("value") == app.get("image"),
             f"W5 HERMES_IMAGE == containers[app].image (profiel-{n})")
        need(re.fullmatch(r"[^\s@]+:[^\s@]+@sha256:[0-9a-f]{64}", app.get("image", "")) is not None,
             f"W5 profiel-{n} image is tag@sha256 pinned")
        if pinned_image is not None:
            need(e.get("HERMES_IMAGE", {}).get("value") == pinned_image, f"W5 profiel-{n} HERMES_IMAGE == plugin PINNED_IMAGE")
        es = [d for d in docs if d.get("kind") == "ExternalSecret" and d["spec"]["target"]["name"] == f"family-ai-hermes-profiel-{n}"]
        need(len(es) == 1, f"W4 exactly one ExternalSecret targets family-ai-hermes-profiel-{n}")
        if es:
            refs = [x for x in es[0]["spec"]["data"] if x["secretKey"] == "CLOUD_API_KEY"]
            need(len(refs) == 1 and refs[0]["remoteRef"] == {"key": "hermes-antrophic-api-key", "property": "credential"},
                 f"W4 profiel-{n} CLOUD_API_KEY remoteRef = hermes-antrophic-api-key/credential")
            tpl = es[0]["spec"]["target"]["template"]["data"].get("CLOUD_API_KEY", "")
            need("fail" in tpl and "sk-ant-" in tpl, f"W4 profiel-{n} CLOUD_API_KEY has a fail-closed template guard")
        sec = [c["name"] for c in allc if c.get("envFrom")
               or any("valueFrom" in x and "secretKeyRef" in x["valueFrom"] for x in c.get("env") or [])]
        need(sec == ["app"], f"W4 only container `app` gets secret env in profiel-{n} (found: {sec})")
        need([x.get("secretRef", {}).get("name") for x in app.get("envFrom") or []] == [f"family-ai-hermes-profiel-{n}"],
             f"W4 profiel-{n} app envFrom = its own Secret only")
        # W2c ledger
        need(cl.get("cloud-spend", {}).get("claimName") == SHARED and "cloud-spend" in cl,
             f"W2c profiel-{n} cloud-spend volume = PVC {SHARED}")
        need(not any(v.get("name") == "cloud-spend" and "emptyDir" in v for v in p.get("volumes") or []),
             f"W2c profiel-{n} cloud-spend is not an emptyDir")
        am = {m["name"]: m for m in app.get("volumeMounts") or []}
        need(am.get("cloud-spend", {}).get("mountPath") == "/cloud-spend", f"W2c profiel-{n} app mounts /cloud-spend")
        need("cloud-spend-old" not in am, f"W2c profiel-{n} app never mounts the old ledger")
        need(e.get("CLOUD_SPEND_PATH", {}).get("value") == "/cloud-spend/month.json", f"W2c profiel-{n} CLOUD_SPEND_PATH in the mount")
        init = [c for c in p.get("initContainers") or [] if c["name"] == "cloud-spend-init"]
        need(len(init) == 1 and not init[0].get("envFrom") and not init[0].get("env"), f"W6 profiel-{n} cloud-spend-init has no env/secret")
        need(len(init) == 1 and init[0].get("command") == ["/opt/hermes/.venv/bin/python", "-I", "/cloud-spend-init/cloud-spend-init.py"],
             f"W2c profiel-{n} cloud-spend-init runs the shared guard")
        names = [c["name"] for c in p.get("initContainers") or []]
        need("seed-once" in names and "cloud-spend-init" in names and names.index("seed-once") < names.index("cloud-spend-init"),
             f"W2b profiel-{n} ledger guard runs after seed-once")
        need(claims(p).get("cloud-spend-init") == {} and any(v["name"] == "cloud-spend-init" and
             (v.get("configMap") or {}).get("name") == GUARD_CM for v in p.get("volumes") or []),
             f"W2c profiel-{n} guard volume = ConfigMap {GUARD_CM}")
        im = {m["name"]: m for m in (init[0].get("volumeMounts") if init else []) or []}
        need(im.get("cloud-spend", {}).get("mountPath") == "/cloud-spend", f"W2c profiel-{n} guard mounts the shared ledger")
        if n == 3:
            need(cl.get("cloud-spend-old") == {"claimName": OLD3, "readOnly": True}, "W2c profiel-3 old ledger volume = own PVC, readOnly")
            need(im.get("cloud-spend-old", {}).get("mountPath") == "/cloud-spend-old" and im["cloud-spend-old"].get("readOnly") is True,
                 "W2c profiel-3 guard mounts the old ledger read-only at /cloud-spend-old")
        else:
            need("cloud-spend-old" not in cl and not any(v.get("claimName") == OLD3 for v in cl.values()),
                 f"W2c profiel-{n} never mounts profiel-3's old ledger")
        # W3
        cnp = find(docs, "CiliumNetworkPolicy", f"hermes-profiel-{n}-cloud")
        if n in egress_off:
            need(not cnp, f"W3 profiel-{n} egress off: no cloud CNP yet (fallback stage)")
            continue
        need(len(cnp) == 1, f"W3 CNP hermes-profiel-{n}-cloud rendered")
        if not cnp:
            continue
        s = cnp[0]["spec"]
        need(s.get("endpointSelector") == {"matchLabels": {"app.kubernetes.io/name": "hermes",
                                                           "app.kubernetes.io/instance": f"hermes-profiel-{n}"}},
             f"W3 selector = hermes + instance hermes-profiel-{n} only")
        need(set(s) == {"endpointSelector", "egress"}, f"W3 profiel-{n} CNP has egress only")
        eg = s.get("egress") or []
        fq = [r for r in eg if "toFQDNs" in r]
        dns = [r for r in eg if "toEndpoints" in r]
        need(len(eg) == 2 and len(fq) == 1 and len(dns) == 1, f"W3 profiel-{n} exactly 2 egress rules (FQDN + DNS)")
        if fq:
            need(set(fq[0]) == {"toFQDNs", "toPorts"} and fq[0]["toFQDNs"] == [{"matchName": HOST}],
                 f"W3 profiel-{n} toFQDNs == [matchName api.anthropic.com] only")
            need(fq[0]["toPorts"] == [{"ports": [{"port": "443", "protocol": "TCP"}]}], f"W3 profiel-{n} FQDN rule TCP 443 only")
        if dns:
            need(dns[0]["toEndpoints"] == [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "kube-system",
                                                            "k8s-app": "kube-dns"}}], f"W3 profiel-{n} DNS rule to kube-dns only")
            tp = dns[0].get("toPorts") or [{}]
            need(len(tp) == 1 and tp[0].get("rules") == {"dns": [{"matchName": HOST}]}, f"W3 profiel-{n} DNS allow = matchName only")
            need(sorted(json.dumps(x, sort_keys=True) for x in tp[0].get("ports", [])) ==
                 sorted(json.dumps(x, sort_keys=True) for x in [{"port": "53", "protocol": "UDP"},
                                                                {"port": "53", "protocol": "TCP"}]), f"W3 profiel-{n} DNS ports 53")
        need(not re.search(r'"(toCIDR|toCIDRSet|toEntities|toServices|matchPattern|toGroups)"', json.dumps(s)),
             f"W3 profiel-{n} no CIDR/entities/wildcard in the cloud CNP")
    allowed = {f"hermes-profiel-{n}-cloud" for n in cloud if n not in egress_off}
    others = [d["metadata"]["name"] for d in docs if d.get("kind") == "CiliumNetworkPolicy"
              and d["metadata"]["name"] not in allowed and "anthropic" in json.dumps(d)]
    need(not others, "W3 no other CNP mentions anthropic (found: %s)" % others)
    return fails


def _dep(d, n):
    return find(d, "Deployment", f"hermes-profiel-{n}")[0]


def _app(d, n):
    return [c for c in pod(_dep(d, n))["containers"] if c["name"] == "app"][0]


def _init(d, n, name):
    return [c for c in pod(_dep(d, n))["initContainers"] if c["name"] == name][0]


def _vol(d, n, name):
    return [v for v in pod(_dep(d, n))["volumes"] if v["name"] == name][0]


def _cnp(d, n):
    return find(d, "CiliumNetworkPolicy", f"hermes-profiel-{n}-cloud")[0]["spec"]


def mutations(cloud, egress_off=frozenset()):
    off = [n for n in (1, 2, 3) if n not in cloud]
    m = {
        "W2c shared PVC RWO": lambda d: find(d, "PersistentVolumeClaim", SHARED)[0]["spec"].__setitem__("accessModes", ["ReadWriteOnce"]),
        "W2c shared PVC prunable": lambda d: find(d, "PersistentVolumeClaim", SHARED)[0]["metadata"]["labels"].pop("kustomize.toolkit.fluxcd.io/prune"),
        "W2c guard source drift": lambda d: find(d, "ConfigMap", GUARD_CM)[0]["data"].__setitem__(
            "cloud-spend-init.py", find(d, "ConfigMap", GUARD_CM)[0]["data"]["cloud-spend-init.py"].replace("LOCK_EX", "LOCK_SH")),
        "W6 old PVC gone": lambda d: d.remove(find(d, "PersistentVolumeClaim", OLD3)[0]),
    }
    for n in egress_off:
        m[f"W3 p{n} CNP present in the fallback stage"] = lambda d, n=n: d.append(copy.deepcopy(dict(find(d, "CiliumNetworkPolicy", "hermes-profiel-3-cloud")[0],
            metadata={"name": f"hermes-profiel-{n}-cloud"})))
    for n in cloud:
        if n in egress_off:
            continue
        m.update({
            f"W5 p{n} image drift": lambda d, n=n: _app(d, n).__setitem__("image", re.sub(r":([^:@]+)@", r":\1-drift@", _app(d, n)["image"])),
            f"W5 p{n} env drift": lambda d, n=n: env_of(_app(d, n))["HERMES_IMAGE"].__setitem__("value", "docker.io/nousresearch/hermes-agent:latest"),
            f"W4 p{n} init envFrom": lambda d, n=n: _init(d, n, "seed-once").__setitem__("envFrom", [{"secretRef": {"name": f"family-ai-hermes-profiel-{n}"}}]),
            f"W2c p{n} emptyDir": lambda d, n=n: _vol(d, n, "cloud-spend").update({"emptyDir": {}}) or _vol(d, n, "cloud-spend").pop("persistentVolumeClaim"),
            f"W2c p{n} own ledger": lambda d, n=n: _vol(d, n, "cloud-spend")["persistentVolumeClaim"].__setitem__("claimName", f"hermes-profiel-cloud-spend-{n}"),
            f"W2b p{n} guard order": lambda d, n=n: pod(_dep(d, n))["initContainers"].reverse(),
            f"W2c p{n} guard command": lambda d, n=n: _init(d, n, "cloud-spend-init").__setitem__("command", ["/bin/true"]),
            f"W3 p{n} wildcard": lambda d, n=n: _cnp(d, n)["egress"][0]["toFQDNs"].append({"matchPattern": "*.anthropic.com"}),
            f"W3 p{n} port 80": lambda d, n=n: _cnp(d, n)["egress"][0]["toPorts"][0]["ports"].append({"port": "80", "protocol": "TCP"}),
            f"W3 p{n} world": lambda d, n=n: _cnp(d, n)["egress"].append({"toEntities": ["world"]}),
            f"W3 p{n} selector": lambda d, n=n: _cnp(d, n)["endpointSelector"]["matchLabels"].pop("app.kubernetes.io/instance"),
            f"W3 p{n} dns pattern": lambda d, n=n: _cnp(d, n)["egress"][1]["toPorts"][0]["rules"]["dns"].__setitem__(0, {"matchPattern": "*"}),
        })
    if 3 in cloud:
        m["W2c p3 old ledger writable"] = lambda d: _vol(d, 3, "cloud-spend-old")["persistentVolumeClaim"].pop("readOnly")
        m["W2c p3 app mounts old ledger"] = lambda d: _app(d, 3)["volumeMounts"].append({"name": "cloud-spend-old", "mountPath": "/x"})
    for n in off:
        m.update({
            f"W4 key in p{n} env": lambda d, n=n: _app(d, n).setdefault("env", []).append({"name": "CLOUD_API_KEY", "value": "x"}),
            f"W2c p{n} mounts the ledger": lambda d, n=n: pod(_dep(d, n))["volumes"].append({"name": "cloud-spend", "persistentVolumeClaim": {"claimName": SHARED}}),
            f"C3 p{n} HERMES_IMAGE": lambda d, n=n: _app(d, n).setdefault("env", []).append({"name": "HERMES_IMAGE", "value": "x"}),
        })
    return m


def main():
    args = sys.argv[1:]
    cloud = {3}
    if "--cloud" in args:
        raw = args[args.index("--cloud") + 1]
        if not re.fullmatch(r"[123](,[123])*", raw):
            print("FAIL --cloud takes profile numbers, e.g. 3 or 2,3 or 1,2,3")
            return 2
        cloud = {int(x) for x in raw.split(",")}
    egress_off = set()
    if "--egress-off" in args:
        raw = args[args.index("--egress-off") + 1]
        if not re.fullmatch(r"[123]", raw) or int(raw) not in cloud or int(raw) == 3:
            print("FAIL --egress-off takes one cloud profile number (1 or 2)")
            return 2
        egress_off = {int(raw)}
    pinned = None
    if "--plugin" in args:
        src = Path(args[args.index("--plugin") + 1]).read_text()
        mm = re.search(r'PINNED_IMAGE = \("([^"]+)"\s*\n\s*"([^"]+)"\)', src)
        if not mm:
            print("FAIL could not read PINNED_IMAGE from the plugin")
            return 1
        pinned = mm.group(1) + mm.group(2)
    docs = render()
    fails = check(docs, cloud, pinned, egress_off)
    for f in fails:
        print("FAIL", f)
    rc = 1 if fails else 0
    print(("PASS" if not fails else "FAIL") + f" check-cloud-wiring: cloud={sorted(cloud)} egress_off={sorted(egress_off)}, {len(docs)} objects, pinned={'yes' if pinned else 'n/a'}")
    if "--self-test" in args and not fails:
        missed = []
        muts = mutations(cloud, egress_off)
        for name, mut in muts.items():
            d = copy.deepcopy(docs)
            mut(d)
            if not check(d, cloud, pinned, egress_off):
                missed.append(name)
        print(("PASS" if not missed else "FAIL") + f" self-test: {len(muts) - len(missed)}/{len(muts)} mutations caught"
              + (f" (missed: {missed})" if missed else ""))
        rc = rc or (1 if missed else 0)
    return rc


if __name__ == "__main__":
    sys.exit(main())
