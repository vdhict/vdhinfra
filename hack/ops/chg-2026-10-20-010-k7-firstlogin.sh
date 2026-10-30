#!/usr/bin/env bash
# chg-2026-10-20-010 K7 (Argus 30-10 09:04:20Z S1-S3): synthetic first login of a child account (gezin +
# owui-profiel-2) through Authelia into Open WebUI; see chg-2026-10-20-010-k7-firstlogin.py. Writes: one synthetic
# lldap user and its OWUI account, both deleted again and read back absent. The lldap admin credential is used for
# this one run only (one-off, logged under F29) and goes into the test process's env, never argv or a file.
#
#   hack/ops/chg-2026-10-20-010-k7-firstlogin.sh <family-ai checkout>   # the checkout holds content/profiles (the
#                                                                         # real profiel-2 username, never printed)
set -uo pipefail
FAI="${1:?family-ai checkout}"
CHG=chg-2026-10-20-010; REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"; HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${K7_PY:-$HOME/Code/pka-wires/_toolchains/open-webui-0.11.4-test/.venv/bin/python3}"   # has httpx + ldap3
TS=$(date -u +%Y%m%dT%H%M%SZ); EV="$REPO/ops/evidence/$CHG/k8s-k7-firstlogin-$TS.txt"; [ ! -e "$EV" ] || exit 1
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
P1=$((20000 + RANDOM % 10000)); P2=$((P1 + 1)); PIDS=""
kubectl -n security port-forward svc/lldap "$P1:8080" "$P2:5389" >/dev/null 2>&1 & PIDS="$!"
trap 'kill $PIDS 2>/dev/null' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 "$P1" 2>/dev/null && nc -z 127.0.0.1 "$P2" 2>/dev/null && break; sleep 1; done
OW=$(kubectl -n family-ai get pod -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
T=$(kubectl -n family-ai exec -i "$OW" -c app -- sh -c 'cd /app/backend && python3 - 2>/dev/null' <<'PY' | grep '^C010TOKEN ' | tail -1
import os, sqlite3
from datetime import timedelta
c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
rows = c.execute("select id, role from user where email = ?", (os.environ.get("WEBUI_ADMIN_EMAIL", "").strip(),)).fetchall()
if len(rows) == 1 and rows[0][1] == "admin":
    from open_webui.utils.auth import create_token
    print("C010TOKEN " + create_token({"id": rows[0][0]}, expires_delta=timedelta(minutes=20)))
PY
)
REAL=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["naam"].lower())' "$FAI/content/profiles/profiel-2/profile.json")
{ echo "$CHG K7 synthetic first login $TS (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"
  echo "lldap admin credential: one-off for this run (F29), env only; OWUI admin: in-pod create_token 20 min, never printed"
  LLDAP_URL="http://127.0.0.1:$P1" LLDAP_LDAP="127.0.0.1:$P2" LLDAP_BASE_DN="$(kubectl -n security get deploy lldap -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LLDAP_LDAP_BASE_DN")].value}')" \
  LLDAP_ADMIN="$(kubectl -n security get secret lldap-secret -o jsonpath='{.data.LLDAP_USER_DN}' | base64 -d)" \
  LLDAP_ADMIN_PASS="$(kubectl -n security get secret lldap-secret -o jsonpath='{.data.LLDAP_LDAP_USER_PASS}' | base64 -d)" \
  OWUI_ADMIN_KEY="${T#C010TOKEN }" CHAT=https://chat.bluejungle.net AUTH=https://auth.bluejungle.net K7_REAL_USER="$REAL" \
    "$PY" -I "$HERE/$CHG-k7-firstlogin.py" 2>&1; echo "rc=$?"; } | tee "$EV"
T=""; REAL=""
RES=$(grep -o 'RESULT K7 [A-Z]*' "$EV" | awk '{print $3}')
"$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg r "${RES:-RED}" --arg ev "${EV#$REPO/}" \
  '{step:"K7 synthetic first login (gezin + owui-profiel-2) through Authelia into OWUI; cleanup read back", result:$r, evidence:$ev,
    credential:"lldap admin one-off under F29, env only", authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
[ "${RES:-RED}" = GREEN ]
