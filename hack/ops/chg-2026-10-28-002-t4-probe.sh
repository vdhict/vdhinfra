#!/usr/bin/env bash
# chg-2026-10-28-002 test T4 (+ the "unreachable from any other pod" half of
# T3): isolation of namespace cursus-gast, in both directions. READ-ONLY
# towards every target: TCP connect checks (nc -z) and DNS lookups, no
# payload.
#
# Phase A (Argus F5): a short-lived pod in cursus-gast WITH cloudflared's pod
#   labels (app.kubernetes.io/name + /controller = cloudflared), so it gets
#   exactly cloudflared's identity and CNPs. It deliberately does NOT carry
#   app.kubernetes.io/instance, so the cloudflared ReplicaSet never adopts
#   it. Expect: only the allowed DNS names and region1/2:7844 (and the
#   origin, if courseware-gast is deployed) succeed. Those successes are
#   phase A's positive controls.
# Phase B: an UNLABELLED pod in cursus-gast (default-deny only). Expect
#   everything blocked, including courseware-gast:8080 and DNS.
# Phase C (Argus G3, reverse): a short-lived pod in `default`, a namespace
#   with NO policy at all, towards the courseware-gast pod IP(s) and Service
#   on 8080 and the cloudflared pod IP(s) on 2000. Expect blocked: only the
#   cursus-gast ingress default-deny stands in the way. Positive controls in
#   the SAME pod: kube-dns 53 and the API server via the kubernetes Service
#   must succeed, else a "blocked" proves nothing.
#
# Counting rules (Argus G3):
#   * Phases B and C count only if phase A passed in this run.
#   * Phase C's blocked results count only if its positive controls passed.
#   Anything not counted makes the run FAIL.
#
# home-automation, network, database and media have NO NetworkPolicy of
# their own, so for their targets the cursus-gast egress default-deny (and
# private-deny) is the ONLY wall. A single "ok" there is a fail.
#
# Output: one line per probe, "phase name expect=<x> got=<y> PASS|FAIL",
# into a write-once evidence file.
# Exit: 0 full pass; 1 any fail or not-counted phase; 4 no fail but some
# probes skipped (e.g. courseware-gast/cloudflared not running yet), so a
# pre-go-live run can never be mistaken for the go-live T4.
# Hubble (optional, run separately): hubble observe -n cursus-gast --verdict DROPPED
#
# Probe pods are removed with `kubectl delete pod` (an EXIT trap, also on
# failure) and carry activeDeadlineSeconds. No rm/unlink/find -delete
# anywhere (AGR-121).
set -euo pipefail

NS=cursus-gast
REVNS=default
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="${REPO}/ops/evidence/chg-2026-10-28-002"
EV="${EVDIR}/t4-probe-${TS}.txt"
IMAGE="docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
SUFFIX="$(echo "${TS}" | tr '[:upper:]' '[:lower:]')"

mkdir -p "${EVDIR}"
( set -o noclobber; : > "${EV}" ) 2>/dev/null || { echo "evidence file exists, refusing to overwrite: ${EV}" >&2; exit 1; }

log() { echo "$*" | tee -a "${EV}"; }

CREATED=()
cleanup() {
  local p
  for p in ${CREATED[@]+"${CREATED[@]}"}; do
    kubectl -n "${p%%/*}" delete pod "${p#*/}" --wait=false >/dev/null 2>&1 \
      || echo "cleanup: could not delete pod ${p}; delete it by hand" >&2
  done
}
trap cleanup EXIT

# --- preflight --------------------------------------------------------------
kubectl get ns "${NS}" >/dev/null
for p in default-deny private-deny cloudflared courseware-gast; do
  kubectl -n "${NS}" get ciliumnetworkpolicy "${p}" >/dev/null
done
# Phase C is only meaningful from a namespace WITHOUT policies.
rev_pol="$(kubectl -n "${REVNS}" get ciliumnetworkpolicy,networkpolicy -o name)"
if [ -n "${rev_pol}" ]; then
  log "namespace ${REVNS} has policies; phase C would not test cursus-gast alone. Abort."
  exit 1
