#!/usr/bin/env python3
"""Render the per-workload NON-SECRET env ConfigMaps for Passkey Point (entra mode, chg-2026-10-05-009).

usage: render-env.py <dir with passkey-point.lab.{web,api,roster-sync,portal}.env> [--check]

Writes kubernetes/main/apps/lab-passkey/passkey-point/app/env-<workload>.yaml from Mack's out/lab/*.env.
The repo is PUBLIC, so this is an ALLOW-LIST (Themis B1). Every key must be on the workload's list
(REQUIRED or OPTIONAL) and its value must match that key's shape. Exit 2 and nothing written on:
  * an unknown key, a missing or empty REQUIRED key, a duplicate key, a malformed line, an empty file;
  * a value that does not match its key's shape (GUID, 64-hex thumbprint, exact origin, enum, int,
    PP_SITES / PP_MANAGER_SCOPE / PP_POPULATION_EXCLUDE JSON with GUIDs);
  * anything secret-shaped in ANY value (PEM, JWT, Entra client-secret 'Q~', long base64/hex outside
    a thumbprint key);
  * the hard-refused names: NODE_*, *_PROXY, *AUTHORITY*, *_HOST, MSAL_*, AZURE_*, *SECRET*, *TOKEN*,
    *PASSW*, *_KEY (except the *_PATH mounts), PP_DELEGATED_PRODUCTION_OVERRIDE, log/audit sinks.
Argus R1-R3: PP_PRIVILEGE_MODE must be app; PP_POPULATION_AU required GUID; PP_REQUIRED_AUTH_CONTEXT
absent or exactly c1.
Keys the Deployments set explicitly are checked (paths, origins, PP_MODE) and then DROPPED, so a file
cannot move a listener, a path, an origin or the api URL.
B2 guard: every rendered ConfigMap carries PP_ENV_RENDERED_FROM (sha256 of the four input files);
each Deployment references that key with optional: false, so a placeholder ConfigMap stops the pod
with CreateContainerConfigError before any supplier code runs.
"""
import hashlib, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "kubernetes/main/apps/lab-passkey/passkey-point/app")
DOMAIN = "bluejungle.net"
FILES = {"web": "web", "api": "api", "roster-sync": "roster", "portal": "portal"}
GUARD = "PP_ENV_RENDERED_FROM"

GUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
def rx(p): return lambda v: re.fullmatch(p, v) is not None
def enum(*a): return lambda v: v in a
def intr(lo, hi): return lambda v: re.fullmatch(r"[0-9]{1,7}", v) is not None and lo <= int(v) <= hi

def guid_list(x, n):
    return isinstance(x, list) and len(x) <= n and all(isinstance(g, str) and re.fullmatch(GUID, g) for g in x)

SHORT = re.compile(r"[A-Za-z0-9 ._:/()+,'&-]{1,80}")
ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:\d{2})")
def sites(v):
    try: s = json.loads(v)
    except ValueError: return False
    if not isinstance(s, list) or not 1 <= len(s) <= 50: return False
    for o in s:
        if not isinstance(o, dict): return False
        for k, x in o.items():
            if k in ("auId", "championGroupId"):
                if not (isinstance(x, str) and re.fullmatch(GUID, x)): return False
            elif k in ("campaignFrom", "campaignUntil"):
                if not (isinstance(x, str) and ISO.fullmatch(x)): return False
            elif k == "listSources":
                if not (isinstance(x, list) and all(isinstance(i, str) and SHORT.fullmatch(i) for i in x)): return False
            elif k in ("tapLifetimeMinutes", "carryOverHours"):
                if not (isinstance(x, int) and 0 <= x <= 43200): return False
            elif k in ("id", "name", "tapPreset", "bu", "timeZone"):
                if not (isinstance(x, str) and SHORT.fullmatch(x)): return False
            else:
                return False
        if not ("id" in o and "championGroupId" in o): return False
    return True

