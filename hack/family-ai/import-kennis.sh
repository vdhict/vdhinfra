#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Import Mack's kennisdienst into the repo (chg-2026-09-26-001, land-11).
#
#   hack/family-ai/import-kennis.sh <delivery-root> [models-staging]
#
# <delivery-root>   Mack's delivery (e.g. ~/family-ai-bundle/8d8d27a-kennis).
#                   Its root SHA256SUMS is verified in full first (lib.sh).
# [models-staging]  default ~/family-ai-models; its SHA256SUMS must hash to
#                   e4d43631... (the land-8a staging set).
#
# Writes (under kubernetes/main/apps/family-ai/kennisdienst/app/):
#   files/kennisdienst.py         the service, byte-identical to the delivery
#   files/models.sha256           the model checksums the init container checks
#   collectie-zeevaart.sops.yaml  one Secret key per source file, SOPS-encrypted
#
# Why the collection is a SOPS Secret and not a plain ConfigMap: it holds
# full texts of the MLC 2006 (ILO) and the ISM Code (IMO). Publishing those
# in a public repo is a licensing question nobody has answered; encrypted,
# they stay out of Git in the clear. Size is measured, not assumed: 300
# files, 611,712 bytes -> ~816 KB base64, under the 1 MiB object limit.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
. "$(dirname "$0")/lib.sh"
SRC="${1:-}"; MODELS="${2:-$HOME/family-ai-models}"
[ -n "$SRC" ] || die "usage: $0 <delivery-root> [models-staging]"
command -v sops >/dev/null || die "sops not on PATH (mise install)"
verify_delivery "$SRC"
ROOT="$(git rev-parse --show-toplevel)"
OUT="$ROOT/kubernetes/main/apps/family-ai/kennisdienst/app"
K="$SRC/kennisdienst"; C="$K/collecties"
[ -f "$K/kennisdienst.py" ] || die "no kennisdienst/kennisdienst.py in delivery"
[ -d "$C" ] || die "no kennisdienst/collecties in delivery"

# Models staging: the land-8a set, byte for byte.
MSUM_WANT=e4d43631c08186772a7ebcd28829be55f8dcef6fa71f93aec046979de5f0a1b4
[ "$(shasum -a 256 "$MODELS/SHA256SUMS" | cut -d' ' -f1)" = "$MSUM_WANT" ] \
  || die "models SHA256SUMS is not the land-8a set ($MSUM_WANT)"

# One collection directory per Secret, flat, *.md only, key-safe names.
cols=$(cd "$C" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||')
[ "$cols" = "zeevaart" ] || die "expected exactly collecties/zeevaart, found: $(echo $cols)"
[ -z "$(cd "$C/zeevaart" && find . -mindepth 1 ! -type f)" ] || die "collecties/zeevaart must be flat regular files"
files=$(cd "$C/zeevaart" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
while IFS= read -r f; do
  [[ "$f" =~ ^[A-Za-z0-9._-]+\.md$ ]] || die "file name not usable as a Secret key: $f"
  [ "${#f}" -le 200 ] || die "file name too long: $f"
done <<<"$files"
n=$(echo "$files" | wc -l | tr -d ' ')
bytes=$(cd "$C/zeevaart" && cat $files | wc -c | tr -d ' ')
[ "$bytes" -lt 740000 ] || die "collection is $bytes bytes - base64 would exceed the 1 MiB Secret limit; split it"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
{
  printf -- '---\n'
  printf '# Collection "zeevaart" for kennisdienst (Mack delivery %s), built by\n' "$(basename "$SRC")"
  printf '# hack/family-ai/import-kennis.sh: %s files, %s bytes. Mounted read-only at\n' "$n" "$bytes"
  printf '# /kennis/collecties/zeevaart (one file per key).\n'
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: kennisdienst-collectie-zeevaart\n'
  printf '  annotations:\n    kustomize.toolkit.fluxcd.io/substitute: disabled\ntype: Opaque\ndata:\n'
  while IFS= read -r f; do
    printf '  %s: %s\n' "$f" "$(base64 < "$C/zeevaart/$f" | tr -d '\n')"
  done <<<"$files"
} > "$TMP/collectie.yaml"
mkdir -p "$OUT/files"
sops_write "$TMP/collectie.yaml" "$OUT/collectie-zeevaart.sops.yaml"
cp "$K/kennisdienst.py" "$OUT/files/kennisdienst.py"
cp "$MODELS/SHA256SUMS" "$OUT/files/models.sha256"
cmp -s "$K/kennisdienst.py" "$OUT/files/kennisdienst.py" || die "copy of kennisdienst.py differs"
echo "import-kennis: zeevaart $n files / $bytes bytes -> collectie-zeevaart.sops.yaml (encrypted);" \
     "kennisdienst.py sha256 $(shasum -a 256 "$OUT/files/kennisdienst.py" | cut -d' ' -f1); models.sha256 $MSUM_WANT"