fi
FAMILY_IP="$(kubectl -n family get svc courseware -o jsonpath='{.spec.clusterIP}')"
APISERVER_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
DNS_IP="$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')"
if kubectl -n "${NS}" get svc courseware-gast >/dev/null 2>&1; then
  ORIGIN_EXPECT=ok
  ORIGIN_SVC_IP="$(kubectl -n "${NS}" get svc courseware-gast -o jsonpath='{.spec.clusterIP}')"
else
  ORIGIN_EXPECT=skip   # courseware-gast still suspended: no Service yet
  ORIGIN_SVC_IP=""
fi
# Real workload pods only (the probe pods never carry the instance label).
CW_IPS="$(kubectl -n "${NS}" get pods -l app.kubernetes.io/name=courseware-gast,app.kubernetes.io/instance=courseware-gast \
  --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')"
CF_IPS="$(kubectl -n "${NS}" get pods -l app.kubernetes.io/name=cloudflared,app.kubernetes.io/instance=cloudflared \
  --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')"
ORIGIN=courseware-gast.cursus-gast.svc.cluster.local

log "chg-2026-10-28-002 T4 probe ${TS}"
log "image ${IMAGE}"
log "origin service present: $([ "${ORIGIN_EXPECT}" = ok ] && echo yes || echo no)"
log "courseware-gast pods running: $(printf '%s' "${CW_IPS}" | grep -c . || true)"
log "cloudflared pods running: $(printf '%s' "${CF_IPS}" | grep -c . || true)"

# kind|name|host|port|expect   (kind: tcp, dns-a, dns-srv; expect skip = not run)
TARGETS_A="$(cat <<EOF
dns-a|dns-origin|${ORIGIN}|-|${ORIGIN_EXPECT}
dns-srv|dns-edge-srv|_v2-origintunneld._tcp.argotunnel.com|-|ok
dns-a|dns-region1|region1.v2.argotunnel.com|-|ok
dns-a|dns-arbitrary|example.org|-|refused
tcp|edge-region1-7844|region1.v2.argotunnel.com|7844|ok
tcp|edge-region2-7844|region2.v2.argotunnel.com|7844|ok
tcp|edge-region1-443|region1.v2.argotunnel.com|443|blocked
tcp|origin-8080|${ORIGIN}|8080|${ORIGIN_EXPECT}
tcp|family-courseware|${FAMILY_IP}|8080|blocked
tcp|ha-8123|172.16.2.237|8123|blocked
tcp|envoy-internal-443|172.16.2.241|443|blocked
tcp|postgres-5432|172.16.2.239|5432|blocked
tcp|minio-9000|172.16.2.245|9000|blocked
tcp|mosquitto-1883|172.16.2.244|1883|blocked
tcp|node81-apid|172.16.2.81|50000|blocked
tcp|node81-kubelet|172.16.2.81|10250|blocked
tcp|node82-apid|172.16.2.82|50000|blocked
tcp|node82-kubelet|172.16.2.82|10250|blocked
tcp|node83-apid|172.16.2.83|50000|blocked
tcp|node83-kubelet|172.16.2.83|10250|blocked
tcp|cp84-apid|172.16.2.84|50000|blocked
tcp|cp84-kubelet|172.16.2.84|10250|blocked
tcp|cp85-apid|172.16.2.85|50000|blocked
tcp|cp85-kubelet|172.16.2.85|10250|blocked
tcp|cp86-apid|172.16.2.86|50000|blocked
tcp|cp86-kubelet|172.16.2.86|10250|blocked
tcp|vip-6443|172.16.2.240|6443|blocked
tcp|udm-443|172.16.2.1|443|blocked
tcp|nas-443|172.16.2.246|443|blocked
tcp|kube-apiserver|${APISERVER_IP}|443|blocked
tcp|kube-dns-metrics|${DNS_IP}|9153|blocked
tcp|internet-443|1.1.1.1|443|blocked
tcp|dot-853|1.1.1.1|853|blocked
EOF
)"

