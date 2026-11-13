#!/usr/bin/env bash
# chg-2026-10-20-010 land 3 B2 (Argus re-review 093319Z): derived delivery = the LIVE profiel-<n> bundle (decrypted
# from Git) with ONLY plugins/gezin/__init__.py replaced by the fe6fd3e blob (sha256 fa3ccacf; is_crisis judges the whole
# text in overlapping windows). Feed <out> to hack/family-ai/build-bundle.sh <n> <out>. Hash prefixes only.
#   chg-2026-10-20-010-derive-gezin-b2.sh <2|3> <gezin-plugin-file> <out>   (<out> must not exist)
set -euo pipefail
N="${1:?n}"; PLUG="${2:?plugin}"; OUT="${3:?out}"
case "$N" in 2|3) ;; *) echo "profiel 2 or 3 only" >&2; exit 1;; esac
OLD=b27fb2e97b907ecbb5bbad653ad11dd35bbdad12907e57fa38331dbf9f99f8c3
NEW=fa3ccacfcf30c3451bf486136f30eecf1f3daf53c2f68006b8abec76783bc411
ROOT="$(git rev-parse --show-toplevel)"
SEC="$ROOT/kubernetes/main/apps/family-ai/hermes/profiel-$N/bundle.sops.yaml"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
[ "$(shasum -a 256 "$PLUG" | cut -d' ' -f1)" = "$NEW" ] || { echo "B2 gezin pin mismatch" >&2; exit 1; }
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
f="$OUT/profiel-$N/plugins/gezin/__init__.py"
[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$OLD" ] || { echo "profiel-$N live gezin is not b27fb2e9: refuse" >&2; exit 1; }
cp "$PLUG" "$f"
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived profiel-$N: $(grep -c . "$OUT/SHA256SUMS") files; gezin ${OLD:0:8} -> ${NEW:0:8}; SHA256SUMS $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
