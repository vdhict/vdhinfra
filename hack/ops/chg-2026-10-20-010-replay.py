"""chg-2026-10-20-010 Argus 16:58:12Z (a) wis + (b) system text: in-pod replay in hermes-profiel-3, decision log only.

Run INSIDE the hermes-profiel-3 app container with the Hermes venv, input JSON on stdin:
  {"mode": "pre"|"post", "since": <epoch>, "pins": {"<rel path under plugins/>": sha256, ...},
   "files": {"<rel path>": base64}}      # pre only: family-cloud files from the bundle (not yet deployed)
pre:  gezin from the pod (deployed), family-cloud from stdin; post: both from /opt/data/plugins (deployed).
Every loaded file must hash-equal its bundle pin.

(b) The replay input is the system prompt this pod's own Hermes built and stored for its newest profiel-3 session
    (state.db, mode=ro; post: a session started at/after <since>, i.e. the canary's). It stays in memory, is never
    printed or stored. family-cloud's cloud_request() must turn it into exactly one system message whose sha256
    equals sha256(cloud-SOUL.strip() + "\\n\\n" + date_line()), and no other system/developer text.
(a) wis: the real gezin hook on "wis mijn geheugen" with ONLY wis_alles stubbed (records the call, wipes nothing);
    that turn and the next must route to the Studio by family-cloud's own wire/view/sticky checks.
Output: one JSON line of booleans and 12-char digest prefixes. Exit 0 only if every check holds.
"""
import base64
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import types

os.chdir("/opt/hermes")
sys.path.insert(0, "/opt/hermes")
inp = json.load(sys.stdin)
mode, pins, blobs = inp["mode"], inp["pins"], inp.get("files") or {}
P = "/opt/data/plugins/"
out, ok = {"mode": mode}, {}
sha = lambda b: hashlib.sha256(b).hexdigest()


def source(rel):
    if mode == "pre" and rel.startswith("model-providers/family-cloud/"):
        data = base64.b64decode(blobs[rel])
    else:
        data = open(P + rel, "rb").read()
    ok["pin " + rel] = sha(data) == pins[rel]
    return data


def load(rel, name):
    src = source(rel)
    m = types.ModuleType(name)
    m.__file__ = P + rel
    exec(compile(src, P + rel, "exec"), m.__dict__)
    return m


home = tempfile.mkdtemp(prefix="c010-replay-")   # gezin's home-mark file goes here, never into /opt/data
os.environ["HERMES_HOME"] = home
fc = load("model-providers/family-cloud/__init__.py", "c010_family_cloud")
st = json.loads(source("model-providers/family-cloud/settings.json"))
cs = source("model-providers/family-cloud/cloud-SOUL.md").decode("utf-8")
gz = load("gezin/__init__.py", "c010_gezin")

# ---- (b) system text from the pod's own Hermes prompt
db = sqlite3.connect("file:/opt/data/state.db?mode=ro", uri=True)
row = db.execute("select coalesce(s.system_prompt, p.prompt), s.started_at from sessions s left join system_prompts p "
                 "on p.hash = s.system_prompt_hash where s.source = 'api_server' and s.started_at >= ? "
                 "order by s.started_at desc limit 1", (float(inp.get("since") or 0),)).fetchone()
ok["hermes prompt found"] = bool(row and row[0])
agent = types.SimpleNamespace(_memory_store=object(), _memory_manager=None, session_id="c010-replay")
if row and row[0]:
    body = {"model": st["model"], "messages": [{"role": "system", "content": row[0]},
                                                {"role": "user", "content": "Hoeveel poten heeft een spin?"}]}
    res = fc.cloud_request(body, agent, st, cloud_soul=cs)
    ok["cloud_request accepts the Hermes prompt (SOUL pin holds)"] = res is not None
    if res is not None:
        sysm = [m for m in res["messages"] if m.get("role") in ("system", "developer")]
        want = cs.strip() + "\n\n" + fc.date_line()
        ok["exactly one system message, first"] = len(sysm) == 1 and res["messages"][0] is sysm[0]
        got = sysm[0]["content"] if sysm and isinstance(sysm[0].get("content"), str) else ""
        ok["sha256(system) == sha256(cloud-SOUL + date line)"] = sha(got.encode()) == sha(want.encode())
        ok["Hermes prompt itself not forwarded"] = row[0] not in json.dumps(res, ensure_ascii=False)
        out["system_sha"], out["want_sha"] = sha(got.encode())[:12], sha(want.encode())[:12]
    del body, res
out["prompt_sha"] = sha(row[0].encode())[:12] if row and row[0] else None
del row


# ---- (a) wis: real gezin hook, only wis_alles stubbed
def turn(context, question, history=()):
    live = [dict(m) for m in history]
    cur = {"role": "user", "content": question}
    if context:
        cur["api_content"] = question + "\n\n" + context
    live.append(cur)
    wire = [dict(m, content=m["api_content"]) if "api_content" in m else dict(m) for m in live]
    for m in wire:
        m.pop("api_content", None)
    body = {"model": st["model"], "messages": [{"role": "system", "content": "c010 synthetisch"}] + wire}
    return body, (context, "", live, len(live) - 1)


def studio(body, view, sticky, sid):
    public = fc.wire_is_public(body) and fc.view_is_public(view, body)
    return not public or not sticky.history_is_cloud(sid, body)


calls = []
g = gz.Gezin("http://127.0.0.1:9", "synthetic", {})
real_wipe = g.wis_alles
g.wis_alles = lambda: calls.append(1) or True     # the ONLY stub: nothing is wiped
ctx = (g.gebruik(user_message="wis mijn geheugen", session_id="c010-replay") or {}).get("context") or ""
ok["real hook reached the wipe (stub called once)"] = calls == [1]
ok["hook returned the wipe context"] = ctx.startswith("[Systeem, niet van hem")
sticky = fc.Sticky(os.path.join(home, "sticky-profiel-3.json"), "profiel-3")
b1, v1 = turn(ctx, "wis mijn geheugen")
ok["wis turn -> Studio"] = studio(b1, v1, sticky, "c010-replay")
hist = [{"role": "user", "content": "wis mijn geheugen"}, {"role": "assistant", "content": "c010 studio-antwoord"}]
ctx2 = (g.gebruik(user_message="Hoe laat is het?", session_id="c010-replay") or {}).get("context") or ""
b2, v2 = turn(ctx2, "Hoe laat is het?", hist)
ok["turn after wis -> Studio"] = studio(b2, v2, sticky, "c010-replay")
b0, v0 = turn("", "Hoeveel poten heeft een spin?")
ok["control: public first turn is cloud-eligible"] = not studio(b0, v0, sticky, "c010-replay-control")
ok["wis_alles not replaced on the class"] = getattr(gz.Gezin, "wis_alles") is getattr(type(g), "wis_alles") and real_wipe is not None

out["checks"] = ok
out["result"] = "PASS" if all(ok.values()) else "FAIL"
print(json.dumps(out, sort_keys=True))
sys.exit(0 if out["result"] == "PASS" else 1)