TARGETS_B="$(cat <<EOF
dns-a|unlabelled-dns-region1|region1.v2.argotunnel.com|-|blocked
tcp|unlabelled-origin-8080|${ORIGIN}|8080|$([ "${ORIGIN_EXPECT}" = ok ] && echo blocked || echo skip)
tcp|unlabelled-edge-7844|region1.v2.argotunnel.com|7844|blocked
tcp|unlabelled-ha-8123|172.16.2.237|8123|blocked
EOF
)"

# Phase C: positive controls first (names start with "control-").
TARGETS_C="control-dns|tcp|${DNS_IP}|53|ok
control-apiserver|tcp|${APISERVER_IP}|443|ok"
TARGETS_C="$(printf '%s\n' "${TARGETS_C}" | awk -F'|' '{print $2"|"$1"|"$3"|"$4"|"$5}')"
if [ -n "${ORIGIN_SVC_IP}" ]; then
  TARGETS_C="${TARGETS_C}
tcp|rev-origin-svc-ip|${ORIGIN_SVC_IP}|8080|blocked
tcp|rev-origin-svc-name|${ORIGIN}|8080|blocked"
else
  TARGETS_C="${TARGETS_C}
tcp|rev-origin-svc|none|8080|skip"
fi
if [ -n "${CW_IPS}" ]; then
  i=0
  while read -r ip; do
    [ -n "${ip}" ] || continue
    i=$((i + 1))
    TARGETS_C="${TARGETS_C}
tcp|rev-origin-pod${i}-8080|${ip}|8080|blocked"
  done <<< "${CW_IPS}"
else
  TARGETS_C="${TARGETS_C}
tcp|rev-origin-pod-8080|none|8080|skip"
fi
if [ -n "${CF_IPS}" ]; then
  i=0
  while read -r ip; do
    [ -n "${ip}" ] || continue
    i=$((i + 1))
    TARGETS_C="${TARGETS_C}
tcp|rev-cloudflared-pod${i}-2000|${ip}|2000|blocked"
  done <<< "${CF_IPS}"
else
  TARGETS_C="${TARGETS_C}
tcp|rev-cloudflared-pod-2000|none|2000|skip"
fi

# The in-pod prober. Prints "R|name|expect|got" per line. dns: ok when an
# answer comes back, refused when the Cilium DNS proxy says REFUSED,
# blocked when the query never gets an answer at all.
PROBER='
echo "$TARGETS" | while IFS="|" read -r kind name host port expect; do
  [ -z "$kind" ] && continue
  if [ "$expect" = skip ]; then echo "R|$name|skip|skip"; continue; fi
  case "$kind" in
    tcp)
      if nc -z -w 4 "$host" "$port" >/dev/null 2>&1; then got=ok; else got=blocked; fi ;;
    dns-a|dns-srv)
      t=a; [ "$kind" = dns-srv ] && t=srv
      out="$(nslookup -type=$t -timeout=4 -retry=1 "$host" 2>&1 || true)"
      if echo "$out" | grep -q REFUSED; then got=refused
      elif echo "$out" | grep -q NXDOMAIN; then got=nxdomain
      elif echo "$out" | grep -qE "timed out|no servers could be reached"; then got=blocked
      elif [ "$t" = srv ] && echo "$out" | grep -q "service ="; then got=ok
      elif [ "$t" = a ] && [ "$(echo "$out" | grep -c "^Address")" -ge 2 ]; then got=ok
      else got=other; fi ;;
    *) got=badkind ;;
  esac
  echo "R|$name|$expect|$got"
done
echo "R-DONE"
'

SKIPS=0
PHASE_FAILS=0
CONTROL_FAILS=0

