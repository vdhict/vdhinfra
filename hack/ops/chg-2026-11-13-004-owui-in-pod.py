# chg-2026-11-13-004 (tsk-2026-11-13-103, Mack 4c6e9d8): Open WebUI records for hermes-profiel-4, the owner's test profile.
# Runs inside the open-webui pod: kubectl exec -i ... -- python3 -c "<this>" <mode> < spec.json
# stdin = JSON {"fid","content","sha256","rollback_content","rollback_sha256","fam":[p1..p3],"model":{"id","naam"},
#               "group","template_group","owner_email","conn_url","conn_key","demo_id"}
#   conn_key is the generated gateway key of hermes-profiel-4 (piped from its Secret); owner_email identifies the owner's
#   account. Neither is ever printed. Prints ids, booleans, counts and hash prefixes only.
# mode: dry | apply | verify | rollback
#   apply   : function -> new content (4 keys), active, not global; connection conn_url appended (or its key corrected);
#             group created with the template group's permissions + the owner as its only member; model record
#             (no base model, stream_response false, exactly one read grant = the group, filterIds [fid]);
#             the inactive demo model deleted.
#   rollback: model inactive + grants emptied; function back to rollback_content; connection removed. Group kept (inert).
# Never uses owui-apply: its write mode also switches the attachment permissions Argus blocked (land 3).
import copy, hashlib, json, os, sys, urllib.error, urllib.request

MODE = sys.argv[1]
assert MODE in ("dry", "apply", "verify", "rollback"), MODE
spec = json.load(sys.stdin)
FID, CONTENT, FAM, MODEL, GROUP = spec["fid"], spec["content"], spec["fam"], spec["model"], spec["group"]
assert hashlib.sha256(CONTENT.encode()).hexdigest() == spec["sha256"], "content hash mismatch"
assert hashlib.sha256(spec["rollback_content"].encode()).hexdigest() == spec["rollback_sha256"], "rollback hash mismatch"
KEY, URL = spec["conn_key"], spec["conn_url"]
assert len(KEY) == 48 and KEY.isalnum(), "gateway key has the wrong shape"
U = "http://127.0.0.1:8080"
META_ALLOW = ("capabilities", "profile_image_url", "suggestion_prompts", "tags")
KEYS = ("meta", "params", "access_grants", "base_model_id", "is_active", "name")


def req(method, path, body=None, tok=None):
    h = {"Content-Type": "application/json"}
    if tok:
        h["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(U + path, method=method, headers=h,
                               data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=60) as x:
            raw = x.read().decode()
            try:
                return json.loads(raw or "null")
            except ValueError:
                return None
    except urllib.error.HTTPError as e:
        if e.code in (401, 404) and method == "GET":
            return None
        raise SystemExit(f"API {e.code} {method} {path.split('?')[0]}: {e.read().decode(errors='replace')[:160]}")


def h(x):
    return hashlib.sha256(json.dumps(x, sort_keys=True).encode()).hexdigest()[:12]


tok = req("POST", "/api/v1/auths/signin",
          {"email": os.environ["WEBUI_ADMIN_EMAIL"], "password": os.environ["WEBUI_ADMIN_PASSWORD"]})["token"]


def allmodels():
    return {m["id"]: m for m in (req("GET", "/api/v1/models/export", tok=tok) or []) + (req("GET", "/api/v1/models/base", tok=tok) or [])}


def fn():
    lst = req("GET", "/api/v1/functions/", tok=tok) or []
    return req("GET", f"/api/v1/functions/id/{FID}", tok=tok) if any(x.get("id") == FID for x in lst) else None


def groups():
    return {g["name"]: g for g in (req("GET", "/api/v1/groups/", tok=tok) or [])}


def conf():
    return req("GET", "/openai/config", tok=tok)


others = [x.get("id") for x in (req("GET", "/api/v1/functions/", tok=tok) or []) if x.get("id") != FID]
print("other functions:", len(others))
if others:
    raise SystemExit("STOP: another Function exists (Argus C4 of chg-2026-11-13-003)")
users = req("GET", "/api/v1/users/all", tok=tok) or {}
users = users.get("users", users) if isinstance(users, dict) else users
match = [u for u in users if (u.get("email") or "").lower() == spec["owner_email"].lower()]
print("owner match:", len(match), "role:", match[0].get("role") if match else None)
assert len(match) == 1 and match[0].get("role") == "admin", "owner account not found exactly once as admin"
OWNER = match[0]["id"]
before = allmodels()
fam_before = {m: {k: h(before[m].get(k)) for k in KEYS} for m in FAM}


def fam_conn(c):   # Argus B1: keys and per-connection configs of positions 0..3 (the family + Studio connections)
    cfg = c.get("OPENAI_API_CONFIGS") or {}
    return h(list(c["OPENAI_API_KEYS"][:4])), h({k: cfg.get(k) for k in ("0", "1", "2", "3")})


conn_before = fam_conn(conf())
print("family connections pre: keys", conn_before[0], "configs", conn_before[1])
assert all(m in before for m in FAM), "a family model is missing"

