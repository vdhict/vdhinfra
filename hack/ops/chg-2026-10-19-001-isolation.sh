#!/usr/bin/env bash
# chg-2026-10-19-001 isolation matrix: from inside each hermes-profiel-N pod, with ITS OWN KENNIS_TOKEN (read from the
# pod env, never printed), POST /v1/zoek for every collection, plus one request without a token.
# Prints status codes and fragment COUNTS only (never fragment text). Exit 1 on any deviation.
# Expected (after step 1): p1 zeevaart 200, all others 403; p2 huiswerk-2 + lesstof-2 200, rest 403;
#                          p3 huiswerk-3 + lesstof-3 200, rest 403; no token 401 everywhere.
#   hack/ops/chg-2026-10-19-001-isolation.sh [pre]   ('pre' = before step 1: lesstof-* is 403 for every token)
set -uo pipefail
PHASE="${1:-post}"
PY='
import json, os, sys, urllib.request, urllib.error
url = os.environ.get("KENNIS_URL", "http://kennisdienst.family-ai.svc.cluster.local:8088").rstrip("/") + "/v1/zoek"
tok = os.environ.get("KENNIS_TOKEN", "")
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def q(col, token):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, method="POST", headers=h,
                               data=json.dumps({"collectie": col, "vraag": "wiskunde binnengebied van een cirkel", "k": 3}).encode())
    try:
        with op.open(r, timeout=30) as resp:
            return [resp.status, len(json.load(resp).get("fragmenten", []))]
    except urllib.error.HTTPError as e:
        return [e.code, 0]
    except Exception as e:
        return [type(e).__name__, 0]
out = {"has_token": bool(tok)}
for c in ("zeevaart", "huiswerk-profiel-2", "huiswerk-profiel-3", "lesstof-profiel-2", "lesstof-profiel-3"):
    out[c] = q(c, tok) if tok else "no-token-in-pod"
out["no_token_lesstof-profiel-2"] = q("lesstof-profiel-2", "")
out["no_token_lesstof-profiel-3"] = q("lesstof-profiel-3", "")
print(json.dumps(out))
'
rc=0
for n in 1 2 3; do
  line=$(kubectl -n family-ai exec "deploy/hermes-profiel-$n" -c app -- python3 -c "$PY" 2>&1 | tail -1)
  echo "profiel-$n $line"
  python3 -I - "$n" "$PHASE" "$line" <<'CHK' || rc=1
import json, sys
n, phase, d = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
own = {"1": {"zeevaart"}, "2": {"huiswerk-profiel-2"}, "3": {"huiswerk-profiel-3"}}[n]
if phase != "pre" and n != "1":
    own = own | {"lesstof-profiel-" + n}
bad = [c for c in ("zeevaart", "huiswerk-profiel-2", "huiswerk-profiel-3", "lesstof-profiel-2", "lesstof-profiel-3")
       if d[c][0] != (200 if c in own else 403) or (c in own and c.startswith("lesstof") and d[c][1] < 1)]
bad += [k for k in d if k.startswith("no_token") and d[k][0] != 401]
if not d["has_token"]: bad.append("no token in pod")
print(f"  profiel-{n}: {'PASS' if not bad else 'FAIL ' + ','.join(bad)}")
sys.exit(1 if bad else 0)
CHK
done
exit $rc
