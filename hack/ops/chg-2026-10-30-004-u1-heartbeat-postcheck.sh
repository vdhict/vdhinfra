#!/usr/bin/env bash
# chg-2026-10-30-004 item 2 (Snapmaker U1 heartbeat): post-check H1/H3 + automatic rollback H2 (Argus 2026-11-13T11:34Z).
#
# Usage: chg-2026-10-30-004-u1-heartbeat-postcheck.sh <heartbeat-commit> <evidence-file> <revert-worktree>
#   Started BEFORE the push (armed): waits until origin/main contains <heartbeat-commit>, Flux has applied it
#   (Kustomizations cilium-policies + blackbox-exporter), and the exporter serves the new modules. Then runs:
#     C1 ready probe success 1 (exporter /probe) and Prometheus probe_success{job="blackbox-printer-ready"} == 1
#     C2 /probe http_2xx .10:7125/printer/info -> probe_http_status_code 403 (L7 proxy)        [H2 trigger]
#     C3 POST .10:7125/server/info from the exporter pod -> 403                                  [H2 trigger]
#     C4 tcp .10:80, .10:7124, .10:7126, .11:7125 -> probe_success 0
#     C5 UDP .10:53 from the exporter pod -> hubble denylist drop
#     C6 hubble: denylist drops for C4/C5 and L7 drops/403 for C2/C3
#     C7 test pods (observability other label, default) -> .10:7125 timeout + hubble denylist drop; pods deleted
#     C8 (H3) ready probe status code is not 403
#   Any failure: git revert <heartbeat-commit> in <revert-worktree>, push to main, reconcile Flux, print INCIDENT.
# Nothing secret is read or printed. The evidence file is write-once.
set -uo pipefail
SHA=${1:?commit}; EV=${2:?evidence file}; WT=${3:?revert worktree}
[ ! -e "$EV" ] || { echo "evidence $EV exists; write-once, refusing" >&2; exit 64; }
K=/Users/sheijden/.local/share/mise/installs/aqua-kubernetes-kubernetes-kubectl/1.36.2/kubectl
FLUX=/Users/sheijden/.local/share/mise/installs/aqua-fluxcd-flux2/2.8.8/flux
exec > >(tee "$EV") 2>&1
ts() { date -u +%H:%M:%SZ; }
FAIL=0; SECFAIL=0
fail() { echo "FAIL $*"; FAIL=1; }
echo "# post-check chg-2026-10-30-004 item 2, heartbeat commit $SHA, armed $(date -u +%Y%m%dT%H%M%SZ)"

# 0. wait for main, Flux and the exporter (max 30 min for the push, 20 min for Flux)
for i in $(seq 1 180); do
  git -C "$WT" fetch -q origin main 2>/dev/null
  git -C "$WT" merge-base --is-ancestor "$SHA" origin/main 2>/dev/null && break; sleep 10
done
git -C "$WT" merge-base --is-ancestor "$SHA" origin/main || { echo "$(ts) commit never reached origin/main: nothing deployed, disarmed"; exit 3; }
MAIN=$(git -C "$WT" rev-parse origin/main); echo "$(ts) origin/main $MAIN contains $SHA"
"$FLUX" -n flux-system reconcile source git flux-system >/dev/null 2>&1
for ks in cilium-policies blackbox-exporter; do
  ok=0
  for i in $(seq 1 120); do
    R=$("$K" -n flux-system get ks "$ks" -o jsonpath='{.status.lastAppliedRevision} {.status.conditions[?(@.type=="Ready")].status}')
    case "$R" in *"${MAIN}"" True") ok=1; break;; esac
    [ "$i" = 3 ] && "$FLUX" -n flux-system reconcile ks "$ks" >/dev/null 2>&1 &
    sleep 10
  done
  echo "$(ts) ks $ks: $R"; [ $ok = 1 ] || fail "ks $ks not Ready at $MAIN"
