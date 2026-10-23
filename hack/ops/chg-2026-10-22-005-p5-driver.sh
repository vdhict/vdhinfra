#!/usr/bin/env bash
# chg-2026-10-22-005 point 5 driver (run from the Mini). Starts one devtenant-build Job per step of
# chg-2026-10-22-005-p5.mjs and prints its RESULT lines. Argus 23-10:
#   C3  refuses to start a step while any Job other than this change's dead-man is active in passkey-point-e2e or
#       devtenant-build;
#   R5  one dead-man for the whole window (`arm`), armed before setup with a green self-check, fires at the given time
#       (no later than 13:00 local), restores everything except the user delete; disarmed only after cleanup (`disarm`);
#   R4  a step starts only while the dead-man pod is Running and its log shows the self-check and `armed`;
#   R6  during a/b/c the driver checks every 15 s: another Job active, or the dead-man pod gone -> an immediate
#       dead-man is started, the case Job deleted, and the case marked invalid;
#   C5a the TAP is created and used inside the case Job's single process; nothing here sees it.
# The temporary CNP pp-p5-browser gives the step pods the Entra sign-in hosts and the .NET LAB desk (via envoy-internal,
# as the .NET E2E does); devtenant-entra already allows login + graph. `teardown` removes the CNP and the ConfigMaps.
#
#   chg-2026-10-22-005-p5-driver.sh precheck | arm <d> <fire-iso> | setup <d> | resume <d> | case <k> <d> | cleanup <d> | disarm | teardown
set -euo pipefail
NS=devtenant-build; HERE=$(cd "$(dirname "$0")" && pwd); SCRIPT=$HERE/chg-2026-10-22-005-p5.mjs
STATE=${P5_STATE:?P5_STATE: scratchpad dir holding before.json (write-once)}
IMAGE=forge.bluejungle.net/palamedes/passkey-point-e2e@sha256:e3341b128ac05b300b760fbc47a5826194e87d1aca8d822275fe07fb71d483df
DESK_HOST=passkey-point-dotnet-lab.bluejungle.net; DESK_IP=172.16.2.241
H=$(shasum -a 256 "$SCRIPT" | cut -c1-10); CM=chg-2026-10-22-005-p5-$H; TS=$(date -u +%Y%m%dt%H%M%Sz | tr A-Z a-z)

active() { # [own-job-to-ignore]
  kubectl get jobs -n passkey-point-e2e -o json | jq -r '.items[]|select((.status.active//0)>0)|"passkey-point-e2e/"+.metadata.name'
  kubectl get jobs -n $NS -o json | jq -r --arg own "${1:-}" '.items[]|select((.status.active//0)>0)|select(.metadata.labels["vdhinfra.io/p5-role"]!="deadman")|select(.metadata.name!=$own)|"devtenant-build/"+.metadata.name'; }
deadman_ok() { # the window dead-man pod is Running and has logged its self-check and `armed`
  local pod; pod=$(kubectl get pods -n $NS -l vdhinfra.io/p5-role=deadman,vdhinfra.io/p5-window=true --field-selector status.phase=Running -o name | head -1)
  [ -n "$pod" ] && kubectl logs -n $NS "$pod" | grep -q '"selfCheck"' && kubectl logs -n $NS "$pod" | grep -q '"armed"'; }
