#!/usr/bin/env python3
"""End-to-end tests of verifier v2 handle() in a temp tree (chg-2026-11-09-003, Argus blockers 4 and condition 4).

Real ssh-keygen; test-only software sk keys. No root, nothing under /usr/local is touched.
  python3 -I tests/test_handle.py
"""
import base64
import hashlib
import importlib.util
import json
import os
import pwd
import tempfile
import types
from datetime import datetime, timezone, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "software_sk.py")).read()


def sk_key(seed_byte):
    m = types.ModuleType(f"sk{seed_byte}")
    exec(SRC.replace("SEED = bytes(range(32))", f"SEED = bytes([{seed_byte}] * 32)"), m.__dict__)
    return m


spec = importlib.util.spec_from_file_location("verifier", os.path.join(HERE, "..", "atlas-approval-verify.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

T = tempfile.mkdtemp(prefix="verifier-handle-")
for k, sub in dict(ETC="etc", VAR="var", INBOX="inbox").items():
    os.makedirs(os.path.join(T, sub))
v.ALLOWED, v.REVOKED, v.UV_EXEMPT = (os.path.join(T, "etc", n) for n in ("allowed_signers", "revoked_keys", "uv_exempt"))
v.VAR = os.path.join(T, "var")
v.GRANTED, v.PROCESSED, v.REJECTED, v.REPLAY = (os.path.join(T, "var", n) for n in ("granted", "processed", "rejected", "replay"))
v.INBOX = os.path.join(T, "inbox")
v.CHANGELOG = os.path.join(T, "changes.jsonl")
v.OWNER = pwd.getpwuid(os.getuid()).pw_name
v.notify = lambda *a, **k: None
LOG = []
v.log = LOG.append
open(v.REVOKED, "w").close()

yk = sk_key(2)
FP = v.pinned_keys.__globals__["_fp"](base64.b64decode(yk.PUBLIC_KEY.split()[1]))
with open(v.ALLOWED, "w") as fh:
    fh.write(f'sander namespaces="atlas-approval" {yk.PUBLIC_KEY}\n')
open(v.UV_EXEMPT, "w").close()

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS" if ok else "FAIL"), name, detail)


def changelog(chg):
    lines = [json.dumps({"actor": "infra-ops", "chg": chg, "event": "requested", "payload": {"summary": "test"}}),
             json.dumps({"actor": "infra-ops", "chg": chg, "event": "planned",
                         "payload": {"signature_eligible": True, "rollback": "test rollback"}})]
    with open(v.CHANGELOG, "a") as fh:
        fh.write("\n".join(lines) + "\n")
    return v.proposal_bytes(chg)[0]


def doc_for(chg, nonce, pbytes, text_suffix="test"):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    z = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
    fields = [("change-id", chg), ("decision", "approve"), ("approved-text", f"Approve {chg}: {text_suffix}"),
              ("proposal-source", "test"), ("proposal-sha256", hashlib.sha256(pbytes).hexdigest()),
              ("issued-at", z(now)), ("expires-at", z(now + timedelta(minutes=10))), ("nonce", nonce),
              ("signer", "sander"), ("signer-key", FP)]
    return ("atlas-approval-v1\n" + "".join(f"{k}: {val}\n" for k, val in fields)).encode()


def drop(chg, nonce, doc, sig):
    name = f"{chg}.{nonce}.approval"
    with open(os.path.join(v.INBOX, name), "wb") as fh:
        fh.write(doc)
    with open(os.path.join(v.INBOX, name + ".sig"), "w") as fh:
        fh.write(sig)
    return name


def granted(chg, nonce):
    return os.path.exists(os.path.join(v.GRANTED, f"{chg}.{nonce}.json"))


# H1 a genuine UV signature is granted; processed/ holds the verified bytes; no snapshot left behind
c1, n1 = "chg-2099-01-01-001", "a" * 32
p1 = changelog(c1)
d1 = doc_for(c1, n1, p1)
name = drop(c1, n1, d1, yk.signature(d1, 5))
v.handle(name, False)
check("H1 genuine signature granted", granted(c1, n1), LOG[-1][:80])
check("H1 processed holds the verified bytes", open(os.path.join(v.PROCESSED, name), "rb").read() == d1)
check("H1 no snapshot dir left", not [d for d in os.listdir(v.VAR) if d.startswith("snap-")])

# H2 the rename race (Argus blocker 4): forged doc in the inbox, swapped for the genuine one right after it is read.
c2, n2 = "chg-2099-01-01-002", "b" * 32
p2 = changelog(c2)
genuine = doc_for(c2, n2, p2, "genuine")
forged = doc_for(c2, n2, p2, "FORGED")
name = drop(c2, n2, forged, yk.signature(genuine, 5))
orig_read = v.read_once


def racing_read(path, limit):
    data = orig_read(path, limit)
    if path.endswith(".approval"):          # attacker swaps in the genuine document after our single read
        with open(path, "wb") as fh:
            fh.write(genuine)
    return data


v.read_once = racing_read
v.handle(name, False)
v.read_once = orig_read
check("H2 race: forged doc + captured genuine signature is refused", not granted(c2, n2), LOG[-1][:100])

# H3 symlinked inbox file is refused
c3, n3 = "chg-2099-01-01-003", "c" * 32
p3 = changelog(c3)
d3 = doc_for(c3, n3, p3)
real = os.path.join(T, "elsewhere.approval")
with open(real, "wb") as fh:
    fh.write(d3)
name = f"{c3}.{n3}.approval"
os.symlink(real, os.path.join(v.INBOX, name))
with open(os.path.join(v.INBOX, name + ".sig"), "w") as fh:
    fh.write(yk.signature(d3, 5))
v.handle(name, False)
check("H3 symlinked document refused", not granted(c3, n3), LOG[-1][:100])

# H4 signature armor with two blocks / junk base64 is refused
c4, n4 = "chg-2099-01-01-004", "d" * 32
p4 = changelog(c4)
d4 = doc_for(c4, n4, p4)
s4 = yk.signature(d4, 5)
name = drop(c4, n4, d4, s4 + s4)
v.handle(name, False)
check("H4 doubled armor refused", not granted(c4, n4), LOG[-1][:100])

# H5 cert-authority line in allowed_signers: fail closed (refused)
c5, n5 = "chg-2099-01-01-005", "e" * 32
p5 = changelog(c5)
d5 = doc_for(c5, n5, p5)
keep = open(v.ALLOWED).read()
with open(v.ALLOWED, "a") as fh:
    fh.write(f'sander cert-authority,namespaces="atlas-approval" {sk_key(9).PUBLIC_KEY}\n')
name = drop(c5, n5, d5, yk.signature(d5, 5))
v.handle(name, False)
with open(v.ALLOWED, "w") as fh:
    fh.write(keep)
check("H5 cert-authority line makes the verifier refuse", not granted(c5, n5), LOG[-1][:100])

# H6 replay of H1's nonce is refused
name = drop(c1, n1, d1, yk.signature(d1, 5))
v.handle(name, False)
check("H6 replay refused", "replay" in LOG[-1] or "no longer awaiting" in LOG[-1], LOG[-1][:100])

print(f"{sum(results)}/{len(results)} passed")
raise SystemExit(0 if all(results) else 1)
