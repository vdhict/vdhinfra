#!/usr/bin/env python3
"""chg-2026-11-28-106 step B: push the offline OCI copy of the running MinIO image, unchanged, into the forge registry.

Source: an OCI image layout on the Mini (B6), built from the Spegel node cache by content digest (every blob verified
against its sha256 before this script runs). The layout holds ONE manifest: linux/amd64 of the upstream index (B1:
the cache serves no other platform, so the platform manifest is copied and pinned, never re-tagged/rebuilt/mutated).

Credential (B3, route of hack/ops/forge-push-cli-token.py): a short-lived admforgejo token, scope write:package, minted
with the in-pod `forgejo admin user generate-access-token --raw`. It lives only in this process and in the environment
of the crane children, which read it through a docker credential helper that holds no secret. It is deleted by SQL in a
finally block and the script proves it is gone (GET /api/v1/user with it = 401, 0 rows left). Never printed.

Checks (B2, B4): crane digest on the forge ref == expected digest (string compare), crane validate --remote PASS,
anonymous manifest GET = 401.

Usage: chg-2026-11-28-106-mirror-push.py <layout-dir> <forge-ref-with-tag> <expected-digest> <scratch-dir> [--check-only]
"""
import datetime
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# forge-push-cli-token.py (+ forge-push-short-token.py) live in the operator checkout; FPCT_DIR points there.
spec = importlib.util.spec_from_file_location(
    "fpct", os.path.join(os.environ.get("FPCT_DIR", HERE), "forge-push-cli-token.py"))
fpct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fpct)
CRANE = os.environ.get("CRANE", "crane")
CHG = "chg-2026-11-28-106"


def anon_manifest_status(ref, digest):
    host, path = ref.split("/", 1)
    repo = path.rsplit(":", 1)[0]
    return subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20",
                           "-H", "Accept: application/vnd.oci.image.manifest.v1+json",
                           "https://%s/v2/%s/manifests/%s" % (host, repo, digest)],
                          capture_output=True, text=True).stdout.strip()


def main():
    args = [a for a in sys.argv[1:] if a != "--check-only"]
    if len(args) != 4:
        sys.exit(__doc__)
    layout, ref, expected, scratch = args
    with open(os.path.join(layout, "index.json")) as f:
        idx = json.load(f)
    descs = idx["manifests"]
    if len(descs) != 1 or descs[0]["digest"] != expected:
        sys.exit("layout index must hold exactly the expected manifest %s; refusing" % expected)
    print("layout manifest %s platform %s" % (descs[0]["digest"], descs[0].get("platform")))
    print("anonymous manifest GET before: HTTP %s" % anon_manifest_status(ref, expected))
    if "--check-only" in sys.argv:
        return

    name = "%s-mirror-push-%s" % (CHG, datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S"))
    tok = fpct.kc("exec", "deploy/forgejo", "-c", "forgejo", "--", "forgejo", "admin", "user", "generate-access-token",
                  "--username", fpct.USER, "--token-name", name, "--scopes", "write:package", "--raw").strip()
    print("minted %s token %s (write:package), value not shown" % (fpct.USER, name))
    tdir = tempfile.mkdtemp(prefix="cred-", dir=scratch)
    helper = os.path.join(tdir, "docker-credential-chg106")
    cfgdir = os.path.join(tdir, "docker")
    ok = False
    try:
        with open(helper, "w") as f:  # holds no secret: the token comes from the child's environment
            f.write('#!/bin/sh\ncase "$1" in get) cat >/dev/null; printf \'{"Username":"%s","Secret":"%%s"}\\n\' '
                    '"$FORGE_PUSH_TOKEN";; *) cat >/dev/null;; esac\n' % fpct.USER)
        os.chmod(helper, stat.S_IRWXU)
        os.mkdir(cfgdir)
        with open(os.path.join(cfgdir, "config.json"), "w") as f:
            json.dump({"credHelpers": {ref.split("/", 1)[0]: "chg106"}}, f)
        env = dict(os.environ, DOCKER_CONFIG=cfgdir, PATH=tdir + os.pathsep + os.environ["PATH"], FORGE_PUSH_TOKEN=tok)

        def crane(*a):
            p = subprocess.run([CRANE, *a], env=env, capture_output=True, text=True)
            out = (p.stdout + p.stderr).replace(tok, "[token]")
            return p.returncode, out.strip()

        rc, out = crane("push", layout, ref)
        print("crane push exit %d: %s" % (rc, out.splitlines()[-1] if out else ""))
        rc_d, got = crane("digest", ref)
        got = got.splitlines()[-1] if got else ""
        print("crane digest %s -> %s" % (ref, got))
        print("expected                   -> %s" % expected)
        same = got == expected
        print("byte-equal string compare: %s" % ("EQUAL" if same else "DIFFERENT"))
        rc_v, vout = crane("validate", "--remote", ref.rsplit(":", 1)[0] + "@" + expected)
        print("crane validate --remote exit %d: %s" % (rc_v, " | ".join(vout.splitlines()[-3:])))
        ok = rc == 0 and rc_d == 0 and same and rc_v == 0 and "PASS" in vout
    finally:
        fpct.sql("DELETE FROM access_token WHERE name=%s" % fpct.lit(name), write=True)
        print("token rows left: %s" % fpct.sql("SELECT count(*) FROM access_token WHERE name=%s" % fpct.lit(name)))
        print("token after delete: GET /api/v1/user -> HTTP %s" % fpct.fpst.token_status(tok))
        tok = None
        os.unlink(helper)
        os.unlink(os.path.join(cfgdir, "config.json"))
        os.rmdir(cfgdir)
        os.rmdir(tdir)
    anon = anon_manifest_status(ref, expected)
    print("anonymous manifest GET after: HTTP %s (must be 401)" % anon)
    ok = ok and anon == "401"
    print("package owner visibility: %s" % fpct.sql(
        "SELECT lower_name, visibility FROM \"user\" WHERE lower_name=%s" % fpct.lit(ref.split("/")[1].lower())))
    print("RESULT %s" % ("OK" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