# run_phase <phase> <namespace> <labels-yaml> <targets>
# Sets PHASE_FAILS (mismatches + pod/prober errors) and CONTROL_FAILS
# (mismatches on control-* probes) for this phase.
run_phase() {
  local phase="$1" ns="$2" labels="$3" targets="$4"
  local pod="t4-probe-${phase}-${SUFFIX}"
  PHASE_FAILS=0
  CONTROL_FAILS=0
  log "--- phase ${phase}: pod ${ns}/${pod}"
  CREATED+=("${ns}/${pod}")
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
  labels:
    t4-probe: "true"
${labels}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  automountServiceAccountToken: false
  enableServiceLinks: false
  dnsConfig:
    options:
      - {name: ndots, value: "1"}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["/bin/sh", "-c"]
      args:
        - |
$(echo "${PROBER}" | sed 's/^/          /')
      env:
        - name: TARGETS
          value: |
$(echo "${targets}" | sed 's/^/            /')
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 32Mi}
EOF
  if ! kubectl -n "${ns}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=280s >/dev/null; then
    log "phase ${phase}: pod did not reach Succeeded"
    PHASE_FAILS=$((PHASE_FAILS + 1))
  fi
  local out
  out="$(kubectl -n "${ns}" logs "${pod}" 2>&1 || true)"
  echo "${out}" | grep -q '^R-DONE' || { log "phase ${phase}: prober did not finish"; PHASE_FAILS=$((PHASE_FAILS + 1)); }
  while IFS='|' read -r tag name expect got; do
    [ "${tag}" = R ] || continue
    if [ "${expect}" = skip ]; then
      log "${phase} ${name} SKIPPED (target not present)"
      SKIPS=$((SKIPS + 1))
    elif [ "${expect}" = "${got}" ]; then
      log "${phase} ${name} expect=${expect} got=${got} PASS"
    else
      log "${phase} ${name} expect=${expect} got=${got} FAIL"
      PHASE_FAILS=$((PHASE_FAILS + 1))
      case "${name}" in control-*) CONTROL_FAILS=$((CONTROL_FAILS + 1)) ;; esac
    fi
  done <<< "${out}"
}

RESULT_FAIL=0

run_phase a "${NS}" "    app.kubernetes.io/name: cloudflared
    app.kubernetes.io/controller: cloudflared" "${TARGETS_A}"
A_FAILS="${PHASE_FAILS}"
if [ "${A_FAILS}" -eq 0 ]; then
  log "phase a: PASS"
else
  log "phase a: FAIL (${A_FAILS})"
  RESULT_FAIL=1
fi

run_phase b "${NS}" "" "${TARGETS_B}"
B_FAILS="${PHASE_FAILS}"
if [ "${A_FAILS}" -ne 0 ]; then
  log "phase b: NOT COUNTED (phase a did not pass in this run)"
  RESULT_FAIL=1
elif [ "${B_FAILS}" -eq 0 ]; then
  log "phase b: PASS"
else
  log "phase b: FAIL (${B_FAILS})"
  RESULT_FAIL=1
fi

run_phase c "${REVNS}" "" "${TARGETS_C}"
C_FAILS="${PHASE_FAILS}"
C_CONTROL_FAILS="${CONTROL_FAILS}"
if [ "${A_FAILS}" -ne 0 ]; then
  log "phase c: NOT COUNTED (phase a did not pass in this run)"
  RESULT_FAIL=1
elif [ "${C_CONTROL_FAILS}" -ne 0 ]; then
  log "phase c: NOT COUNTED (positive controls failed: the probe pod had no working network)"
  RESULT_FAIL=1
elif [ "${C_FAILS}" -eq 0 ]; then
  log "phase c: PASS"
else
  log "phase c: FAIL (${C_FAILS})"
  RESULT_FAIL=1
fi

if [ "${RESULT_FAIL}" -ne 0 ]; then
  log "T4 RESULT FAIL"
  echo "evidence: ${EV}"
  exit 1
fi
if [ "${SKIPS}" -gt 0 ]; then
  log "T4 RESULT PARTIAL (no failures, ${SKIPS} probes skipped: workload not running) - not the go-live T4"
  echo "evidence: ${EV}"
  exit 4
fi
log "T4 RESULT PASS"
echo "evidence: ${EV}"
exit 0
