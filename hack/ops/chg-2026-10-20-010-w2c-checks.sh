# chg-2026-10-20-010 W2c post-checks as PURE predicates on recorded input (sourced by golive-w2c.sh and by
# hack/ops/chg-2026-10-20-010-test-w2c-checks.sh). Atlas 30-10: two harness faults in a row (stage A 65d2c336: the
# init-container secret check counted a ConfigMap env; A retry 12a9579d: "first move" assumed on an already seeded
# ledger), so every check is a function of files only, tested against today's real outputs and land-2 records.
# Each function returns 0 (green) or 1 (red) and prints nothing on success; no cluster access, no network.
# Inputs: pod JSON (kubectl get pod -o json, or a pod-template {spec: ...}), guard log text, ledger/marker/seed JSON,
# route records JSON ([[ts, route, rule, id_class], ...] or {"records": [...]}), CNP name lists, F6 tsv rows.
W2C_PY=/usr/bin/python3

# --- pod spec ----------------------------------------------------------------------------------------------------
# no init container gets secrets: no envFrom at all, no env with valueFrom.secretKeyRef (ConfigMap env is fine)
w2c_init_no_secret() { # $1 pod json
  [ "$(jq '[.spec.initContainers[]? | select(.envFrom or ([.env[]?.valueFrom.secretKeyRef] | map(select(.)) | length > 0))] | length' "$1")" = 0 ]; }
