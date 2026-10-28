#!/usr/bin/env bash
# chg-2026-10-28-002 test T4 (+ the "unreachable from any other pod" half of
# T3): egress isolation of namespace cursus-gast. READ-ONLY towards every
# target: TCP connect checks (nc -z) and DNS lookups, no payload.
#
# Phase A (Argus F5): a short-lived pod in cursus-gast WITH cloudflared's
#   pod labels (app.kubernetes.io/name + /controller = cloudflared), so it
#   gets exactly cloudflared's identity and CNPs. It deliberately does NOT
#   carry app.kubernetes.io/instance, so the cloudflared ReplicaSet never
#   adopts it. Expect: only the allowed DNS names and region1/2:7844 (and the
#   origin, if courseware-gast is deployed) succeed.
# Phase B: an UNLABELLED pod in cursus-gast (default-deny only). Expect:
#   everything blocked, including courseware-gast:8080 and DNS.
#
# home-automation, network, database and media have NO NetworkPolicy of
# their own, so for their targets the cursus-gast egress default-deny (and
# private-deny) is the ONLY wall. A single "ok" there is a fail.
#
# Output: one line per probe, "name expect=<x> got=<y> PASS|FAIL", into a
# write-once evidence file. Exit 0 only if every probe matches.
# Hubble (optional, run separately): hubble observe -n cursus-gast --verdict DROPPED
#
# No rm/unlink/find -delete anywhere (AGR-121). Probe pods are removed with
# kubectl delete pod; they also carry activeDeadlineSeconds.
set -euo pipefail

NS=cursus-gast
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="${REPO}/ops/evidence/chg-2026-10-28-002"
EV="${EVDIR}/t4-probe-${TS}.txt"
IMAGE="docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
SUFFIX="$(echo "${TS}" | tr '[:upper:]' '[:lower:]')"

mkdir -p "${EVDIR}"
if [ -e "${EV}" ]; then
  echo "evidence file exists, refusing to overwrite: ${EV}" >&2
  exit 2
fi

log() { echo "$*" | tee -a "${EV}"; }

# --- preflight --------------------------------------------------------------
kubectl get ns "${NS}" >/dev/null
for p in default-deny private-deny cloudflared courseware-gast; do
  kubectl -n "${NS}" get ciliumnetworkpolicy "${p}" >/dev/null
done
FAMILY_IP="$(kubectl -n family get svc courseware -o jsonpath='{.spec.clusterIP}')"
APISERVER_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
DNS_IP="$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')"
if kubectl -n "${NS}" get svc courseware-gast >/dev/null 2>&1; then
  ORIGIN_EXPECT=ok
else
  ORIGIN_EXPECT=skip   # courseware-gast still suspended: no Service yet
fi
ORIGIN=courseware-gast.cursus-gast.svc.cluster.local

log "chg-2026-10-28-002 T4 probe ${TS}"
log "image ${IMAGE}"
log "origin service present: $([ "${ORIGIN_EXPECT}" = ok ] && echo yes || echo no)"

# kind|name|host|port|expect   (kind: tcp, dns-a, dns-srv)
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

FAILS=0

run_phase() {
  local phase="$1" labels="$2" targets="$3"
  local pod="t4-probe-${phase}-${SUFFIX}"
  log "--- phase ${phase}: pod ${pod}"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NS}
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
  if ! kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" --timeout=280s >/dev/null; then
    log "phase ${phase}: pod did not reach Succeeded"
    FAILS=$((FAILS + 1))
  fi
  local out
  out="$(kubectl -n "${NS}" logs "${pod}" 2>&1 || true)"
  echo "${out}" | grep -q '^R-DONE' || { log "phase ${phase}: prober did not finish"; FAILS=$((FAILS + 1)); }
  while IFS='|' read -r tag name expect got; do
    [ "${tag}" = R ] || continue
    if [ "${expect}" = "${got}" ]; then
      log "${name} expect=${expect} got=${got} PASS"
    else
      log "${name} expect=${expect} got=${got} FAIL"
      FAILS=$((FAILS + 1))
    fi
  done <<< "${out}"
  kubectl -n "${NS}" delete pod "${pod}" --wait=false >/dev/null
}

run_phase a "    app.kubernetes.io/name: cloudflared
    app.kubernetes.io/controller: cloudflared" "${TARGETS_A}"
run_phase b "" "${TARGETS_B}"

if [ "${FAILS}" -eq 0 ]; then
  log "T4 RESULT PASS"
  echo "evidence: ${EV}"
  exit 0
fi
log "T4 RESULT FAIL (${FAILS} mismatches)"
echo "evidence: ${EV}"
exit 1
