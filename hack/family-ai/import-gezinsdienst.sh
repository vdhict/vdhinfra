#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Import Mack's gezinsdienst into the repo (chg-2026-09-26-001).
#
#   hack/family-ai/import-gezinsdienst.sh <delivery-root>
#
#   gezinsdienst.py, teksten.json -> app/files/ in CLEAR (ConfigMap). Checked:
#                                    stdlib-only imports, valid JSON, and NO
#                                    string from config.json's names / page map
#                                    appears in them.
#   config.json                   -> app/config.sops.yaml, SOPS-ENCRYPTED
#                                    Secret. It holds the children's names and
#                                    the login->profile map; this repo is
#                                    PUBLIC. It NEVER lands in clear: the
#                                    plaintext exists only in a mktemp dir.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
. "$(dirname "$0")/lib.sh"
SRC="${1:-}"; [ -n "$SRC" ] || die "usage: $0 <delivery-root>"
command -v sops >/dev/null || die "sops not on PATH (mise install)"
verify_delivery "$SRC"
G="$SRC/gezinsdienst"
ROOT="$(git rev-parse --show-toplevel)"
APP="$ROOT/kubernetes/main/apps/family-ai/gezinsdienst/app"
for f in gezinsdienst.py config.json teksten.json; do [ -f "$G/$f" ] || die "missing gezinsdienst/$f"; done
python3 -m json.tool "$G/config.json" >/dev/null || die "config.json is not valid JSON"
python3 -m json.tool "$G/teksten.json" >/dev/null || die "teksten.json is not valid JSON"
python3 - "$G" <<'PY' || die "check failed (see above)"
import ast, json, os, re, sys
g = sys.argv[1]
tree = ast.parse(open(os.path.join(g, "gezinsdienst.py")).read())
mods = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import): mods |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module: mods.add(n.module.split(".")[0])
bad = sorted(m for m in mods if m not in sys.stdlib_module_names and m != "__future__")
if bad: print("NON-STDLIB imports:", len(bad)); sys.exit(1)
c = json.load(open(os.path.join(g, "config.json")))
ident = {str(o.get("naam", "")).lower() for o in c.get("onderwerpen", {}).values()}
for k, v in c.get("toegang", {}).get("eigen_pagina", {}).items():
    ident |= {str(k).lower(), str(v).lower()}
ident = {i for i in ident if i and not re.fullmatch(r"profiel-\d+", i)}
for f in ("gezinsdienst.py", "teksten.json"):
    s = open(os.path.join(g, f), errors="ignore").read().lower()
    n = sum(1 for i in ident if re.search(r"\b" + re.escape(i) + r"\b", s))
    if n: print(f"{f}: contains {n} identifying string(s) from config.json - refusing to ship it in clear"); sys.exit(1)
print("stdlib-only, JSON valid, clear-text files free of config.json identifiers")
PY
cp "$G/gezinsdienst.py" "$G/teksten.json" "$APP/files/"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
{
  printf -- '---\n# gezinsdienst config.json (Mack'"'"'s delivery %s). Contains names and the\n' "$(basename "$SRC")"
  printf '# login->profile map: SOPS-encrypted, never in clear (public repo).\n'
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: gezinsdienst-config\n  annotations:\n    kustomize.toolkit.fluxcd.io/substitute: disabled\ntype: Opaque\ndata:\n'
  printf '  config.json: %s\n' "$(base64 < "$G/config.json" | tr -d '\n')"
} > "$TMP/config.sops.yaml"
sops_write "$TMP/config.sops.yaml" "$APP/config.sops.yaml"
( cd "$APP/files" && shasum -a 256 gezinsdienst.py teksten.json )
echo "import-gezinsdienst: config.json sha256 $(shasum -a 256 "$G/config.json" | cut -d' ' -f1) -> $APP/config.sops.yaml (encrypted)"
