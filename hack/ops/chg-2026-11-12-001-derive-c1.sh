#!/usr/bin/env bash
# chg-2026-11-12-001 C1: derived delivery = the LIVE profiel-<n> bundle (decrypted from Git) with ONLY
# plugins/lesstof/__init__.py replaced by the C1 blob (b45ceab, f41093fe). Feed <out> to
# hack/family-ai/build-bundle.sh <n> <out>. Prints counts and hash prefixes only (family content stays local).
#   chg-2026-11-12-001-derive-c1.sh <2|3> <c1-plugin-file> <out>   (<out> must not exist)
set -euo pipefail
N="${1:?n}"; PLUG="${2:?plugin}"; OUT="${3:?out}"
case "$N" in 2|3) ;; *) echo "profiel 2 or 3 only" >&2; exit 1;; esac
OLD=368026712682a80d6763e0f7c84a6ec6db12eb576a60725d5f7c0ee17a4dec79
NEW=f41093fe750dde1ab0f8c61feac21371bd1f26587f8a9ab93ad006929de25384
ROOT="$(git rev-parse --show-toplevel)"
SEC="$ROOT/kubernetes/main/apps/family-ai/hermes/profiel-$N/bundle.sops.yaml"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
[ "$(shasum -a 256 "$PLUG" | cut -d' ' -f1)" = "$NEW" ] || { echo "C1 plugin pin mismatch" >&2; exit 1; }
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
[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$OLD" ] || { echo "profiel-$N live lesstof is not 36802671: refuse" >&2; exit 1; }
cp "$PLUG" "$f"
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived profiel-$N: $(grep -c . "$OUT/SHA256SUMS") files; lesstof ${OLD:0:8} -> ${NEW:0:8}; SHA256SUMS $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
