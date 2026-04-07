#!/bin/sh
# Collect CNPG cluster status across all namespaces.
set -u

CLUSTERS=$(kubectl get clusters.postgresql.cnpg.io -A -o json 2>/dev/null || echo '{"items":[]}')

python3 - "$CLUSTERS" <<'PY'
import json, sys
data = json.loads(sys.argv[1] or '{"items":[]}')
out = {"clusters": []}
for it in data.get("items", []):
    md = it["metadata"]
    st = it.get("status", {})
    cond = next((c for c in st.get("conditions", []) if c.get("type") == "Ready"), {})
    out["clusters"].append({
        "namespace": md["namespace"],
        "name": md["name"],
        "phase": st.get("phase"),
        "ready": cond.get("status") == "True",
        "instances": it.get("spec", {}).get("instances"),
        "ready_instances": st.get("readyInstances"),
        "current_primary": st.get("currentPrimary"),
        "first_recoverability_point": st.get("firstRecoverabilityPoint"),
        "last_archived_wal": st.get("lastArchivedWAL"),
        "last_archived_wal_time": st.get("lastArchivedWALTime"),
        "last_failed_archive_time": st.get("lastFailedArchiveTime"),
        "instances_status": st.get("instancesStatus"),
    })
out["total"] = len(out["clusters"])
out["ready"] = sum(1 for c in out["clusters"] if c["ready"])
json.dump(out, sys.stdout, indent=2, default=str)
PY
