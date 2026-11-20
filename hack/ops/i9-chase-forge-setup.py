#!/usr/bin/env python3
"""I9 C1/C2 forge setup (chg-2026-10-14-005). Admin API via a short-lived admforgejo CLI token
(hack/ops/lib/forge_admin_token.py, chg-2026-11-20-001: the old admin Secret gets 401), handed to curl inside the
forge pod on STDIN and deleted afterwards; nothing secret printed or written. Idempotent: existing repo/keys are left alone.
  setup   create VDHICT/atlas-ops-export (private, main), key ~/.ssh/forge_atlas_ops_export as WRITE deploy key there;
          key ~/.ssh/forge_exchange_atlas_c2_ro as READ-ONLY deploy key on VDHICT/cluster-wires-exchange
  remove  delete those two deploy keys (rollback); repo is kept
"""
import json, os, subprocess, sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import forge_admin_token as fat  # noqa: E402

SSH = Path.home() / ".ssh"
ORG, REPO, EXCH = "VDHICT", "atlas-ops-export", "cluster-wires-exchange"
KEYS = [("forge_atlas_ops_export", REPO, False, "atlas-i9-c1-export-rw"),
        ("forge_exchange_atlas_c2_ro", EXCH, True, "atlas-i9-c2-to-atlas-ro")]
SCOPES = {"setup": "write:organization,write:repository", "remove": "write:repository"}
TOK = None  # admforgejo CLI token, held only inside main()


def forge(method, path, body=None):
    return fat.pod_api(TOK, method, path, body)


def main():
    global TOK
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in SCOPES:
        sys.exit(__doc__)
    with fat.temp_token("i9-chase-forge-" + mode, SCOPES[mode], log=print) as TOK:
        _main()
    TOK = None


def _main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "setup":
        c, t = forge("GET", "/repos/%s/%s" % (ORG, REPO))
        if c == 404:
            c, t = forge("POST", "/orgs/%s/repos" % ORG, {"name": REPO, "private": True, "auto_init": True,
                         "default_branch": "main", "description": "Atlas open-loop change export (I9 C1)"})
            print("repo create HTTP", c)
            if c != 201:
                sys.exit(t[:200])
        else:
            print("repo exists HTTP", c)
        for fn, repo, ro, title in KEYS:
            p = SSH / fn
            if not p.exists():
                subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", title, "-f", str(p)], check=True)
            pub = (SSH / (fn + ".pub")).read_text().strip()
            c, t = forge("GET", "/repos/%s/%s/keys" % (ORG, repo))
            have = [k for k in json.loads(t) if k.get("title") == title] if c == 200 else []
            if have:
                print("%s: key already on %s" % (title, repo)); continue
            c, t = forge("POST", "/repos/%s/%s/keys" % (ORG, repo), {"title": title, "key": pub, "read_only": ro})
            print("%s: add to %s read_only=%s HTTP %d" % (title, repo, ro, c))
            if c != 201:
                sys.exit(t[:200])
    elif mode == "remove":
        for fn, repo, ro, title in KEYS:
            c, t = forge("GET", "/repos/%s/%s/keys" % (ORG, repo))
            for k in (json.loads(t) if c == 200 else []):
                if k.get("title") == title:
                    print(title, "delete HTTP", forge("DELETE", "/repos/%s/%s/keys/%d" % (ORG, repo, k["id"]))[0])
    else:
        sys.exit(__doc__)


main()
