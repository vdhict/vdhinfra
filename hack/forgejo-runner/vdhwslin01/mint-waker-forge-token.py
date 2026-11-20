#!/usr/bin/env python3
"""Mint the vdhwslin01 waker's forge token (chg-2026-10-05-031, Argus F5).

Narrowest Forgejo 15 allows: user mypka-bot, scope read:repository, and
RESTRICTED to the one repository mypka-bot/passkey-point-dotnet (API
`repositories` on token create). Forgejo has no token expiry, so the expiry is
a date in kubernetes/main/apps/devtools/vdhwslin01-waker/app/kustomization.yaml
(forge_token_expires) that the waker enforces itself: rotate with this script
and bump that date (+90 days).

Secrets stay in memory: the token is minted by the forge CLI inside the pod
(hack/ops/lib/forge_admin_token.py; chg-2026-11-20-001: the old admin Secret
gets 401 and the token API wants a password login), restricted to the one
repository by the same DB row the API's `repositories` option writes, and goes
straight into `kubectl apply` on stdin. --delete-old deletes the old token row
by SQL. Nothing secret is printed or written to disk.

Usage: mint-waker-forge-token.py [--delete-old <token-name>]
"""
import datetime
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ops", "lib"))
import forge_admin_token as fat  # noqa: E402

NS = "devtools"
USER = "mypka-bot"
REPO = {"owner": "mypka-bot", "name": "passkey-point-dotnet"}
SECRET = "vdhwslin01-waker-forge"


def kubectl(*args, stdin=None):
    return subprocess.run(["kubectl", "-n", NS, *args], input=stdin, capture_output=True, check=True).stdout


def main():
    old = sys.argv[sys.argv.index("--delete-old") + 1] if "--delete-old" in sys.argv else None
    name = "vdhwslin01-waker-%s" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M")
    tok = {"sha1": fat.mint(USER, "read:repository", name)}
    try:
        tok["id"], _ = fat.restrict_to_repo(name, USER, REPO["owner"], REPO["name"])
    except Exception:
        print("restriction failed; deleting the new token: rows left %s" % fat.delete_token(USER, name=name))
        raise
    tok.update(name=name, scopes=["read:repository"], repositories=[{"full_name": "%s/%s" % (REPO["owner"], REPO["name"])}])
    secret = json.dumps({"apiVersion": "v1", "kind": "Secret",
                         "metadata": {"name": SECRET, "namespace": NS,
                                      "labels": {"app.kubernetes.io/name": "vdhwslin01-waker",
                                                 "vdh.chg": "chg-2026-10-05-031"}},
                         "type": "Opaque", "stringData": {"token": tok["sha1"]}})
    kubectl("apply", "-f", "-", stdin=secret.encode())
    secret = None
    print("minted token id=%s name=%s scopes=%s repositories=%s -> Secret %s/%s" % (
        tok.get("id"), tok.get("name"), tok.get("scopes"),
        [r.get("full_name") or r.get("name") for r in (tok.get("repositories") or [])], NS, SECRET))
    if old:
        print("deleted old token %s by SQL: rows left %s" % (old, fat.delete_token(USER, name=old)))
    rows = fat.sql("SELECT t.name, t.scope, t.resource_all_repos, coalesce(string_agg(r.owner_name||'/'||r.name, ','), '') "
                   "FROM access_token t LEFT JOIN access_token_resource_repo x ON x.token_id=t.id "
                   "LEFT JOIN repository r ON r.id=x.repo_id WHERE t.uid=(SELECT id FROM \"user\" WHERE lower_name=%s) "
                   "AND t.name LIKE 'vdhwslin01-waker%%' GROUP BY t.id ORDER BY t.id" % fat.lit(USER))
    for line in rows.splitlines():
        n, sc, allr, repos = line.split("|")
        print("present: name=%s scopes=%s all_repos=%s repositories=%s" % (n, sc, allr, repos.split(",") if repos else []))


if __name__ == "__main__":
    main()