def manager_scope(v):
    try: o = json.loads(v)
    except ValueError: return False
    if not isinstance(o, dict): return False
    for k, x in o.items():
        if k in ("managerGroupIds", "pilotManagerIds"):
            if not guid_list(x, 200): return False
        elif k in ("name", "tapPreset"):
            if not (isinstance(x, str) and SHORT.fullmatch(x)): return False
        elif k in ("tapLifetimeMinutes", "deputyMaxDays"):
            if not (isinstance(x, int) and 0 <= x <= 43200): return False
        else:
            return False
    return True

def exclude(v):
    try: o = json.loads(v)
    except ValueError: return False
    return isinstance(o, dict) and set(o) <= {"objectIds", "groupIds"} and guid_list(o.get("objectIds", []), 1000) and guid_list(o.get("groupIds", []), 20)

def population_aus(v):
    try: o = json.loads(v)
    except ValueError: return False
    return isinstance(o, dict) and 0 < len(o) <= 20 and all(SHORT.fullmatch(k) and isinstance(x, str) and re.fullmatch(GUID, x) for k, x in o.items())

S = {  # key -> shape
    "PP_MODE": enum("entra"),
    "PP_PRIVILEGE_MODE": enum("app"),                       # Argus R1
    "PP_REQUIRED_AUTH_CONTEXT": enum("c1"),                 # Argus R3
    "PP_SITES": sites,
    "PP_POPULATION_AU": rx(GUID),                           # Argus R2
    "PP_POPULATION_AUS": population_aus,
    "PP_POPULATION_EXCLUDE": exclude,
    "PP_MANAGER_SOURCE": enum("entra", "hr"),
    "PP_MANAGER_SCOPE": manager_scope,
    "PP_ROSTER_OWNER_AUDIENCE": rx(GUID + "|api://" + GUID),
    "PP_ROSTER_OWNER_TENANT_ID": rx(GUID),
    "PP_TP_EMPLOYEE_TYPES": rx(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}(,[A-Za-z0-9 ][A-Za-z0-9 ._-]{0,63}){0,9}"),  # app: each <= 64
    "PP_TP_BU_ATTRIBUTE": rx(r"companyName|department|extensionAttribute([1-9]|1[0-5])"),
    "ENTRA_TENANT_ID": rx(GUID),
    "ENTRA_CLIENT_ID": rx(GUID),
    "ENTRA_CERT_THUMBPRINT_SHA256": rx(r"[0-9a-fA-F]{64}"),
    "PP_API_SCOPE": rx(r"api://" + GUID + r"/[A-Za-z_.]{1,64}"),
    "PP_API_AUDIENCE": rx(GUID + "|api://" + GUID),
    "PP_API_SCOPE_NAME": rx(r"[A-Za-z_.]{1,64}"),
    "PP_WEB_CLIENT_ID": rx(GUID),
    "PP_API_CLIENT_ID": rx(GUID),
    "ROSTER_SYNC_TENANT_ID": rx(GUID),
    "ROSTER_SYNC_CLIENT_ID": rx(GUID),
    "ROSTER_SYNC_CERT_THUMBPRINT_SHA256": rx(r"[0-9a-fA-F]{64}"),
    "PP_PORTAL_CLIENT_ID": rx(GUID),
    "PORTAL_CERT_THUMBPRINT_SHA256": rx(r"[0-9a-fA-F]{64}"),
    "PP_GRAPH_SCOPES": enum("granular", "broad"),
    "PP_PIM_MODE": enum("group", "role"),
    "PP_CONFIRM_PRESET": enum("lean", "standard"),
    "PP_SITE_SOURCE": enum("config", "portal"),
    "PP_SYNC_REGION": enum("EU", "APAC"),
    "PP_DOCUMENT_CATEGORIES": rx(r"[a-z_]{2,40}(,[a-z_]{2,40}){0,20}"),
    "PP_ROSTER_OPERATOR_AUTH": enum("token"),
    "PP_ROSTER_TWO_PERSON": enum("1", "true", "yes", "on"),
    "SUPPORT_CONTACT": rx(r"[A-Za-z0-9 .,()'+-]{1,120}"),
    "STEPUP_PER_TAP": enum("true", "1", "yes"),
}
for k in ("ATTESTATION_VALID_SECONDS", "LOANER_HOURS", "MAX_TAPS_PER_CHAMPION_PER_HOUR", "PP_IMPORT_CHANGE_MIN_ROWS",
          "PP_IMPORT_MAX_BYTES", "PP_IMPORT_MAX_CHANGE_PERCENT", "PP_IMPORT_MAX_ROWS", "PP_IMPORT_PLANNED_FUTURE_DAYS",
          "PP_IMPORT_PLANNED_PAST_DAYS", "ROSTER_CARRY_OVER_HOURS", "ROSTER_RETENTION_DAYS", "SESSION_IDLE_MINUTES",
          "SESSION_MAX_HOURS", "SHIFT_DEFAULT_HOURS", "SHIFT_MAX_HOURS", "SHIFT_MAX_WAIT_MINUTES", "SHIFT_POLL_SECONDS",
          "SHIFT_SLOW_MINUTES", "STEPUP_MAX_AGE_SECONDS", "TAP_DISPLAY_MAX_SECONDS", "TAP_DISPLAY_SECONDS",
          "TAP_LIFETIME_MAX_MINUTES", "TAP_LIFETIME_MINUTES"):
    S[k] = intr(0, 50_000_000)
