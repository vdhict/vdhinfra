#!/usr/bin/env bash
# chg-2026-10-19-001 lesstof: one-off fill of lesstof-profiel-2/-3 onto PVC kennis-prive (KENNIS_EXTRA=/prive).
#   hack/ops/chg-2026-10-19-001-fill.sh dry-run|execute <lesstof-pakket.tar.gz>
#   hack/ops/chg-2026-10-19-001-fill.sh rollback <lesstof-pakket.tar.gz>   (only AFTER KENNIS_TOEGANG no longer names lesstof)
# The private book text goes Mini -> `kubectl exec -i` stdin -> tar in the pod. It is never written to git, an image,
# a log or evidence. Output: fixed lines, counts, sha256 prefixes only.
# Trusted filler = ConfigMap huiswerk-refresh-scripts key vul-kennis-prive (sha256 4ed58415..., == family-ai
# bin/vul-kennis-prive at 6c8743c == the package's own vul-kennis-prive.sh); the package's script is data only.
# Pod: label app.kubernetes.io/name=kennis-prive-vullen (CNP: no network), uid 65532, required podAffinity to
# kennisdienst (RWO volume), activeDeadlineSeconds 1800, no SA token. Removed with `kubectl delete pod` at the end.
# Failure after the package reached the volume -> automatic data rollback (moves into a .retired-* dir, nothing deleted).
set -euo pipefail
MODE="${1:?dry-run|execute}"; TGZ="${2:?package}"
NS=family-ai; POD=kennis-prive-vullen-chg-2026-10-19-001
TGZ_SHA=08c419c14e3708478e85fe58d1aa34e29703e12379ba4ae3d778b277f92f8701
SUMS_SHA=d072c69e874372018fb748d0a2a96c31bb71d2f2629451fb61e7932bbc224ff0
FILLER_SHA=4ed584152ccca23ef077a7dcdf5572d7e83d19f91c11bcb46d90b3687284bc02
IMAGE=docker.io/library/python:3.13.15-bookworm@sha256:227b6570d6ee07061ae6ca2eb04dedfb6d2b34045835f343065b9869e4d427ea
SNAP=kennis-prive-pre-chg-2026-10-19-001
fail() { echo "FILL: FAIL: $*" >&2; exit 1; }
say() { echo "FILL: $*"; }

# --- local prechecks (no cluster writes)
[ "$(shasum -a 256 "$TGZ" | cut -d' ' -f1)" = "$TGZ_SHA" ] || fail "package sha256"
[ "$(tar -xzOf "$TGZ" SHA256SUMS | shasum -a 256 | cut -d' ' -f1)" = "$SUMS_SHA" ] || fail "SHA256SUMS sha256"
types=$(tar -tzvf "$TGZ" | cut -c1 | sort -u | tr -d '\n'); [ "$types" = "-d" ] || fail "non-regular member types: $types"
dirs=$(tar -tzf "$TGZ" | grep '/$' | LC_ALL=C sort | tr '\n' ' '); [ "$dirs" = "lesstof-profiel-2/ lesstof-profiel-3/ " ] || fail "collection dirs"
say "package sha256 ${TGZ_SHA:0:12} OK, SHA256SUMS ${SUMS_SHA:0:12} OK, members $(tar -tzf "$TGZ" | grep -vc '/$') files in 2 collection dirs"
# Argus C3: refuse 16:30-17:45 local (refresh 17:20, pod deadline 1800 s) and with an active refresh Job; re-checked
# right before the swap.
refresh_guard() {
  local hh active
  hh=$(TZ=Europe/Amsterdam date +%H%M)
  [ "$hh" -lt 1630 ] || [ "$hh" -gt 1745 ] || fail "huiswerk-refresh window 16:30-17:45 local ($1)"
  active=$(kubectl -n "$NS" get jobs -l app.kubernetes.io/name=huiswerk-refresh -o jsonpath='{range .items[*]}{.status.active}{"\n"}{end}' | grep -c '[1-9]' || true)
  [ "$active" = 0 ] || fail "a huiswerk-refresh Job is active ($1)"
}
refresh_guard start
cm=$(kubectl -n "$NS" get cm huiswerk-refresh-scripts -o jsonpath='{.data.vul-kennis-prive}' | shasum -a 256 | cut -d' ' -f1)
[ "$cm" = "$FILLER_SHA" ] || fail "trusted filler sha in ConfigMap"
toeg=$(kubectl -n "$NS" get deploy kennisdienst -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KENNIS_TOEGANG")].value}')
case "$toeg" in *lesstof*) fail "KENNIS_TOEGANG names lesstof (fill: not yet; rollback: revert step 1 first)";; esac
! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 || fail "pod $POD already exists"

