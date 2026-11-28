#!/usr/bin/env bash
# chg-2026-11-28-109 post-check: MinIO console (:9001) off the LoadBalancer, S3 (:9000) unchanged.
# Run from the Mac Mini (LAN), after Flux has applied the commit from main:
#   hack/ops/chg-2026-11-28-109-postcheck.sh <change-time-UTC, e.g. 2026-11-28T12:00:00Z>
# Run it again >= 65 min after the change so at least one hourly VolSync source has synced through it.
# Read-only. Writes one write-once evidence file. Exit 0 PASS, 1 FAIL (rollback: git revert + flux), 2 INCONCLUSIVE.
set -uo pipefail
CHANGE_TS="${1:?usage: $0 <change-time-UTC ISO8601>}"
LB=172.16.2.245
CONTROL_HOST=172.16.2.241   # envoy-internal, must be open or the probe is not trusted
CONTROL_PORT=443
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$REPO/ops/evidence/chg-2026-11-28-109/10-postcheck-$STAMP.txt"
[ -e "$OUT" ] && { echo "evidence file exists: $OUT" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)" || true

fail=0; inconclusive=0
log() { echo "$*" | tee -a "$OUT"; }
probe() { if nc -z -G3 "$1" "$2" 2>/dev/null; then echo open; else echo closed; fi; }

log "chg-2026-11-28-109 post-check $STAMP (date -u) host=$(hostname -s) change_ts=$CHANGE_TS"

# 1. Ports from the Mini
c=$(probe "$CONTROL_HOST" "$CONTROL_PORT"); p9001=$(probe "$LB" 9001); p9000=$(probe "$LB" 9000)
h=$(curl -s -o /dev/null -m5 -w '%{http_code}' "http://$LB:9000/minio/health/live")
log "control $CONTROL_HOST:$CONTROL_PORT=$c  $LB:9001=$p9001 (want closed)  $LB:9000=$p9000 (want open)  health=$h (want 200)"
if [ "$c" != open ]; then log "INCONCLUSIVE: control port closed, LAN probe not trusted"; inconclusive=1; fi
[ "$p9001" = closed ] || { log "FAIL: 9001 still reachable"; fail=1; }
[ "$p9000" = open ] && [ "$h" = 200 ] || { log "FAIL: S3 9000 not healthy on the LB"; fail=1; }

# 2. Live Service shape
ports=$(kubectl -n storage get svc minio-lb -o jsonpath='{range .spec.ports[*]}{.port}/{.nodePort} {end}')
ip=$(kubectl -n storage get svc minio-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "svc minio-lb ip=$ip ports=$ports (want ip $LB, only 9000/30143)"
[ "$ip" = "$LB" ] && [ "$(echo $ports)" = "9000/30143" ] || { log "FAIL: minio-lb shape differs"; fail=1; }
rdy=$(kubectl -n storage get pod -l app.kubernetes.io/name=minio -o jsonpath='{range .items[*]}{.metadata.name} ready={.status.containerStatuses[0].ready} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}')
log "minio pod: $rdy"
echo "$rdy" | grep -q "ready=true" || { log "FAIL: minio pod not Ready"; fail=1; }

# 3. S3 clients: VolSync, CNPG, off-site mirror
py() { python3 -I -c "$1" "$CHANGE_TS"; }
vs=$(kubectl get replicationsource -A -o json | py '
import json,sys,datetime as d
ch=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); now=d.datetime.now(d.timezone.utc)
bad=0; after=0; n=0
for i in json.load(sys.stdin)["items"]:
  n+=1; s=i.get("status",{}); t=s.get("lastSyncTime"); r=s.get("latestMoverStatus",{}).get("result")
  ts=d.datetime.fromisoformat(t.replace("Z","+00:00")) if t else None
  ok = r=="Successful" and ts and now-ts < d.timedelta(hours=26)
  if ts and ts>ch and r=="Successful": after+=1
  if not ok: bad+=1; print("  BAD", i["metadata"]["namespace"]+"/"+i["metadata"]["name"], t, r)
print(f"VOLSYNC n={n} bad={bad} synced_ok_after_change={after}")
')
log "$vs"
echo "$vs" | grep -q " bad=0 " || { log "FAIL: VolSync source not successful within 26h"; fail=1; }
echo "$vs" | grep -q "synced_ok_after_change=0" && { log "INCONCLUSIVE: no VolSync sync after the change yet (re-run after the next hourly sync)"; inconclusive=1; }

pg=$(kubectl get clusters.postgresql.cnpg.io -A -o json | py '
import json,sys,datetime as d
ch=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); now=d.datetime.now(d.timezone.utc)
P=lambda t: d.datetime.fromisoformat(t.replace("Z","+00:00")) if t else None
bad=0
for i in json.load(sys.stdin)["items"]:
  if not i["spec"].get("backup"): continue
  s=i.get("status",{}); name=i["metadata"]["namespace"]+"/"+i["metadata"]["name"]
  arch={c["type"]:c["status"] for c in s.get("conditions",[])}.get("ContinuousArchiving")
  lsb=P(s.get("lastSuccessfulBackup")); lfb=P(s.get("lastFailedBackup"))
  ok = arch=="True" and lsb and now-lsb < d.timedelta(hours=26) and not (lfb and lfb>ch)
  bad+= not ok
  print(("  ok  " if ok else "  BAD ")+name, "ContinuousArchiving="+str(arch), "lastSuccessfulBackup="+str(s.get("lastSuccessfulBackup")), "lastFailedBackup="+str(s.get("lastFailedBackup")))
print(f"CNPG bad={bad}")
')
log "$pg"
echo "$pg" | grep -q "CNPG bad=0" || { log "FAIL: CNPG archiving/backup not healthy"; fail=1; }

om=$(kubectl -n storage get cronjob minio-offsite-mirror -o jsonpath='{.status.lastSuccessfulTime}')
log "minio-offsite-mirror lastSuccessfulTime=$om (daily 04:30; judged within 26h)"
python3 -I -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); sys.exit(0 if d.datetime.now(d.timezone.utc)-t<d.timedelta(hours=26) else 1)' "$om" 2>/dev/null \
  || { log "FAIL: off-site mirror not successful within 26h"; fail=1; }

# 4. No new errors in MinIO since the change
since=$(python3 -I -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(max(60,int((d.datetime.now(d.timezone.utc)-t).total_seconds())))' "$CHANGE_TS")
errs=$(kubectl -n storage logs -l app.kubernetes.io/name=minio --since="${since}s" --tail=-1 2>/dev/null | grep -c -i -E "error|denied|fatal" || true)
log "minio log lines matching error|denied|fatal since change: $errs (want 0)"
[ "${errs:-0}" = 0 ] || { log "FAIL: MinIO logged errors since the change"; fail=1; }

if [ $fail = 1 ]; then log "RESULT: FAIL -> rollback: git revert <sha> on main, push, flux reconcile ks minio -n flux-system --with-source"; exit 1; fi
if [ $inconclusive = 1 ]; then log "RESULT: INCONCLUSIVE"; exit 2; fi
log "RESULT: PASS"; exit 0