TUNING = {k for k in S if k not in {
    "PP_MODE", "PP_PRIVILEGE_MODE", "PP_SITES", "PP_POPULATION_AU", "PP_ROSTER_OWNER_AUDIENCE", "PP_ROSTER_OWNER_TENANT_ID",
    "ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_CERT_THUMBPRINT_SHA256", "PP_API_SCOPE", "PP_API_AUDIENCE", "PP_API_SCOPE_NAME",
    "PP_WEB_CLIENT_ID", "PP_API_CLIENT_ID", "ROSTER_SYNC_TENANT_ID", "ROSTER_SYNC_CLIENT_ID", "ROSTER_SYNC_CERT_THUMBPRINT_SHA256",
    "PP_PORTAL_CLIENT_ID", "PORTAL_CERT_THUMBPRINT_SHA256"}}

COMMON_REQ = {"PP_MODE", "PP_PRIVILEGE_MODE", "PP_SITES", "PP_POPULATION_AU", "PP_ROSTER_OWNER_AUDIENCE", "PP_ROSTER_OWNER_TENANT_ID"}
REQUIRED = {
    "web": COMMON_REQ | {"ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_CERT_THUMBPRINT_SHA256", "PP_API_SCOPE"},
    "api": COMMON_REQ | {"ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_CERT_THUMBPRINT_SHA256", "PP_API_AUDIENCE", "PP_WEB_CLIENT_ID"},
    "roster-sync": COMMON_REQ | {"ROSTER_SYNC_TENANT_ID", "ROSTER_SYNC_CLIENT_ID", "ROSTER_SYNC_CERT_THUMBPRINT_SHA256"},
    "portal": COMMON_REQ | {"PP_PORTAL_CLIENT_ID", "PORTAL_CERT_THUMBPRINT_SHA256", "ROSTER_SYNC_TENANT_ID",
                            "ROSTER_SYNC_CLIENT_ID", "ROSTER_SYNC_CERT_THUMBPRINT_SHA256"},
}
OPTIONAL = {
    "web": TUNING | {"PP_API_SCOPE_NAME"},
    "api": TUNING | {"PP_API_SCOPE_NAME"},
    "roster-sync": TUNING | {"PP_API_CLIENT_ID", "ENTRA_CLIENT_ID", "ENTRA_TENANT_ID"},   # sync refuses equal ids
    "portal": TUNING | {"PP_API_CLIENT_ID", "ENTRA_CLIENT_ID", "ENTRA_TENANT_ID"},
}
# Checked here, then dropped (the Deployment sets them).
KEY_PATHS = {"ENTRA_CERT_PRIVATE_KEY_PATH": "/etc/passkey-point/entra/key.pem",
             "ROSTER_SYNC_CERT_PRIVATE_KEY_PATH": "/etc/passkey-point/entra/key.pem",
             "PORTAL_CERT_PRIVATE_KEY_PATH": "/etc/passkey-point/entra-portal/key.pem"}
