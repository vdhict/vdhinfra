#!/usr/bin/env bash
# chg-2026-11-12-002: derived delivery = the LIVE profiel-<n> bundle (decrypted from Git) with ONLY
# plugins/lesstof/__init__.py replaced by the KOP-source blob (5123314, 372a47ad). Feed <out> to
# hack/family-ai/build-bundle.sh <n> <out>. Prints counts and hash prefixes only (family content stays local).
#   chg-2026-11-12-002-derive.sh <2|3> <plugin-file> <out>   (<out> must not exist)
set -euo pipefail
N="${1:?n}"; PLUG="${2:?plugin}"; OUT="${3:?out}"
case "$N" in 2|3) ;; *) echo "profiel 2 or 3 only" >&2; exit 1;; esac
OLD=f41093fe750dde1ab0f8c61feac21371bd1f26587f8a9ab93ad006929de25384
NEW=372a47adaf8cd27bdaa80c2428d0dfea9cc673759d812e702dc7fa974d7ec2ad
ROOT="$(git rev-parse --show-toplevel)"
SEC="$ROOT/kubernetes/main/apps/family-ai/hermes/profiel-$N/bundle.sops.yaml"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
[ "$(shasum -a 256 "$PLUG" | cut -d' ' -f1)" = "$NEW" ] || { echo "plugin pin mismatch" >&2; exit 1; }
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
f="$OUT/profiel-$N/plugins/lesstof/__init__.py"
[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$OLD" ] || { echo "profiel-$N live lesstof is not f41093fe: refuse" >&2; exit 1; }
cp "$PLUG" "$f"
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived profiel-$N: $(grep -c . "$OUT/SHA256SUMS") files; lesstof ${OLD:0:8} -> ${NEW:0:8}; SHA256SUMS $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
