#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Build the SOPS Secret carrying one Hermes profile's config bundle
# (chg-2026-09-26-001). Run on the workstation, inside the repo.
#
#   hack/family-ai/build-bundle.sh <1|2|3|4> <delivery-root>
#
# <delivery-root> is Mack's delivery (path from Sander). Its root SHA256SUMS
# is verified in full first; a delivery carrying VERVANGEN.txt (superseded)
# is refused.
#
# ALLOW-LIST (Argus A8): only config.yaml, SOUL.md and plugins/**
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
case "$N" in 1|2|3|4) ;; *) die "usage: $0 <1|2|3|4> <delivery-root>";; esac
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
    config.yaml|SOUL.md|plugins/*) ;;
    *) die "not on the allow-list: $f" ;;
  esac
done <<<"$files"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# chg-2026-11-13-004 (Argus C1) + chg-2026-10-20-010 (Argus N3): a live profile's bundle never changes silently.
# Compared with the LIVE bundle (decrypted from Git), every file that is new, removed or different - config.yaml,
# SOUL.md and plugins/** alike, every profile including 4 - must be named in ALLOW_BUNDLE_CHANGE (space-separated
# paths). A delivery rendered from an older line once carried a webeerlijk/kennis older than live, and would have
# added a cloud provider to profiel-1. ALLOW_PLUGIN_CHANGE is still read as an alias.
ALLOW=" ${ALLOW_BUNDLE_CHANGE:-} ${ALLOW_PLUGIN_CHANGE:-} "
if [ -f "$OUT" ]; then
  mkdir "$TMP/live"
  sops -d --output-type json "$OUT" | python3 -I -c '
import sys, json, base64, io, tarfile
t = tarfile.open(fileobj=io.BytesIO(base64.b64decode(json.load(sys.stdin)["data"]["bundle.tar.gz"])))
t.extractall(sys.argv[1], filter="data")' "$TMP/live" || die "cannot read the live bundle for the change guard"
  live=$(cd "$TMP/live" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)
  changed=""
  for f in $(printf '%s\n%s\n' "$files" "$live" | LC_ALL=C sort -u); do
    if [ ! -f "$TMP/live/$f" ]; then changed="$changed $f"; why="new"
    elif [ ! -f "$P/$f" ]; then changed="$changed $f"; why="removed"
    elif ! cmp -s "$TMP/live/$f" "$P/$f"; then changed="$changed $f"; why="differs"
    else continue; fi
    case "$ALLOW" in *" $f "*) echo "bundle change allowed ($why): $f" ;;
      *) die "bundle file $why vs live and is not in ALLOW_BUNDLE_CHANGE: $f" ;; esac
  done
  [ -n "$changed" ] || echo "bundle identical to live (no file changes)"
fi
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
# Written into /opt/data on EVERY start by the seed-once init container.
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
