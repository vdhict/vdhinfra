#!/usr/bin/env python3
# chg-2026-10-20-001: roll out the .NET LAB (kubernetes/main/apps/lab-passkey-dotnet) after the commit is on main, with
# the automated post-check and the automatic rollback (AGR-109: tests are the gate).
#
#   python3 -I hack/ops/chg-2026-10-20-001-dotnet-lab-rollout.py <vdhinfra-checkout> <evidence-dir>
#
# Order (Flux does the applying; this script watches, copies the pull secret, checks, and rolls back):
#   S0 preflight     origin/main carries the manifests and the pinned desk digest; TS LAB baseline captured
#   S1 namespace     wait for lab-passkey-dotnet; copy devtenant-build/devtenant-pull -> passkey-point-palamedes-pull
#   S2 db            Kustomizations network-policies, base, db Ready (CNPG Cluster healthy)
#   S3 migrate       Job passkey-point-migrate-<digest7> Complete; Failed -> STOP (desk is never applied: dependsOn)
#   S4 grants        Job passkey-point-grants-<sha7> Complete; Failed -> STOP
#   S5 desk          api + web Available within 8 min. CrashLoop / exit 78 / timeout -> ROLLBACK: suspend
#                    Kustomization lab-passkey-dotnet-desk, scale both Deployments to 0, record, exit 3
#   S6 post-check    readyz through envoy-internal, pod imageIDs, api banner (o365-mds, db postgres), schema 12 +
#                    V012 rights for pp_runtime, fail-closed test for the retired keys, TS LAB unchanged, leak check.
#                    A desk-health check failing -> ROLLBACK (exit 3); only fail-closed/TS/leak failing -> exit 4, desk stays.
# Never prints a secret: secret values are only read in memory for the pull-secret copy and the leak check.
import base64, hashlib, json, os, subprocess, sys, time

REPO, EV = sys.argv[1], sys.argv[2]
NS, CHG, ACTOR = "lab-passkey-dotnet", "chg-2026-10-20-001", "k8s-engineer"
DIGEST = "sha256:b412ec9c6df0d47ee9c8d57e93a950acc4d29cab48c210cf6591d1e7916adee9"
IMAGE = "forge.bluejungle.net/palamedes/passkey-point-dotnet@" + DIGEST
MIGRATE_JOB, GRANTS_JOB = "passkey-point-migrate-b412ec9", "passkey-point-grants-234141e"
HOST, ENVOY_IP = "passkey-point-dotnet-lab.bluejungle.net", "172.16.2.241"
KS = ["lab-passkey-dotnet-network-policies", "lab-passkey-dotnet-base", "lab-passkey-dotnet-db",
      "lab-passkey-dotnet-migrate", "lab-passkey-dotnet-grants", "lab-passkey-dotnet-desk"]
STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
LOG = os.path.join(EV, f"10-rollout-{STAMP}.txt")
if os.path.exists(LOG): sys.exit(f"{LOG} exists; write-once")


