#!/usr/bin/env bash
# fetch.sh <entity> <attrs:0|1>  -> h/<entity>.jsonl (one state per line), 24h slices 2026-09-09T00Z..now
set -euo pipefail
T=$(cat ~/Code/homelab-migration/config/hasskey); E=$1; A=${2:-0}
S=/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/743312b1-6b9e-4bf4-bf26-d4504d06a737/scratchpad
out=$S/h/$E.jsonl; : > $out
for d in $(seq 0 14); do
  st=$(date -u -j -v+${d}d -f "%Y-%m-%dT%H:%M:%SZ" "2026-09-08T22:00:00Z" +%Y-%m-%dT%H:%M:%SZ)
  en=$(date -u -j -v+$((d+1))d -f "%Y-%m-%dT%H:%M:%SZ" "2026-09-08T22:00:00Z" +%Y-%m-%dT%H:%M:%SZ)
  q="filter_entity_id=$E&end_time=$en"; [ "$A" = 0 ] && q="$q&no_attributes"
  curl -fsS -G -H "Authorization: Bearer $T" "http://172.16.2.237:8123/api/history/period/$st" --data-urlencode "filter_entity_id=$E" --data-urlencode "end_time=$en" $( [ "$A" = 0 ] && echo --data-urlencode no_attributes ) \
   | jq -c --arg st "$st" '(.[0] // [])[] | {s:.state,lc:.last_changed,lu:.last_updated,a:(.attributes // null),slice:$st}' >> $out
done
wc -l $out
