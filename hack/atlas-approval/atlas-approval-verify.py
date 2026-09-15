#!/usr/bin/env python3
"""
atlas-approval-verify — the gate for signed approvals of Atlas changes.

Runs as ROOT, from a LaunchDaemon, polling the inbox. Atlas (the model) never
invokes it and cannot modify it: that is the point. Atlas's integrity decides
whether an approval is HONOURED; it must not decide whether one is GENUINE.

FAILS CLOSED. Every path that is not an explicit success is a refusal.

Trust anchors, root:wheel, not writable by uid 501:
    /usr/local/etc/atlas-approval/allowed_signers
    /usr/local/etc/atlas-approval/revoked_keys
State, root:wheel — the authority the execution gate reads:
    /usr/local/var/atlas-approval/granted/<chg>.<nonce>.json
    /usr/local/var/atlas-approval/replay
    /usr/local/var/atlas-approval/{processed,rejected}/
Untrusted input, uid 501 (the signature is what protects it):
    ~sheijden/atlas-approvals/inbox/<chg>.<nonce>.approval + .sig

An `approved` event is ALSO appended to ops/changes.jsonl so the change log
stays readable — but that event is a RECORD, never the authority. Anything
running as uid 501 can forge it; nothing running as uid 501 can forge a grant.
"""

import hashlib
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone, timedelta

ETC = "/usr/local/etc/atlas-approval"
VAR = "/usr/local/var/atlas-approval"
ALLOWED = os.path.join(ETC, "allowed_signers")
REVOKED = os.path.join(ETC, "revoked_keys")
GRANTED = os.path.join(VAR, "granted")
REPLAY = os.path.join(VAR, "replay")
PROCESSED = os.path.join(VAR, "processed")
REJECTED = os.path.join(VAR, "rejected")

OWNER = "sheijden"
INBOX = f"/Users/{OWNER}/atlas-approvals/inbox"
CHANGELOG = f"/Users/{OWNER}/Code/homelab-migration/vdhinfra/ops/changes.jsonl"
HA_TOKEN_FILE = f"/Users/{OWNER}/Code/homelab-migration/config/hasskey"
HA_URL = "http://172.16.2.237:8123/api/services/notify/mobile_app_galaxy_s25_ultra"

NAMESPACE = "atlas-approval"
MAX_WINDOW = timedelta(minutes=30)
FUTURE_SLACK = timedelta(minutes=2)
MAX_DOC = 2048

NAME_RE = re.compile(r"^(chg-\d{4}-\d{2}-\d{2}-\d{3})\.([0-9a-f]{32})\.approval$")
CHG_RE = re.compile(r"^chg-\d{4}-\d{2}-\d{2}-\d{3}$")
REQUIRED = ["change-id", "decision", "approved-text", "proposal-source",
            "proposal-sha256", "issued-at", "expires-at", "nonce",
            "signer", "signer-key"]


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


def notify(title, message):
    """Out-of-band to Sander's handset. Best effort; never blocks a decision."""
    try:
        token = open(HA_TOKEN_FILE).read().strip()
        body = json.dumps({"title": title, "message": message}).encode()
        subprocess.run(
            ["curl", "-sS", "-m", "10", "-X", "POST", HA_URL,
             "-H", f"Authorization: Bearer {token}",
             "-H", "Content-Type: application/json", "-d", "@-"],
            input=body, capture_output=True, timeout=20)
    except Exception as e:
        log(f"notify failed (non-fatal): {e}")


# ---------------------------------------------------------------- proposal

def proposal_bytes(chg):
    """The signed bytes: `requested` + `planned` lines for chg, in file order.

    Selection is on the DECODED `chg` field, and the WHOLE log is refused if any
    non-empty line is unparsable, is not an object, or carries a duplicate key.
    Both rules match the Mac-side command exactly; if the two ever disagree on
    which bytes were signed, the hash must fail rather than quietly differ.
    """
    dup = []

    def nodup(pairs):
        ks = [k for k, _ in pairs]
        if len(ks) != len(set(ks)):
            dup.append(1)
        return dict(pairs)

    out, latest_planned = [], None
    with open(CHANGELOG, "rb") as fh:
        for raw in fh:
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw.decode(), object_pairs_hook=nodup)
            except Exception:
                raise ValueError("change log has an unparsable line")
            if dup:
                raise ValueError("change log has a duplicate key")
            if not isinstance(obj, dict):
                raise ValueError("change log has a non-object line")
            if obj.get("chg") == chg and obj.get("event") in ("requested", "planned"):
                out.append(raw if raw.endswith(b"\n") else raw + b"\n")
                if obj.get("event") == "planned":
                    latest_planned = obj
    if not out:
        raise ValueError(f"no requested/planned events for {chg}")
    return b"".join(out), latest_planned


def already_decided(chg):
    """True if the change has moved past awaiting-approval."""
    seen = set()
    with open(CHANGELOG) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                return True  # unreadable log: fail closed
            if o.get("chg") == chg:
                seen.add(o.get("event"))
    return bool(seen & {"approved", "rejected", "executed", "closed", "rolled_back"})