def now(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def W(s):
    print(s, flush=True)
    with open(LOG, "a") as f: f.write(s + "\n")
def run(*a, input=None, check=False):
    r = subprocess.run(list(a), capture_output=True, text=True, input=input)
    if check and r.returncode != 0: raise RuntimeError(f"{a[0]} {a[1] if len(a) > 1 else ''} rc={r.returncode}: {r.stderr.strip()[:300]}")
    return r
def kj(*a):
    r = run("kubectl", *a, "-o", "json")
    return json.loads(r.stdout) if r.returncode == 0 else None
def event(ev, payload):
    payload = dict(payload, authority="AGR-109: tests are the gate; Passkey exempt from windows (AGR-098)")
    r = run(os.path.join(REPO, "ops", "ops"), "change", "event", CHG, ev, "--actor", ACTOR, "--payload-json", json.dumps(payload))
    W(f"   change-log {ev}: rc={r.returncode} {r.stdout.strip()[-60:]}")
def ks_ready(name):
    j = kj("-n", "flux-system", "get", "kustomization", name)
    if not j: return None, "absent"
    c = {x["type"]: x for x in j.get("status", {}).get("conditions", [])}.get("Ready", {})
    return c.get("status"), (c.get("reason", "") + " " + c.get("message", "")[:200]).strip()
def wait_ks(name, timeout):
    end = time.time() + timeout
    while time.time() < end:
        st, msg = ks_ready(name)
        if st == "True": W(f"   {name}: Ready ({msg[:120]})"); return True
        time.sleep(10)
    W(f"   {name}: NOT Ready after {timeout}s: {msg}"); return False
def job_state(name):
    j = kj("-n", NS, "get", "job", name)
    if not j: return "absent"
    for c in j.get("status", {}).get("conditions", []):
        if c["type"] in ("Complete", "Failed") and c["status"] == "True": return c["type"]
    return "running"
def job_logs(name, fname):
    r = run("kubectl", "-n", NS, "logs", f"job/{name}", "--all-containers", "--tail=200")
    p = os.path.join(EV, f"{fname}-{STAMP}.log")
    with open(p, "x") as f: f.write(r.stdout + (("\n[stderr] " + r.stderr) if r.returncode else ""))
    W(f"   logs -> {os.path.basename(p)}:"); [W("     " + l) for l in r.stdout.strip().splitlines()[-25:]]
def wait_job(name, timeout):
    end = time.time() + timeout
    while time.time() < end:
        s = job_state(name)
        if s in ("Complete", "Failed"): return s
        time.sleep(5)
    return "timeout"
def ts_baseline():
    out = {}
    for ns, kind, name in [("lab-passkey", "deploy", "passkey-point-api"), ("lab-passkey", "deploy", "passkey-point-web"),
                           ("lab-passkey", "cm", "passkey-point-v01-env"), ("lab-passkey", "cm", "tap-sim-config"),
                           ("passkey-point-e2e", "cronjob", "passkey-point-e2e"), ("passkey-point-e2e", "cm", "passkey-point-e2e-config"),
                           ("passkey-point-e2e", "cnp", "e2e-entra"), ("passkey-point-e2e", "cnp", "e2e-lab")]:
        j = kj("-n", ns, "get", kind, name)
        body = j.get("spec", j.get("data")) if j else None
        out[f"{ns}/{kind}/{name}"] = {"resourceVersion": j["metadata"]["resourceVersion"] if j else None,
                                      "spec_sha256": hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16] if j else None,
                                      "generation": j["metadata"].get("generation") if j else None}
    return out
def rollback(reason):
    W(f"!! ROLLBACK {now()}: {reason}")
    r1 = run("flux", "-n", "flux-system", "suspend", "kustomization", "lab-passkey-dotnet-desk")
    W(f"   flux suspend ks lab-passkey-dotnet-desk: rc={r1.returncode}")
    for d in ("passkey-point-api", "passkey-point-web"):
        r = run("kubectl", "-n", NS, "scale", "deploy", d, "--replicas=0")
        W(f"   scale {d} 0: rc={r.returncode} {r.stdout.strip()}")
    for d in ("passkey-point-api", "passkey-point-web"):
        r = run("kubectl", "-n", NS, "logs", f"deploy/{d}", "--all-containers", "--tail=80", "--previous")
        if r.returncode: r = run("kubectl", "-n", NS, "logs", f"deploy/{d}", "--all-containers", "--tail=80")
        p = os.path.join(EV, f"11-rollback-{d}-{STAMP}.log")
        with open(p, "x") as f: f.write(r.stdout)
    time.sleep(20)
    pods = kj("-n", NS, "get", "pods", "-l", "app.kubernetes.io/name in (passkey-point-api,passkey-point-web)")
    W(f"   desk pods left after rollback: {len((pods or {}).get('items', []))}")
    event("executed", {"category": "rollback", "reason": reason, "action": "suspended ks lab-passkey-dotnet-desk, scaled api+web to 0",
                       "revert": "git revert <rollout commit> on main, then flux resume ks lab-passkey-dotnet-desk",
                       "evidence": os.path.relpath(LOG, REPO)})
    sys.exit(3)


W(f"# {CHG} .NET LAB rollout {now()} ({ACTOR}); evidence write-once")
# ---- S0 preflight
W("== S0 preflight")
for p in ["kubernetes/main/apps/lab-passkey-dotnet/desk/app/api.yaml", "kubernetes/main/apps/lab-passkey-dotnet/components/desk-image/kustomization.yaml"]:
    r = run("git", "-C", REPO, "cat-file", "-e", f"origin/main:{p}"); W(f"   origin/main:{p} present: {r.returncode == 0}")
    if r.returncode: sys.exit("not on origin/main: Flux deploys from main only")
