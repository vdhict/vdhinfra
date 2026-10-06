#!/usr/bin/env python3
"""Static check of the Passkey Point startup guards against the MERGED env of each Deployment (chg-2026-10-05-009,
inc-2026-10-06-005: a dry run cannot see the app's own ConfigError guards; roster-sync exited 78 on PP_PUBLIC_ORIGIN).

usage: check-env-guards.py <kustomize build of passkey-point/app, ${SECRET_DOMAIN} substituted>

Merged env = the envFrom ConfigMap data, overlaid by the Deployment's explicit env (explicit wins, as in Kubernetes).
secretKeyRef values are "present" (never read). Volume mounts are checked for every *_PATH / *_FILE / *_DIR.
A SUBSET of the 105 ConfigError throws in a184498 src/config.ts (+ tls.ts, credential.ts, app-only.ts, portal/*):
the cross-cutting ones (mode, NODE_ENV, origins/https, sites, privilege mode, ids, credentials + key-file mounts,
data/roster dirs incl. SEC-13 layout, TLS/plain HTTP, portal MAC key). The full set is exercised by
config-guard pods (hack/passkey-point/config-guard-pod.sh) that run the app's own loadConfig in-cluster.
Exit 0 = no guard would trip, 1 = at least one would, 2 = input error.
"""
import json, re, sys, subprocess

GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
ORIGIN = re.compile(r"^https?://[^/]+$")
# workload -> (loadConfig workload, role, listener, credential prefixes)
KIND = {
    "passkey-point-web":    {"issuing": True,  "role": "web",    "listener": True,  "prefixes": ["ENTRA_"]},
    "passkey-point-api":    {"issuing": True,  "role": "api",    "listener": True,  "prefixes": ["ENTRA_"]},
    "passkey-point-roster": {"issuing": False, "role": "sync",   "listener": False, "prefixes": ["ROSTER_SYNC_"]},
    "passkey-point-portal": {"issuing": False, "role": "portal", "listener": True,  "prefixes": ["ROSTER_SYNC_", "PORTAL_"]},
}

def load(path):
    out = subprocess.run(["yq", "-o=json", "-I=0", ".", path], capture_output=True, text=True, check=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip() and l.strip() != "null"]

