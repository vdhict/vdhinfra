#!/usr/bin/env bash
# chg-2026-10-22-006: Passkey Point container gates (ci/run.sh, steps 0-11) on an amd64 cluster runner in pp-ci
# (Mack 22-10, tsk-2026-10-17-002). Driver, run from the Mini:
#
#   chg-2026-10-22-006-pp-ci-gates.sh <run-id> <ref-bundle> <ref-commit> <raw-dir> <label>=<bundle>@<full-commit>...
#
# <raw-dir> is a scratchpad directory, never the repo (Argus C5): raw logs may carry repo text. Evidence for the repo
# is extracted from it afterwards (step lines, exit codes, pulled image digests, grype counts) after a term scan.
# 1. CiliumCIDRGroup pp-ci-house-wan from the UDM API (the house's WAN addresses; values never printed, never in git).
# 2. ConfigMap with the in-pod runner (chg-2026-10-22-006-pp-ci-runner.sh, named by its sha256 prefix).
# 3. Job pp-ci-<run-id>: debian:13.4 by index digest, privileged (rootful podman), no ServiceAccount token, no Secret,
#    emptyDirs, pinned to the dedicated worker PP_CI_NODE with the taint pp-ci=run:NoSchedule tolerated (Argus C2).
#    hostUsers: false is not possible: Talos sets user.max_user_namespaces=0 (measured 22-10, sandbox ENOSPC on unshare).
#    Refuses to start while any pod of a sensitive namespace runs on that node, or while the node lacks the taint.
# 4. Network proof (Argus C3): negative probes from the pod and from a podman container must all be closed, the
#    positive control open; plus Hubble drop records. Otherwise ABORT before any input is copied.
# 5. Copies the bundles + targets.txt in, GO; waits for DONE; copies /work/out to <raw-dir>/raw-<run-id>/
#    (write-once); COLLECTED; deletes the Job and the ConfigMap (Argus C7).
# Nothing here holds or passes a credential (the UDM key is read locally for one GET and never leaves the Mini).
set -euo pipefail
RUN=${1:?run-id}; REFB=${2:?ref bundle}; REFC=${3:?ref commit}; EVD=${4:?raw dir (scratchpad)}; shift 4
case "$EVD" in */vdhinfra/*) echo "raw dir inside the repo; refusing (Argus C5)" >&2; exit 64 ;; esac
[ $# -ge 1 ] || { echo "need at least one <label>=<bundle>@<commit>" >&2; exit 64; }
NS=pp-ci; JOB=pp-ci-$RUN; HERE=$(cd "$(dirname "$0")" && pwd)
NODE_PIN=${PP_CI_NODE:?PP_CI_NODE (the dedicated, tainted worker)}
SENSITIVE='^(flux-system|security|devtools|devtenant-build|devtenant-ops|lab-passkey|lab-passkey-dotnet|passkey-point-e2e|database|mypka|family|family-ai|cert-manager|external-secrets|kube-system-secrets)$'
kubectl get node "$NODE_PIN" -o json | jq -e '[.spec.taints[]? | select(.key=="pp-ci" and .value=="run" and .effect=="NoSchedule")] | length == 1' >/dev/null || { echo "node $NODE_PIN lacks taint pp-ci=run:NoSchedule; refusing" >&2; exit 67; }
LEFT=$(kubectl get pods -A --field-selector spec.nodeName="$NODE_PIN",status.phase=Running -o json | jq -r --arg re "$SENSITIVE" '.items[] | select(.metadata.namespace|test($re)) | "\(.metadata.namespace)/\(.metadata.name)"')
[ -z "$LEFT" ] || { echo "sensitive pods still on $NODE_PIN, refusing (Argus C2):"; echo "$LEFT"; exit 68; }
echo "node $NODE_PIN: tainted, no sensitive pods"
IMAGE=docker.io/library/debian:13.4@sha256:e2d08da6f42ef4b09b165d55528a12727aeed8240dc9edf888e3ec07e10ef9da
OUT="$EVD/raw-$RUN"; [ ! -e "$OUT" ] || { echo "$OUT exists; write-once, refusing" >&2; exit 64; }
[ -f "$REFB" ] && [[ "$REFC" =~ ^[0-9a-f]{40}$ ]] || { echo "reference bundle/commit" >&2; exit 64; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ppci-in.XXXXXX"); : > "$STAGE/targets.txt"
cp "$REFB" "$STAGE/ref.bundle"; echo "$REFC" > "$STAGE/ref.commit"
for t in "$@"; do
  label=${t%%=*}; rest=${t#*=}; b=${rest%@*}; c=${rest##*@}
  [[ "$label" =~ ^[a-z0-9-]+$ && "$c" =~ ^[0-9a-f]{40}$ && -f "$b" ]] || { echo "bad target $t" >&2; exit 64; }
  git bundle verify -q "$b" >/dev/null 2>&1 || { echo "bundle $b does not verify" >&2; exit 64; }
  cp "$b" "$STAGE/$label.bundle"; echo "$label $label.bundle $c" >> "$STAGE/targets.txt"
  echo "target $label commit $c bundle sha256 $(shasum -a 256 "$b" | cut -c1-64)"
done
echo "reference commit $REFC bundle sha256 $(shasum -a 256 "$REFB" | cut -c1-64)"

# 1. The house WAN addresses as an in-cluster CIDR group (stdin only; never printed).
UK=$(cat "$HOME/Code/homelab-migration/config/unifi-api-key")
WANS=$(curl -sk -H "X-API-KEY: $UK" https://172.16.2.1/proxy/network/api/s/default/stat/device | jq -c '[.data[]|select(.type=="udm")|.wan1.ip, .wan2.ip|select(.!=null and .!="")]|unique|map(.+"/32")')
UK=""
[ "$(jq length <<<"$WANS")" -ge 1 ] || { echo "no WAN address from the UDM; refusing" >&2; exit 65; }
jq -n --argjson c "$WANS" '{apiVersion:"cilium.io/v2",kind:"CiliumCIDRGroup",metadata:{name:"pp-ci-house-wan",labels:{"vdhinfra.io/chg":"chg-2026-10-22-006"}},spec:{externalCIDRs:$c}}' | kubectl apply -f - >/dev/null
echo "cidr group pp-ci-house-wan: $(kubectl get ciliumcidrgroup pp-ci-house-wan -o jsonpath='{.spec.externalCIDRs}' | jq length) WAN addresses (not printed)"
WAN1=$(jq -r '.[0]|sub("/32$";"")' <<<"$WANS"); WANS=""

RS="$HERE/chg-2026-10-22-006-pp-ci-runner.sh"; H=$(shasum -a 256 "$RS" | cut -c1-10); CM=pp-ci-runner-$H
kubectl -n $NS get configmap $CM >/dev/null 2>&1 || kubectl -n $NS create configmap $CM --from-file=runner.sh="$RS"
kubectl -n $NS label configmap $CM vdhinfra.io/chg=chg-2026-10-22-006 --overwrite >/dev/null
kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
  labels: {app.kubernetes.io/name: pp-ci-runner, vdhinfra.io/chg: chg-2026-10-22-006}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 14400
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels: {app.kubernetes.io/name: pp-ci-runner, vdhinfra.io/chg: chg-2026-10-22-006}
    spec:
      restartPolicy: Never
      tolerations: [{key: pp-ci, operator: Equal, value: run, effect: NoSchedule}]
      automountServiceAccountToken: false
      enableServiceLinks: false
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions: [{key: kubernetes.io/hostname, operator: In, values: [$NODE_PIN]}]
      containers:
        - name: runner
          image: $IMAGE
          command: [bash, /runner/runner.sh]
          securityContext: {privileged: true}
          resources:
            requests: {cpu: "4", memory: 12Gi, ephemeral-storage: 40Gi}
            limits: {memory: 24Gi, ephemeral-storage: 120Gi}
          volumeMounts:
            - {name: runner, mountPath: /runner, readOnly: true}
            - {name: work, mountPath: /work}
            - {name: containers, mountPath: /var/lib/containers}
      volumes:
        - name: runner
          configMap: {name: $CM, defaultMode: 0555}
        - name: work
          emptyDir: {sizeLimit: 40Gi}
        - name: containers
          emptyDir: {sizeLimit: 80Gi}
EOF
POD=""
for _ in $(seq 1 60); do POD=$(kubectl -n $NS get pod -l job-name=$JOB -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); [ -n "$POD" ] && break; sleep 5; done
kubectl -n $NS wait --for=condition=Ready pod/$POD --timeout=10m
NODE=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}'); NODEIP=$(kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "pod $POD on $NODE; hostUsers=$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.hostUsers}')"
[ "$(kubectl -n $NS get pod $POD -o jsonpath='{.spec.nodeName}')" = "$NODE_PIN" ] || { echo "pod not on $NODE_PIN; refusing"; kubectl -n $NS delete job $JOB --wait=false; exit 66; }
until kubectl -n $NS exec $POD -- test -e /work/out/TOOLS 2>/dev/null; do
  kubectl -n $NS exec $POD -- test -e /work/out/DONE 2>/dev/null && break; sleep 15
done
PODIP=$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
cat > "$STAGE/probes.txt" <<P
api-vip 172.16.2.240 6443 closed
api-svc kubernetes.default.svc.cluster.local 443 closed
kubelet $NODEIP 10250 closed
udm 172.16.2.1 443 closed
nas 172.16.2.246 443 closed
pod $PODIP 8080 closed
house-wan $WAN1 443 closed
registry registry-1.docker.io 443 open
mcr mcr.microsoft.com 443 open
P
kubectl -n $NS exec $POD -- mkdir -p /work/in
kubectl -n $NS cp "$STAGE/probes.txt" "$POD:/work/in/probes.txt"
until kubectl -n $NS exec $POD -- test -e /work/out/READY 2>/dev/null; do
  kubectl -n $NS exec $POD -- test -e /work/out/DONE 2>/dev/null && break; sleep 10
done
PROBES=$(kubectl -n $NS exec $POD -- cat /work/out/probes.txt 2>/dev/null)
echo "$PROBES" | sed 's/^/probe /'
CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
HUBBLE=$(kubectl -n kube-system exec $CIL -c cilium-agent -- hubble observe --namespace $NS --verdict DROPPED --last 200 -o compact 2>/dev/null | tail -40 | sed "s/${WAN1//./\\.}/<house-wan>/g" || true)
WAN1=""
BAD=$(echo "$PROBES" | awk '{split($2,a,"=");split($3,b,"=");split($4,c,"="); if(a[2]!=c[2]||b[2]!=c[2]) print $1}')
if [ -n "$BAD" ] || [ -z "$PROBES" ]; then
  echo "probe check FAILED: ${BAD:-no probe output}; ABORT, no inputs copied"
  kubectl -n $NS exec $POD -- touch /work/in/ABORT
else
  echo "probe check passed (all negatives closed from pod and container, positives open)"
  for f in "$STAGE"/*; do case "$f" in */probes.txt) continue;; esac; kubectl -n $NS cp "$f" "$POD:/work/in/$(basename "$f")"; done
  kubectl -n $NS exec $POD -- touch /work/in/GO
  echo "inputs copied, GO at $(date -u +%H:%M:%SZ)"
fi
until kubectl -n $NS exec $POD -- test -e /work/out/DONE 2>/dev/null; do sleep 30; done
mkdir -p "$OUT"
kubectl -n $NS exec $POD -- tar -C /work/out -cf - . | tar -C "$OUT" -xf -
printf '%s\n' "$HUBBLE" > "$OUT/hubble-drops.txt"
kubectl -n $NS exec $POD -- touch /work/in/COLLECTED 2>/dev/null || kubectl -n $NS exec $POD -- sh -c 'mkdir -p /work/in && touch /work/in/COLLECTED'
echo "collected into $OUT"
kubectl -n $NS delete job $JOB --wait=false >/dev/null; kubectl -n $NS delete configmap $CM >/dev/null
echo "job and configmap deleted (C7)"
for d in "$OUT"/*/; do [ -f "$d/exit" ] && echo "$(basename "$d"): exit $(cat "$d/exit")"; done
mv "$STAGE" "${TMPDIR:-/tmp}/ppci-in-done-$RUN"