cm() {
  local args=(--from-file=p5.mjs="$SCRIPT"); [ -f "$STATE/before.json" ] && args+=(--from-file=before.json="$STATE/before.json")
  local name=$CM; [ -f "$STATE/before.json" ] && name=$CM-$(shasum -a 256 "$STATE/before.json" | cut -c1-6)
  kubectl get cm -n $NS "$name" >/dev/null 2>&1 || { kubectl create cm -n $NS "$name" "${args[@]}" >/dev/null; kubectl label cm -n $NS "$name" vdhinfra.io/chg=chg-2026-10-22-005 >/dev/null; }
  echo "$name"
}
cnp() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: pp-p5-browser, namespace: $NS, labels: {vdhinfra.io/chg: chg-2026-10-22-005}}
spec:
  endpointSelector: {matchLabels: {vdhinfra.io/p5: "true"}}
  egress:
    - toEndpoints: [{matchLabels: {k8s-app: kube-dns, "k8s:io.kubernetes.pod.namespace": kube-system}}]
      toPorts: [{ports: [{port: "53", protocol: UDP}, {port: "53", protocol: TCP}], rules: {dns: [{matchName: login.microsoftonline.com}, {matchName: login.microsoft.com}, {matchName: aadcdn.msftauth.net}, {matchName: aadcdn.msauth.net}, {matchName: logincdn.msauth.net}, {matchName: graph.microsoft.com}, {matchName: $DESK_HOST}]}}]
    - toFQDNs: [{matchName: login.microsoft.com}, {matchName: aadcdn.msftauth.net}, {matchName: aadcdn.msauth.net}, {matchName: logincdn.msauth.net}]
      toPorts: [{ports: [{port: "443", protocol: TCP}]}]
    - toEndpoints: [{matchLabels: {app.kubernetes.io/name: envoy, gateway.envoyproxy.io/owning-gateway-name: envoy-internal, "k8s:io.kubernetes.pod.namespace": network}}]
      toPorts: [{ports: [{port: "10443", protocol: TCP}]}]
EOF
}
job() { # <name> <role> <deadline-s> <args...>   (P5_WINDOW=true labels the window dead-man)
  local name=$1 role=$2 dl=$3; shift 3; local c; c=$(cm)
  jq -n --arg n "$name" --arg role "$role" --arg win "${P5_WINDOW:-false}" --arg cm "$c" --arg img "$IMAGE" --arg host "$DESK_HOST" --arg ip "$DESK_IP" --argjson dl "$dl" --args '$ARGS.positional as $a |
  {apiVersion:"batch/v1",kind:"Job",metadata:{name:$n,namespace:"devtenant-build",labels:{"vdhinfra.io/chg":"chg-2026-10-22-005","vdhinfra.io/p5-role":$role}},
   spec:{backoffLimit:0,activeDeadlineSeconds:$dl,ttlSecondsAfterFinished:86400,template:{metadata:{labels:{"app.kubernetes.io/name":"devtenant","vdhinfra.io/p5":"true","vdhinfra.io/p5-role":$role,"vdhinfra.io/p5-window":$win}},
   spec:{restartPolicy:"Never",serviceAccountName:"devtenant",automountServiceAccountToken:false,enableServiceLinks:false,imagePullSecrets:[{name:"devtenant-pull"}],
     hostAliases:[{ip:$ip,hostnames:[$host]}],
     securityContext:{runAsNonRoot:true,runAsUser:10001,runAsGroup:10001,fsGroup:10001,seccompProfile:{type:"RuntimeDefault"}},
     containers:[{name:"p5",image:$img,command:(["node","/work/p5.mjs"]+$a),env:[{name:"HOME",value:"/tmp"}],
       securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}},
       resources:{requests:{cpu:"500m",memory:"512Mi"},limits:{memory:"1536Mi"}},
       volumeMounts:[{name:"work",mountPath:"/work",readOnly:true},{name:"build",mountPath:"/secrets/build",readOnly:true},{name:"tmp",mountPath:"/tmp"},{name:"shm",mountPath:"/dev/shm"}]}],
     volumes:[{name:"work",configMap:{name:$cm,defaultMode:292}},{name:"build",secret:{secretName:"atlas-devtenant-build-key",defaultMode:288}},
       {name:"tmp",emptyDir:{sizeLimit:"512Mi"}},{name:"shm",emptyDir:{medium:"Memory",sizeLimit:"256Mi"}}]}}}}' -- "$@" | kubectl create -f - >/dev/null
  echo "job $name ($role) created $(date -u +%TZ)"
}
waitlog() { # <name>
  until kubectl get job -n $NS "$1" -o jsonpath='{.status.succeeded}{.status.failed}' | grep -q 1; do sleep 5; done
  kubectl logs -n $NS "job/$1" | grep -E '^(RESULT|BEFORE)' | grep -v '^BEFORE' || true
  kubectl get job -n $NS "$1" -o jsonpath='{.status.succeeded}' | grep -q 1
}
gate() { local a; a=$(active); [ -z "$a" ] || { echo "C3: active Jobs, refusing:"; echo "$a"; exit 3; }; }

