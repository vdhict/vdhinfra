#!/usr/bin/env bash
# chg-2026-10-30-004 item 2, v2 (dedicated exporter blackbox-printer, after inc-2026-11-13-003): post-check H1/H3,
# node check, and automatic rollback H2. Same contract as chg-2026-10-30-004-u1-heartbeat-postcheck.sh (v1).
#
# Usage: chg-2026-10-30-004-u1-heartbeat-postcheck-v2.sh <heartbeat-commit> <evidence-file> <revert-worktree>
#   Started BEFORE the push (armed). Waits until origin/main contains the commit, Flux applied it (cilium-policies,
#   blackbox-exporter incl. HelmRelease blackbox-printer) and the printer exporter answers. Then:
#     N  printer exporter pod runs on vdhclu01node01-03 (UDM allows only .81-.83)
#     C1 /probe http_moonraker_ready .10:7125/server/info -> success 1; Prometheus job blackbox-printer-ready == 1
#     C2 /probe http_moonraker_ready with target .10:7125/printer/info -> status 403 (L7)          [H2 trigger]
#        and busybox wget GET /printer/info from the printer exporter pod -> 403                     [H2 trigger]
#     C3 POST .10:7125/server/info from the printer exporter pod -> 403                              [H2 trigger]
#     C4 printer exporter -> .10:80, .10:7124, .10:7126, .11:7125 (nc) fail;
#        shared exporter /probe tcp .10:7125 -> 0 (fully denied); shared exporter tcp NAS 5001 -> 1 (control)
#     C5 printer exporter UDP .10:53 -> dropped
#     C6 hubble: drops for C4/C5 (printer + shared) and "http-request DROPPED" for C2/C3 (>= 3)
#     C7 test pods (observability other label, default) -> .10:7125 000 + denylist drop; deleted
#     C8 (H3) ready probe status != 403; alert PrinterU1ProbeBlocked loaded
#     C9 (Argus V1) a pod in default -> blackbox-printer:9115/probe times out + Hubble drop at the exporter
#   Any failure: git revert <commit> in <revert-worktree>, push main, reconcile Flux, print INCIDENT.
# Nothing secret is read or printed. Evidence file write-once.
set -uo pipefail
SHA=${1:?commit}; EV=${2:?evidence file}; WT=${3:?revert worktree}
[ ! -e "$EV" ] || { echo "evidence $EV exists; write-once, refusing" >&2; exit 64; }
K=/Users/sheijden/.local/share/mise/installs/aqua-kubernetes-kubernetes-kubectl/1.36.2/kubectl
FLUX=/Users/sheijden/.local/share/mise/installs/aqua-fluxcd-flux2/2.8.8/flux
exec > >(tee "$EV") 2>&1
ts() { date -u +%H:%M:%SZ; }
FAIL=0; SECFAIL=0
fail() { echo "FAIL $*"; FAIL=1; }
sec() { fail "$*"; SECFAIL=1; }
echo "# post-check v2 chg-2026-10-30-004 item 2, heartbeat commit $SHA, armed $(date -u +%Y%m%dT%H%M%SZ)"

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
echo "$(ts) hr blackbox-printer: $("$K" -n observability get hr blackbox-printer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].message}' 2>&1 | cut -c1-120)"
"$K" -n observability get cnp blackbox-printer -o jsonpath='{.metadata.name} valid={.status.conditions[?(@.type=="Valid")].status}{"\n"}'
echo "$(ts) ccnp specs: $("$K" get ccnp printer-subnet-egress-deny -o jsonpath='{.specs[*].description}' | grep -o 'chg-2026-10-30-004' | wc -l | tr -d ' ')"
"$K" -n observability rollout status deploy/blackbox-printer --timeout=180s >/dev/null 2>&1
"$K" -n observability rollout status deploy/blackbox-exporter --timeout=180s >/dev/null 2>&1
pp() { "$K" -n observability exec deploy/blackbox-printer -- wget -qO- -T 15 "http://127.0.0.1:9115/probe?module=$1&target=$2" 2>/dev/null; }
sp() { "$K" -n observability exec deploy/blackbox-exporter -- wget -qO- -T 15 "http://127.0.0.1:9115/probe?module=$1&target=$2" 2>/dev/null; }
val() { awk -v m="$1" '$1==m{print $2}'; }
for i in $(seq 1 30); do O=$(pp http_moonraker_ready "http://172.16.7.10:7125/server/info"); [ -n "$O" ] && break; sleep 10; done
info() { "$K" -n observability get pod -l "app.kubernetes.io/name=$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name} {.items[0].spec.nodeName} {.items[0].status.podIP}'; }
set -- $(info blackbox-printer); PPOD=$1; PNODE=$2; PIP=$3
set -- $(info blackbox-exporter); SPOD=$1; SNODE=$2; SIP=$3
echo "$(ts) printer exporter $PPOD on $PNODE ip $PIP; shared exporter $SPOD on $SNODE ip $SIP"
# N
case "$PNODE" in vdhclu01node01|vdhclu01node02|vdhclu01node03) echo "$(ts) N node $PNODE is a worker (UDM allow .81-.83): OK";; *) fail "N printer exporter on $PNODE, not a worker";; esac
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# C1 + C8
S1=$(echo "$O" | val probe_success); C1=$(echo "$O" | val probe_http_status_code)
echo "$(ts) C1 /probe http_moonraker_ready .10:7125/server/info: probe_success $S1 status $C1"
[ "$S1" = 1 ] || fail "C1 ready probe"
[ "$C1" != 403 ] || fail "C8 ready probe status 403 (proxy blocks the heartbeat)"
# C2
C2=$(pp http_moonraker_ready "http://172.16.7.10:7125/printer/info" | val probe_http_status_code)
echo "$(ts) C2 /probe (GET) .10:7125/printer/info: status $C2 (want 403)"
[ "$C2" = 403 ] || sec "C2 /probe /printer/info not 403"
W=$("$K" -n observability exec "$PPOD" -- wget -qO- -T 10 "http://172.16.7.10:7125/printer/info" 2>&1 | grep -o 'HTTP/1.1 [0-9]*' | head -1)
echo "$(ts) C2 wget GET /printer/info from printer exporter: '$W' (want HTTP/1.1 403)"
[ "$W" = "HTTP/1.1 403" ] || sec "C2 wget /printer/info not 403"
# C3
C3=$("$K" -n observability exec "$PPOD" -- wget -qO- -T 10 --post-data='{}' --header='Content-Type: application/json' "http://172.16.7.10:7125/server/info" 2>&1 | grep -o 'HTTP/1.1 [0-9]*' | head -1)
echo "$(ts) C3 POST /server/info from printer exporter: '$C3' (want HTTP/1.1 403)"
[ "$C3" = "HTTP/1.1 403" ] || sec "C3 POST not 403"
# C4
for t in "172.16.7.10 80" "172.16.7.10 7124" "172.16.7.10 7126" "172.16.7.11 7125"; do
  R=$("$K" -n observability exec "$PPOD" -- sh -c "nc -w 4 $t </dev/null >/dev/null 2>&1 && echo OPEN || echo closed" 2>/dev/null)
  echo "$(ts) C4 printer exporter tcp ${t/ /:}: $R (want closed)"; [ "$R" = closed ] || sec "C4 printer exporter reaches ${t/ /:}"
