#!/usr/bin/env bash
# chg-2026-10-20-010 land 3: independent timed rollback (Argus review 20261112T202811Z "arm an independent timed rollback
# before the run; disarm it only after the final readback"). Started with nohup BEFORE the overlay commit is pushed.
#   chg-2026-10-20-010-timed-rollback.sh <commit-to-revert> <minutes> <disarm-file> <log>
# After <minutes>, unless <disarm-file> exists: git revert <commit> on a fresh detached checkout of origin/main, push,
# reconcile Flux, log. It never touches anything else.
set -uo pipefail
C="${1:?commit}"; MIN="${2:?minutes}"; DIS="${3:?disarm file}"; LOG="${4:?log}"
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
WT=$(mktemp -d "${TMPDIR:-/tmp}/l3-rollback.XXXXXX")
echo "$(date -u +%FT%TZ) armed: revert $C after ${MIN}m unless $DIS exists" >> "$LOG"
END=$(( $(date +%s) + MIN * 60 ))
while [ "$(date +%s)" -lt "$END" ]; do
  [ -e "$DIS" ] && { echo "$(date -u +%FT%TZ) disarmed" >> "$LOG"; exit 0; }
  sleep 15
done
[ -e "$DIS" ] && { echo "$(date -u +%FT%TZ) disarmed" >> "$LOG"; exit 0; }
echo "$(date -u +%FT%TZ) TIMEOUT: reverting $C" >> "$LOG"
git -C "$REPO" fetch -q origin && git -C "$REPO" worktree add -q --detach "$WT/wt" origin/main >> "$LOG" 2>&1 || exit 2
git -C "$WT/wt" -c user.name=Atlas -c user.email=atlas@local revert --no-edit "$C" >> "$LOG" 2>&1 || exit 3
git -C "$WT/wt" push origin HEAD:main >> "$LOG" 2>&1 || exit 4
flux reconcile source git flux-system -n flux-system >> "$LOG" 2>&1
flux reconcile kustomization family-ai-open-webui -n flux-system >> "$LOG" 2>&1
"$REPO/ops/ops" change event chg-2026-10-20-010 executed --actor infra-ops \
  --payload-json "{\"step\":\"timed rollback fired: reverted $C (not disarmed within ${MIN}m)\"}" >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) rollback pushed" >> "$LOG"
