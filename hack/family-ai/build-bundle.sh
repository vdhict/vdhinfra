#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Build the SOPS Secret carrying one Hermes profile's config bundle
# (chg-2026-09-26-001). Run on the workstation, inside the repo.
#
#   hack/family-ai/build-bundle.sh <1|2|3> <delivery-root>
#
# <delivery-root> is Mack's delivery (path from Sander). Its root SHA256SUMS
# is verified in full first; a delivery carrying VERVANGEN.txt (superseded)
# is refused.
#
# ALLOW-LIST (Argus A8): only config.yaml, SOUL.md, plugins/** and skills/**
# from profiel-<n>/ are shipped. Refused anywhere: .env, auth.json, state
# (memories/, state.db*, sessions/), symlinks, anything outside the list.
# The seed-once init container re-checks all of this in the pod BEFORE it
# extracts anything.
#
# Output: kubernetes/main/apps/family-ai/hermes/profiel-<n>/bundle.sops.yaml,
# SOPS-encrypted. The profile content (persona etc.) is family content and
# never reaches Git in clear. Prints only file counts and checksums.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
. "$(dirname "$0")/lib.sh"
N="${1:-}"; SRC="${2:-}"
case "$N" in 1|2|3) ;; *) die "usage: $0 <1|2|3> <delivery-root>";; esac
command -v sops >/dev/null || die "sops not on PATH (mise install)"
verify_delivery "$SRC"
ROOT="$(git rev-parse --show-toplevel)"
OUT="$ROOT/kubernetes/main/apps/family-ai/hermes/profiel-$N/bundle.sops.yaml"
P="$SRC/profiel-$N"; [ -d "$P" ] || die "no profiel-$N in delivery"

files=$(cd "$P" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
while IFS= read -r f; do
  case "$f" in
    *" "*) die "file name with space: refused" ;;
    .env|*/.env|auth.json|*/auth.json) die "refused: $f" ;;
    config.yaml|SOUL.md|plugins/*|skills/*) ;;
    *) die "not on the allow-list: $f" ;;
  esac
done <<<"$files"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/b"
( cd "$P" && COPYFILE_DISABLE=1 tar -cf - $files ) | ( cd "$TMP/b" && tar -xf - )
( cd "$TMP/b" && shasum -a 256 $files > SHA256SUMS )
# each file's checksum must equal the one in Mack's root SHA256SUMS
while IFS= read -r f; do
  want=$(awk -v p="profiel-$N/$f" '{q=$2; sub(/^\*/,"",q); if (q==p) print $1}' "$SRC/SHA256SUMS")
  got=$(shasum -a 256 "$TMP/b/$f" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for profiel-$N/$f"
done <<<"$files"
( cd "$TMP/b" && COPYFILE_DISABLE=1 tar --format=ustar --uid 10000 --gid 10000 --uname hermes --gname hermes \
    -cf "$TMP/bundle.tar" SHA256SUMS $files )
gzip -n -9 "$TMP/bundle.tar"
S=$(shasum -a 256 "$TMP/bundle.tar.gz" | cut -d' ' -f1)
BYTES=$(wc -c < "$TMP/bundle.tar.gz" | tr -d ' ')
[ "$BYTES" -lt 700000 ] || die "bundle.tar.gz is $BYTES bytes - too large for a Secret"
printf '%s  bundle.tar.gz\n' "$S" > "$TMP/bundle.tar.gz.sha256"
cat > "$TMP/bundle.sops.yaml" <<YAML
---
# Config bundle for hermes-profiel-$N (Mack's delivery $(basename "$SRC")), built by
# hack/family-ai/build-bundle.sh. bundle.tar.gz sha256 $S.
# Copied ONCE into /opt/data by the seed-once init container.
apiVersion: v1
kind: Secret
metadata:
  name: family-ai-hermes-profiel-bundle
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
type: Opaque
data:
  bundle.tar.gz: $(base64 < "$TMP/bundle.tar.gz" | tr -d '\n')
  bundle.tar.gz.sha256: $(base64 < "$TMP/bundle.tar.gz.sha256" | tr -d '\n')
YAML
sops_write "$TMP/bundle.sops.yaml" "$OUT"
echo "build-bundle: profiel-$N $(echo "$files" | wc -l | tr -d ' ') files -> $OUT (encrypted), bundle sha256 $S, $BYTES bytes"