# ---------------------------------------------------------------- document

def parse_doc(text):
    if len(text.encode()) > MAX_DOC:
        raise ValueError("document over 2 KiB")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[0] != "atlas-approval-v1":
        raise ValueError("missing or wrong version banner")
    doc = {}
    for ln in lines[1:]:
        if not ln or ln != ln.strip() or ": " not in ln:
            raise ValueError(f"malformed line: {ln[:40]!r}")
        k, v = ln.split(": ", 1)
        if k in doc:
            raise ValueError(f"duplicate key {k}")
        if any(ord(c) < 32 or ord(c) == 127 for c in v):
            raise ValueError("control character in value")
        doc[k] = v
    if set(doc) != set(REQUIRED):
        raise ValueError(f"key set mismatch: {sorted(set(doc) ^ set(REQUIRED))}")
    if doc["decision"] not in ("approve", "reject"):
        raise ValueError("decision must be approve or reject")
    if not CHG_RE.match(doc["change-id"]):
        raise ValueError("bad change-id shape")
    verb = "Approve" if doc["decision"] == "approve" else "Reject"
    if not doc["approved-text"].startswith(f"{verb} {doc['change-id']}: "):
        raise ValueError("approved-text does not name the decision and change")
    if len(doc["approved-text"]) > 500:
        raise ValueError("approved-text over 500 chars")
    if not re.fullmatch(r"[0-9a-f]{64}", doc["proposal-sha256"]):
        raise ValueError("bad proposal-sha256")
    if not re.fullmatch(r"[0-9a-f]{32}", doc["nonce"]):
        raise ValueError("bad nonce")
    return doc


def iso(s):
    if not s.endswith("Z"):
        raise ValueError("timestamp not UTC Z")
    return datetime.fromisoformat(s[:-1]).replace(tzinfo=timezone.utc)


# ---------------------------------------------------------------- signature