if MODE in ("dry", "apply"):
    f, c, g = fn(), conf(), groups()
    print("function content differs:", (f or {}).get("content") != CONTENT)
    print("connection present:", URL in c["OPENAI_API_BASE_URLS"], "connections:", len(c["OPENAI_API_BASE_URLS"]))
    print("group exists:", GROUP in g, "template group exists:", spec["template_group"] in g)
    print("model exists:", MODEL["id"] in before, "demo exists:", spec["demo_id"] in before)
    if MODE == "apply":
        # 1. function (content first, then flags - toggles flip, so only after reading the state)
        if f.get("content") != CONTENT:
            req("POST", f"/api/v1/functions/id/{FID}/update",
                {"id": FID, "name": "Gezin voortgang", "content": CONTENT, "meta": {"description": "Neutrale voortgang per model"}}, tok)
        if fn().get("is_active") is False:
            req("POST", f"/api/v1/functions/id/{FID}/toggle", tok=tok)
        if fn().get("is_global") is True:
            req("POST", f"/api/v1/functions/id/{FID}/toggle/global", tok=tok)
        # 2. connection: append, never reorder (positions 0..3 stay exactly as they are)
        urls, keys = list(c["OPENAI_API_BASE_URLS"]), list(c["OPENAI_API_KEYS"])
        keys += [""] * (len(urls) - len(keys))
        if URL in urls:
            i = urls.index(URL)
            if keys[i] != KEY:
                keys[i] = KEY
        else:
            assert str(len(urls)) not in (c.get("OPENAI_API_CONFIGS") or {}), "stale per-connection config at the new index"
            urls.append(URL); keys.append(KEY)
        if (urls, keys) != (c["OPENAI_API_BASE_URLS"], c["OPENAI_API_KEYS"]):
            req("POST", "/openai/config/update", {"ENABLE_OPENAI_API": c.get("ENABLE_OPENAI_API"), "OPENAI_API_BASE_URLS": urls,
                                                   "OPENAI_API_KEYS": keys, "OPENAI_API_CONFIGS": c.get("OPENAI_API_CONFIGS") or {}}, tok)
        # 3. group = template group's permissions and data, owner as the only member
        g = groups()
        if GROUP not in g:
            t = g[spec["template_group"]]
            req("POST", "/api/v1/groups/create", {"name": GROUP, "description": "Testprofiel (chg-2026-11-13-004)",
                                                  "permissions": copy.deepcopy(t.get("permissions")), "data": copy.deepcopy(t.get("data"))}, tok)
            g = groups()
        gid = g[GROUP]["id"]
        req("POST", f"/api/v1/groups/id/{gid}/users/add", {"user_ids": [OWNER]}, tok)
        # 4. model record: p1's meta (capabilities etc.) with its own description and filter list
        if MODEL["id"] not in allmodels():
            # Argus B2: allow-list, never a whole-meta copy (no knowledge/tool/skill/action reference may travel)
            src = before[FAM[0]].get("meta") or {}
            refs = [k for k in ("knowledge", "toolIds", "skillIds", "actionIds") if src.get(k)]
            assert not refs, f"profiel-1 meta carries resource references: {refs}"
            meta = {k: copy.deepcopy(src[k]) for k in META_ALLOW if k in src}
            meta["description"] = "Testprofiel: zelfde opzet als Mijn team, zonder kennis"
            meta["filterIds"] = [FID]
            req("POST", "/api/v1/models/create", {
                "id": MODEL["id"], "name": MODEL["naam"], "base_model_id": None, "meta": meta,
                "params": {"stream_response": False},
                "access_grants": [{"principal_type": "group", "principal_id": gid, "permission": "read"}]}, tok)
        # 5. the inactive demo record goes (team data)
        if spec["demo_id"] in allmodels():
            req("POST", "/api/v1/models/model/delete", {"id": spec["demo_id"]}, tok)

if MODE == "rollback":
    m = allmodels().get(MODEL["id"])
    if m:
        req("POST", "/api/v1/models/model/access/update", {"id": MODEL["id"], "access_grants": []}, tok)
        if allmodels()[MODEL["id"]].get("is_active") is not False:
            req("POST", f"/api/v1/models/model/toggle?id={MODEL['id']}", tok=tok)
    if (fn() or {}).get("content") != spec["rollback_content"]:
        req("POST", f"/api/v1/functions/id/{FID}/update",
            {"id": FID, "name": "Gezin voortgang", "content": spec["rollback_content"], "meta": {"description": "Neutrale voortgang per model"}}, tok)
    c = conf()
    if URL in c["OPENAI_API_BASE_URLS"]:
        i = c["OPENAI_API_BASE_URLS"].index(URL)
        urls = [u for j, u in enumerate(c["OPENAI_API_BASE_URLS"]) if j != i]
        keys = [k for j, k in enumerate(c["OPENAI_API_KEYS"]) if j != i]
        cfg = {}
        for k, v in (c.get("OPENAI_API_CONFIGS") or {}).items():   # Argus B1: drop only index i, shift higher ones down
            if not k.isdigit():
                cfg[k] = v
            elif int(k) < i:
                cfg[k] = v
            elif int(k) > i:
                cfg[str(int(k) - 1)] = v
        req("POST", "/openai/config/update", {"ENABLE_OPENAI_API": c.get("ENABLE_OPENAI_API"), "OPENAI_API_BASE_URLS": urls,
                                               "OPENAI_API_KEYS": keys, "OPENAI_API_CONFIGS": cfg}, tok)
    print("rollback steps sent")

