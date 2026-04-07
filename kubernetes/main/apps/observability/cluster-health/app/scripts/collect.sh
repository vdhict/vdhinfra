#!/bin/sh
# Orchestrator: runs all collectors and merges their JSON output into one
# raw report at /data/raw/YYYY-MM-DD.json. Individual collector failures are
# tolerated — partial data is better than no data.
#
# Written for BusyBox ash (alpine). Avoids `mktemp -d` without a template
# (which BusyBox does not support) and uses explicit paths.
set -u

# Use /data for both temp and output so a single PVC mount is enough.
DATE=$(date -u +%Y-%m-%d)
[ -z "$DATE" ] && DATE=unknown
OUT_DIR=/data/raw
OUT="${OUT_DIR}/${DATE}.json"
TMP="/data/.collect-${DATE}-$$"

mkdir -p "$OUT_DIR" "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "[collect] DATE=$DATE TMP=$TMP OUT=$OUT" >&2

run_collector() {
  name="$1"; shift
  echo "[collect] $name" >&2
  out="${TMP}/${name}.json"
  err="${TMP}/${name}.err"
  if "$@" >"$out" 2>"$err"; then
    echo "[collect] $name OK ($(wc -c < "$out") bytes)" >&2
  else
    rc=$?
    head_err=$(head -c 300 "$err" 2>/dev/null || echo "")
    echo "[collect] $name FAILED rc=$rc — $head_err" >&2
    # Stub so the section appears in the merged report
    python3 -c "import json,sys; print(json.dumps({'_error': open('$err').read()[:500] if __import__('os').path.exists('$err') else 'no stderr'}))" > "$out" 2>/dev/null || echo '{"_error": "stub"}' > "$out"
  fi
}

run_collector k8s        python3 /scripts/collect_k8s.py
run_collector prom       python3 /scripts/collect_prom.py
run_collector ceph       sh      /scripts/collect_ceph.sh
run_collector postgres   sh      /scripts/collect_postgres.sh
run_collector mqtt       sh      /scripts/collect_mqtt.sh
run_collector ha         python3 /scripts/collect_ha.py
run_collector z2m        python3 /scripts/collect_z2m.py
run_collector zwave      python3 /scripts/collect_zwave.py
run_collector esphome    python3 /scripts/collect_esphome.py
run_collector offsite    python3 /scripts/collect_offsite.py

# Merge into one document
TMP="$TMP" OUT="$OUT" DATE="$DATE" python3 <<'PY'
import json, os, sys
from datetime import datetime, timezone
tmp = os.environ["TMP"]
out = os.environ["OUT"]
date = os.environ["DATE"]
merged = {
    "date": date,
    "collected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "sections": {},
}
for name in ("k8s", "prom", "ceph", "postgres", "mqtt", "ha", "z2m", "zwave", "esphome", "offsite"):
    p = os.path.join(tmp, f"{name}.json")
    try:
        with open(p) as f:
            merged["sections"][name] = json.load(f)
    except Exception as e:
        merged["sections"][name] = {"_error": str(e)}
with open(out, "w") as f:
    json.dump(merged, f, indent=2, sort_keys=True, default=str)
print(f"[collect] wrote {out} ({os.path.getsize(out)} bytes)", file=sys.stderr)
PY

echo "[collect] done" >&2
