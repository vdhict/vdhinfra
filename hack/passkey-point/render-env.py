#!/usr/bin/env python3
"""Render the per-workload NON-SECRET env ConfigMaps for Passkey Point (entra mode, chg-2026-10-05-009).

usage: render-env.py <dir with passkey-point.lab.{web,api,roster-sync,portal}.env> [--check]

Writes kubernetes/main/apps/lab-passkey/passkey-point/app/env-<workload>.yaml. The files are Mack's
out/lab/*.env (ids, thumbprints, origins, paths). Fails closed (exit 2, nothing written) on:
  * anything secret-shaped (PEM, MAC key, client secrets, federated token files, mock IdP keys);
  * PP_MODE other than entra; NODE_ENV (decision recorded: unset, TLS ends at envoy-internal);
  * a key file path that differs from our mount path; an origin that differs from our route
    hostname (it is the registered redirect URI);
  * outputs that would need egress we did not grant (PP_LOGS_INGESTION_*, http audit sinks).
Keys the Deployments set explicitly are DROPPED from the ConfigMap (listed), so the file cannot move a
listener, a path, an origin or the api URL. Values are written verbatim, with `${` escaped to `$${`
because Flux postBuild substitution runs over this directory.
"""
import json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "kubernetes/main/apps/lab-passkey/passkey-point/app")
DOMAIN = "bluejungle.net"
WORKLOADS = {"web": "web", "api": "api", "roster-sync": "roster", "portal": "portal"}
KEY_PATHS = {"ENTRA_CERT_PRIVATE_KEY_PATH": "/etc/passkey-point/entra/key.pem",
             "ROSTER_SYNC_CERT_PRIVATE_KEY_PATH": "/etc/passkey-point/entra/key.pem",
             "PORTAL_CERT_PRIVATE_KEY_PATH": "/etc/passkey-point/entra-portal/key.pem"}
ORIGINS = {"PP_PUBLIC_ORIGIN": f"https://passkey-point-lab.{DOMAIN}",
           "PP_PORTAL_PUBLIC_ORIGIN": f"https://passkey-point-portal-lab.{DOMAIN}"}
EXPLICIT = {"PP_MODE", "HOST", "PORT", "HOME", "PP_DATA_DIR", "PP_ROSTER_DIR", "PP_ALLOW_PLAIN_HTTP", "PP_API_URL",
            "PP_TLS_CERT_FILE", "PP_TLS_KEY_FILE", "PP_TLS_CLIENT_CA_FILE", "PP_API_CA_FILE",
            "PP_API_CLIENT_CERT_FILE", "PP_API_CLIENT_KEY_FILE"} | set(KEY_PATHS) | set(ORIGINS)
FORBIDDEN = re.compile(r"(CLIENT_SECRET|FEDERATED_TOKEN_FILE|MAC_KEY|PRIVATE_KEY$|PP_MOCK_IDP_|PASSWORD|TOKEN$)")
EGRESS = re.compile(r"^(PP_LOGS_INGESTION_|PP_AUDIT_SINK$|PP_AUDIT_OUTPUTS$|PP_PORTAL_URL$|MSAL_FORCE_REGION$)")

def parse(path):
    env = {}
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:]
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if not m:
            raise SystemExit(f"FAIL {path}:{n}: not KEY=VALUE")
        k, v = m.group(1), m.group(2)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        env[k] = v
    return env

def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src, check = sys.argv[1], "--check" in sys.argv
    errors, rendered, notes = [], {}, []
    for f, w in WORKLOADS.items():
        p = os.path.join(src, f"passkey-point.lab.{f}.env")
        if not os.path.isfile(p):
            errors.append(f"missing {p}"); continue
        env, keep = parse(p), {}
        for k, v in env.items():
            if "-----BEGIN" in v or (len(v) > 400 and re.fullmatch(r"[A-Za-z0-9+/=\s]+", v)):
                errors.append(f"{f}: {k} looks like key material"); continue
            if FORBIDDEN.search(k) and k not in KEY_PATHS:
                errors.append(f"{f}: {k} is secret-shaped; secrets come from 1Password files, never env/ConfigMap"); continue
            if EGRESS.search(k) or (k.startswith("PP_AUDIT") and "http" in v):
                errors.append(f"{f}: {k} needs egress/config not granted by the CNPs (re-review)"); continue
            if k == "NODE_ENV":
                errors.append(f"{f}: NODE_ENV={v}: decision is UNSET (lab, TLS at envoy-internal); remove it or re-gate"); continue
            if k == "PP_MODE" and v != "entra":
                errors.append(f"{f}: PP_MODE={v}, expected entra"); continue
            if k in KEY_PATHS and v != KEY_PATHS[k]:
                errors.append(f"{f}: {k}={v} != mount path {KEY_PATHS[k]}"); continue
            if k in ORIGINS and v.rstrip("/") != ORIGINS[k]:
                errors.append(f"{f}: {k}={v} != route origin {ORIGINS[k]} (redirect URI)"); continue
            if k in EXPLICIT:
                notes.append(f"{f}: {k} dropped (set explicitly in the Deployment)"); continue
            keep[k] = v
        rendered[w] = (f, keep)
    if errors:
        print("\n".join("FAIL  " + e for e in errors)); print("nothing written"); sys.exit(2)
    for w, (f, keep) in rendered.items():
        lines = ["---", f"# RENDERED by hack/passkey-point/render-env.py from passkey-point.lab.{f}.env (non-secret).",
                 "# Do not edit by hand: re-render. Values verbatim; `$${` = Flux postBuild escape.",
                 "apiVersion: v1", "kind: ConfigMap", "metadata:", f"  name: passkey-point-{w}-env", "data:",
                 '  PP_ENV_RENDERED: "true"']
        for k in sorted(keep):
            lines.append(f"  {k}: {json.dumps(keep[k].replace('${', '$${'), ensure_ascii=False)}")
        out = os.path.join(OUT, f"env-{w}.yaml")
        if not check:
            open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
        print(f"OK    {w}: {len(keep)} keys -> {os.path.relpath(out, ROOT)}{' (check only)' if check else ''}")
        for k in ("ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "PP_API_AUDIENCE", "PP_WEB_CLIENT_ID", "ROSTER_SYNC_CLIENT_ID",
                  "PP_PORTAL_CLIENT_ID", "PP_ROSTER_OWNER_AUDIENCE", "PP_POPULATION_AU"):
            if k in keep:
                print(f"        {k}={keep[k]}")
    for n in notes:
        print("NOTE  " + n)

main()
