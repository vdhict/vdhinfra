#!/usr/bin/env bash
# chg-2026-11-28-106 A3: forge-pg retention dry run under the 120d guard (post-check of the guard commit).
# Run AFTER Atlas pushed the guard and Flux applied it. Called on its own; no rm; prints no secret.
# Usage: chg-2026-11-28-106-retention-dryrun.sh <write-once evidence file> [--check-only]
#  1. refuse unless origin/main AND the live Cluster say retentionPolicy=120d, and the live imageName = manifest image
#  2. apply CNP + pod (manifest hack/ops/chg-2026-11-28-106/retention-dryrun.yaml), wait for Succeeded
#  3. parse the pod log: list count, 120d dry run, 14d positive control
#  PASS = 120d lists 0 'delet' lines (0 backups, 0 WAL), list count == completed forge-pg Backup CRs,
#         14d control lists > 0 'delet' lines, all exits 0.
#  Teardown is a separate script: chg-2026-11-28-106-retention-dryrun-teardown.sh
set -uo pipefail
OUT=${1:?write-once evidence file}
[ -e "$OUT" ] && { echo "refuse: $OUT exists (write-once)"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
MAN="$HERE/chg-2026-11-28-106/retention-dryrun.yaml"
NS=devtools; POD=chg-2026-11-28-106-retention-dryrun
exec > >(tee "$OUT") 2>&1
echo "chg-2026-11-28-106 A3 retention dry run, $(date -u +%Y-%m-%dT%H:%M:%SZ) (date -u), Heph. AGR-109: tests are the gate."
main_pol=$(git -C "$HERE" show origin/main:kubernetes/main/apps/devtools/forge-pg/app/cluster.yaml | awk '/^ *retentionPolicy:/{gsub(/"/,"",$2);print $2}')
live_pol=$(kubectl -n $NS get clusters.postgresql.cnpg.io forge-pg -o jsonpath='{.spec.backup.retentionPolicy}')
live_img=$(kubectl -n $NS get clusters.postgresql.cnpg.io forge-pg -o jsonpath='{.spec.imageName}')
man_img=$(awk '/^ *image: ghcr.io\/cloudnative-pg/{print $2}' "$MAN")
echo "origin/main $(git -C "$HERE" rev-parse --short origin/main) retentionPolicy=$main_pol; live=$live_pol"
echo "live imageName=$live_img; manifest image=$man_img"
[ "$main_pol" = 120d ] && [ "$live_pol" = 120d ] || { echo "STOP: guard not live (need 120d on origin/main and live)"; exit 2; }
[ "$live_img" = "$man_img" ] || { echo "STOP: live forge-pg image differs from the dry-run image"; exit 2; }
crs=$(kubectl -n $NS get backups.postgresql.cnpg.io -o jsonpath='{range .items[*]}{.spec.cluster.name} {.status.phase}{"\n"}{end}' | grep -c '^forge-pg completed$')
echo "completed forge-pg Backup CRs: $crs"
kubectl -n $NS get pod $POD >/dev/null 2>&1 && { echo "refuse: pod $POD already exists; run teardown first"; exit 2; }
if [ "${2:-}" = "--check-only" ]; then
  kubectl apply --dry-run=server -f "$MAN"; echo "CHECK-ONLY done (server dry run, nothing created)"; exit 0
fi
kubectl apply -f "$MAN"
for i in $(seq 180); do
  ph=$(kubectl -n $NS get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$ph" in Succeeded|Failed) break;; esac; sleep 5
done
echo "pod phase: $ph node=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')"
LOG=$(kubectl -n $NS logs $POD)
sect(){ printf '%s\n' "$LOG" | awk -v s="=== $1" -v e="=== $1_EXIT" '$0==s{f=1;next} index($0,e)==1{f=0} f'; }
ex(){ printf '%s\n' "$LOG" | awk -v e="=== $1_EXIT" 'index($0,e)==1{print $3}'; }
printf '%s\n' "$LOG" | grep '^BARMAN_VERSION'
list_n=$(sect LIST | grep -cE '^[0-9]{8}T[0-9]{6}')
g_del=$(sect GUARD_120D | grep -ci 'delet')
c_del=$(sect CONTROL_14D | grep -ci 'delet')
echo "LIST exit=$(ex LIST) backup ids=$list_n (Backup CRs completed=$crs)"
echo "GUARD_120D exit=$(ex GUARD_120D) lines mentioning delet=$g_del; full output follows:"
sect GUARD_120D | sed 's/^/  | /'
echo "CONTROL_14D exit=$(ex CONTROL_14D) lines mentioning delet=$c_del (count only)"
ok=1
[ "$ph" = Succeeded ] || ok=0
[ "$(ex LIST)" = 0 ] && [ "$(ex GUARD_120D)" = 0 ] && [ "$(ex CONTROL_14D)" = 0 ] || ok=0
[ "$g_del" -eq 0 ] || ok=0
[ "$c_del" -gt 0 ] || ok=0
[ "$list_n" -eq "$crs" ] || ok=0
echo "A3 $( [ $ok = 1 ] && echo PASS || echo FAIL ): 120d deletions=$g_del (must be 0), list=$list_n vs CRs=$crs (must be equal), control deletions=$c_del (must be >0)"
echo "next: hack/ops/chg-2026-11-28-106-retention-dryrun-teardown.sh (own call)"
[ $ok = 1 ]
