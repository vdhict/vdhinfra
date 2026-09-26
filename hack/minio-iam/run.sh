#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Run the forge MinIO IAM Job (chg-2026-09-23-002) and collect evidence.
#
#   hack/minio-iam/run.sh apply  <evidence-file>   create/refresh + prove
#   hack/minio-iam/run.sh remove <evidence-file>   rollback (users + policies;
#                                                  buckets only if empty)
#   hack/minio-iam/run.sh check                    read-only: is IAM present?
#                                                  (used by DR 00-prereqs.sh)
#
# Sequence: server-side dry-run -> ExternalSecret -> wait SecretSynced ->
# Job -> wait complete/failed -> logs of every container to the evidence
# file -> delete Job + ConfigMap + ExternalSecret (its Secret goes with it).
# Cleanup runs on every exit path. Secrets never reach this shell: the Job
# reads them from Kubernetes Secrets, and its scripts redact their output.
#
# HIGH RISK (auth). Needs a change record with user approval before `apply`
# or `remove` against production.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
NS=storage
MODE="${1:-}"
EVIDENCE="${2:-}"

# IAM_SET selects which identity set to operate on. Default `forge` keeps
# every existing caller (DR 00-prereqs.sh, the DR runbook) byte-identical.
#   forge      forge-pg + forge-volsync         (chg-2026-09-23-002)
#   family-ai  family-ai-volsync                (chg-2026-09-26-001)
IAM_SET="${IAM_SET:-forge}"
case "$IAM_SET" in
  forge)
    KDIR="$DIR"; KFLAGS=()
    WANT=('"accessKey":"forge-pg","policyName":"forge-backups-rw","userStatus":"enabled"'
          '"accessKey":"forge-volsync","policyName":"forge-volsync-rw","userStatus":"enabled"') ;;
  family-ai)
    # family-ai/ reuses the scripts one level up, hence the load restrictor.
    KDIR="$DIR/family-ai"; KFLAGS=(--load-restrictor LoadRestrictionsNone)
    WANT=('"accessKey":"family-ai-volsync","policyName":"family-ai-volsync-rw","userStatus":"enabled"') ;;
  *) echo "run.sh: unknown IAM_SET '$IAM_SET' (forge|family-ai)" >&2; exit 1 ;;
esac
JOB="minio-iam-$IAM_SET"

die() { echo "run.sh: $*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not on PATH"

render() {
  if [ "$MODE" = remove ]; then
    # Same objects; the Job runs only iam-apply.sh remove (no verify, no restic).
    kubectl kustomize "${KFLAGS[@]+"${KFLAGS[@]}"}" "$KDIR" | yq '
      (select(.kind == "Job") | .metadata.name) = "'"$JOB"'-remove" |
      (select(.kind == "Job") | .spec.template.spec.containers) =
        [ (select(.kind == "Job") | .spec.template.spec.initContainers[0]) | .command = ["/bin/bash", "/iam/iam-apply.sh", "remove"] ] |
      (select(.kind == "Job") | .spec.template.spec.initContainers) = []'
  else
    kubectl kustomize "${KFLAGS[@]+"${KFLAGS[@]}"}" "$KDIR"
  fi
}

cleanup() {
  echo "── cleanup ──"
  kubectl -n "$NS" delete job "$JOB" "$JOB-remove" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pod -l "app.kubernetes.io/name=$JOB" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "$NS" delete configmap "$JOB-scripts" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NS" delete externalsecret "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  # Owner GC removes the Secret; wait for it and SAY if it is still there.
  for _ in $(seq 1 30); do
    kubectl -n "$NS" get secret "$JOB" >/dev/null 2>&1 || { echo "cleanup: Job, ConfigMap, ExternalSecret and Secret gone"; return 0; }
    sleep 2
  done
  echo "cleanup: WARNING Secret storage/$JOB still present - delete it by hand" >&2
}

case "$MODE" in
  check)
    # Read-only: do the two users exist with the right policies? Uses a
    # throwaway root-only pod (no scoped creds needed).
    kubectl -n "$NS" get secret minio-secret >/dev/null || die "storage/minio-secret missing"
    kubectl -n "$NS" delete pod minio-iam-check --ignore-not-found >/dev/null 2>&1
    kubectl -n "$NS" run minio-iam-check --restart=Never --quiet \
      --image=quay.io/minio/mc:RELEASE.2024-09-09T07-53-10Z@sha256:782e3b2caa88fb565d5c78b15575939ea9778754a4577794922c1d359c06f422 \
      --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"quay.io/minio/mc:RELEASE.2024-09-09T07-53-10Z@sha256:782e3b2caa88fb565d5c78b15575939ea9778754a4577794922c1d359c06f422","command":["/bin/bash","-c","export MC_CONFIG_DIR=/tmp/mc HOME=/tmp; mc alias set r http://minio.storage.svc.cluster.local:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null && mc --json admin user list r; rc=$?; rm -rf /tmp/mc; exit $rc"],"env":[{"name":"MINIO_ROOT_USER","valueFrom":{"secretKeyRef":{"name":"minio-secret","key":"MINIO_ROOT_USER"}}},{"name":"MINIO_ROOT_PASSWORD","valueFrom":{"secretKeyRef":{"name":"minio-secret","key":"MINIO_ROOT_PASSWORD"}}}],"volumeMounts":[{"name":"t","mountPath":"/tmp"}],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}],"volumes":[{"name":"t","emptyDir":{"medium":"Memory","sizeLimit":"16Mi"}}]}}' >/dev/null
    kubectl -n "$NS" wait pod/minio-iam-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null || true
    out=$(kubectl -n "$NS" logs minio-iam-check 2>&1 || true)
    kubectl -n "$NS" delete pod minio-iam-check --ignore-not-found >/dev/null 2>&1
    echo "$out"
    missing=0
    for want in "${WANT[@]}"; do
      case "$out" in *"$want"*) ;; *) echo "MISSING: $want"; missing=1;; esac
    done
    [ $missing -eq 0 ] && echo "MinIO IAM: $IAM_SET identities present" || { echo "MinIO IAM: $IAM_SET identities MISSING - run: IAM_SET=$IAM_SET hack/minio-iam/run.sh apply <evidence-file>"; exit 3; }
    exit 0
    ;;
  apply|remove)
    [ -n "$EVIDENCE" ] || die "usage: $0 $MODE <evidence-file>"
    command -v yq >/dev/null || die "yq not on PATH (mise install)" ;;
  *) die "usage: $0 apply|remove <evidence-file> | check" ;;