done
"$K" get ccnp printer-subnet-egress-deny -o jsonpath='{.metadata.generation} specs={.specs[*].description}{"\n"}' | cut -c1-200
"$K" -n observability get cnp blackbox-exporter-printer-l7 -o jsonpath='cnp {.metadata.name} valid={.status.conditions[?(@.type=="Valid")].status}{"\n"}'
probe() { "$K" -n observability exec deploy/blackbox-exporter -- wget -qO- -T 15 "http://127.0.0.1:9115/probe?module=$1&target=$2" 2>/dev/null; }
val() { awk -v m="$1" '$1==m{print $2}'; }
for i in $(seq 1 30); do
  "$K" -n observability rollout status deploy/blackbox-exporter --timeout=60s >/dev/null 2>&1
  O=$(probe http_moonraker_ready "http://172.16.7.10:7125/server/info"); [ -n "$O" ] && break; sleep 10
done
POD=$("$K" -n observability get pod -l app.kubernetes.io/name=blackbox-exporter -o jsonpath='{.items[0].metadata.name} {.items[0].spec.nodeName} {.items[0].status.podIP}')
set -- $POD; BPOD=$1; BNODE=$2; BIP=$3; echo "$(ts) exporter $BPOD on $BNODE ip $BIP"
CIL=$("$K" -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName="$BNODE" -o name | head -1)
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# C1
S1=$(echo "$O" | val probe_success); C1=$(echo "$O" | val probe_http_status_code)
echo "$(ts) C1 /probe http_moonraker_ready .10:7125/server/info: probe_success $S1 status $C1"
[ "$S1" = 1 ] || fail "C1 ready probe"
# C8 (H3)
[ "$C1" != 403 ] || { fail "C8 ready probe status 403 (proxy blocks the heartbeat)"; }
# C2 (H2 trigger)
O=$(probe http_2xx "http://172.16.7.10:7125/printer/info"); C2=$(echo "$O" | val probe_http_status_code)
echo "$(ts) C2 /probe http_2xx .10:7125/printer/info: status $C2 success $(echo "$O" | val probe_success) (want 403)"
[ "$C2" = 403 ] || { fail "C2 /printer/info not 403: 7125 reachable without the L7 proxy"; SECFAIL=1; }
# C3 (H2 trigger): busybox wget POST from the exporter pod
C3=$("$K" -n observability exec "$BPOD" -- wget -qO- -T 10 --post-data='{}' --header='Content-Type: application/json' "http://172.16.7.10:7125/server/info" 2>&1 | grep -o 'HTTP/1.1 [0-9]*' | head -1)
echo "$(ts) C3 POST .10:7125/server/info from exporter: '$C3' (want HTTP/1.1 403)"
[ "$C3" = "HTTP/1.1 403" ] || { fail "C3 POST not 403"; SECFAIL=1; }
# C4
for t in 172.16.7.10:80 172.16.7.10:7124 172.16.7.10:7126 172.16.7.11:7125; do
  S=$(probe tcp_lan_5s "$t" | val probe_success); echo "$(ts) C4 tcp $t: probe_success $S (want 0)"
  [ "$S" = 0 ] || { fail "C4 $t reachable"; SECFAIL=1; }
done
# C5 UDP
"$K" -n observability exec "$BPOD" -- sh -c 'echo x | nc -u -w 2 172.16.7.10 53' >/dev/null 2>&1
echo "$(ts) C5 UDP .10:53 sent from exporter"
sleep 5
# C6 hubble
H=$("$K" -n kube-system exec "$CIL" -c cilium-agent -- hubble observe --since "$T0" --from-ip "$BIP" -o compact 2>/dev/null | grep -E '172\.16\.7\.')
for pat in '172.16.7.10:80 ' '172.16.7.10:7124 ' '172.16.7.10:7126 ' '172.16.7.11:7125 ' '172.16.7.10:53 '; do
  n=$(echo "$H" | grep -F "$pat" | grep -c 'denylist DROPPED'); echo "$(ts) C6 hubble denylist drops to ${pat% }: $n"
  [ "$n" -ge 1 ] || fail "C6 no denylist drop for ${pat% }"
