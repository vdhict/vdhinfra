#!/usr/bin/env bash
# Raw per-sample history + inter-sample gap stats. ha-cli.sh `history` aggregates
# timestamps away and this change is ABOUT the cadence. curl fetches because
# Homebrew python3 gets EHOSTUNREACH to the LAN (macOS Local Network Privacy).
set -euo pipefail
ENT="$1"; HOURS="${2:-48}"
SP=/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/2ac34ba5-b5fe-4aff-880a-a3a46c85be6f/scratchpad
TOKEN=$(cat /Users/sheijden/Code/homelab-migration/config/hasskey)
START=$(date -u -v-"${HOURS}"H +"%Y-%m-%dT%H:%M:%SZ")
END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "http://172.16.2.237:8123/api/history/period/${START}?filter_entity_id=${ENT}&minimal_response&end_time=${END}" \
| python3 "$SP/gapstats.py" "$ENT" "$HOURS"
