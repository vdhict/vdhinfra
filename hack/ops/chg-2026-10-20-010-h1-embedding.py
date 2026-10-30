"""chg-2026-10-20-010 W2c H1 (Argus): the Open WebUI document embedding is healthy, right before C2 (profiel-1's document
turn must reach the RAG path, else the bare question would go to the cloud: 27-10 attempt 11). Run IN the open-webui
pod (stdin to `cd /app/backend && python3 -`): an in-pod create_token for the service admin (10 min, never printed),
then over 127.0.0.1:8080:
  1. GET /api/v1/retrieval/embedding (OWUI 0.11.4 keys RAG_EMBEDDING_ENGINE/_MODEL): engine "" (local), model == env
  2. POST /api/v1/files/ a synthetic text file; poll GET /api/v1/files/<id> until meta/data shows processing done
     without an error (status "completed" or content present), at most 120 s
  3. DELETE the file, GET -> 404
Prints booleans/statuses only, never content or the token; "H1 GREEN" iff all hold. The synthetic vector collection
of the file may stay (OWUI's file delete leaves its collection: known, follow-up card from 27-10)."""
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
import uuid
from datetime import timedelta

c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
rows = c.execute("select id, role from user where email = ?", (os.environ.get("WEBUI_ADMIN_EMAIL", "").strip(),)).fetchall()
assert len(rows) == 1 and rows[0][1] == "admin", "service admin not found"
from open_webui.utils.auth import create_token  # noqa: E402

TOK = create_token({"id": rows[0][0]}, expires_delta=timedelta(minutes=10))
U = "http://127.0.0.1:8080"


def req(method, path, body=None, headers=None):
    r = urllib.request.Request(U + path, data=body, method=method, headers=dict({"Authorization": "Bearer " + TOK}, **(headers or {})))
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, None


ok = True
st, emb = req("GET", "/api/v1/retrieval/embedding")
want = os.environ.get("RAG_EMBEDDING_MODEL", "")
m1 = st == 200 and isinstance(emb, dict) and emb.get("RAG_EMBEDDING_ENGINE", "") == "" and emb.get("RAG_EMBEDDING_MODEL") == want and bool(want)
print("H1 1 embedding config: http %s engine local %s model == env %s" % (st, isinstance(emb, dict) and emb.get("RAG_EMBEDDING_ENGINE", "") == "", isinstance(emb, dict) and emb.get("RAG_EMBEDDING_MODEL") == want))
ok &= m1
b = "c010-h1-" + uuid.uuid4().hex
body = ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"c010-h1.txt\"\r\nContent-Type: text/plain\r\n\r\n"
        "c010 H1 synthetisch document: de vuurtoren is groen.\r\n--%s--\r\n" % (b, b)).encode()
st, f = req("POST", "/api/v1/files/", body, {"Content-Type": "multipart/form-data; boundary=" + b})
fid = (f or {}).get("id") if isinstance(f, dict) else None
print("H1 2 upload: http %s file id %s" % (st, "yes" if fid else "no"))
done = False
if fid:
    for _ in range(60):
        s2, info = req("GET", "/api/v1/files/" + fid)
        meta = (info or {}).get("meta") or {}
        data = (info or {}).get("data") or {}
        status = data.get("status") or meta.get("status")
        err = data.get("error") or meta.get("error")
        if err:
            break
        if status == "completed" or (status is None and data.get("content")):
            done = True
            break
        time.sleep(2)
    print("H1 2 processing: completed %s error %s" % (done, bool(err)))
    s3, _ = req("DELETE", "/api/v1/files/" + fid)
    s4, _ = req("GET", "/api/v1/files/" + fid)
    print("H1 3 cleanup: delete http %s, read back http %s" % (s3, s4))
    ok &= s3 == 200 and s4 == 404
ok &= bool(fid) and done
print("H1 GREEN" if ok else "H1 RED")