esac

kubectl -n "$NS" get secret minio-secret >/dev/null || die "storage/minio-secret missing - MinIO root not available"
if kubectl -n "$NS" get job "$JOB" "$JOB-remove" >/dev/null 2>&1; then die "a previous $JOB Job still exists - inspect, then delete it"; fi

mkdir -p "$(dirname "$EVIDENCE")"
exec > >(tee -a "$EVIDENCE") 2>&1
echo "# minio-iam run.sh $MODE  set=$IAM_SET  $(date -u +%FT%TZ)  context=$(kubectl config current-context)"
echo "# git: $(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo n/a)  rendered sha256: $(render | shasum -a 256 | cut -c1-16)"

echo "── server-side dry-run ──"
render | kubectl apply --dry-run=server -f -

trap cleanup EXIT

echo "── ExternalSecret ──"
render | yq 'select(.kind == "ExternalSecret")' | kubectl apply -f -
if ! kubectl -n "$NS" wait "externalsecret/$JOB" --for=condition=Ready --timeout=120s; then
  echo "ExternalSecret NOT Ready. Status (no secret material):"
  kubectl -n "$NS" get externalsecret "$JOB" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  die "1Password items missing or a field label is wrong - nothing was changed in MinIO"
fi

echo "── Job ($MODE) ──"
render | yq 'select(.kind != "ExternalSecret")' | kubectl apply -f -
J="$JOB"; [ "$MODE" = remove ] && J="$JOB-remove"
rc=1
for _ in $(seq 1 180); do   # 180 x 5s = the Job's own 900s activeDeadline
  st=$(kubectl -n "$NS" get job "$J" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)
  case " $st " in *" Complete "*) rc=0; break;; *" Failed "*) rc=1; break;; esac
  sleep 5
done
POD=$(kubectl -n "$NS" get pod -l "job-name=$J" -o jsonpath='{.items[0].metadata.name}')
for c in $(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}'); do
  echo "════════ container $c ════════"
  kubectl -n "$NS" logs "$POD" -c "$c" 2>&1 || echo "(no log)"
done
kubectl -n "$NS" get pod "$POD" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: exit={.state.terminated.exitCode}{"\n"}{end}{range .status.containerStatuses[*]}{.name}: exit={.state.terminated.exitCode}{"\n"}{end}'
if [ $rc -eq 0 ]; then echo "RESULT: Job $J Complete"; else echo "RESULT: Job $J did NOT complete"; exit 1; fi
