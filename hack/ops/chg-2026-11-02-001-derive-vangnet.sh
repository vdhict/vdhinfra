#!/usr/bin/env bash
# chg-2026-11-02-001 standnaam-vangnet (tsk-2026-11-12-209): derived delivery = the LIVE profiel-<n> bundle (decrypted
# from Git) with ONLY plugins/gezin/__init__.py replaced by the e25f17e blob (sha256 b27fb2e9; a bare stand name or empty
# answer is never sent, help block completed). Feed <out> to hack/family-ai/build-bundle.sh <n> <out>. Hash prefixes only.
#   chg-2026-11-02-001-derive-vangnet.sh <2|3> <gezin-plugin-file> <out>   (<out> must not exist)
set -euo pipefail
N="${1:?n}"; PLUG="${2:?plugin}"; OUT="${3:?out}"
case "$N" in 2|3) ;; *) echo "profiel 2 or 3 only" >&2; exit 1;; esac
OLD=5f6d70406628ff4c5e5124ef6e69663dde9649acd21e0bf5b19da651406814fe
NEW=b27fb2e97b907ecbb5bbad653ad11dd35bbdad12907e57fa38331dbf9f99f8c3
ROOT="$(git rev-parse --show-toplevel)"
SEC="$ROOT/kubernetes/main/apps/family-ai/hermes/profiel-$N/bundle.sops.yaml"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
[ "$(shasum -a 256 "$PLUG" | cut -d' ' -f1)" = "$NEW" ] || { echo "vangnet gezin pin mismatch" >&2; exit 1; }
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
[ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$OLD" ] || { echo "profiel-$N live gezin is not 5f6d7040: refuse" >&2; exit 1; }
cp "$PLUG" "$f"
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived profiel-$N: $(grep -c . "$OUT/SHA256SUMS") files; gezin ${OLD:0:8} -> ${NEW:0:8}; SHA256SUMS $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
