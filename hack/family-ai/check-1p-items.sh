#!/usr/bin/env bash
# Read-only check of the 1Password items family-ai needs (chg-2026-09-26-001).
# Run it YOURSELF in your own terminal (needs the `op` CLI, signed in).
# Prints item titles, exact field labels, value-present flags, and for secret
# fields ONLY length + charset. Values never leave the python process.
# ACCESS_KEY and WEBUI_ADMIN_EMAIL are not secrets and are shown.
set -euo pipefail
for t in "family-ai" "family-ai MODEL_API_KEY" "minio-family-ai-volsync"; do
  echo "== $t"
  n=$(op item list --vault home-infra --format json | python3 -c 'import json,sys; t=sys.argv[1]; print(sum(1 for i in json.load(sys.stdin) if i.get("title")==t))' "$t")
  [ "$n" = 1 ] || { echo "  EXPECTED exactly 1 item titled '$t' in home-infra, found $n (ESO fails on 0 and on >1)"; continue; }
  op item get "$t" --vault home-infra --format json | python3 -c '
import json,sys
it=json.load(sys.stdin); t=it["title"]
want={
 "family-ai":["WEBUI_SECRET_KEY","WEBUI_ADMIN_EMAIL","WEBUI_ADMIN_PASSWORD",
              "API_SERVER_KEY_1","API_SERVER_KEY_2","API_SERVER_KEY_3",
              "GEZIN_TOKEN_PROFIEL_2","GEZIN_TOKEN_PROFIEL_3",
              "GEZIN_NTFY_TOPIC","GEZIN_NTFY_TOPIC_TEST"],
 "family-ai MODEL_API_KEY":["password"],
 "minio-family-ai-volsync":["ACCESS_KEY","SECRET_KEY","RESTIC_PASSWORD"]}[t]
show={"ACCESS_KEY","WEBUI_ADMIN_EMAIL"}
labels={}
for f in it.get("fields",[]):
    l=f.get("label"); v=f.get("value") or ""
    if l in ("notesPlain","",None): continue
    if l in labels: print(f"  DUPLICATE label {l!r} - ESO refuses duplicate labels")
    labels[l]=v
for w in want:
    if w not in labels:
        near=[l for l in labels if l.lower()==w.lower() or l.strip()==w]
        print(f"  MISSING {w!r}"+(f" (near-miss {near!r})" if near else "")); continue
    v=labels[w]
    line=f"  {w}: present={bool(v)}"
    if w in show: line+=f" value={v!r}"
    else:
        line+=f" length={len(v)} alnum_only={v.isascii() and v.isalnum()} has_semicolon={chr(59) in v} edge_whitespace={v!=v.strip()}"
    if w=="ACCESS_KEY": line+=" ok="+str(v=="family-ai-volsync")
    if w=="SECRET_KEY": line+=" (want 40, alnum)"
    print(line)
k=[labels.get(f"API_SERVER_KEY_{i}") for i in (1,2,3)]
if t=="family-ai" and all(k): print("  API_SERVER_KEY_1..3 distinct:", len(set(k))==3)
g=[labels.get(f"GEZIN_TOKEN_PROFIEL_{i}") for i in (2,3)]
if t=="family-ai" and all(g): print("  GEZIN_TOKEN_PROFIEL_2/3 distinct:", len(set(g))==2, "(gezinsdienst refuses tokens shorter than 24)")
'
done
