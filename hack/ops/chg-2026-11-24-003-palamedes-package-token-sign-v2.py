#!/usr/bin/env python3
"""v2 (2026-11-26, desk-557e3a6, Larry 051909 point 2) of chg-2026-11-24-003-palamedes-package-token-sign.py: token name
desk-557e3a6; the token file left EMPTY by run4 (truncated 25-11) is reused in place only when it is 0 bytes and 0600
(a non-empty file is moved aside to a timestamped name, never deleted); palamedes row count before == after is
checked and fails the run if not. Mint, revoke, proof and the never-print rule unchanged. Earlier header follows.
chg-2026-11-24-003 / tsk-2026-11-24-961: ONE short-lived palamedes write:package token for the dce1f1e demo-video
image push + cosign signing, then revoke at once (Mack via Larry 184429, 2026-11-25; chg-2026-11-20-001 stands).

Mint route = 13-10 (chg-2026-10-12-004 evidence 27-mackdev): `forgejo admin user generate-access-token --raw` in the
forge pod, user palamedes, scope write:package (Forgejo cannot scope a token per package; palamedes owns only
passkey-point-* packages). The value goes ONLY into ~/.config/pka/mack-dev-forge-package (0600, the file the
build-sign script reads, as on 13-10). The previous (revoked 20-11) value is moved aside first, not deleted.
Revoke route = chg-2026-11-20-001 / forge-push-cli-token.py: SQL delete on the forge-pg primary in a finally block,
then the file is truncated, and the proof is printed: public API 401 for the token, 0 rows with its name.
Never prints the token.

Usage: chg-2026-11-24-003-palamedes-package-token-sign.py <sign-script> <src-git> <commit> <sign-log> <evidence-dir>
(PP_SCRATCH must be set, as for the sign script.)
"""
import datetime
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fpct", os.path.join(HERE, "forge-push-cli-token.py"))
fpct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fpct)

USER = "palamedes"
TOKFILE = os.path.expanduser("~/.config/pka/mack-dev-forge-package")


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    sign, src, commit, log, evd = sys.argv[1:6]
    if os.path.exists(log):
        sys.exit("sign log exists; write-once, refusing")
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")
    name = "chg-2026-11-24-003-desk-557e3a6-%s" % ts
    before = fpct.sql("SELECT count(*) FROM access_token t JOIN \"user\" u ON u.id=t.uid WHERE u.lower_name='palamedes'")
    print("palamedes token rows before: %s" % before)
    reuse = False
    if os.path.exists(TOKFILE):
        st = os.stat(TOKFILE)
        if st.st_size == 0 and (st.st_mode & 0o777) == 0o600:
            reuse = True
            print("token file exists, 0 bytes, mode 600 (truncated by run4): reused in place")
        else:
            aside = TOKFILE + ".aside-" + ts
            if os.path.exists(aside):
                sys.exit("%s exists; refusing" % aside)
            os.replace(TOKFILE, aside)
            print("non-empty token file moved aside to %s, not deleted" % os.path.basename(aside))
    tok = None
    rc = 1
    try:
        tok = fpct.kc("exec", "deploy/forgejo", "-c", "forgejo", "--", "forgejo", "admin", "user",
                      "generate-access-token", "--username", USER, "--token-name", name, "--scopes", "write:package",
                      "--raw").strip()
        if len(tok) != 40:
            raise SystemExit("mint output is not a 40-char token (length %d); refusing" % len(tok))
        print("minted %s token %s, value not shown, length %d" % (USER, name, len(tok)))
        print("scope readback (forge DB): %s" % fpct.sql("SELECT scope FROM access_token WHERE name=%s" % fpct.lit(name)))
        fd = os.open(TOKFILE, os.O_WRONLY | os.O_TRUNC) if reuse else os.open(TOKFILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(tok)
        print("token file written mode %o" % (os.stat(TOKFILE).st_mode & 0o777))
        p = subprocess.run([sign, "sign", src, commit, log, evd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rc = p.returncode
        print("sign run exit %d (log %s)" % (rc, log))
        with open(log, errors="replace") as f:
            if tok in f.read():
                print("WARNING: token value found in the sign log")
                rc = 99
    finally:
        if os.path.exists(TOKFILE):
            with open(TOKFILE, "w"):
                pass
            print("token file truncated to %d bytes" % os.path.getsize(TOKFILE))
        fpct.sql("DELETE FROM access_token WHERE name=%s" % fpct.lit(name), write=True)
        print("token rows left with name %s: %s" % (name, fpct.sql("SELECT count(*) FROM access_token WHERE name=%s" % fpct.lit(name))))
        after = fpct.sql("SELECT count(*) FROM access_token t JOIN \"user\" u ON u.id=t.uid WHERE u.lower_name='palamedes'")
        print("palamedes token rows after: %s (before %s): %s" % (after, before, "EQUAL" if str(after).strip() == str(before).strip() else "MISMATCH"))
        if str(after).strip() != str(before).strip():
            rc = 98
        if tok:
            print("token after delete: GET /api/v1/user -> HTTP %s" % fpct.fpst.token_status(tok))
        tok = None
    sys.exit(rc)


if __name__ == "__main__":
    main()
