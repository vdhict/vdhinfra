#!/usr/bin/env python3
"""Mint the vdhwslin01 waker's forge token (chg-2026-10-05-031, Argus F5).

Narrowest Forgejo 15 allows: user mypka-bot, scope read:repository, and
RESTRICTED to the one repository mypka-bot/passkey-point-dotnet (API
`repositories` on token create). Forgejo has no token expiry, so the expiry is
a date in kubernetes/main/apps/devtools/vdhwslin01-waker/app/kustomization.yaml
(forge_token_expires) that the waker enforces itself: rotate with this script
and bump that date (+90 days).

Secrets stay in memory: the forge admin login is read from the cluster Secret
and handed to curl inside the forge pod as a curl config on STDIN (never in
argv); the new token goes from the API response straight into
`kubectl apply` on stdin. Nothing secret is printed or written to disk.

Usage: mint-waker-forge-token.py [--delete-old <token-name>]
"""
import base64
import datetime
import json
import subprocess
import sys

NS = "devtools"
USER = "mypka-bot"
REPO = {"owner": "mypka-bot", "name": "passkey-point-dotnet"}
SECRET = "vdhwslin01-waker-forge"


def kubectl(*args, stdin=None):
    return subprocess.run(["kubectl", "-n", NS, *args], input=stdin, capture_output=True, check=True).stdout


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def forge(method, path, body=None):
    sec = json.loads(kubectl("get", "secret", "forgejo-admin-secret", "-o", "json"))["data"]
    user = base64.b64decode(sec["username"]).decode()
    pw = base64.b64decode(sec["password"]).decode()
    cfg = "user = %s\nrequest = %s\nurl = %s\nheader = \"Content-Type: application/json\"\n" % (
        q(user + ":" + pw), q(method), q("http://127.0.0.1:3000/api/v1" + path))
    if body is not None:
        cfg += "data = %s\n" % q(json.dumps(body))
    out = kubectl("exec", "-i", "deploy/forgejo", "-c", "forgejo", "--",
                  "curl", "-sS", "-w", "\n%{http_code}", "-K", "-", stdin=cfg.encode())
    text, _, code = out.decode().rpartition("\n")
    return int(code), text


def main():
    old = sys.argv[sys.argv.index("--delete-old") + 1] if "--delete-old" in sys.argv else None
    name = "vdhwslin01-waker-%s" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M")
    code, text = forge("POST", "/users/%s/tokens" % USER,
                       {"name": name, "scopes": ["read:repository"], "repositories": [REPO]})
    if code != 201:
        sys.exit("token create failed: HTTP %d %s" % (code, text[:200]))
    tok = json.loads(text)
    secret = json.dumps({"apiVersion": "v1", "kind": "Secret",
                         "metadata": {"name": SECRET, "namespace": NS,
                                      "labels": {"app.kubernetes.io/name": "vdhwslin01-waker",
                                                 "vdh.chg": "chg-2026-10-05-031"}},
                         "type": "Opaque", "stringData": {"token": tok["sha1"]}})
    kubectl("apply", "-f", "-", stdin=secret.encode())
    print("minted token id=%s name=%s scopes=%s repositories=%s -> Secret %s/%s" % (
        tok.get("id"), tok.get("name"), tok.get("scopes"),
        [r.get("full_name") or r.get("name") for r in (tok.get("repositories") or [])], NS, SECRET))
    if old:
        code, text = forge("DELETE", "/users/%s/tokens/%s" % (USER, old))
        print("deleted old token %s: HTTP %d" % (old, code))
    code, text = forge("GET", "/users/%s/tokens" % USER)
    for t in json.loads(text):
        if t.get("name", "").startswith("vdhwslin01-waker"):
            print("present: name=%s scopes=%s repositories=%s" % (
                t.get("name"), t.get("scopes"), [r.get("full_name") for r in (t.get("repositories") or [])]))


if __name__ == "__main__":
    main()