done
S=$(sp tcp_lan_5s 172.16.7.10:7125 | val probe_success); echo "$(ts) C4 shared exporter /probe tcp .10:7125: $S (want 0)"
[ "$S" = 0 ] || sec "C4 shared exporter reaches the printer"
S=$(sp tcp_lan_5s 172.16.2.246:5001 | val probe_success); echo "$(ts) C4 control shared exporter tcp NAS 5001: $S (want 1)"
[ "$S" = 1 ] || fail "C4 control: shared exporter lost LAN reach"
# C5
"$K" -n observability exec "$PPOD" -- sh -c 'echo x | nc -u -w 2 172.16.7.10 53' >/dev/null 2>&1
echo "$(ts) C5 UDP .10:53 sent from printer exporter"; sleep 5
# C6
hub() { local node=$1 ip=$2; local cp; cp=$("$K" -n kube-system get pod -l k8s-app=cilium -o wide --no-headers | awk -v n="$node" '$7==n{print $1}');
  "$K" -n kube-system exec "$cp" -c cilium-agent -- hubble observe --since "$T0" --from-ip "$ip" $3 -o compact 2>/dev/null; }
HP=$(hub "$PNODE" "$PIP" "" | grep -F '172.16.7.')
for pat in '172.16.7.10:80 ' '172.16.7.10:7124 ' '172.16.7.10:7126 ' '172.16.7.11:7125 ' '172.16.7.10:53 '; do
  n=$(echo "$HP" | grep -F "$pat" | grep -c -E 'denylist DROPPED|Policy denied DROPPED'); echo "$(ts) C6 hubble printer exporter drops to ${pat% }: $n"
  [ "$n" -ge 1 ] || fail "C6 no drop for ${pat% }"