comp = run("git", "-C", REPO, "show", "origin/main:kubernetes/main/apps/lab-passkey-dotnet/components/desk-image/kustomization.yaml").stdout
W(f"   pinned digest on origin/main == {DIGEST[:19]}..: {DIGEST in comp}")
if DIGEST not in comp: sys.exit("digest mismatch")
BASE = ts_baseline()
with open(os.path.join(EV, f"10-ts-lab-baseline-before-{STAMP}.json"), "x") as f: json.dump(BASE, f, indent=1)
W(f"   TS LAB + TS E2E baseline captured ({len(BASE)} objects)")
W("   flux reconcile source git flux-system: rc=" + str(run("flux", "reconcile", "source", "git", "flux-system").returncode))
W("   flux reconcile ks cluster-apps: rc=" + str(run("flux", "reconcile", "kustomization", "cluster-apps").returncode))

# ---- S1 namespace + pull secret
W("== S1 namespace + pull secret")
end = time.time() + 600
while time.time() < end and not kj("get", "ns", NS): time.sleep(5)
if not kj("get", "ns", NS): sys.exit("namespace never appeared")
W(f"   namespace {NS} present {now()}")
if kj("-n", NS, "get", "secret", "passkey-point-palamedes-pull"):
    W("   passkey-point-palamedes-pull already present (not re-copied)")
else:
    src = kj("-n", "devtenant-build", "get", "secret", "devtenant-pull")
    body = json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
                       "metadata": {"name": "passkey-point-palamedes-pull", "namespace": NS,
                                    "labels": {"vdhinfra.io/chg": CHG, "vdhinfra.io/copied-from": "devtenant-build.devtenant-pull"}},
                       "data": {".dockerconfigjson": src["data"][".dockerconfigjson"]}}); del src
    r = run("kubectl", "create", "-f", "-", input=body); del body
    W(f"   copy devtenant-build/devtenant-pull -> {NS}/passkey-point-palamedes-pull (value via stdin, not printed): rc={r.returncode} {r.stdout.strip()}")
    event("executed", {"category": "pull_secret", "action": f"one-off copy devtenant-build/devtenant-pull -> {NS}/passkey-point-palamedes-pull",
                       "pattern": "same as lab-passkey and passkey-point-e2e (chg-2026-10-12-004)", "rc": r.returncode})

# ---- S2 policies, base, db
W("== S2 network-policies, base, db")
for name, t in [(KS[0], 300), (KS[1], 600), (KS[2], 900)]:
    if not wait_ks(name, t): sys.exit(f"{name} not Ready: nothing with state was written; no desk pod exists")
cl = kj("-n", NS, "get", "cluster.postgresql.cnpg.io", "pp-dotnet-pg")
W(f"   CNPG pp-dotnet-pg: phase={cl['status'].get('phase')} ready={cl['status'].get('readyInstances')}/{cl['spec']['instances']} image={cl['spec']['imageName'][-20:]}")

# ---- S3 migrate
W("== S3 migrate (ops migrate, V001..V012)")
end = time.time() + 300
while time.time() < end and job_state(MIGRATE_JOB) == "absent": time.sleep(5)
s = wait_job(MIGRATE_JOB, 600); W(f"   Job {MIGRATE_JOB}: {s}"); job_logs(MIGRATE_JOB, "12-migrate")
event("executed", {"category": "migrate", "job": MIGRATE_JOB, "image": IMAGE, "result": s})
if s != "Complete":
    W("!! migrate did not complete: grants/ and desk/ are NOT applied (dependsOn); no desk pod exists. STOP.")
    sys.exit(2)

# ---- S4 grants
W("== S4 grants (grants.sql @e7fbe8a minus CREATE ROLE)")
end = time.time() + 300
while time.time() < end and job_state(GRANTS_JOB) == "absent": time.sleep(5)
s = wait_job(GRANTS_JOB, 300); W(f"   Job {GRANTS_JOB}: {s}"); job_logs(GRANTS_JOB, "13-grants")
event("executed", {"category": "grants", "job": GRANTS_JOB, "result": s})
if s != "Complete":
    W("!! grants did not complete: desk/ is NOT applied (dependsOn); no desk pod exists. STOP.")
    sys.exit(2)

# ---- S5 desk with the canary watch
W("== S5 desk rollout (readiness = /readyz on api and web)")
end, ok = time.time() + 480, False
while time.time() < end:
    bad = []
    for p in (kj("-n", NS, "get", "pods", "-l", "app.kubernetes.io/name in (passkey-point-api,passkey-point-web)") or {}).get("items", []):
        for cs in p.get("status", {}).get("containerStatuses", []) or []:
            term = (cs.get("lastState", {}).get("terminated") or cs.get("state", {}).get("terminated") or {})
            wait = (cs.get("state", {}).get("waiting") or {}).get("reason", "")
            if cs.get("restartCount", 0) >= 2 or term.get("exitCode") == 78 or wait in ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError"):
                bad.append(f"{p['metadata']['name']}/{cs['name']} restarts={cs.get('restartCount')} exit={term.get('exitCode')} waiting={wait}")
    if bad: rollback("desk container failing: " + "; ".join(bad))
    av = []
    for d in ("passkey-point-api", "passkey-point-web"):
        j = kj("-n", NS, "get", "deploy", d)
        av.append(bool(j) and j.get("status", {}).get("availableReplicas", 0) == 1 and j["status"].get("updatedReplicas", 0) == 1)
    if all(av): ok = True; break
    time.sleep(10)