def verify_sig(doc_path, sig_path):
    r = subprocess.run(
        ["ssh-keygen", "-Y", "verify", "-f", ALLOWED, "-I", "sander",
         "-n", NAMESPACE, "-s", sig_path, "-r", REVOKED],
        stdin=open(doc_path, "rb"), capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise ValueError(f"ssh-keygen verify failed: {r.stderr.strip()[:200]}")
    return True


def sig_flags(sig_path):
    """Authenticator flags from the SSHSIG blob: UP 0x01, UV 0x04.

    allowed_signers has no `verify-required` option, so ssh-keygen cannot
    enforce user-verification for us. We read the byte ourselves. Returns None
    if this is not an sk key or the blob cannot be walked -- caller decides.
    """
    import base64
    import struct
    try:
        armor = open(sig_path).read()
        b64 = "".join(l for l in armor.splitlines() if "SSH SIGNATURE" not in l)
        blob = base64.b64decode(b64)
        if blob[:6] != b"SSHSIG":
            return None
        off = 6 + 4  # magic + version
        def s():
            nonlocal off
            (n,) = struct.unpack(">I", blob[off:off + 4])
            off += 4
            v = blob[off:off + n]
            off += n
            return v
        s(); s(); s(); s()          # publickey, namespace, reserved, hash_alg
        inner = s()                  # signature blob
        io = 0
        def s2():
            nonlocal io
            (n,) = struct.unpack(">I", inner[io:io + 4])
            io += 4
            v = inner[io:io + n]
            io += n
            return v
        alg = s2()
        if b"sk-" not in alg:
            return None
        s2()                         # ecdsa sig blob
        return inner[io]             # flags byte
    except Exception:
        return None


def key_fingerprint():
    line = open(ALLOWED).read().split()
    return subprocess.run(
        ["ssh-keygen", "-lf", "/dev/stdin"],
        input=f"{line[2]} {line[3]}\n", capture_output=True, text=True
    ).stdout.split()[1]


# ---------------------------------------------------------------- main

def replay_seen(nonce):
    if not os.path.exists(REPLAY):
        return False
    with open(REPLAY) as fh:
        return any(l.strip() == nonce for l in fh)


def replay_add(nonce):
    fd = os.open(REPLAY, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, (nonce + "\n").encode())
    os.close(fd)


def handle(name, require_uv):
    m = NAME_RE.match(name)
    if not m:
        return
    chg, nonce = m.group(1), m.group(2)
    doc_path = os.path.join(INBOX, name)
    sig_path = doc_path + ".sig"

    def reject(why):
        log(f"REJECT {name}: {why}")
        notify("Atlas approval REFUSED",
               f"{chg}\n{why}\n\nIf you did not just sign this, treat it as an "
               f"attempt to forge an approval.")
        os.makedirs(REJECTED, mode=0o700, exist_ok=True)
        for p in (doc_path, sig_path):
            if os.path.exists(p):
                shutil.move(p, os.path.join(REJECTED, os.path.basename(p)))

    try:
        if not os.path.exists(sig_path):
            return  # orphan .sig ordering: wait for the pair
        st = os.lstat(doc_path)
        if stat_is_link(st) or st.st_uid not in (0, pwd.getpwnam(OWNER).pw_uid):
            return reject("inbox file is a symlink or has an unexpected owner")

        doc = parse_doc(open(doc_path).read())
        if doc["change-id"] != chg or doc["nonce"] != nonce:
            return reject("filename does not match document contents")

        verify_sig(doc_path, sig_path)
        if doc["signer-key"] != key_fingerprint():
            return reject("signer-key does not match the pinned key")

        flags = sig_flags(sig_path)
        if require_uv and not (flags is not None and flags & 0x04):
            return reject(f"user-verification bit not set (flags={flags}); "
                          f"Touch ID cannot be proven")

        now = datetime.now(timezone.utc)
        issued, expires = iso(doc["issued-at"]), iso(doc["expires-at"])
        if issued - now > FUTURE_SLACK:
            return reject("issued-at is in the future")
        if expires <= now:
            return reject("approval has expired")
        if expires - issued > MAX_WINDOW:
            return reject("validity window longer than 30 minutes")

        if replay_seen(nonce):
            return reject("nonce already used (replay)")
        if already_decided(chg):
            return reject("change is no longer awaiting approval")

        pbytes, planned = proposal_bytes(chg)
        if hashlib.sha256(pbytes).hexdigest() != doc["proposal-sha256"]:
            return reject("proposal hash mismatch — the plan changed after signing")
        if doc["decision"] == "approve":
            if planned is None:
                return reject("no planned event")
            pay = planned.get("payload", {})
            if pay.get("signature_eligible") is not True:
                return reject("latest planned event is not marked signature_eligible")
            if not str(pay.get("rollback", "")).strip():
                return reject("latest planned event has no rollback")

        # ---- accepted -------------------------------------------------
        replay_add(nonce)
        os.makedirs(GRANTED, mode=0o755, exist_ok=True)
        grant = {
            "change_id": chg, "decision": doc["decision"], "nonce": nonce,
            "signer": doc["signer"], "signer_key": doc["signer-key"],
            "proposal_sha256": doc["proposal-sha256"],
            "approval_sha256": hashlib.sha256(open(doc_path, "rb").read()).hexdigest(),
            "sk_flags": flags, "uv_set": bool(flags is not None and flags & 0x04),
            "approved_text": doc["approved-text"],
            "verified_at": datetime.now(timezone.utc).isoformat(),
            "proposal_bytes_b64": __import__("base64").b64encode(pbytes).decode(),
        }
        gp = os.path.join(GRANTED, f"{chg}.{nonce}.json")
        fd = os.open(gp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        os.write(fd, json.dumps(grant, indent=2).encode())
        os.close(fd)

        ev = {"actor": "user", "chg": chg,
              "event": "approved" if doc["decision"] == "approve" else "rejected",
              "payload": {"approved_by": "user", "scope": "this_change_only",
                          "method": "ssh-sig", "nonce": nonce,
                          "proposal_sha256": doc["proposal-sha256"],
                          "approval_sha256": grant["approval_sha256"],
                          "signer_key": doc["signer-key"],
                          "sk_flags": flags, "uv_set": grant["uv_set"],
                          "authority": f"grant record at {gp} — this log line is a "
                                       f"RECORD, not the authority"},
              "resource": "", "risk": "",
              "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
        with open(CHANGELOG, "a") as fh:
            fh.write(json.dumps(ev, sort_keys=True) + "\n")

        os.makedirs(PROCESSED, mode=0o700, exist_ok=True)
        for p in (doc_path, sig_path):
            shutil.move(p, os.path.join(PROCESSED, os.path.basename(p)))

        log(f"ACCEPT {name} decision={doc['decision']} uv={grant['uv_set']}")
        notify(f"Atlas approval accepted ({doc['decision']})",
               f"{doc['approved-text']}\n\nuv={grant['uv_set']} "
               f"nonce={nonce[:8]}…\n\nIf you did not just sign this, say so now.")
    except Exception as e:
        reject(f"{type(e).__name__}: {e}")


def stat_is_link(st):
    import stat as _s
    return _s.S_ISLNK(st.st_mode)


def main():
    require_uv = "--require-uv" in sys.argv
    once = "--once" in sys.argv
    for d in (GRANTED, PROCESSED, REJECTED):
        os.makedirs(d, mode=0o755 if d == GRANTED else 0o700, exist_ok=True)
    log(f"atlas-approval-verify start require_uv={require_uv} once={once}")
    while True:
        try:
            names = sorted(os.listdir(INBOX)) if os.path.isdir(INBOX) else []
        except Exception as e:
            log(f"inbox unreadable: {e}")
            names = []
        for n in names:
            if n.endswith(".approval"):
                handle(n, require_uv)
        if once:
            return
        time.sleep(15)


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("must run as root")
    main()