# ---- readback (every mode)
after, f, c, g = allmodels(), fn(), conf(), groups()
err = []
want_sha = spec["rollback_sha256"] if MODE == "rollback" else spec["sha256"]
fsha = hashlib.sha256(((f or {}).get("content") or "").encode()).hexdigest()
if MODE != "dry":
    if fsha != want_sha:
        err.append("function content")
    if not f or f.get("is_active") is not True or f.get("is_global") is not False:
        err.append("function not active or global")
for m in FAM:
    if {k: h(after[m].get(k)) for k in KEYS} != fam_before[m]:
        err.append(f"{m} changed")
urls = c["OPENAI_API_BASE_URLS"]
print("connections:", len(urls), "first four unchanged:", urls[:4] == ["http://hermes-profiel-1:8642/v1", "http://hermes-profiel-2:8642/v1",
                                                                      "http://hermes-profiel-3:8642/v1", "https://api.bluejungle.net/v1"])
conn_after = fam_conn(c)
print("family connections post: keys", conn_after[0], "configs", conn_after[1], "unchanged:", conn_after == conn_before)
if conn_after != conn_before:
    err.append("family connection keys/configs changed")
if urls[:4] != ["http://hermes-profiel-1:8642/v1", "http://hermes-profiel-2:8642/v1", "http://hermes-profiel-3:8642/v1", "https://api.bluejungle.net/v1"]:
    err.append("family connections changed")
carry = sorted(m for m, x in after.items() if FID in ((x.get("meta") or {}).get("filterIds") or []) and x.get("is_active") is not False)
print("active models with filter:", carry)
if MODE in ("apply", "verify"):
    present = URL in urls
    keyok = present and c["OPENAI_API_KEYS"][urls.index(URL)] == KEY
    print("p4 connection present:", present, "key matches the Secret:", keyok)
    if not keyok:
        err.append("p4 connection or key")
    gid = (g.get(GROUP) or {}).get("id")
    if not gid:
        err.append("group missing")
    else:
        mem = req("POST", f"/api/v1/groups/id/{gid}/users", {}, tok) or []
        ids = [u.get("id") for u in mem] if isinstance(mem, list) else []
        perm_same = h(g[GROUP].get("permissions")) == h(g[spec["template_group"]].get("permissions"))
        print("group: members", len(ids), "owner only:", ids == [OWNER], "permissions == template:", perm_same,
              "file_upload:", ((g[GROUP].get("permissions") or {}).get("chat") or {}).get("file_upload"))
        if ids != [OWNER]:
            err.append("group members")
        if not perm_same:
            err.append("group permissions")
        if ((g[GROUP].get("permissions") or {}).get("chat") or {}).get("file_upload") is not False:
            err.append("group file_upload not False")
    d = after.get(MODEL["id"])
    if not d:
        err.append("model missing")
    else:
        gr = d.get("access_grants") or []
        checks = {"name": d.get("name") == MODEL["naam"], "no_base": d.get("base_model_id") is None,
                  "stream_false": (d.get("params") or {}).get("stream_response") is False,
                  "one_group_read_grant": len(gr) == 1 and gr[0].get("principal_type") == "group" and gr[0].get("permission") == "read"
                                          and gr[0].get("principal_id") == gid,
                  "no_star": all(x.get("principal_id") != "*" for x in gr),
                  "filterIds": (d.get("meta") or {}).get("filterIds") == [FID], "active": d.get("is_active") is not False,
                  "meta_allow_list": not ({k for k, v in (d.get("meta") or {}).items() if v not in (None, [], {}, "")}
                                          - set(META_ALLOW) - {"description", "filterIds"})}
        print("model meta keys:", sorted(k for k, v in (d.get("meta") or {}).items() if v not in (None, [], {}, "")))
        print("model:", checks)
        err += [f"model {k}" for k, v in checks.items() if not v]
    if spec["demo_id"] in after:
        err.append("demo record still present")
    if carry != sorted(FAM + [MODEL["id"]]):
        err.append("filter carriers differ")
if MODE == "rollback":
    d = after.get(MODEL["id"])
    if d and (d.get("is_active") is not False or d.get("access_grants")):
        err.append("model still active or granted")
    if URL in urls:
        err.append("connection still present")
print("function:", {"active": (f or {}).get("is_active"), "global": (f or {}).get("is_global"), "sha": fsha[:12]})
print("family models unchanged:", all(f"{m} changed" not in err for m in FAM))
print("VERIFY", "0 fouten" if not err else err)
try:
    req("GET", "/api/v1/auths/signout", tok=tok)
except SystemExit:
    pass