POD_YAML=$(cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
  labels: {app.kubernetes.io/name: kennis-prive-vullen, app.kubernetes.io/part-of: family-ai}
  annotations: {ops/change: chg-2026-10-19-001}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 1800
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, fsGroupChangePolicy: OnRootMismatch, seccompProfile: {type: RuntimeDefault}}
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - topologyKey: kubernetes.io/hostname
          labelSelector: {matchLabels: {app.kubernetes.io/name: kennisdienst}}
  containers:
    - name: vul
      image: $IMAGE
      command: [sleep, "1800"]
      env: [{name: HOME, value: /tmp}, {name: PYTHONDONTWRITEBYTECODE, value: "1"}]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 500m, memory: 256Mi}}
      volumeMounts:
        - {name: prive, mountPath: /vul}
        - {name: scripts, mountPath: /opt/huiswerk, readOnly: true}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: prive, persistentVolumeClaim: {claimName: kennis-prive}}
    - {name: scripts, configMap: {name: huiswerk-refresh-scripts, defaultMode: 292}}
    - {name: tmp, emptyDir: {}}
YAML
)

if [ "$MODE" = dry-run ]; then
  echo "$POD_YAML" | kubectl apply --dry-run=server -f - >/dev/null && say "pod spec server dry-run OK"
  say "dry-run done: 0 cluster writes"
  exit 0
fi
[ "$MODE" = execute ] || [ "$MODE" = rollback ] || fail "mode"
[ "$(kubectl -n "$NS" get volumesnapshot "$SNAP" -o jsonpath='{.status.readyToUse}')" = true ] || fail "snapshot $SNAP not readyToUse"

kx() { kubectl -n "$NS" exec -i "$POD" -c vul -- "$@"; }
LANDED=0
rollback_data() {
  [ "$LANDED" = 1 ] || return 0
  say "AUTOMATIC DATA ROLLBACK: moving .nieuw and lesstof-profiel-2/-3 into a new .retired dir"
  kx python3 -I -c '
import tempfile; from pathlib import Path
v = Path("/vul"); r = Path(tempfile.mkdtemp(prefix=".retired-chg-2026-10-19-001-rb-", dir=v))
for n in (".nieuw", "lesstof-profiel-2", "lesstof-profiel-3"):
    if (v / n).exists(): (v / n).rename(r / n.lstrip("."))
print("FILL: rollback moved into", r.name)' || echo "FILL: ROLLBACK FAILED - restore from VolumeSnapshot $SNAP" >&2
}
cleanup() { rc=$?; [ $rc = 0 ] || rollback_data; kubectl -n "$NS" delete pod "$POD" --wait=true --timeout=120s >/dev/null 2>&1 || true; say "pod removed (rc $rc)"; }
trap cleanup EXIT

echo "$POD_YAML" | kubectl apply -f - >/dev/null
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null || fail "pod not Ready"
if [ "$MODE" = rollback ]; then LANDED=1; rollback_data; LANDED=0; exit 0; fi
# digest over (path, sha256) of every file of the collections that must not change; printed as a 12-char prefix
KEEP='cd /vul && find huiswerk-profiel-2 huiswerk-profiel-3 zeevaart -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum | sha256sum | cut -c1-12'
keep_before=$(kx sh -c "$KEEP")
say "pod Ready on $(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}') (kennisdienst on $(kubectl -n "$NS" get pod -l app.kubernetes.io/name=kennisdienst -o jsonpath='{.items[0].spec.nodeName}'))"
[ "$(kx sha256sum /opt/huiswerk/vul-kennis-prive | cut -d' ' -f1)" = "$FILLER_SHA" ] || fail "filler sha in pod"
kx sh -c 'test ! -e /vul/.nieuw && test ! -e /vul/lesstof-profiel-2 && test ! -e /vul/lesstof-profiel-3' || fail "target names already exist on the volume"
before=$(kx sh -c 'ls -A /vul | grep -c "^\.retired-" || true')
kx mkdir -m 700 /vul/.nieuw
LANDED=1
kx tar -xzf - -C /vul/.nieuw --no-same-owner --no-same-permissions < "$TGZ" || fail "tar in pod"
[ "$(kx sha256sum /vul/.nieuw/SHA256SUMS | cut -d' ' -f1)" = "$SUMS_SHA" ] || fail "SHA256SUMS on the volume"
refresh_guard "before swap"
kx sh /opt/huiswerk/vul-kennis-prive "$SUMS_SHA" /vul | sed 's/^/FILL: /'
for c in lesstof-profiel-2 lesstof-profiel-3; do
  n=$(kx sh -c "ls /vul/$c/*.md | wc -l" | tr -d ' ')
  [ "$n" = 24 ] || fail "$c has $n md files, want 24"
done
kx sh -c 'cd /vul && cmp -s lesstof-profiel-2/wiskunde-1.md lesstof-profiel-3/wiskunde-1.md && diff -rq lesstof-profiel-2 lesstof-profiel-3 >/dev/null' \
  || fail "the two collections are not byte-identical"
after=$(kx sh -c 'ls -A /vul | grep -c "^\.retired-" || true')
[ "$after" = $((before + 1)) ] || fail ".retired count $before -> $after"
kx sh -c 'test ! -e /vul/.nieuw' || fail ".nieuw left behind"
keep_after=$(kx sh -c "$KEEP")
[ "$keep_before" = "$keep_after" ] || fail "huiswerk/zeevaart digest changed $keep_before -> $keep_after"
say "PASS: lesstof-profiel-2 24 md, lesstof-profiel-3 24 md, byte-identical; .retired $before -> $after; huiswerk+zeevaart digest $keep_after unchanged"
LANDED=0
