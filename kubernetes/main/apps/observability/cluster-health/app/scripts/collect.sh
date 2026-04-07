#!/bin/sh
# Orchestrator: runs all collectors and merges their JSON output into one
# raw report at /data/raw/YYYY-MM-DD.json. Individual collector failures are
# tolerated — partial data is better than no data.
set -u

DATE=$(date +%F)
OUT=/data/raw/${DATE}.json
TMP=$(mktemp -d)
mkdir -p /data/raw

run_collector() {
  name="$1"; shift
  echo "[collect] $name" >&2
  if "$@" >"${TMP}/${name}.json" 2>"${TMP}/${name}.err"; then
    echo "[collect] $name OK" >&2
  else
    echo "[collect] $name FAILED rc=$? — $(head -c 300 ${TMP}/${name}.err)" >&2
    # Write a minimal error stub so the section appears in the report
    printf '{"_error": %s}\n' "$(printf '%s' "$(cat ${TMP}/${name}.err 2>/dev/null | head -c 500)" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" > "${TMP}/${name}.json"
  fi
}

run_collector k8s        python3 /scripts/collect_k8s.py
run_collector prom       python3 /scripts/collect_prom.py
run_collector ceph       sh     /scripts/collect_ceph.sh
run_collector postgres   sh     /scripts/collect_postgres.sh
run_collector mqtt       sh     /scripts/collect_mqtt.sh
run_collector ha         python3 /scripts/collect_ha.py
run_collector z2m        python3 /scripts/collect_z2m.py
run_collector zwave      python3 /scripts/collect_zwave.py
run_collector esphome    python3 /scripts/collect_esphome.py

# Merge into one document
python3 - "$TMP" "$OUT" "$DATE" <<'PY'
import json, os, sys
from datetime import datetime, timezone
tmp, out, date = sys.argv[1], sys.argv[2], sys.argv[3]
merged = {
    "date": date,
    "collected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "sections": {},
}
for name in ("k8s", "prom", "ceph", "postgres", "mqtt", "ha", "z2m", "zwave", "esphome"):
    p = os.path.join(tmp, f"{name}.json")
    try:
        with open(p) as f:
            merged["sections"][name] = json.load(f)
    except Exception as e:
        merged["sections"][name] = {"_error": str(e)}
with open(out, "w") as f:
    json.dump(merged, f, indent=2, sort_keys=True, default=str)
print(f"[collect] wrote {out}", file=sys.stderr)
PY

rm -rf "$TMP"
echo "[collect] done" >&2
