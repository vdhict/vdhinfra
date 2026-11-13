# chg-2026-10-20-010 land 3, Argus O1: post-check of the overlay mount (runs inside the open-webui pod, python3 - ).
# Synthetic only: one temporary local account o1-<rand>@acceptatie.invalid in group owui-profiel-4 (the owner's test
# group, same permissions as owui-profiel-1), deleted at the end (also after a failure). Checks:
#   family image upload: stored, no EXIF/GPS left; family text upload: stored unchanged;
#   non-family (service admin) image upload: stored bytes unchanged (vendor behaviour).
# Prints PASS/FAIL lines only; no tokens, no content.
import hashlib, io, json, os, secrets, sys, urllib.error, urllib.request, uuid
from PIL import Image

U = "http://127.0.0.1:8080"
fails = []


def ok(c, m):
    print(("PASS " if c else "FAIL ") + m, flush=True)
    if not c:
        fails.append(m)


def req(method, path, body=None, tok=None, raw=None, ctype="application/json"):
    h = {}
    if tok:
        h["Authorization"] = "Bearer " + tok
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None:
        h["Content-Type"] = ctype
    r = urllib.request.Request(U + path, method=method, headers=h, data=data)
    with urllib.request.urlopen(r, timeout=120) as x:
        b = x.read()
        try:
            return json.loads(b or b"null")
        except ValueError:
            return b


def upload(tok, name, data, mime):
    bnd = uuid.uuid4().hex
    body = (f"--{bnd}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: {mime}\r\n\r\n").encode() \
        + data + f"\r\n--{bnd}--\r\n".encode()
    return req("POST", "/api/v1/files/?process=false", tok=tok, raw=body, ctype="multipart/form-data; boundary=" + bnd)


def jpeg_with_exif():
    im = Image.new("RGB", (64, 64), (200, 120, 40))
    ex = Image.Exif(); ex[0x010F] = "SYNTHETIC-CAMERA"; ex[0x8825] = {1: "N", 2: (52.0, 0.0, 0.0)}
    out = io.BytesIO(); im.save(out, format="JPEG", exif=ex.tobytes())
    return out.getvalue()


admin = req("POST", "/api/v1/auths/signin", {"email": os.environ["WEBUI_ADMIN_EMAIL"], "password": os.environ["WEBUI_ADMIN_PASSWORD"]})["token"]
email = f"o1-{secrets.token_hex(4)}@acceptatie.invalid"
uid = None
try:
    pw = secrets.token_urlsafe(24)
    u = req("POST", "/api/v1/auths/add", {"name": "O1 synthetic", "email": email, "password": pw, "role": "user"}, admin)
    uid = u["id"]
    gid = [g["id"] for g in req("GET", "/api/v1/groups/", tok=admin) if g["name"] == "owui-profiel-4"][0]
    req("POST", f"/api/v1/groups/id/{gid}/users/add", {"user_ids": [uid]}, admin)
    tok = req("POST", "/api/v1/auths/signin", {"email": email, "password": pw})["token"]
    pw = None
    img = jpeg_with_exif()
    ok(b"SYNTHETIC-CAMERA" in img, "fixture JPEG carries EXIF")
    f = upload(tok, "foto.jpg", img, "image/jpeg")
    stored = req("GET", f"/api/v1/files/{f['id']}/content", tok=tok)
    ok(isinstance(stored, (bytes, bytearray)) and len(stored) > 0, "family image upload stored (no error)")
    ok(b"SYNTHETIC-CAMERA" not in stored and b"Exif" not in stored[:200], "family image: EXIF/GPS gone in stored bytes")
    txt = b"Synthetische samenvatting hoofdstuk 3: rivieren.\n"
    t = upload(tok, "samenvatting.txt", txt, "text/plain")
    ok(req("GET", f"/api/v1/files/{t['id']}/content", tok=tok) == txt, "family text upload stored unchanged")
    a = upload(admin, "admin-foto.jpg", img, "image/jpeg")
    ok(req("GET", f"/api/v1/files/{a['id']}/content", tok=admin) == img, "non-family image upload stored byte-identical (vendor)")
    for fid in (f["id"], t["id"], a["id"]):
        req("DELETE", f"/api/v1/files/{fid}", tok=admin)
except Exception as e:
    ok(False, "run aborted: " + type(e).__name__ + (f" {e.code}" if isinstance(e, urllib.error.HTTPError) else ""))
finally:
    if uid:
        try:
            req("DELETE", f"/api/v1/users/{uid}", tok=admin)
        except Exception:
            pass
    left = [x for x in (req("GET", "/api/v1/users/all", tok=admin) or {}).get("users", []) if x.get("email") == email]
    ok(not left, "synthetic account deleted")
print("RESULT O1", "GREEN" if not fails else "RED")
sys.exit(1 if fails else 0)
