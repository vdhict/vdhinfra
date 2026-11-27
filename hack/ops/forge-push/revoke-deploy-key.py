#!/usr/bin/env python3
"""Revoke one forge push deploy key with readback (chg-2026-11-13-002 L7). Runbook: docs/runbooks/forge-deploy-key-revoke.md

Usage: revoke-deploy-key.py <chg-id> <owner/repo> [--execute]
Without --execute it only shows what it would delete (dry run). With --execute:
  1 DELETE /repos/<owner>/<repo>/keys/<deploy_key_id> with a short-lived admforgejo token (hack/ops/lib, deleted after);
  2 readback A: the API key list of the repo no longer holds deploy_key_id;
  3 readback B: read-only SQL, deploy_key rows for public_key_id = 0 and public_key row gone;
  4 readback C: if the key file is still on disk, `git ls-remote` with it is refused by the forge;
  5 one changes.jsonl line (executed) with the three readbacks; then set the entry's status to "revoked" in
    deploy-keys.json by hand (reviewed commit). The local key file is moved aside by hand (mv, never rm, AGR-121).
Nothing secret is printed.
"""
import json
import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
REGISTRY = HERE / "deploy-keys.json"
OPS_CLI = HERE.parents[2] / "ops" / "ops"


def main(argv):
    execute = "--execute" in argv
    args = [a for a in argv if a != "--execute"]
    if len(args) != 2 or not re.match(r"^chg-\d{4}-\d{2}-\d{2}-\d{3}$", args[0]):
        sys.exit(__doc__)
    chg, repo = args
    reg = json.loads(REGISTRY.read_text())
    e = next((k for k in reg["keys"] if k["repo"].lower() == repo.lower()), None)
    if not e or not e.get("deploy_key_id") or not e.get("public_key_id"):
        sys.exit("no registered deploy_key_id/public_key_id for %s; read the forge (deploy_key table) by hand" % repo)
    owner, name = e["repo"].split("/", 1)
    print("target: %s deploy_key_id=%s public_key_id=%s fingerprint=%s" % (e["repo"], e["deploy_key_id"],
                                                                         e["public_key_id"], e["fingerprint"]))
    if not execute:
        print("dry run: nothing deleted (add --execute)")
        return 0
    import forge_admin_token as fat  # noqa: PLC0415 - only when executing
    with fat.temp_token("%s-revoke" % chg, "write:repository", log=print) as tok:
        code, _ = fat.pod_api(tok, "DELETE", "/repos/%s/%s/keys/%d" % (owner, name, int(e["deploy_key_id"])))
        print("DELETE deploy key -> HTTP %d" % code)
        lcode, text = fat.pod_api(tok, "GET", "/repos/%s/%s/keys?limit=50" % (owner, name))
    ids = [k.get("id") for k in json.loads(text)] if lcode == 200 else None
    a_ok = ids is not None and int(e["deploy_key_id"]) not in ids
    rows = fat.sql("select (select count(*) from deploy_key where key_id=%d), (select count(*) from public_key "
                   "where id=%d)" % (int(e["public_key_id"]), int(e["public_key_id"]))).strip()
    b_ok = rows.replace(" ", "") in ("0|0", "0,0")
    kf = os.path.expanduser(e["key_file"])
    c = "key file absent"
    c_ok = True
    if os.path.isfile(kf):
        ssh = "ssh -F none -i %s -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=%s " \
              "-o StrictHostKeyChecking=yes -o HostKeyAlias=%s -o BatchMode=yes" % (kf, HERE / "known_hosts",
                                                                                  reg["forge_ssh_host"])
        r = subprocess.run(["git", "ls-remote", "ssh://git@%s:%d/%s.git" % (reg["forge_ssh_host"],
                                                                         reg["forge_ssh_port"], e["repo"])],
                           env=dict(os.environ, GIT_SSH_COMMAND=ssh, GIT_TERMINAL_PROMPT="0"),
                           capture_output=True, text=True, timeout=60)
        c_ok = r.returncode != 0
        c = "ls-remote with the key exit %d (%s)" % (r.returncode, "refused" if c_ok else "STILL WORKS")
    result = "REVOKED" if (code == 204 and a_ok and b_ok and c_ok) else "REVOKE-INCOMPLETE"
    payload = {"kind": "forge-deploy-key-revoke", "repo": e["repo"], "deploy_key_id": e["deploy_key_id"],
               "public_key_id": e["public_key_id"], "fingerprint": e["fingerprint"], "delete_http": code,
               "readback_api": "absent" if a_ok else "PRESENT", "readback_sql": rows, "readback_git": c,
               "result": result}
    subprocess.run([sys.executable, str(OPS_CLI), "change", "event", chg, "executed", "--actor", "k8s-engineer",
                    "--payload-json", json.dumps(payload, sort_keys=True)], check=True)
    print(result, json.dumps(payload, sort_keys=True))
    return 0 if result == "REVOKED" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