done
n=$(hub "$SNODE" "$SIP" "" | grep -F '172.16.7.10:7125' | grep -c 'denylist DROPPED'); echo "$(ts) C6 hubble shared exporter denylist drops to .10:7125: $n"
[ "$n" -ge 1 ] || fail "C6 no denylist drop for the shared exporter"
L7=$(hub "$PNODE" "$PIP" "--type l7" | grep -F '172.16.7.10:7125')
echo "$L7" | grep -E 'http-request' | head -6 | sed 's/^/    /'
n=$(echo "$L7" | grep -E 'printer/info|POST' | grep -c 'http-request DROPPED'); echo "$(ts) C6 hubble L7 http-request DROPPED (/printer/info x2, POST): $n (want >= 3)"
[ "$n" -ge 3 ] || fail "C6 L7 drops not seen in hubble"
n=$(echo "$L7" | grep -F '/server/info' | grep -c 'GET.*FORWARDED\|FORWARDED.*GET'); echo "$(ts) C6 hubble L7 GET /server/info forwarded: $n"
# C7
for ns in observability default; do
  N=p3d-h1-$ns-$(date -u +%H%M%S)
  "$K" -n "$ns" run "$N" --image=docker.io/curlimages/curl:8.17.0 --restart=Never --labels=app.kubernetes.io/name=p3d-h1-probe \
    --overrides='{"spec":{"activeDeadlineSeconds":90,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"docker.io/curlimages/curl:8.17.0","command":["sh","-c","curl -s -o /dev/null -m 8 -w \"%{http_code}\" http://172.16.7.10:7125/server/info"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  "$K" -n "$ns" wait --for=jsonpath='{.status.phase}'=Failed pod/"$N" --timeout=60s >/dev/null 2>&1 || "$K" -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$N" --timeout=30s >/dev/null 2>&1
  R=$("$K" -n "$ns" logs "$N" 2>/dev/null | tail -c 3)
  TN=$("$K" -n "$ns" get pod "$N" -o jsonpath='{.spec.nodeName}'); TI=$("$K" -n "$ns" get pod "$N" -o jsonpath='{.status.podIP}')
  d=$(T0=$(date -u -v-3M +%Y-%m-%dT%H:%M:%SZ) hub "$TN" "$TI" "" | grep -F '172.16.7.10:7125' | grep -c 'denylist DROPPED')
  "$K" -n "$ns" delete pod "$N" --wait=true >/dev/null 2>&1; G=$("$K" -n "$ns" get pod "$N" 2>&1 | grep -c NotFound)
  echo "$(ts) C7 test pod $ns/$N -> .10:7125 http '$R' (want 000), hubble denylist drops $d, deleted $G"
  [ "$R" = 000 ] && [ "$d" -ge 1 ] || sec "C7 $ns test pod not dropped"