def main():
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    docs = load(sys.argv[1])
    cms = {d["metadata"]["name"]: d.get("data", {}) for d in docs if d.get("kind") == "ConfigMap"}
    deps = [d for d in docs if d.get("kind") == "Deployment"]
    trips = 0
    for d in deps:
        name = d["metadata"]["name"]; k = KIND.get(name)
        if not k:
            print(f"SKIP  {name}: unknown workload"); continue
        spec = d["spec"]["template"]["spec"]; c = spec["containers"][0]
        env = {}
        for ef in c.get("envFrom", []):
            env.update(cms.get(ef.get("configMapRef", {}).get("name"), {}))
        for e in c.get("env", []):
            if "value" in e: env[e["name"]] = str(e["value"])
            elif "secretKeyRef" in e.get("valueFrom", {}): env[e["name"]] = "<secret>"
            elif "configMapKeyRef" in e.get("valueFrom", {}):
                r = e["valueFrom"]["configMapKeyRef"]; v = cms.get(r["name"], {}).get(r["key"])
                if v is not None: env[e["name"]] = v
        vols = {v["name"]: v for v in spec.get("volumes", [])}
        mounts = {m["mountPath"].rstrip("/"): (vols.get(m["name"], {}), bool(m.get("readOnly"))) for m in c.get("volumeMounts", [])}
        bad = []
        def g(cond, line, msg):
            if not cond: bad.append(f"[{line}] {msg}")
        # Renderer contract (inc-2026-10-06-005): every key render-env.py drops as "Deployment sets it" must be set
        # EXPLICITLY by THIS Deployment (not just exist somewhere in the merged env).
        explicit = {e["name"] for e in c.get("env", [])}
        must = {"PP_MODE", "PP_PUBLIC_ORIGIN", "PP_DATA_DIR"} | ({"PORT"} if k["listener"] else set()) \
            | ({"PP_ROSTER_DIR"} if k["role"] in ("api", "sync", "portal") else set()) \
            | {f"{p}CERT_PRIVATE_KEY_PATH" for p in k["prefixes"]} | ({"PP_PORTAL_PUBLIC_ORIGIN"} if k["role"] == "portal" else set()) \
            | ({"PP_API_URL"} if k["role"] == "web" else set())
        for key in sorted(must - explicit):
            bad.append(f"[render-env contract] {key} is dropped from the env file but NOT set by this Deployment")
        mode = env.get("PP_MODE", "mock"); prod = env.get("NODE_ENV") == "production"
        g(mode in ("mock", "entra"), "config.ts:667", f"PP_MODE={mode}")
        g(mode == "entra", "chg-009", "PP_MODE must be entra for the dev-tenant run")
        g(not (mode == "mock" and prod), "config.ts:669", "mock refuses NODE_ENV=production")
        port = env.get("PORT", "3000")
        origin = env.get("PP_PUBLIC_ORIGIN", f"http://localhost:{port}").rstrip("/")
        g(bool(ORIGIN.match(origin)), "config.ts:673", f"PP_PUBLIC_ORIGIN not an origin ({origin})")
        g(origin.startswith("https://") or re.match(r"^http://localhost(:\d+)?$", origin) is not None, "config.ts:674", f"PP_PUBLIC_ORIGIN must be https ({origin})")
        g(not prod or origin.startswith("https://"), "config.ts:678", f"PP_PUBLIC_ORIGIN must be https in production ({origin})")
        sites = env.get("PP_SITES")
        g(bool(sites), "config.ts:690", "PP_SITES is required in entra")
        if sites:
            try: json.loads(sites)
            except ValueError: bad.append("[config.ts:parseSites] PP_SITES is not JSON")
        pm = env.get("PP_PRIVILEGE_MODE") or "app"
        g(pm in ("app", "delegated"), "config.ts:697", f"PP_PRIVILEGE_MODE={pm}")
        g("PP_DELEGATED_PRODUCTION_OVERRIDE" not in env, "config.ts:701", "override only with delegated")
        g(not (prod and pm == "delegated"), "config.ts:707", "delegated refused in production")
        g(not env.get("TAP_DISPLAY_SECONDS"), "config.ts:686", "TAP_DISPLAY_SECONDS renamed")
        engine = env.get("PP_DB_ENGINE", "sqlite")
        g(engine in ("sqlite", "postgres", "mssql", "oracle"), "config.ts:797", f"PP_DB_ENGINE={engine}")
        data = env.get("PP_DATA_DIR", "./data")
        g(not (prod and engine == "sqlite" and re.match(r"^/(tmp|var/tmp|dev/shm)(/|$)", data)), "config.ts:816", f"PP_DATA_DIR {data} under /tmp in production")
        g(data.rstrip("/") in mounts, "layout", f"PP_DATA_DIR {data} is not a mounted volume")
        roster = env.get("PP_ROSTER_DIR") or data
        if k["role"] in ("api", "sync", "portal"):
            g(roster.rstrip("/") in mounts, "layout", f"PP_ROSTER_DIR {roster} is not a mounted volume")
        if k["issuing"] and mode == "entra":
            for key in ("ENTRA_TENANT_ID", "ENTRA_CLIENT_ID"):
                g(bool(GUID.match(env.get(key, ""))), "config.ts:760", f"{key} must be a GUID")
            g(env.get("PP_ROSTER_READONLY", "true").lower() not in ("false", "0", "no"), "config.ts:827", "PP_ROSTER_READONLY=false refused for the issuing service")
            if prod and pm == "app":
                g(bool(GUID.match(env.get("PP_POPULATION_AU", ""))), "config.ts:928", "PP_POPULATION_AU required in production")
        if k["role"] == "api" and mode == "entra":
            g(bool(env.get("PP_WEB_CLIENT_ID")), "config.ts:932", "PP_WEB_CLIENT_ID required for the api")
            if prod and engine == "sqlite":
                g(roster.rstrip("/") != data.rstrip("/"), "config.ts:1019", "SEC-13: PP_ROSTER_DIR must differ from PP_DATA_DIR")
                g(mounts.get(roster.rstrip("/"), ({}, False))[1], "config.ts:937-1065", "SEC-13: the roster dir must be a readOnly mount for the api")
        if k["role"] == "web":
            g(bool(re.match(r"^https?://[^\s/]+$", env.get("PP_API_URL", ""))), "config.ts:808 / web/server.ts", "PP_API_URL required, an origin")
        for pre in k["prefixes"]:
            keyp, thumb = env.get(f"{pre}CERT_PRIVATE_KEY_PATH"), env.get(f"{pre}CERT_THUMBPRINT_SHA256")
            fed, sec = env.get(f"{pre}FEDERATED_TOKEN_FILE") or env.get("AZURE_FEDERATED_TOKEN_FILE"), env.get(f"{pre}CLIENT_SECRET")
            g(bool(fed or (keyp and thumb) or sec), "credential.ts:35", f"{pre} credential missing (key path + thumbprint)")
            g(not (prod and sec and not fed and not (keyp and thumb)), "credential.ts:32", f"{pre}CLIENT_SECRET refused in production")
            g(not sec, "chg-009", f"{pre}CLIENT_SECRET must not be set at all")
            if keyp:
                dirp, base = keyp.rsplit("/", 1)
                v = mounts.get(dirp)
                ok = bool(v and "secret" in v[0])
                g(ok, "credential.ts msalAuth", f"{pre}CERT_PRIVATE_KEY_PATH {keyp}: no secret volume mounted at {dirp}")
                if ok:
                    items = v[0]["secret"].get("items")
                    g(items is None or any(i.get("path") == base for i in items), "credential.ts msalAuth", f"{keyp}: {base} not projected")
                    g(v[1], "K4/least-priv", f"{dirp} must be mounted readOnly")
        if k["role"] in ("sync", "portal"):
            for key in ("ROSTER_SYNC_TENANT_ID", "ROSTER_SYNC_CLIENT_ID"):
                g(bool(GUID.match(env.get(key, ""))), "app-only.ts:31-32", f"{key} must be a GUID")
            sid = env.get("ROSTER_SYNC_CLIENT_ID", "").lower()
            for other in ("ENTRA_CLIENT_ID", "PP_API_CLIENT_ID"):
                g(not (env.get(other) and env[other].lower() == sid), "app-only.ts:33-36", f"ROSTER_SYNC_CLIENT_ID equals {other}")
        if k["role"] == "portal" and mode == "entra":
            g(env.get("PP_PORTAL_MAC_KEY") == "<secret>", "portal/server.ts:30", "PP_PORTAL_MAC_KEY (secretKeyRef) required in entra")
            po = env.get("PP_PORTAL_PUBLIC_ORIGIN", "")
            g(bool(re.match(r"^https://[^/]+$", po)), "config.ts:82", f"PP_PORTAL_PUBLIC_ORIGIN must be an https origin ({po})")
            for key in ("PP_PORTAL_CLIENT_ID", "PP_ROSTER_OWNER_AUDIENCE", "PP_ROSTER_OWNER_TENANT_ID"):
                g(bool(env.get(key)), "portal/auth.ts:19", f"{key} required for the portal sign-in")
        if k["listener"]:
            cert, key_, plain = env.get("PP_TLS_CERT_FILE"), env.get("PP_TLS_KEY_FILE"), env.get("PP_ALLOW_PLAIN_HTTP", "").lower() in ("1", "true", "yes")
            if cert and key_:
                for f in (cert, key_):
                    dirp = f.rsplit("/", 1)[0]
                    g(dirp in mounts and "secret" in mounts[dirp][0], "tls.ts:28", f"TLS file {f} not on a mounted secret")
            else:
                g(plain, "tls.ts:48", "no TLS files and PP_ALLOW_PLAIN_HTTP not set")
                g(not (prod and mode == "entra"), "tls.ts:49", "plain HTTP refused with NODE_ENV=production in entra mode")
        if g and bad:
            trips += len(bad)
            for b in bad: print(f"TRIP  {name}: {b}")
        else:
            print(f"OK    {name}: NODE_ENV={'production' if prod else 'unset'} origin={origin} data={data} roster={roster}")
    print(f"guard trips: {trips}")
    sys.exit(1 if trips else 0)

main()
