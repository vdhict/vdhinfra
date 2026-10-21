#!/usr/bin/env python3
"""chg-2026-10-20-010 land 2: render checks for the profiel-3 cloud wiring (Argus C3, W3, W4, W5, W6).

    hack/family-ai/check-cloud-wiring.py [--plugin <family-cloud/__init__.py>] [--self-test]

Renders kubernetes/main/apps/family-ai/{hermes,network-policies/app,open-webui/app,gezinsdienst/app,
kennisdienst/app} with kustomize (+ yq for JSON) and checks:
  W5  hermes-profiel-3: env HERMES_IMAGE == containers[app].image of the same pod spec (and == PINNED_IMAGE
      of the plugin when --plugin is given); profiel-1/2 have no HERMES_IMAGE/CLOUD_* env.
  W4  the string CLOUD_API_KEY occurs ONLY in the profiel-3 ExternalSecret (target family-ai-hermes-profiel-3);
      in the profiel-3 Deployment only container `app` has envFrom/secret refs, init containers have none.
  W6  PVC hermes-profiel-cloud-spend-3 (rook-ceph-block, prune disabled) mounted ONLY by hermes-profiel-3,
      as a PVC (never emptyDir), CLOUD_SPEND_PATH inside that mount; cloud-spend-init has no secret.
  W3  CNP hermes-profiel-3-cloud selects profiel-3 only; egress = toFQDNs [matchName api.anthropic.com] TCP
      443 + kube-dns with dns [matchName api.anthropic.com]; no matchPattern, CIDR, entities or other ports;
      no other family-ai CNP mentions anthropic.
--self-test applies one mutation per rule to the rendered objects and requires each to be caught.
Prints PASS/FAIL lines only (no Secret content: the bundle Secret is SOPS-encrypted and skipped).
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


def check(docs, pinned_image=None):
    fails = []

    def need(cond, msg):
        if not cond:
            fails.append(msg)

    deps = {n: (find(docs, "Deployment", f"hermes-profiel-{n}") or [None])[0] for n in (1, 2, 3)}
    need(all(deps.values()), "hermes-profiel-1/2/3 Deployments rendered")
    if not all(deps.values()):
        return fails
    p3 = pod(deps[3])
    app = [c for c in p3["containers"] if c["name"] == "app"]
    need(len(app) == 1 and len(p3["containers"]) == 1, "W5 profiel-3 has exactly one container `app`")
    app = app[0] if app else {}
    e = env_of(app)
    # W5
    need("HERMES_IMAGE" in e and e["HERMES_IMAGE"].get("value") == app.get("image"),
         "W5 HERMES_IMAGE == containers[app].image (profiel-3)")
    need(re.fullmatch(r"[^\s@]+:[^\s@]+@sha256:[0-9a-f]{64}", app.get("image", "")) is not None,
         "W5 profiel-3 image is tag@sha256 pinned")
    if pinned_image is not None:
        need(e.get("HERMES_IMAGE", {}).get("value") == pinned_image, "W5 HERMES_IMAGE == plugin PINNED_IMAGE")
    for n in (1, 2):
        pe = {k for c in pod(deps[n])["containers"] + (pod(deps[n]).get("initContainers") or []) for k in env_of(c)}
        need(not ({"HERMES_IMAGE", "CLOUD_SPEND_PATH", "CLOUD_API_KEY"} & pe), f"C3 profiel-{n} has no cloud env")
        vols = json.dumps(pod(deps[n]).get("volumes"))
        need("cloud-spend" not in vols, f"W6 profiel-{n} mounts no cloud-spend volume")
    # W4: the key name appears only in the profiel-3 ExternalSecret
    holders = [f'{d["_tree"]}:{d["kind"]}/{d["metadata"]["name"]}' for d in docs
               if "CLOUD_API_KEY" in json.dumps({k: v for k, v in d.items() if k != "_tree"})]
    es3 = [d for d in docs if d.get("kind") == "ExternalSecret"
           and d["spec"]["target"]["name"] == "family-ai-hermes-profiel-3"]
    need(len(es3) == 1, "W4 exactly one ExternalSecret targets family-ai-hermes-profiel-3")
    need(holders == ["hermes:ExternalSecret/family-ai-hermes-profiel-3"],
         "W4 CLOUD_API_KEY only in the profiel-3 ExternalSecret (found: %s)" % holders)
    if es3:
        refs = [x for x in es3[0]["spec"]["data"] if x["secretKey"] == "CLOUD_API_KEY"]
        need(len(refs) == 1 and refs[0]["remoteRef"] == {"key": "hermes-antrophic-api-key", "property": "credential"},
             "W4 CLOUD_API_KEY remoteRef = hermes-antrophic-api-key/credential")
        need("CLOUD_API_KEY" in es3[0]["spec"]["target"]["template"]["data"], "W4 CLOUD_API_KEY has a template guard")
    sec_refs = [c["name"] for c in p3["containers"] + (p3.get("initContainers") or [])
                if c.get("envFrom") or any("valueFrom" in x and "secretKeyRef" in x["valueFrom"] for x in c.get("env") or [])]
    need(sec_refs == ["app"], "W4 only container `app` gets secret env in profiel-3 (found: %s)" % sec_refs)
    need([x.get("secretRef", {}).get("name") for x in app.get("envFrom") or []] == ["family-ai-hermes-profiel-3"],
         "W4 app envFrom = family-ai-hermes-profiel-3 only")
    # W6
    pvc = find(docs, "PersistentVolumeClaim", "hermes-profiel-cloud-spend-3")
    need(len(pvc) == 1, "W6 PVC hermes-profiel-cloud-spend-3 rendered")
    if pvc:
        need(pvc[0]["spec"].get("storageClassName") == "rook-ceph-block", "W6 PVC on rook-ceph-block")
        need(pvc[0]["metadata"].get("labels", {}).get("kustomize.toolkit.fluxcd.io/prune") == "disabled",
             "W6 PVC prune disabled (revert keeps the month total)")
    vol = [v for v in p3["volumes"] if v["name"] == "cloud-spend"]
    need(len(vol) == 1 and (vol[0].get("persistentVolumeClaim") or {}).get("claimName") == "hermes-profiel-cloud-spend-3"
         and "emptyDir" not in vol[0], "W6 cloud-spend volume is the PVC (not emptyDir)")
    mounts = {m["name"]: m["mountPath"] for m in app.get("volumeMounts") or []}
    need(mounts.get("cloud-spend") == "/cloud-spend", "W6 app mounts /cloud-spend")
    need(e.get("CLOUD_SPEND_PATH", {}).get("value") == "/cloud-spend/month.json", "W6 CLOUD_SPEND_PATH in the mount")
    other = [d["metadata"]["name"] for d in docs if d.get("kind") in ("Deployment", "StatefulSet", "CronJob", "Job")
             and d["metadata"]["name"] != "hermes-profiel-3" and "hermes-profiel-cloud-spend" in json.dumps(d)]
    need(not other, "W6 no other workload mounts the spend PVC (found: %s)" % other)
    init = [c for c in p3.get("initContainers") or [] if c["name"] == "cloud-spend-init"]
    need(len(init) == 1 and not init[0].get("envFrom") and not init[0].get("env"), "W6 cloud-spend-init has no env/secret")
    need(len(init) == 1 and init[0].get("command") == ["/opt/hermes/.venv/bin/python", "-I", "/cloud-spend-init/cloud-spend-init.py"],
         "W2b cloud-spend-init runs the ledger guard")
    names = [c["name"] for c in p3.get("initContainers") or []]
    need("seed-once" in names and "cloud-spend-init" in names and names.index("seed-once") < names.index("cloud-spend-init"),
         "W2b ledger guard runs after seed-once (its price_confirmed=false must not be overwritten)")
    cm = find(docs, "ConfigMap", "hermes-cloud-spend-init-3")
    need(len(cm) == 1 and set(cm[0].get("data", {})) == {"cloud-spend-init.py"}
         and cm[0]["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/substitute") == "disabled",
         "W2b guard ConfigMap holds only cloud-spend-init.py, substitution disabled")
    # W3
    cnp = find(docs, "CiliumNetworkPolicy", "hermes-profiel-3-cloud")
    need(len(cnp) == 1, "W3 CNP hermes-profiel-3-cloud rendered")
    if cnp:
        s = cnp[0]["spec"]
        need(s.get("endpointSelector") == {"matchLabels": {"app.kubernetes.io/name": "hermes",
                                                           "app.kubernetes.io/instance": "hermes-profiel-3"}},
             "W3 selector = hermes + instance hermes-profiel-3 only")
        need(set(s) == {"endpointSelector", "egress"}, "W3 CNP has egress only (no ingress, no deny/other keys)")
        eg = s.get("egress") or []
        fq = [r for r in eg if "toFQDNs" in r]
        dns = [r for r in eg if "toEndpoints" in r]
        need(len(eg) == 2 and len(fq) == 1 and len(dns) == 1, "W3 exactly 2 egress rules (FQDN + DNS)")
        if fq:
            need(set(fq[0]) == {"toFQDNs", "toPorts"} and fq[0]["toFQDNs"] == [{"matchName": HOST}],
                 "W3 toFQDNs == [matchName api.anthropic.com] only")
            need(fq[0]["toPorts"] == [{"ports": [{"port": "443", "protocol": "TCP"}]}], "W3 FQDN rule TCP 443 only")
        if dns:
            need(dns[0]["toEndpoints"] == [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "kube-system",
                                                            "k8s-app": "kube-dns"}}], "W3 DNS rule to kube-dns only")
            tp = dns[0].get("toPorts") or [{}]
            need(len(tp) == 1 and tp[0].get("rules") == {"dns": [{"matchName": HOST}]}, "W3 DNS allow = matchName only")
            need(sorted(json.dumps(p, sort_keys=True) for p in tp[0].get("ports", [])) ==
                 sorted(json.dumps(p, sort_keys=True) for p in [{"port": "53", "protocol": "UDP"},
                                                                {"port": "53", "protocol": "TCP"}]), "W3 DNS ports 53")
        flat = json.dumps(s)
        need(not re.search(r'"(toCIDR|toCIDRSet|toEntities|toServices|matchPattern|toGroups)"', flat),
             "W3 no CIDR/entities/wildcard in the cloud CNP")
    others = [d["metadata"]["name"] for d in docs if d.get("kind") == "CiliumNetworkPolicy"
              and d["metadata"]["name"] != "hermes-profiel-3-cloud" and "anthropic" in json.dumps(d)]
    need(not others, "W3 no other CNP mentions anthropic (found: %s)" % others)
    return fails


MUTATIONS = {
    "W5 image drift": lambda d: _app3(d).__setitem__("image", _app3(d)["image"].replace("v2026.9.24", "v2026.9.25")),
    "W5 env drift": lambda d: _env3(d, "HERMES_IMAGE").__setitem__("value", "docker.io/nousresearch/hermes-agent:latest"),
    "W4 key in p2 env": lambda d: _app(d, 2).setdefault("env", []).append({"name": "CLOUD_API_KEY", "value": "x"}),
    "W4 init envFrom": lambda d: [c for c in pod(_dep(d, 3))["initContainers"] if c["name"] == "seed-once"][0]
    .__setitem__("envFrom", [{"secretRef": {"name": "family-ai-hermes-profiel-3"}}]),
    "W6 emptyDir": lambda d: [v for v in pod(_dep(d, 3))["volumes"] if v["name"] == "cloud-spend"][0]
    .update({"emptyDir": {}}) or [v for v in pod(_dep(d, 3))["volumes"] if v["name"] == "cloud-spend"][0]
    .pop("persistentVolumeClaim"),
    "W6 p1 mounts spend": lambda d: pod(_dep(d, 1))["volumes"].append(
        {"name": "cloud-spend", "persistentVolumeClaim": {"claimName": "hermes-profiel-cloud-spend-3"}}),
    "W2b guard order": lambda d: pod(_dep(d, 3))["initContainers"].reverse(),
    "W2b guard command": lambda d: [c for c in pod(_dep(d, 3))["initContainers"] if c["name"] == "cloud-spend-init"][0]
    .__setitem__("command", ["/bin/true"]),
    "W3 wildcard": lambda d: _cnp(d)["egress"][0]["toFQDNs"].append({"matchPattern": "*.anthropic.com"}),
    "W3 port 80": lambda d: _cnp(d)["egress"][0]["toPorts"][0]["ports"].append({"port": "80", "protocol": "TCP"}),
    "W3 world": lambda d: _cnp(d)["egress"].append({"toEntities": ["world"]}),
    "W3 p1 selector": lambda d: _cnp(d)["endpointSelector"]["matchLabels"].pop("app.kubernetes.io/instance"),
    "W3 dns pattern": lambda d: _cnp(d)["egress"][1]["toPorts"][0]["rules"]["dns"].__setitem__(0, {"matchPattern": "*"}),
}


def _dep(d, n):
    return find(d, "Deployment", f"hermes-profiel-{n}")[0]


def _app(d, n):
    return [c for c in pod(_dep(d, n))["containers"] if c["name"] == "app"][0]


def _app3(d):
    return _app(d, 3)


def _env3(d, name):
    return env_of(_app3(d))[name]


def _cnp(d):
    return find(d, "CiliumNetworkPolicy", "hermes-profiel-3-cloud")[0]["spec"]


def main():
    args = sys.argv[1:]
    pinned = None
    if "--plugin" in args:
        src = Path(args[args.index("--plugin") + 1]).read_text()
        m = re.search(r'PINNED_IMAGE = \("([^"]+)"\s*\n\s*"([^"]+)"\)', src)
        if not m:
            print("FAIL could not read PINNED_IMAGE from the plugin")
            return 1
        pinned = m.group(1) + m.group(2)
    docs = render()
    fails = check(docs, pinned)
    for f in fails:
        print("FAIL", f)
    rc = 1 if fails else 0
    print(("PASS" if not fails else "FAIL") + f" check-cloud-wiring: {len(docs)} objects, pinned={'yes' if pinned else 'n/a'}")
    if "--self-test" in args and not fails:
        missed = []
        for name, mut in MUTATIONS.items():
            d = copy.deepcopy(docs)
            mut(d)
            if not check(d, pinned):
                missed.append(name)
        print(("PASS" if not missed else "FAIL") + f" self-test: {len(MUTATIONS) - len(missed)}/{len(MUTATIONS)} mutations caught"
              + (f" (missed: {missed})" if missed else ""))
        rc = rc or (1 if missed else 0)
    return rc


if __name__ == "__main__":
    sys.exit(main())