if not ok: rollback("desk not Available within 8 min")
W(f"   api + web Available {now()}")
if not wait_ks(KS[5], 300): rollback("Kustomization lab-passkey-dotnet-desk not Ready")
event("executed", {"category": "rollout", "deployments": ["passkey-point-api", "passkey-point-web"], "image": IMAGE, "result": "Available, Kustomization Ready"})

# ---- S6 post-check
W("== S6 post-check")
fails = []
for name in KS:
    st, msg = ks_ready(name); W(f"   ks {name}: Ready={st}"); fails += [] if st == "True" else [f"ks {name}"]
for p in (kj("-n", NS, "get", "pods", "-l", "app.kubernetes.io/name in (passkey-point-api,passkey-point-web)") or {}).get("items", []):
    for cs in p["status"]["containerStatuses"]:
        W(f"   pod {p['metadata']['name']} {cs['name']}: ready={cs['ready']} restarts={cs['restartCount']} imageID={cs['imageID']}")
        if cs["name"] in ("api", "web") and not cs["imageID"].endswith(DIGEST): fails.append(f"imageID {cs['name']}")
for path in ("/readyz", "/healthz", "/signin"):
    r = run("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15", "--resolve", f"{HOST}:443:{ENVOY_IP}", f"https://{HOST}{path}")
    W(f"   GET https://{HOST}{path} via envoy-internal: HTTP {r.stdout}")
    if path == "/readyz" and r.stdout != "200": fails.append("readyz via envoy")
banner = run("kubectl", "-n", NS, "logs", "deploy/passkey-point-api", "-c", "api", "--tail=400").stdout
bl = [l for l in banner.splitlines() if "Passkey Point api" in l]
W(f"   api banner: {bl[-1][:300] if bl else 'NOT FOUND'}")
if not bl or "(o365-mds)" not in bl[-1] or "db postgres" not in bl[-1]: fails.append("api banner o365-mds/postgres")
pg = "pp-dotnet-pg-1"
q = ("SELECT 'schema_max='||max(version) FROM schema_migrations UNION ALL "
     "SELECT 'versions='||string_agg(version::text, ',' ORDER BY version) FROM schema_migrations UNION ALL "
     "SELECT 'id_check_confirmations='||(to_regclass('public.id_check_confirmations') IS NOT NULL) UNION ALL "
     "SELECT 'runtime_insert='||has_table_privilege('pp_runtime','id_check_confirmations','INSERT') UNION ALL "
     "SELECT 'runtime_update='||has_table_privilege('pp_runtime','id_check_confirmations','UPDATE') UNION ALL "
     "SELECT 'runtime_delete='||has_table_privilege('pp_runtime','id_check_confirmations','DELETE') UNION ALL "
     "SELECT 'runtime_audit_update='||has_table_privilege('pp_runtime','audit','UPDATE') UNION ALL "
     "SELECT 'runtime_create_public='||has_schema_privilege('pp_runtime','public','CREATE') UNION ALL "
     "SELECT 'runtime_super='||rolsuper||' createrole='||rolcreaterole||' createdb='||rolcreatedb FROM pg_roles WHERE rolname='pp_runtime'")
r = run("kubectl", "-n", NS, "exec", pg, "-c", "postgres", "--", "psql", "-X", "-At", "-d", "passkeypoint", "-c", q)
db = dict(l.split("=", 1) for l in r.stdout.strip().splitlines() if "=" in l and not l.startswith("runtime_super"))
for l in r.stdout.strip().splitlines(): W(f"   db {l}")
want = {"schema_max": "12", "id_check_confirmations": "true", "runtime_insert": "true", "runtime_update": "false",
        "runtime_delete": "false", "runtime_audit_update": "false", "runtime_create_public": "false"}
for k, v in want.items():
    if db.get(k) != v: fails.append(f"db {k}={db.get(k)} want {v}")
