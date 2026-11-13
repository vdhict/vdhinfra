# chg-2026-10-20-010 land 3, Argus R2: rollback of ONE group's attachment step by SNAPSHOT RESTORE (not
# --attachments-off, which would write features.notes=False although the groups had notes=True before).
# Runs inside the open-webui pod:  python3 - <group> <model> [verify]   stdin = the 0600 pre-snapshot JSON
#   {"groups": {name: {"permissions", "data"}}, "models": {id: {"meta", "params"}}}
# Restores the group's permissions and the model's meta.capabilities to the snapshot, keeps everything else (members,
# grants, filterIds), then reads back: group permissions and model capabilities equal the snapshot.
# Mode "verify": read back only. Prints booleans and hash prefixes only.
import copy, hashlib, json, os, sys, urllib.request

GROUP, MODEL = sys.argv[1], sys.argv[2]
VERIFY = len(sys.argv) > 3 and sys.argv[3] == "verify"
snap = json.load(sys.stdin)
U = "http://127.0.0.1:8080"


def req(m, p, b=None, t=None):
    h = {"Content-Type": "application/json"}
    if t:
        h["Authorization"] = "Bearer " + t
    r = urllib.request.Request(U + p, method=m, headers=h, data=json.dumps(b).encode() if b is not None else None)
    with urllib.request.urlopen(r, timeout=60) as x:
        return json.loads(x.read().decode() or "null")


def h(x):
    return hashlib.sha256(json.dumps(x, sort_keys=True).encode()).hexdigest()[:12]


tok = req("POST", "/api/v1/auths/signin", {"email": os.environ["WEBUI_ADMIN_EMAIL"], "password": os.environ["WEBUI_ADMIN_PASSWORD"]})["token"]


def state():
    g = {x["name"]: x for x in req("GET", "/api/v1/groups/", t=tok)}[GROUP]
    m = {x["id"]: x for x in (req("GET", "/api/v1/models/export", t=tok) or []) + (req("GET", "/api/v1/models/base", t=tok) or [])}[MODEL]
    return g, m


def caps(meta):
    c = (meta or {}).get("capabilities") or {}
    return {k: c.get(k) for k in ("vision", "file_upload", "file_context")}


g, m = state()
want_p, want_c = snap["groups"][GROUP]["permissions"], caps(snap["models"][MODEL]["meta"])
if not VERIFY:
    req("POST", f"/api/v1/groups/id/{g['id']}/update", {"name": g["name"], "description": g.get("description") or "",
                                                       "permissions": copy.deepcopy(want_p), "data": g.get("data")}, tok)
    meta = copy.deepcopy(m.get("meta") or {})
    c = dict(meta.get("capabilities") or {})
    for k, v in want_c.items():
        if v is None:
            c.pop(k, None)
        else:
            c[k] = v
    meta["capabilities"] = c
    req("POST", "/api/v1/models/model/update", {"id": m["id"], "name": m["name"], "base_model_id": m.get("base_model_id"),
                                                "meta": meta, "params": m.get("params"), "is_active": m.get("is_active")}, tok)
g, m = state()
p_ok = h(g.get("permissions")) == h(want_p)
c_now = caps(m.get("meta"))
c_ok = all((c_now[k] or False) == (want_c[k] or False) for k in want_c)
notes = ((g.get("permissions") or {}).get("features") or {}).get("notes")
print(GROUP, "permissions == snapshot:", p_ok, "(sha", h(g.get("permissions")), ")", "features.notes:", notes,
      "| model capabilities == snapshot:", c_ok, c_now)
print("RESTORE", "OK" if p_ok and c_ok else "MISMATCH")
sys.exit(0 if p_ok and c_ok else 1)