# container app: env HERMES_IMAGE == its image, tag@sha256 pinned; [$2 = the plugin's PINNED_IMAGE]
w2c_image_pinned() { # $1 pod json [$2 pinned image]
  local img env; img=$(jq -r '.spec.containers[] | select(.name=="app") | .image' "$1")
  env=$(jq -r '.spec.containers[] | select(.name=="app") | [.env[]? | select(.name=="HERMES_IMAGE") | .value] | if length == 1 then .[0] else "" end' "$1")
  [[ "$img" =~ ^[^[:space:]@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] && [ "$env" = "$img" ] && { [ -z "${2:-}" ] || [ "$env" = "$2" ]; }; }
# the app container mounts the SHARED ledger at /cloud-spend; only profiel-3's guard mounts its old ledger, read-only
w2c_ledger_mounts() { # $1 pod json $2 profile number
  $W2C_PY -I - "$1" "$2" <<'PY'
import json, sys
p, n = json.load(open(sys.argv[1]))["spec"], sys.argv[2]
vols = {v["name"]: v for v in p.get("volumes", [])}
cl = lambda name: (vols.get(name) or {}).get("persistentVolumeClaim") or {}
app = [c for c in p["containers"] if c["name"] == "app"][0]
am = {m["name"]: m["mountPath"] for m in app.get("volumeMounts") or []} if app.get("volumeMounts") is not None else None
init = [c for c in p.get("initContainers", []) if c["name"] == "cloud-spend-init"]
im = {m["name"]: m for m in (init[0].get("volumeMounts") or [])} if init else {}
ok = cl("cloud-spend").get("claimName") == "hermes-cloud-spend-shared" and "cloud-spend" in im and im["cloud-spend"]["mountPath"] == "/cloud-spend"
ok = ok and (am is None or (am.get("cloud-spend") == "/cloud-spend" and "cloud-spend-old" not in am))
if n == "3":
    ok = ok and cl("cloud-spend-old") == {"claimName": "hermes-profiel-cloud-spend-3", "readOnly": True} \
        and im.get("cloud-spend-old", {}).get("readOnly") is True
else:
    ok = ok and "cloud-spend-old" not in vols and not any((v.get("persistentVolumeClaim") or {}).get("claimName") == "hermes-profiel-cloud-spend-3" for v in vols.values())
sys.exit(0 if ok else 1)
PY
}

# --- settings, ledger, seed, guard ----------------------------------------------------------------------------
w2c_settings() { # $1 settings.json $2 profile number : budget 99, price_confirmed true, person profiel-N
  [ "$(jq -c '[.budget_usd, .price_confirmed, .person]' "$1")" = "[99,true,\"profiel-$2\"]" ]; }
w2c_ledger_schema() { # $1 ledger json : numbers only, the plugin's exact key set
  $W2C_PY -I -c 'import json,sys,math
d=json.load(open(sys.argv[1])); K={"month","usd","input_tokens","output_tokens","cache_read_tokens","cache_write_tokens","person_usd"}
num=lambda v: type(v) in (int,float) and math.isfinite(v) and v>=0
ok=isinstance(d,dict) and set(d)==K and set(d["person_usd"])=={"profiel-1","profiel-2","profiel-3"} and num(d["usd"]) and all(num(v) for v in d["person_usd"].values()) and all(type(d[k]) is int and d[k]>=0 for k in K-{"month","usd","person_usd"})
sys.exit(0 if ok else 1)' "$1" 2>/dev/null; }
w2c_seed() { # $1 seed json : written by the move
  jq -e '.source == "migrated" and (.usd|type) == "number" and (.month|test("^[0-9]{4}-[0-9]{2}$"))' "$1" >/dev/null 2>&1; }
# guard log of this start. $2: A = moved (first W2c start) OR kept (the volume was seeded by an earlier, reverted A);
# B/C = kept only. Any REFUSED line is red.
w2c_guard_ok() { # $1 guard log file $2 A|B|C
  grep -q 'REFUSED' "$1" && return 1
  case "$2" in
    A) grep -q -E '^cloud-spend-init: (moved: month\.json|shared month\.json present, kept)' "$1";;
    *) grep -q -E '^cloud-spend-init: shared month\.json present, kept' "$1";;
  esac; }
# the shared ledger total == the reference total (stage A: profiel-3's OWN ledger read just before the push)
w2c_total_equal() { # $1 ledger json (after) $2 ledger json (reference)
  $W2C_PY -I -c 'import json,sys; a,b=(json.load(open(p)) for p in sys.argv[1:3]); sys.exit(0 if a["usd"]==b["usd"] and a["person_usd"]==b["person_usd"] and a["input_tokens"]==b["input_tokens"] else 1)' "$1" "$2" 2>/dev/null; }
w2c_same_bytes() { cmp -s "$1" "$2"; }   # restart: the guard kept the ledger byte-for-byte

# --- network policies -------------------------------------------------------------------------------------------
# the cloud CNPs present == exactly the expected profiles ("" = none; "3"; "2,3"; ...)
w2c_cloud_cnps() { # $1 names json array $2 expected comma list
  local want got; want=$(echo "$2" | tr ',' '\n' | grep . | sed 's/^/hermes-profiel-/; s/$/-cloud/' | LC_ALL=C sort | paste -sd, -)
  got=$(jq -r '.[]' "$1" | grep -E '^hermes-profiel-[123]-cloud$' | LC_ALL=C sort | paste -sd, -)
  [ "$got" = "$want" ]; }
w2c_cnp_spec_eq() { # $1 live CNP json $2 repo CNP yaml-as-json : .spec equal
  [ "$(jq -cS .spec "$1")" = "$(jq -cS .spec "$2")" ]; }

# --- turns -----------------------------------------------------------------------------------------------------
_w2c_recs='import json,sys
def recs(p):
    d=json.load(open(p)); r=d["records"] if isinstance(d,dict) else d
    assert isinstance(r,list) and all(isinstance(x,list) and len(x)==4 and x[1] in ("cloud","studio") for x in r)
    return r'
# M3 fallback (cloud unreachable): exactly ONE studio/cloud_failed, no cloud route, any further records Studio
# (e.g. a tool follow-up); the shared ledger rose by exactly one reservation on this person, tokens unchanged; the
# failure-line count rose by exactly 1.
w2c_fallback() { # $1 recs $2 ledger before $3 ledger after $4 reserve usd $5 profile n $6 failure-line delta
  $W2C_PY -I -c "$_w2c_recs"'
r=recs(sys.argv[1]); a,b=(json.load(open(p)) for p in sys.argv[2:4]); res=float(sys.argv[4]); who="profiel-"+sys.argv[5]
cf=[x for x in r if x[1]=="studio" and x[2]=="cloud_failed"]
ok=len(cf)==1 and not any(x[1]=="cloud" or x[2]=="cloud_ok" for x in r) and all(x[1]=="studio" for x in r)
ok=ok and abs((b["usd"]-a["usd"])-res)<1e-9 and abs((b["person_usd"][who]-a["person_usd"][who])-res)<1e-9
ok=ok and b["input_tokens"]==a["input_tokens"] and all(b["person_usd"][k]==a["person_usd"][k] for k in a["person_usd"] if k!=who)
ok=ok and sys.argv[6]=="1"
sys.exit(0 if ok else 1)' "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null; }
# M4 cloud turn: B2 = exactly [cloud/cloud_ok]; C2 (web) = first cloud/cloud_ok, then >= 1 studio/private_context and
# nothing else. Ledger: usd and the person's amount rose by > 0 and <= one reservation per cloud call, tokens rose,
# other persons unchanged.
w2c_cloud_turn() { # $1 recs $2 ledger before $3 ledger after $4 reserve $5 profile n $6 plain|web
  $W2C_PY -I -c "$_w2c_recs"'
r=recs(sys.argv[1]); a,b=(json.load(open(p)) for p in sys.argv[2:4]); res=float(sys.argv[4]); who="profiel-"+sys.argv[5]
rules=[x[1]+"/"+x[2] for x in sorted(r)]
if sys.argv[6]=="plain": ok=rules==["cloud/cloud_ok"]
else: ok=len(rules)>=2 and rules[0]=="cloud/cloud_ok" and all(x=="studio/private_context" for x in rules[1:])
n=sum(1 for x in rules if x.startswith("cloud/"))
d=b["usd"]-a["usd"]; dp=b["person_usd"][who]-a["person_usd"][who]
ok=ok and 0<d<=n*res+1e-9 and abs(dp-d)<1e-9 and b["input_tokens"]>a["input_tokens"]
ok=ok and all(b["person_usd"][k]==a["person_usd"][k] for k in a["person_usd"] if k!=who)
sys.exit(0 if ok else 1)' "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null; }
# F6 rows (pturn): exactly $2 rows, all ok (a private turn that reached the cloud is a red row)
w2c_private_rows() { # $1 f6.tsv $2 expected rows
  [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ] && [ "$(awk -F'\t' '$3=="ok"' "$1" | wc -l | tr -d ' ')" = "$2" ]; }
# the records of one private turn window: none on the cloud
w2c_private_window() { # $1 recs
  $W2C_PY -I -c "$_w2c_recs"'
r=recs(sys.argv[1]); sys.exit(0 if r and all(x[1]=="studio" and not x[2].startswith("cloud") for x in r) else 1)' "$1" 2>/dev/null; }
# canary account model list: of the agents only its own
w2c_models_only() { # $1 /api/models json $2 profile n
  [ "$(jq -c '[.data[].id | select(startswith("hermes-agent"))]' "$1")" = "[\"hermes-agent-profiel-$2\"]" ]; }
w2c_http_answer() { # $1 http code $2 resp_meta line
  [ "$1" = 200 ] && grep -q 'content=yes' <<< "$2"; }
