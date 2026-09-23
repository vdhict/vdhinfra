#!/usr/bin/env bash
# Read-only check of the two 1Password items the forge MinIO identities need.
# Run it YOURSELF in your own terminal (needs the `op` CLI, signed in).
# Prints titles, exact field labels, value-present flags, ACCESS_KEY (not a
# secret), and for SECRET_KEY / RESTIC_PASSWORD ONLY length + charset.
# Secret values never leave the python process.
set -euo pipefail
for t in minio-forge-pg minio-forge-volsync; do
  echo "== $t"
  op item get "$t" --vault home-infra --format json | python3 -c '
import json,sys
it=json.load(sys.stdin)
print("  title:",repr(it.get("title")))
want={"minio-forge-pg":["ACCESS_KEY","SECRET_KEY"],"minio-forge-volsync":["ACCESS_KEY","SECRET_KEY","RESTIC_PASSWORD"]}[it["title"]]
exp={"minio-forge-pg":"forge-pg","minio-forge-volsync":"forge-volsync"}[it["title"]]
labels={}
for f in it.get("fields",[]):
    l=f.get("label"); v=f.get("value") or ""
    if l in ("notesPlain","",None): continue
    labels[l]=v
    line=f"  field {l!r}: value_present={bool(v)}"
    if l=="ACCESS_KEY": line+=f" value={v!r} expected={exp!r} ok={v==exp}"
    elif l=="SECRET_KEY": line+=f" length={len(v)} (want 40) alnum_only={v.isascii() and v.isalnum()}"
    elif l=="RESTIC_PASSWORD": line+=f" length={len(v)}"
    print(line)
for w in want:
    if w not in labels:
        near=[l for l in labels if l.lower()==w.lower() or l.strip()==w]
        print(f"  MISSING label {w!r}" + (f" - found near-miss {near!r} (case/whitespace)" if near else ""))
'
done
