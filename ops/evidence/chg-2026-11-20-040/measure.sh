#!/usr/bin/env bash
# usage: measure.sh <label>  -> prints usage (kubectl top) and requests of Running pods in PP namespaces
set -u
NS="lab-passkey lab-passkey-dotnet lab-passkey-dotnet-maxsession passkey-point-e2e pp-ci devtenant-build devtenant-ops"
echo "# PP measurement $1 at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "## kubectl top pods --containers (usage)"
tu_cpu=0; tu_mem=0
for ns in $NS; do
  out=$(kubectl top pods -n "$ns" --no-headers 2>/dev/null)
  [ -n "$out" ] && echo "$out" | sed "s/^/$ns /"
  c=$(echo "$out" | awk '{gsub("m","",$2); s+=$2} END{print s+0}')
  m=$(echo "$out" | awk '{gsub("Mi","",$3); s+=$3} END{print s+0}')
  echo "  ns=$ns usage_cpu_m=$c usage_mem_Mi=$m"
  tu_cpu=$((tu_cpu+c)); tu_mem=$((tu_mem+m))
done
echo "TOTAL usage_cpu_m=$tu_cpu usage_mem_Mi=$tu_mem"
echo "## requests of Running pods (containers; initContainers excluded)"
for ns in $NS; do
  kubectl get pods -n "$ns" --field-selector=status.phase=Running -o json | python3 -I -c '
import json,sys
ns=sys.argv[1]
def cpu(v):
    return float(v[:-1]) if v.endswith("m") else float(v)*1000
def mem(v):
    u={"Ki":1/1024,"Mi":1,"Gi":1024,"K":1/1048.576,"M":1/1.048576,"G":1000/1.048576}
    for k in sorted(u,key=len,reverse=True):
        if v.endswith(k): return float(v[:-len(k)])*u[k]
    return float(v)/1048576
tc=tm=0
for p in json.load(sys.stdin)["items"]:
    for c in p["spec"]["containers"]:
        r=c.get("resources",{}).get("requests",{})
        pc=cpu(r["cpu"]) if "cpu" in r else 0; pm=mem(r["memory"]) if "memory" in r else 0
        tc+=pc; tm+=pm
        pn=p["metadata"]["name"]; cn=c["name"]
        print(f"{ns} {pn} {cn} req_cpu_m={pc:.0f} req_mem_Mi={pm:.0f}")
print(f"  ns={ns} req_cpu_m={tc:.0f} req_mem_Mi={tm:.0f}")
' "$ns"
done | awk '/^  ns=/{split($2,a,"=");split($3,b,"=");c+=a[2];m+=b[2]} {print} END{print "TOTAL req_cpu_m=" c " req_mem_Mi=" m}'
