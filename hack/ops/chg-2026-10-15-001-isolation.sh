#!/usr/bin/env bash
# chg-2026-10-15-001 T1-T3 (Argus C7): from inside each hermes-profiel-N pod, with ITS OWN KENNIS_TOKEN (read from the
# pod env, never printed), POST /v1/zoek for every collection (zeevaart, huiswerk-profiel-2, huiswerk-profiel-3), plus
# one request without a token. Prints status codes and fragment COUNTS only (never fragment text).
# Expected: profiel-1 200/403/403; profiel-2 403/200/403; profiel-3 403/403/200; no token 401 everywhere.
set -uo pipefail
PY='
import json, os, urllib.request, urllib.error
url = os.environ.get("KENNIS_URL", "http://kennisdienst.family-ai.svc.cluster.local:8088").rstrip("/") + "/v1/zoek"
tok = os.environ.get("KENNIS_TOKEN", "")
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def q(col, token):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, method="POST", headers=h,
                               data=json.dumps({"collectie": col, "vraag": "huiswerk morgen toets", "k": 3}).encode())
    try:
        with op.open(r, timeout=15) as resp:
            return resp.status, len(json.load(resp).get("fragmenten", []))
    except urllib.error.HTTPError as e:
        return e.code, 0
    except Exception as e:
        return type(e).__name__, 0
out = {"has_token": bool(tok)}
for c in ("zeevaart", "huiswerk-profiel-2", "huiswerk-profiel-3"):
    out[c] = q(c, tok) if tok else "no-token-in-pod"
out["no_token"] = q("zeevaart", "")
print(json.dumps(out))
'
for n in 1 2 3; do
  printf 'profiel-%s ' "$n"
  kubectl -n family-ai exec "deploy/hermes-profiel-$n" -c app -- python3 -c "$PY" 2>&1 | tail -1
done