WEB_O, PORTAL_O = f"https://passkey-point-lab.{DOMAIN}", f"https://passkey-point-portal-lab.{DOMAIN}"
# Per workload: the portal's own PP_PUBLIC_ORIGIN is the portal origin (it reads PP_PORTAL_PUBLIC_ORIGIN first).
ORIGINS = {"web": {"PP_PUBLIC_ORIGIN": WEB_O}, "api": {"PP_PUBLIC_ORIGIN": WEB_O}, "roster-sync": {"PP_PUBLIC_ORIGIN": WEB_O},
           "portal": {"PP_PUBLIC_ORIGIN": PORTAL_O, "PP_PORTAL_PUBLIC_ORIGIN": PORTAL_O}}
# Runtime keys the Deployments set explicitly: accepted ONLY with exactly our value, then dropped.
RUNTIME = {"web": {"PORT": "8080", "PP_DATA_DIR": "/var/lib/passkey-point"},
           "api": {"PORT": "8443", "PP_DATA_DIR": "/var/lib/passkey-point", "PP_ROSTER_DIR": "/var/lib/passkey-point-roster", "PP_DB_ENGINE": "sqlite"},
           "roster-sync": {"PP_DATA_DIR": "/var/lib/passkey-point-roster", "PP_ROSTER_DIR": "/var/lib/passkey-point-roster", "PP_DB_ENGINE": "sqlite"},
           "portal": {"PORT": "8080", "PP_DATA_DIR": "/var/lib/passkey-point", "PP_ROSTER_DIR": "/var/lib/passkey-point-roster", "PP_DB_ENGINE": "sqlite"}}
DROP_ANY = {"PP_API_URL"}  # Mack's file carries the LAB address; ours = the in-cluster api Service

HARD = re.compile(r"^(NODE_|MSAL_|AZURE_|HTTPS?_PROXY$|NO_PROXY$|ALL_PROXY$)|_PROXY$|AUTHORITY|_HOST$|SECRET|TOKEN|PASSW|PASSPHRASE|"
                  r"COOKIE|SESSION_KEY|_KEY$|^PP_DELEGATED_PRODUCTION_OVERRIDE$|^PP_LOGS_INGESTION_|^PP_AUDIT_|^PP_PORTAL_URL$|"
                  r"^PP_DB_|^PP_MOCK_|^PP_TLS_|^PP_POLICY_FILE$|^PP_TP_EXCEPTIONS_FILE$|^THEME_DIR$|^PP_SCREENSHOT_MODE$|"
                  r"^PP_ROSTER_READONLY$|^PP_REGION_MAP$|^PP_ALLOW_PLAIN_HTTP$")

def secret_shaped(k, v):
    if "-----BEGIN" in v: return "PEM block"
    if re.search(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.", v): return "JWT"
    if "Q~" in v: return "Entra client-secret format (Q~)"
    if not k.endswith("_THUMBPRINT_SHA256") and re.search(r"(?<![0-9a-fA-F-])[0-9a-fA-F]{40,}(?![0-9a-fA-F-])", v): return "long hex outside a thumbprint key"
    rest = re.sub(GUID, "", v).replace("api://", "")  # GUIDs and api:// scopes are expected, not tokens
    if re.search(r"[A-Za-z0-9+/_-]{40,}={0,2}", rest) and not re.fullmatch(r"[0-9a-fA-F]{64}", v): return "long base64-like token"
    return None

def parse(path, errors, f):
    env, seen = {}, set()
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.rstrip("\n").strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:]
        m = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", line)
        if not m:
            errors.append(f"{f}:{n}: not KEY=VALUE"); continue
        k, v = m.group(1), m.group(2)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        if k in seen:
            errors.append(f"{f}: duplicate key {k}"); continue
        seen.add(k); env[k] = v
    if not env:
        errors.append(f"{f}: empty file")
    return env

