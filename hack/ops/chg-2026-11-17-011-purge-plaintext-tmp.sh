#!/usr/bin/env bash
# chg-2026-11-17-011 (tsk-2026-11-20-122 wq-033, tsk-2026-11-09-101 wq-032): remove plaintext family-ai render trees.
#   wq-033: nine /private/tmp render trees of Mack, released by team choice (Larry 190256); ~/family-ai-bundle is NOT touched.
#   wq-032: Atlas's own leftovers in the session scratchpad (appr030, p101) after the 101 rollout (Argus F1 20261120T173657Z).
# AGR-121: deletion only via a reviewed script with fixed explicit paths.
#   dry   : names, file counts and sizes only, never content
#   purge : delete exactly the fixed list, then prove each is gone
set -euo pipefail
SP="/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/ee591319-eebc-404d-a6ee-14e79ef61e04/scratchpad"
TARGETS=(
  /private/tmp/rb-base-live
  /private/tmp/rb-base-test
  /private/tmp/rb-main
  /private/tmp/rb-mbase
  /private/tmp/rb-mnew
  /private/tmp/rb-new-live
  /private/tmp/rb-new-test
  /private/tmp/lf-dist-try
  /private/tmp/lf-dist-try2
  "$SP/appr030"
  "$SP/p101"
)
MODE="${1:?usage: dry | purge}"
case "$MODE" in dry|purge) ;; *) echo "usage: dry | purge"; exit 2;; esac
for p in "${TARGETS[@]}"; do
  if [ -L "$p" ]; then echo "refused: $p is a symlink (broken or not)"; exit 2; fi
  [ -e "$p" ] || { echo "absent: $p"; continue; }
  [ -d "$p" ] || { echo "refused: $p is not a directory"; exit 2; }
  real=$(cd "$p" && pwd -P)
  [ "$real" = "$p" ] || { echo "refused: $p resolves to $real"; exit 2; }
  echo "$p files=$(find "$p" -type f | wc -l | tr -d ' ') size=$(du -sk "$p" | cut -f1)k"
done
[ "$MODE" = dry ] && exit 0
for p in "${TARGETS[@]}"; do
  [ -d "${p:?}" ] && rm -rf -- "${p:?}"
done
for p in "${TARGETS[@]}"; do { [ -e "$p" ] || [ -L "$p" ]; } && { echo "FAILED: $p still present"; exit 6; }; done
[ -d "$HOME/family-ai-bundle" ] && echo "untouched: ~/family-ai-bundle present"
echo "OK: ${#TARGETS[@]} paths gone ($(date -u +%FT%TZ))"
