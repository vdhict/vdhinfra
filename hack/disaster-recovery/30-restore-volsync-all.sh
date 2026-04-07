#!/usr/bin/env bash
# Restore all 7 VolSync-protected apps in priority order.
# Each app is restored sequentially (not in parallel) to keep the
# bookkeeping simple — total wall time is still <15 min.
source "$(dirname "$0")/lib.sh"
require_cluster

log "starting full VolSync restore for all 7 protected apps"
log "order: zwave-js-ui → zigbee2mqtt → home-assistant → node-red → esphome → mealie → radarr"
echo
confirm "Begin full VolSync restore?"

FAILED=()
for spec in "${VOLSYNC_APPS[@]}"; do
  IFS=: read -r ns app pvc <<< "$spec"
  echo
  log "===== restoring $app ====="
  if "$(dirname "$0")/30-restore-volsync-app.sh" "$app"; then
    ok "$app restored"
  else
    err "$app FAILED — continuing with next app, will report at end"
    FAILED+=("$app")
  fi
done

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  ok "all 7 VolSync apps restored successfully"
else
  err "the following apps FAILED to restore: ${FAILED[*]}"
  err "investigate per-app: kubectl -n <ns> describe replicationdestination <app>-dst"
  exit 1
fi