done
L7=$("$K" -n kube-system exec "$CIL" -c cilium-agent -- hubble observe --since "$T0" --from-ip "$BIP" --type l7 -o compact 2>/dev/null | grep -F '172.16.7.10:7125')
echo "$L7" | grep -E 'printer/info|POST' | head -4 | sed 's/^/    /'
nl7=$(echo "$L7" | grep -E 'printer/info|POST' | grep -c -E 'DROPPED|403')
echo "$(ts) C6 hubble L7 denied (/printer/info + POST): $nl7"
[ "$nl7" -ge 2 ] || fail "C6 L7 denies not seen in hubble"
# C7 test pods
for ns in observability default; do
  N=p3d-h1-$ns-$(date -u +%H%M%S)
  "$K" -n "$ns" run "$N" --image=docker.io/curlimages/curl:8.17.0 --restart=Never --labels=app.kubernetes.io/name=p3d-h1-probe \
    --overrides='{"spec":{"activeDeadlineSeconds":90,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"docker.io/curlimages/curl:8.17.0","command":["sh","-c","curl -s -o /dev/null -m 8 -w \"%{http_code}\" http://172.16.7.10:7125/server/info"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  "$K" -n "$ns" wait --for=jsonpath='{.status.phase}'=Failed pod/"$N" --timeout=60s >/dev/null 2>&1 || "$K" -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$N" --timeout=30s >/dev/null 2>&1
  R=$("$K" -n "$ns" logs "$N" 2>/dev/null | tail -c 3); PIP=$("$K" -n "$ns" get pod "$N" -o jsonpath='{.status.podIP} {.spec.nodeName}')
  set -- $PIP; TC=$("$K" -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName="$2" -o name | head -1)
  d=$("$K" -n kube-system exec "$TC" -c cilium-agent -- hubble observe --since 3m --from-ip "$1" -o compact 2>/dev/null | grep -F '172.16.7.10:7125' | grep -c 'denylist DROPPED')
  "$K" -n "$ns" delete pod "$N" --wait=true >/dev/null 2>&1; G=$("$K" -n "$ns" get pod "$N" 2>&1 | grep -c NotFound)
  echo "$(ts) C7 test pod $ns/$N -> .10:7125 http '$R' (want 000), hubble denylist drops $d, deleted $G"
  [ "$R" = 000 ] && [ "$d" -ge 1 ] || { fail "C7 $ns test pod not dropped"; SECFAIL=1; }
done
# C1 Prometheus (scrape every 60s)
for i in $(seq 1 18); do
  P=$("$K" -n observability exec prometheus-kube-prometheus-stack-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success%7Bjob%3D%22blackbox-printer-ready%22%7D' 2>/dev/null | grep -o '"value":\[[^]]*\]' | head -1)
  case "$P" in *'"1"]') break;; esac; sleep 10
done
echo "$(ts) C1 prometheus probe_success{job=blackbox-printer-ready}: $P"
case "$P" in *'"1"]') ;; *) fail "C1 prometheus ready series not 1";; esac
A=$("$K" -n observability exec prometheus-kube-prometheus-stack-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' 2>/dev/null | grep -o '"name":"PrinterU1[A-Za-z]*"' | sort -u | tr '\n' ' ')
echo "$(ts) loaded alert rules: $A"
echo "$A" | grep -q PrinterU1ProbeBlocked || fail "H3 alert PrinterU1ProbeBlocked not loaded"

if [ "$FAIL" = 0 ]; then echo "RESULT PASS (H1 + H3), no rollback"; exit 0; fi
echo "RESULT FAIL (security-relevant: $SECFAIL): automatic rollback (H2)"
git -C "$WT" checkout -q --detach origin/main && git -C "$WT" revert --no-edit "$SHA" && \
  git -C "$WT" commit -q --amend -m "revert: U1 heartbeat $SHA, post-check failed (chg-2026-10-30-004, Argus H2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && \
  git -C "$WT" push origin HEAD:refs/heads/main && echo "$(ts) revert pushed $(git -C "$WT" rev-parse --short HEAD)"
"$FLUX" -n flux-system reconcile source git flux-system >/dev/null 2>&1
"$FLUX" -n flux-system reconcile ks cilium-policies >/dev/null 2>&1; "$FLUX" -n flux-system reconcile ks blackbox-exporter >/dev/null 2>&1
"$K" -n observability get cnp blackbox-exporter-printer-l7 2>&1 | tail -1
echo "INCIDENT NEEDED: open one for chg-2026-10-30-004 item 2 (Argus H2)"
exit 1
