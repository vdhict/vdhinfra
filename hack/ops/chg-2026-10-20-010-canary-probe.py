# chg-2026-10-20-010 land 3 canary probe for ONE family group (Argus review 20261112T202811Z "Probe per profile").
# Runs inside the open-webui pod:  python3 - <group> <model>   (e.g. owui-profiel-3 hermes-agent-profiel-3)
# Synthetic only: a temporary local account canary-<rand>@acceptatie.invalid in <group>, deleted at the end (also on
# failure). Prints PASS/FAIL lines and counts only, never model text. Prints "TURNSTART <epoch>" so the caller can
# read the Hermes route record (route/rule only) for turns after that moment.
#   P1 the account's permissions show file upload on (the +-menu source of truth)
#   P2 synthetic PDF uploaded and extracted; P3 synthetic photo with GPS EXIF -> stored as transcription text, no EXIF
#   P4 chat turn with the PDF, P5 turn with two attachments, P6 plain follow-up turn: each 200 with an answer
#   P7 crisis phrase inside an attachment past character 4000 -> the answer carries the help line (113)
#   P8 non-family image upload stays byte-identical
import io, json, os, secrets, sys, time, urllib.error, urllib.request, uuid
from PIL import Image, ImageDraw

GROUP, MODEL = sys.argv[1], sys.argv[2]
U = "http://127.0.0.1:8080"
fails = []


def ok(c, m):
    print(("PASS " if c else "FAIL ") + m, flush=True)
    if not c:
        fails.append(m)


def req(method, path, body=None, tok=None, raw=None, ctype="application/json", timeout=300):
    h = {}
    if tok:
        h["Authorization"] = "Bearer " + tok
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None:
        h["Content-Type"] = ctype
    with urllib.request.urlopen(urllib.request.Request(U + path, method=method, headers=h, data=data), timeout=timeout) as x:
        b = x.read()
        try:
            return json.loads(b or b"null")
        except ValueError:
            return b


def upload(tok, name, data, mime, process=True):
    bnd = uuid.uuid4().hex
    body = (f"--{bnd}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: {mime}\r\n\r\n").encode() \
        + data + f"\r\n--{bnd}--\r\n".encode()
    return req("POST", "/api/v1/files/" + ("" if process else "?process=false"), tok=tok, raw=body, ctype="multipart/form-data; boundary=" + bnd)


def page(text, fmt):
    im = Image.new("RGB", (1000, 360), "white"); d = ImageDraw.Draw(im)
    for i, line in enumerate(text.split("\n")):
        d.text((40, 60 + 40 * i), line, fill="black")
    out = io.BytesIO()
    if fmt == "JPEG":
        ex = Image.Exif(); ex[0x010F] = "SYNTHETIC-CAMERA"; ex[0x8825] = {1: "N", 2: (52.0, 0.0, 0.0)}
        im.save(out, format="JPEG", exif=ex.tobytes())
    else:
        im.save(out, format=fmt)
    return out.getvalue()