if "runtime_super=false createrole=false createdb=false" not in r.stdout: fails.append("pp_runtime attributes")
# fail-closed: the desk must refuse the retired keys at start (exit 78)
for tag, extra in [("oldkey", [{"name": "PP_TAP_CUSTOMER_ENV", "value": "dev-fake"}]), ("oldservice", [{"name": "PP_TAP_SERVICE", "value": "customer"}])]:
    jn = f"pp-dotnet-cfgcheck-{tag}-{STAMP.lower()[:15]}"
    job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": jn, "namespace": NS, "labels": {"vdhinfra.io/chg": CHG}},
           "spec": {"backoffLimit": 0, "ttlSecondsAfterFinished": 900, "activeDeadlineSeconds": 120, "template": {
               "metadata": {"labels": {"app.kubernetes.io/name": "passkey-point-cfgcheck"}},
               "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False, "enableServiceLinks": False,
                        "imagePullSecrets": [{"name": "passkey-point-palamedes-pull"}], "nodeSelector": {"kubernetes.io/hostname": "vdhclu01node02"},
                        "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001, "seccompProfile": {"type": "RuntimeDefault"}},
                        "containers": [{"name": "api", "image": IMAGE, "args": ["api"], "envFrom": [{"configMapRef": {"name": "passkey-point-config"}}],
                                        "env": [{"name": "PP_MODE", "value": "entra"}, {"name": "HOME", "value": "/tmp"}] + extra,
                                        "resources": {"requests": {"cpu": "20m", "memory": "96Mi"}, "limits": {"memory": "256Mi"}},
                                        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                                        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]}],
                        "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "16Mi"}}]}}}}
    rc = run("kubectl", "create", "-f", "-", input=json.dumps(job)).returncode
    s = wait_job(jn, 150)
    pods = kj("-n", NS, "get", "pods", "-l", f"job-name={jn}")
    code = None
    for p in (pods or {}).get("items", []):
        for cs in p["status"].get("containerStatuses", []): code = (cs["state"].get("terminated") or {}).get("exitCode")
    msg = run("kubectl", "-n", NS, "logs", f"job/{jn}", "--tail=5").stdout.strip()
    W(f"   fail-closed {tag}: create rc={rc} job={s} exit={code} log: {msg[:220]}")
    if not (s == "Failed" and code == 78 and "retired" in msg): fails.append(f"fail-closed {tag}")
after = ts_baseline()
with open(os.path.join(EV, f"10-ts-lab-baseline-after-{STAMP}.json"), "x") as f: json.dump(after, f, indent=1)
same = all(BASE[k]["spec_sha256"] == after[k]["spec_sha256"] and BASE[k]["generation"] == after[k]["generation"] for k in BASE)
W(f"   TS LAB + TS nightly E2E unchanged (spec sha + generation, {len(BASE)} objects): {same}")
if not same: fails.append("TS LAB changed")
# leak check: no secret value of this namespace in any evidence file written by this run
vals = []
for sname in ("pp-dotnet-pg-runtime", "pp-dotnet-pg-app", "passkey-point-palamedes-pull"):
    j = kj("-n", NS, "get", "secret", sname)
    for v in (j or {}).get("data", {}).values():
        b = base64.b64decode(v).decode(errors="ignore")
        if len(b) >= 12: vals.append(b)
        for part in b.replace('"', " ").split():
            if len(part) >= 24: vals.append(part)
hits = 0
for fn in os.listdir(EV):
    if STAMP in fn:
        t = open(os.path.join(EV, fn), errors="ignore").read()
        hits += sum(1 for v in vals if v in t)
del vals
W(f"   leak check (secret values of {NS} in this run's evidence): hits={hits}")
if hits: fails.append("leak")
verdict = "PASS" if not fails else "FAIL: " + ", ".join(fails)
W(f"== VERDICT {verdict} {now()}")
event("validated" if not fails else "executed", {"category": "post_check", "verdict": verdict, "image": IMAGE,
      "checks": "ks Ready x6, imageIDs, readyz via envoy-internal, api banner o365-mds+postgres, schema 12 + V012 rights, fail-closed retired keys x2, TS LAB unchanged, leak check",
      "evidence": os.path.relpath(LOG, REPO)})
# Desk health failures roll back; a fail-closed, TS-baseline or leak finding is reported (verdict FAIL, exit 4)
# without taking a healthy desk down.
health = [f for f in fails if f.startswith(("ks ", "imageID", "readyz", "api banner", "db ", "pp_runtime"))]
if health: rollback("post-check failed: " + ", ".join(health))
if fails: sys.exit(4)
