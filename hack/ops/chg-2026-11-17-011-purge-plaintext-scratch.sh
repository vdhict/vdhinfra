#!/usr/bin/env bash
# chg-2026-11-17-011 (tsk-2026-11-09-101, wq-029): remove the plaintext profiel-1 bundle copies that the 101 rollout
# left in Atlas's session scratchpad (AGR-121: deletion only via a reviewed script with explicit paths).
#   dry    : list what would go (names and sizes only, never content)
#   purge  : delete exactly the three fixed directories below, then prove they are gone
# Refuses anything outside the fixed scratchpad p101 directory; never follows symlinks out of it.
set -euo pipefail
BASE="/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/ee591319-eebc-404d-a6ee-14e79ef61e04/scratchpad/p101"
TARGETS=(live delivery-p1-p101 dist)
MODE="${1:?usage: dry | purge}"
[ -d "$BASE" ] && [ ! -L "$BASE" ] || { echo "refused: $BASE missing or a symlink"; exit 2; }
for t in "${TARGETS[@]}"; do
  p="$BASE/$t"
  [ -e "$p" ] || { echo "absent: $t"; continue; }
  [ ! -L "$p" ] || { echo "refused: $t is a symlink"; exit 2; }
  real=$(cd "$p" && pwd -P); case "$real" in "$BASE"/*) ;; *) echo "refused: $t resolves outside base"; exit 2;; esac
  echo "$t files=$(find "$p" -type f | wc -l | tr -d ' ') bytes=$(du -sk "$p" | cut -f1)k"
done
[ "$MODE" = dry ] && exit 0
[ "$MODE" = purge ] || { echo "usage: dry | purge"; exit 2; }
for t in "${TARGETS[@]}"; do
  [ -e "$BASE/${t:?}" ] && rm -rf -- "${BASE:?}/${t:?}"
done
for t in "${TARGETS[@]}"; do [ -e "$BASE/$t" ] && { echo "FAILED: $t still present"; exit 6; }; done
echo "OK: ${TARGETS[*]} gone from $BASE ($(date -u +%FT%TZ))"
