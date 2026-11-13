# land 3 (chg-2026-10-20-010, Argus B1 shape b): init-container check before the overlay is used.
# 1. the VENDOR files in the image equal source.json (the 15 files the overlay replaces, OWUI 0.11.4): a different
#    image refuses to start, so the overlay can never land on code it was not built against;
# 2. every overlay file mounted from the ConfigMaps equals overlay-sha256.json.
# Exit 1 on any mismatch (the pod does not start). Prints file names and booleans only.
import hashlib
import json
import os
import sys

APP = "/app/backend/open_webui"
OV = "/overlay"
src = json.load(open("/bijlagen-check/source.json"))
ovl = json.load(open("/bijlagen-check/overlay-sha256.json"))["sha256"]
bad = []
for rel, want in sorted(src["sha256"].items()):
    p = os.path.join(APP, rel)
    got = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else None
    if got != want:
        bad.append("vendor " + rel)
seen = set()
for d in sorted(os.listdir(OV)):
    for k in sorted(os.listdir(os.path.join(OV, d))):
        if k.startswith(".."):
            continue
        p = os.path.join(OV, d, k)
        if not os.path.isfile(p):
            continue
        seen.add(k)
        if hashlib.sha256(open(p, "rb").read()).hexdigest() != ovl.get(k):
            bad.append("overlay " + k)
missing = sorted(set(ovl) - seen)
bad += ["overlay missing " + k for k in missing]
print("land3 check: vendor files", len(src["sha256"]), "overlay files", len(seen), "mismatches", len(bad))
for b in bad:
    print("MISMATCH", b)
sys.exit(1 if bad else 0)
