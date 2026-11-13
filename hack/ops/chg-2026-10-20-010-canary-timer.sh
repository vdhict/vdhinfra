#!/usr/bin/env bash
# chg-2026-10-20-010 land 3: independent timed rollback for ONE group's attachment step (Argus: arm before, disarm
# only after the final readback). After <minutes>, unless <disarm-file> exists, restores the group's permissions and
# the model's capabilities from the 0600 snapshot (hack/ops/chg-2026-10-20-010-restore-group.py; Argus R2).
#   chg-2026-10-20-010-canary-timer.sh <n> <minutes> <snapshot.json> <disarm-file> <log>
set -uo pipefail
N="${1:?profile number}"; MIN="${2:?minutes}"; SNAP="${3:?snapshot}"; DIS="${4:?disarm}"; LOG="${5:?log}"
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "$(date -u +%FT%TZ) armed: restore owui-profiel-$N after ${MIN}m unless $DIS exists" >> "$LOG"
END=$(( $(date +%s) + MIN * 60 ))
while [ "$(date +%s)" -lt "$END" ]; do
  [ -e "$DIS" ] && { echo "$(date -u +%FT%TZ) disarmed" >> "$LOG"; exit 0; }
  sleep 15
done
[ -e "$DIS" ] && { echo "$(date -u +%FT%TZ) disarmed" >> "$LOG"; exit 0; }
echo "$(date -u +%FT%TZ) TIMEOUT: restoring owui-profiel-$N" >> "$LOG"
kubectl -n family-ai exec -i deploy/open-webui -c app -- python3 -c "$(cat "$HERE/chg-2026-10-20-010-restore-group.py")" \
  "owui-profiel-$N" "hermes-agent-profiel-$N" < "$SNAP" >> "$LOG" 2>&1
/Users/sheijden/Code/homelab-migration/vdhinfra/ops/ops change event chg-2026-10-20-010 executed --actor infra-ops \
  --payload-json "{\"step\":\"canary timer fired: owui-profiel-$N restored from snapshot (not disarmed within ${MIN}m)\"}" >> "$LOG" 2>&1
