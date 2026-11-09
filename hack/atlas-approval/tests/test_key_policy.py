#!/usr/bin/env python3
"""Offline tests for verifier v2 key policy (chg-2026-11-09-003): several pinned keys, UV per key.

Uses real `ssh-keygen -Y verify` and test-only software sk-ssh-ed25519 signatures (software_sk.py, copied from
pka-approve d4bceb9 tests). Never touches /usr/local; runs as any user.  python3 -I tests/test_key_policy.py
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "software_sk.py")).read()


def sk_key(seed_byte):
    m = types.ModuleType(f"sk{seed_byte}")
    exec(SRC.replace("SEED = bytes(range(32))", f"SEED = bytes([{seed_byte}] * 32)"), m.__dict__)
    return m


spec = importlib.util.spec_from_file_location("verifier", os.path.join(HERE, "..", "atlas-approval-verify.py"))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

tmp = tempfile.mkdtemp(prefix="verifier-v2-")
v.ALLOWED = os.path.join(tmp, "allowed_signers")
v.REVOKED = os.path.join(tmp, "revoked_keys")
v.UV_EXEMPT = os.path.join(tmp, "uv_exempt")
open(v.REVOKED, "w").close()
OPTS = 'namespaces="atlas-approval",valid-before="20270915"'

se, yk, stranger = sk_key(1), sk_key(2), sk_key(3)   # se stands in for the Secure Enclave key (exempt)
plain = os.path.join(tmp, "plain")
subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", plain], check=True)
plain_pub = open(plain + ".pub").read().split()


def write(path, text):
    with open(path, "w") as fh:
        fh.write(text)


def fp_of(m):
    return v.pinned_keys.__globals__["_fp"](__import__("base64").b64decode(m.PUBLIC_KEY.split()[1]))


write(v.ALLOWED, f"sander {OPTS} {se.PUBLIC_KEY}\nsander {OPTS} {yk.PUBLIC_KEY}\n"
                 f"sander {OPTS} {plain_pub[0]} {plain_pub[1]}\n")
write(v.UV_EXEMPT, f"# Secure Enclave\n{fp_of(se)}\n")
MSG = b"atlas-approval-v1 test document\n"
results = []


def case(name, signer, flags, doc_fp=None, require_uv=False, expect=None, sig=None):
    d = tempfile.mkdtemp(dir=tmp)
    doc, sigp = os.path.join(d, "a.approval"), os.path.join(d, "a.approval.sig")
    write(doc, MSG.decode())
    write(sigp, sig if sig is not None else signer.signature(MSG, flags))
    try:
        v.verify_sig(doc, sigp)
        why, _ = v.key_policy(sigp, doc_fp or fp_of(signer), require_uv)
    except Exception as e:
        why = f"{type(e).__name__}: {e}"
    ok = (why is None) if expect is None else (why is not None and expect in why)
    results.append(ok)
    print(("PASS" if ok else "FAIL"), name, "->", why or "ACCEPT")


case("T1 YubiKey-like, UP+UV", yk, 5)
case("T2 YubiKey-like, UP only (no UV)", yk, 1, expect="user-verification bit not set")
case("T3 exempt SE-like key, UP only", se, 1)
case("T4 unpinned key", stranger, 5, expect="ssh-keygen verify failed")
case("T5 doc signer-key names the other pinned key", yk, 5, doc_fp=fp_of(se), expect="does not match the key that signed")
case("T6 global --require-uv overrides the exemption", se, 1, require_uv=True, expect="user-verification bit not set")
os.rename(v.UV_EXEMPT, v.UV_EXEMPT + ".off")
case("T7 uv_exempt missing: no exemptions (fail closed)", se, 1, expect="user-verification bit not set")
os.rename(v.UV_EXEMPT + ".off", v.UV_EXEMPT)
pd = tempfile.mkdtemp(dir=tmp)
write(os.path.join(pd, "m"), MSG.decode())
plain_sig = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", plain, "-n", "atlas-approval", os.path.join(pd, "m")],
                           capture_output=True, text=True)
case("T8 pinned but not sk (software key)", None, 0, doc_fp=subprocess.run(
    ["ssh-keygen", "-lf", plain + ".pub"], capture_output=True, text=True).stdout.split()[1],
    expect="not hardware-backed", sig=open(os.path.join(pd, "m.sig")).read())

# T9: fingerprints from the real, installed allowed_signers match ssh-keygen -lf (read-only)
real = "/usr/local/etc/atlas-approval/allowed_signers"
if os.path.exists(real):
    v.ALLOWED = real
    mine = set(v.pinned_keys())
    theirs = set()
    for line in open(real):
        f = line.split()
        if f:
            theirs.add(subprocess.run(["ssh-keygen", "-lf", "/dev/stdin"], input=f"{f[2]} {f[3]}\n",
                                      capture_output=True, text=True).stdout.split()[1])
    ok = mine == theirs and len(mine) >= 1
    results.append(ok)
    print(("PASS" if ok else "FAIL"), "T9 real allowed_signers fingerprints = ssh-keygen -lf:", sorted(mine))

print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