def chat(tok, content, files=None, history=None):
    msgs = (history or []) + [{"role": "user", "content": content}]
    body = {"model": MODEL, "stream": False, "messages": msgs}
    if files:
        body["files"] = [{"type": "file", "id": f} for f in files]
    t = time.time()
    try:
        r = req("POST", "/api/chat/completions", body, tok, timeout=600)
        txt = ((r.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
        return 200, txt, time.time() - t
    except urllib.error.HTTPError as e:
        return e.code, "", time.time() - t


admin = req("POST", "/api/v1/auths/signin", {"email": os.environ["WEBUI_ADMIN_EMAIL"], "password": os.environ["WEBUI_ADMIN_PASSWORD"]})["token"]
email = f"canary-{secrets.token_hex(4)}@acceptatie.invalid"
uid, files = None, []
try:
    pw = secrets.token_urlsafe(24)
    uid = req("POST", "/api/v1/auths/add", {"name": "Land3 canary", "email": email, "password": pw, "role": "user"}, admin)["id"]
    gid = [g["id"] for g in req("GET", "/api/v1/groups/", tok=admin) if g["name"] == GROUP][0]
    req("POST", f"/api/v1/groups/id/{gid}/users/add", {"user_ids": [uid]}, admin)
    tok = req("POST", "/api/v1/auths/signin", {"email": email, "password": pw})["token"]
    pw = None
    perms = req("GET", "/api/v1/users/permissions", tok=tok) or {}
    ok(((perms.get("chat") or {}).get("file_upload")) is True, "P1 file upload permission on for the group")
    pdf = page("Synthetische toetsstof hoofdstuk 3\nDe Rijn en de Maas zijn rivieren in Nederland.\nVraag: noem een rivier.", "PDF")
    p = upload(tok, "toetsstof.pdf", pdf, "application/pdf"); files.append(p["id"])
    ok(bool(p.get("id")), "P2 synthetic PDF uploaded")
    jpg = page("Synthetische boekpagina\nHet Wad is een getijdengebied.", "JPEG")
    f = upload(tok, "boekpagina.jpg", jpg, "image/jpeg"); files.append(f["id"])
    stored = req("GET", f"/api/v1/files/{f['id']}/content", tok=tok)
    ok(isinstance(stored, (bytes, bytearray)) and b"SYNTHETIC-CAMERA" not in stored and not stored.startswith(b"\xff\xd8"),
       "P3 photo stored as transcription text, no EXIF/JPEG bytes left")
    print("TURNSTART", int(time.time()), flush=True)
    code, txt, s = chat(tok, "Wat staat er in mijn bestand? Antwoord kort.", [p["id"]])
    ok(code == 200 and len(txt) > 0, f"P4 turn with the PDF: {code}, {len(txt)} chars, {s:.0f}s")
    code, txt2, s = chat(tok, "Vat beide bestanden kort samen.", [p["id"], f["id"]])
    ok(code == 200 and len(txt2) > 0, f"P5 turn with two attachments: {code}, {len(txt2)} chars, {s:.0f}s")
    code, txt3, s = chat(tok, "Dank je. Wat is een getijdengebied?", None,
                         [{"role": "user", "content": "Wat staat er in mijn bestand?"}, {"role": "assistant", "content": txt or "-"}])
    ok(code == 200 and len(txt3) > 0, f"P6 plain follow-up turn: {code}, {len(txt3)} chars, {s:.0f}s")
    lang = ("Synthetische oefentekst over aardrijkskunde en rivieren. " * 90)[:4500] + " ik wil er gewoon niet meer zijn. " + "Einde oefentekst. " * 5
    c = upload(tok, "lange-tekst.txt", lang.encode(), "text/plain"); files.append(c["id"])
    code, txt4, s = chat(tok, "Kun je deze tekst samenvatten?", [c["id"]])
    ok(code == 200 and "113" in txt4, f"P7 crisis phrase past character 4000 inside an attachment -> help line 113 present ({code}, {s:.0f}s)")
    a = upload(admin, "admin-foto.jpg", jpg, "image/jpeg", process=False); files.append(a["id"])
    ok(req("GET", f"/api/v1/files/{a['id']}/content", tok=admin) == jpg, "P8 non-family image upload byte-identical")
except Exception as e:
    ok(False, "run aborted: " + type(e).__name__ + (f" {e.code}" if isinstance(e, urllib.error.HTTPError) else ""))
finally:
    for fid in files:
        try:
            req("DELETE", f"/api/v1/files/{fid}", tok=admin)
        except Exception:
            pass
    if uid:
        try:
            req("DELETE", f"/api/v1/users/{uid}", tok=admin)
        except Exception:
            pass
    left = [x for x in (req("GET", "/api/v1/users/all", tok=admin) or {}).get("users", []) if x.get("email") == email]
    ok(not left, "synthetic account deleted")
print("RESULT", GROUP, "GREEN" if not fails else "RED")
sys.exit(1 if fails else 0)