def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    src, check = sys.argv[1], "--check" in sys.argv[2:]
    errors, rendered, notes, h = [], {}, [], hashlib.sha256()
    for f, w in FILES.items():
        p = os.path.join(src, f"passkey-point.lab.{f}.env")
        if not os.path.isfile(p):
            errors.append(f"missing {p}"); continue
        h.update(open(p, "rb").read())
        env, keep = parse(p, errors, f), {}
        for k, v in env.items():
            why = secret_shaped(k, v)
            if why:
                errors.append(f"{f}: {k}: value is secret-shaped ({why})"); continue
            if k in KEY_PATHS:
                if v != KEY_PATHS[k]: errors.append(f"{f}: {k}={v} != mount path {KEY_PATHS[k]}")
                else: notes.append(f"{f}: {k} checked + dropped (Deployment sets it)")
                continue
            if k in ORIGINS[f]:
                if v.rstrip("/") != ORIGINS[f][k]: errors.append(f"{f}: {k}={v} != route origin {ORIGINS[f][k]} (redirect URI)")
                else: notes.append(f"{f}: {k} checked + dropped (Deployment sets it)")
                continue
            if k in RUNTIME[f]:
                if v != RUNTIME[f][k]: errors.append(f"{f}: {k}={v} != the Deployment's {RUNTIME[f][k]}")
                else: notes.append(f"{f}: {k} checked + dropped (Deployment sets it)")
                continue
            if k in DROP_ANY:
                notes.append(f"{f}: {k} dropped (Deployment sets the in-cluster api URL)"); continue
            if HARD.search(k):
                errors.append(f"{f}: {k} is hard-refused (secret/runtime/egress/override class)"); continue
            if k not in REQUIRED[f] and k not in OPTIONAL[f]:
                errors.append(f"{f}: {k} is not on the {f} allow-list"); continue
            if v == "":
                errors.append(f"{f}: {k} is empty"); continue
            if not S[k](v):
                errors.append(f"{f}: {k} value does not match its shape"); continue
            if k == "PP_MODE":
                continue  # explicit in the Deployment; checked = entra
            keep[k] = v
        for k in sorted(REQUIRED[f]):
            if not env.get(k):
                errors.append(f"{f}: required key {k} missing or empty")
        rendered[w] = (f, keep)
    if errors:
        print("\n".join("FAIL  " + e for e in errors)); print("nothing written"); sys.exit(2)
    digest = h.hexdigest()
    for w, (f, keep) in rendered.items():
        lines = ["---", f"# RENDERED by hack/passkey-point/render-env.py from passkey-point.lab.{f}.env (non-secret, allow-listed).",
                 "# Do not edit by hand: re-render, commit, then `kubectl rollout restart` the Deployment (fixed name).",
                 "apiVersion: v1", "kind: ConfigMap", "metadata:", f"  name: passkey-point-{w}-env", "data:",
                 f'  {GUARD}: "sha256:{digest}"']
        for k in sorted(keep):
            lines.append(f"  {k}: {json.dumps(keep[k].replace('${', '$${'), ensure_ascii=False)}")
        out = os.path.join(OUT, f"env-{w}.yaml")
        if not check:
            open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
        print(f"OK    {w}: {len(keep)} keys -> {os.path.relpath(out, ROOT)}{' (check only)' if check else ''}")
        for k in sorted(keep):
            print(f"        {k}={keep[k]}")
    print(f"guard {GUARD}=sha256:{digest}")
    for n in notes:
        print("NOTE  " + n)

main()