done
# C9 (Argus V1): ingress default-deny on the printer exporter; a pod in default must not reach /probe on 9115
N=p3d-v1-default-$(date -u +%H%M%S)
"$K" -n default run "$N" --image=docker.io/curlimages/curl:8.17.0 --restart=Never --labels=app.kubernetes.io/name=p3d-v1-probe \
  --overrides='{"spec":{"activeDeadlineSeconds":90,"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"docker.io/curlimages/curl:8.17.0","command":["sh","-c","curl -s -o /dev/null -m 8 -w \"%{http_code}\" \"http://blackbox-printer.observability.svc.cluster.local:9115/probe?module=http_moonraker_ready&target=http://172.16.7.10:7125/server/info\""],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
"$K" -n default wait --for=jsonpath='{.status.phase}'=Failed pod/"$N" --timeout=60s >/dev/null 2>&1 || "$K" -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$N" --timeout=30s >/dev/null 2>&1
R=$("$K" -n default logs "$N" 2>/dev/null | tail -c 3); TI=$("$K" -n default get pod "$N" -o jsonpath='{.status.podIP}')
d=$(T0=$(date -u -v-3M +%Y-%m-%dT%H:%M:%SZ) hub "$PNODE" "$TI" "" | grep -F "$PIP:9115" | grep -c 'DROPPED')
"$K" -n default delete pod "$N" --wait=true >/dev/null 2>&1; G=$("$K" -n default get pod "$N" 2>&1 | grep -c NotFound)
echo "$(ts) C9 default/$N -> blackbox-printer:9115/probe http '$R' (want 000), hubble drops at the exporter $d, deleted $G"
[ "$R" = 000 ] && [ "$d" -ge 1 ] || sec "C9 default pod reaches blackbox-printer /probe"
# C1 Prometheus (also proves the Prometheus -> exporter ingress allow)
for i in $(seq 1 24); do
  P=$("$K" -n observability exec prometheus-kube-prometheus-stack-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success%7Bjob%3D%22blackbox-printer-ready%22%7D' 2>/dev/null | grep -o '"value":\[[^]]*\]' | head -1)
  case "$P" in *'"1"]') break;; esac; sleep 10
done
echo "$(ts) C1 prometheus probe_success{job=blackbox-printer-ready}: $P"
case "$P" in *'"1"]') ;; *) fail "C1 prometheus ready series not 1";; esac
A=$("$K" -n observability exec prometheus-kube-prometheus-stack-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' 2>/dev/null | grep -o '"name":"PrinterU1[A-Za-z]*"' | sort -u | tr '\n' ' ')
echo "$(ts) loaded alert rules: $A"
echo "$A" | grep -q PrinterU1ProbeBlocked || fail "H3 alert PrinterU1ProbeBlocked not loaded"

if [ "$FAIL" = 0 ]; then echo "RESULT PASS (H1 + H3 + node), no rollback"; exit 0; fi
echo "RESULT FAIL (security-relevant: $SECFAIL): automatic rollback (H2)"
git -C "$WT" fetch -q origin main && git -C "$WT" checkout -q --detach origin/main && git -C "$WT" revert --no-edit "$SHA" && \
  git -C "$WT" commit -q --amend -m "revert: U1 heartbeat v2 $SHA, post-check failed (chg-2026-10-30-004, Argus H2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && \
  git -C "$WT" push origin HEAD:refs/heads/main && echo "$(ts) revert pushed $(git -C "$WT" rev-parse --short HEAD)"
"$FLUX" -n flux-system reconcile source git flux-system >/dev/null 2>&1
"$FLUX" -n flux-system reconcile ks cilium-policies >/dev/null 2>&1; "$FLUX" -n flux-system reconcile ks blackbox-exporter >/dev/null 2>&1
"$K" -n observability get cnp blackbox-printer 2>&1 | tail -1
echo "INCIDENT NEEDED: open one for chg-2026-10-30-004 item 2 v2 (Argus H2)"
exit 1