mode=${1:?mode}; shift
case $mode in
  precheck)
    gate; cnp; job p5-precheck-$TS precheck 300 precheck
    waitlog p5-precheck-$TS && rc=0 || rc=$?
    if [ "$rc" = 0 ] && [ ! -e "$STATE/before.json" ]; then kubectl logs -n $NS job/p5-precheck-$TS | sed -n 's/^BEFORE //p' > "$STATE/before.json"; chmod 0444 "$STATE/before.json"; echo "before.json written once ($(shasum -a 256 "$STATE/before.json" | cut -c1-16))"; fi
    exit $rc ;;
  setup) gate; [ -f "$STATE/before.json" ] || exit 64; job p5-setup-$TS setup 300 setup "${1:?date}"; waitlog p5-setup-$TS ;;
  arm)
    d=${1:?date}; fire=${2:?fire-iso}; [ -f "$STATE/before.json" ] || exit 64
    secs=$(( $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$fire" +%s) - $(date -u +%s) )); [ "$secs" -gt 0 ] && [ "$secs" -le 25200 ] || { echo "fire time out of range"; exit 64; }
    P5_WINDOW=true job p5-deadman-window-$TS deadman $((secs + 900)) deadman "$d" "$fire"
    for _ in $(seq 1 60); do deadman_ok && break; sleep 5; done
    deadman_ok || { echo "dead-man not armed (no self-check/armed line)"; kubectl logs -n $NS job/p5-deadman-window-$TS | grep RESULT; exit 1; }
    kubectl logs -n $NS job/p5-deadman-window-$TS | grep RESULT ;;
  case)
    k=${1:?case}; d=${2:?date}; gate; [ -f "$STATE/before.json" ] || exit 64
    deadman_ok || { echo "R4: window dead-man not Running/armed; refusing"; exit 3; }
    name=p5-case-$k-$TS; job $name case 1500 case "$k" "$d"
    while ! kubectl get job -n $NS $name -o jsonpath='{.status.succeeded}{.status.failed}' | grep -q 1; do
      if [[ $k =~ ^[abc]$ ]]; then
        a=$(active $name); if [ -n "$a" ] || ! deadman_ok; then
          echo "R6: $( [ -n "$a" ] && echo "other Job active: $a" || echo "dead-man gone") -> immediate dead-man, case $k INVALID"
          job p5-deadman-now-$TS deadman 900 deadman "$d" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; kubectl delete job -n $NS $name --wait=false >/dev/null
          exit 4; fi
      fi
      sleep 15
    done
    waitlog $name || { echo "case $k did not pass: the window dead-man stays armed"; exit 1; } ;;
  resume) gate; [ -f "$STATE/before.json" ] || exit 64; deadman_ok || { echo "R4: window dead-man not Running/armed; refusing"; exit 3; }; job p5-resume-$TS setup 300 resume "${1:?date}"; waitlog p5-resume-$TS ;;
  cleanup) gate; job p5-cleanup-$TS cleanup 600 cleanup "${1:?date}"; waitlog p5-cleanup-$TS ;;
  disarm) kubectl get jobs -n $NS -l vdhinfra.io/p5-role=deadman -o name | while read -r j; do kubectl logs -n $NS "$j" | grep '^RESULT' | tail -3; kubectl delete -n $NS "$j" >/dev/null; echo "disarmed $j"; done ;;
  selftest) node "$SCRIPT" selftest ;;
  teardown) kubectl delete cnp -n $NS pp-p5-browser --ignore-not-found; kubectl delete cm -n $NS -l vdhinfra.io/chg=chg-2026-10-22-005 --ignore-not-found ;;
  *) echo "mode?" >&2; exit 64 ;;
esac
