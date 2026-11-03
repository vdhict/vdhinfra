#!/usr/bin/env bash
# Runs one pod-based suite of the vdhwslin01 bundle in a THROWAWAY namespace and
# cleans up with delete + read-back (chg-2026-10-05-031). Run from the Mini.
#
#   tests/run-in-pod.sh <arch|nft|sudo> <evidence-file> [fixtures-box-dir]
#   sudo  tests/sudo-window-container.sh: as arch (PSA baseline, default capabilities).
#
#   arch  tests/arch-container.sh: namespace PSA enforce=baseline, root in the
#         container with the DEFAULT capability set only (pacman, useradd,
#         chroot, mknod need root; nothing is added), seccomp RuntimeDefault.
#   nft   tests/nft-kernel.sh: namespace PSA enforce=privileged ONLY because
#         baseline forbids adding a capability; the pod is NOT privileged, it
#         adds exactly NET_ADMIN, in its OWN network namespace (no hostNetwork),
#         so the nft rules it loads live and die with the pod.
# Both: automountServiceAccountToken=false, no service links, image pinned by
# digest, activeDeadlineSeconds (the kubelet kills the pod at the deadline even
# if this script dies), labels vdhict.net/throwaway=true + chg + expires.
# Cleanup (trap): "${K[@]}" delete namespace --wait, then read back that the
# namespace and every pod with the label are gone; the read-back is appended to
# the evidence file, which is written once (refuses an existing file) and made 0444.
set -euo pipefail
suite="${1:?arch|nft|sudo}"; ev="${2:?evidence file}"; fixtures="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"; bundle="$(cd "$here/.." && pwd)"
[[ ! -e "$ev" ]] || { echo "evidence $ev exists (write-once)" >&2; exit 2; }
# C6 (Argus 2026-11-03): every kubectl call pins the context and an absolute binary.
KUBECTL="${KUBECTL:-$(command -v kubectl)}"; [[ "$KUBECTL" == /* ]] || { echo "KUBECTL must be an absolute path" >&2; exit 2; }
K=("$KUBECTL" --context admin@vdhinfra-local)
IMAGE="docker.io/library/archlinux:base@sha256:ece6c971fec3c532fd508bce299a446deaf469feecbfe7c353e995bc1a5e7bba"
ts="$(date -u +%Y%m%dt%H%M%Sz)"; ns="vdhwslin01-test-${suite}-${ts}"
exp="$(( $(date +%s) + 7200 ))"
case "$suite" in
  arch) psa=baseline; caps='"drop": []'; script=tests/arch-container.sh; deadline=3600
        res='"requests": {"cpu": "500m", "memory": "1Gi", "ephemeral-storage": "4Gi"}, "limits": {"cpu": "2", "memory": "4Gi", "ephemeral-storage": "12Gi"}' ;;
  sudo) psa=baseline; caps='"drop": []'; script=tests/sudo-window-container.sh; deadline=1800
        res='"requests": {"cpu": "500m", "memory": "512Mi", "ephemeral-storage": "2Gi"}, "limits": {"cpu": "2", "memory": "2Gi", "ephemeral-storage": "6Gi"}' ;;
  nft)  psa=privileged; caps='"add": ["NET_ADMIN"]'; script=tests/nft-kernel.sh; deadline=1200
        res='"requests": {"cpu": "200m", "memory": "256Mi", "ephemeral-storage": "1Gi"}, "limits": {"cpu": "1", "memory": "1Gi", "ephemeral-storage": "3Gi"}' ;;
  *) echo "suite must be arch, nft or sudo" >&2; exit 2 ;;
esac

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  {
    echo
    echo "# cleanup $(date -u +%FT%TZ): kubectl --context admin@vdhinfra-local delete namespace $ns"
    "${K[@]}" delete namespace "$ns" --wait=true --timeout=300s 2>&1 | sed 's/^/#   /' || true
    if "${K[@]}" get namespace "$ns" -o name >/dev/null 2>&1; then echo "# READBACK FAIL: namespace $ns still present"
    else echo "# readback: namespace $ns NotFound"; fi
    left="$("${K[@]}" get pods -A -l vdhict.net/throwaway=true,vdhict.net/chg=chg-2026-10-05-031 -o name 2>/dev/null | wc -l | tr -d ' ')"
    lns="$("${K[@]}" get ns -l vdhict.net/throwaway=true,vdhict.net/chg=chg-2026-10-05-031 -o name 2>/dev/null | wc -l | tr -d ' ')"
    echo "# readback: throwaway pods left (chg label, all namespaces) = $left; throwaway namespaces left = $lns"
  } >> "$ev"
  chmod 0444 "$ev"
}
trap cleanup EXIT

{
  echo "# chg-2026-10-05-031 $script in throwaway pod; $(date -u +%FT%TZ); runner: $(hostname -s)"
  echo "# namespace $ns (PSA enforce=$psa), image $IMAGE, capabilities {$caps}, activeDeadlineSeconds $deadline"
  echo "# bundle provision.sh sha256 $(shasum -a 256 "$bundle/provision.sh" | cut -d' ' -f1)"
  [[ -n "$fixtures" ]] && echo "# fixtures-box: $(cd "$fixtures" && shasum -a 256 ./* | tr '\n' ';')"
} > "$ev"

"${K[@]}" apply -f - >/dev/null <<EOF
{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "$ns", "labels": {
  "vdhict.net/throwaway": "true", "vdhict.net/chg": "chg-2026-10-05-031", "vdhict.net/expires": "$exp",
  "pod-security.kubernetes.io/enforce": "$psa", "pod-security.kubernetes.io/warn": "baseline"}}}
EOF
"${K[@]}" apply -f - >/dev/null <<EOF
{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "suite", "namespace": "$ns", "labels": {
  "vdhict.net/throwaway": "true", "vdhict.net/chg": "chg-2026-10-05-031", "vdhict.net/expires": "$exp"}},
 "spec": {"restartPolicy": "Never", "activeDeadlineSeconds": $deadline, "terminationGracePeriodSeconds": 5,
  "automountServiceAccountToken": false, "enableServiceLinks": false,
  "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "t", "image": "$IMAGE", "command": ["sleep", "$((deadline - 60))"],
    "securityContext": {"privileged": false, "capabilities": {$caps}},
    "resources": {$res}}]}}
EOF
"${K[@]}" -n "$ns" wait --for=condition=Ready pod/suite --timeout=300s >/dev/null
echo "# node: $("${K[@]}" -n "$ns" get pod suite -o jsonpath='{.spec.nodeName}'), kernel: $("${K[@]}" -n "$ns" exec suite -- uname -r)" >> "$ev"

# Bundle in: only what the suites need; fixtures-box (if given) next to it.
"${K[@]}" -n "$ns" exec suite -- mkdir -p /bundle
COPYFILE_DISABLE=1 tar -C "$bundle" -cf - provision.sh src tests sudo-window \
  | "${K[@]}" -n "$ns" exec -i suite -- tar -C /bundle -xf -
if [[ -n "$fixtures" ]]; then
  COPYFILE_DISABLE=1 tar -C "$(dirname "$fixtures")" -cf - "$(basename "$fixtures")" | "${K[@]}" -n "$ns" exec -i suite -- tar -C /bundle -xf -
  "${K[@]}" -n "$ns" exec suite -- sh -c "[ -d /bundle/fixtures-box ] || mv /bundle/$(basename "$fixtures") /bundle/fixtures-box"
fi

set +e
"${K[@]}" -n "$ns" exec suite -- bash "/bundle/$script" /bundle >> "$ev" 2>&1
rc=$?
set -e
echo "# suite exit code: $rc" >> "$ev"
grep -E '^(RESULT|# suite exit)' "$ev" || true
exit "$rc"
