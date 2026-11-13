#!/usr/bin/env bash
# chg-2026-10-20-010 land 3 B2/N1 for the adult profiles: derived delivery = the LIVE profiel-<n> bundle (decrypted
# from Git) with ONLY plugins/webeerlijk/__init__.py replaced by family-ai-cluster 27379e7 (sha256 feffcb0e: live
# ce67e9e2 + hulpnet net + whole-text crisis windows with the N1 fix). Feed <out> to hack/family-ai/build-bundle.sh <n> <out>. Hash prefixes only.
#   chg-2026-10-20-010-derive-webeerlijk.sh <1|4> <webeerlijk-plugin-file> <out>   (<out> must not exist)
set -euo pipefail
N="${1:?n}"; PLUG="${2:?plugin}"; OUT="${3:?out}"
case "$N" in 1) OLD=ce67e9e2eb;; 4) OLD=a6d7d44696;; *) echo "profiel 1 or 4 only" >&2; exit 1;; esac
NEW=feffcb0e441e5e686447486e8783390d860702b724dfd6724f852138b7cdae4a
ROOT="$(git rev-parse --show-toplevel)"
SEC="$ROOT/kubernetes/main/apps/family-ai/hermes/profiel-$N/bundle.sops.yaml"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
[ "$(shasum -a 256 "$PLUG" | cut -d' ' -f1)" = "$NEW" ] || { echo "webeerlijk pin mismatch" >&2; exit 1; }
mkdir -p "$OUT/profiel-$N"
sops -d --output-type json "$SEC" | python3 -I -c '
import sys, json, base64, hashlib, io, tarfile, pathlib
out = pathlib.Path(sys.argv[1]); d = json.load(sys.stdin)["data"]
b = base64.b64decode(d["bundle.tar.gz"]); want = base64.b64decode(d["bundle.tar.gz.sha256"]).decode().split()[0]
assert hashlib.sha256(b).hexdigest() == want, "bundle sha256 mismatch"
t = tarfile.open(fileobj=io.BytesIO(b)); n = 0
for m in t.getmembers():
    assert m.isfile() and not m.name.startswith(("/", "..")) and ".." not in m.name.split("/"), m.name
    if m.name == "SHA256SUMS": continue
    p = out / m.name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(t.extractfile(m).read()); n += 1
print(f"live bundle sha256 {want[:12]}, {n} files extracted")
' "$OUT/profiel-$N"
f="$OUT/profiel-$N/plugins/webeerlijk/__init__.py"
case "$(shasum -a 256 "$f" | cut -d' ' -f1)" in "$OLD"*) ;; *) echo "profiel-$N live webeerlijk is not ${OLD:0:8}: refuse" >&2; exit 1;; esac
cp "$PLUG" "$f"
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived profiel-$N: $(grep -c . "$OUT/SHA256SUMS") files; webeerlijk ${OLD:0:8} -> ${NEW:0:8}; SHA256SUMS $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
