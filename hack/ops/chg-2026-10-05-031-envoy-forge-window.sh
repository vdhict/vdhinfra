#!/usr/bin/env bash
# chg-2026-10-05-031 envoy-forge window runner (Argus C7/R9; same pattern as
# hack/ops/inc-2026-10-12-013-window.sh).
#
# Lands FIX_SHA (new Gateway network/envoy-forge on 172.16.2.251 + second
# parentRef on devtools/forgejo) on main, proves it serves ONLY the forge and
# leaves the household gateways alone, and reverts automatically otherwise.
#
#   hack/ops/chg-2026-10-05-031-envoy-forge-window.sh dry-run   # no writes; any time
#   hack/ops/chg-2026-10-05-031-envoy-forge-window.sh execute   # gated, 01:00-05:30
#
# execute first WAITS for the 01:05 gateway runner (chg-2026-10-13-002) to
# reach a terminal state (DONE marker / its execute log + launchd idle), max
# until 03:30. It aborts if that run ended with "ROLLBACK checks STILL RED".
# Then it refuses (exit 3, nothing changed) unless ALL of:
#   - local time 01:00-05:30 Europe/Amsterdam (AGR-082)
#   - chg has no 'rejected' event (AGR-109: tests are the gate)
#   - ops freeze status does not block 'high'
#   - lock k8s.gateway.envoy-forge names the chg
#   - owner lookup unique for envoy-internal/-external (inc-2026-10-12-013 guard)
#   - 172.16.2.251 unused (no LB Service holds it, no ARP answer)
#   - self-test + 3 consecutive green checks
#
# A household check = nc .241:443 + nc .243:443 + both l2announce leases +
#   dig @172.16.2.1 grafana == .241 + dig forge == .241 only + forge 200 via .241
# A forge check = forge /api/healthz 200 via .251; grafana via .251 NOT
#   served (no 2xx/3xx); .251:80 closed; envoy-forge owner lookup == 1 Service.
#
# Shell rules (AGR-079): deletes nothing on disk; evidence is write-once.
# The in-cluster fallback (only if the git revert cannot be pushed) suspends
# the Kustomization and deletes the Gateway object it created.

set -uo pipefail

MODE="${1:-dry-run}"
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
CHG=chg-2026-10-05-031
FIX_SHA=200f3e1b1a505fec24297297a339f78db26da0d3
FIX_BRANCH=feat/envoy-forge-chg-2026-10-05-031-v2
GW_FILE=kubernetes/main/apps/network/envoy-gateway/gateway/envoy-forge.yaml
FORGE_IP=172.16.2.251
INT_IP=172.16.2.241
EXT_IP=172.16.2.243
INT_SVC=envoy-network-envoy-internal-1102ed95
EXT_SVC=envoy-network-envoy-external-27f017ad
DNS_SERVER=172.16.2.1
DOMAIN=bluejungle.net
FORGE_HOST="forge.${DOMAIN}"
DNS_NAME="grafana.${DOMAIN}"
CONTROL_HOST=172.16.2.84
CONTROL_PORT=50000
SOAK_SECONDS=600
PREV_EV="${REPO}/ops/evidence/chg-2026-10-13-002-drop-gw-addresses"
PREV_LABEL=net.vdhict.inc-2026-10-12-013-execute
RUN="$(date -u +%Y%m%dT%H%M%SZ)-${MODE}"
EV="${REPO}/ops/evidence/${CHG}-envoy-forge"
LOG="${EV}/${RUN}-run.log"
DONE_MARKER="${EV}/DONE-executed-ok"
WT_BASE="${HOME}/.cache/${CHG}-envoy-forge"
HANDOFF_DIR="${HOME}/mypka-handoff/2026-10-14"
HANDOFF="${HANDOFF_DIR}/2026-10-14-atlas-to-larry-runner.md"
STATE=init
APPLIED_SHA=""

mkdir -p "${EV}" "${WT_BASE}"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
cd "${REPO}" || exit 2
eval "$(mise env -s bash -C "${REPO}" 2>/dev/null)"

log() { echo "$(date -u +%FT%TZ) $*" | tee -a "${LOG}"; }
ops() { "${REPO}/ops/ops" "$@"; }
ev()  { ops change event "${CHG}" "$1" --actor k8s-engineer --payload-json "$2" >>"${LOG}" 2>&1; }
milestone() { # one line to Larry (execute only)
  [ "${MODE}" = execute ] || return 0
  mkdir -p "${HANDOFF_DIR}"
  echo "- $(TZ=Europe/Amsterdam date +%H:%M) $*" >>"${HANDOFF}"
}

# ---------- probes ----------------------------------------------------------
lease_holder() { kubectl -n kube-system get lease "cilium-l2announce-network-$1" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
gw_status()    { kubectl -n network get gateway "$1" -o jsonpath='{.status.addresses[*].value}' 2>/dev/null; }
owner_svcs()   { kubectl -n network get svc -l "gateway.envoyproxy.io/owning-gateway-name=$1,gateway.envoyproxy.io/owning-gateway-namespace=network" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; }
http_code()    { curl -sk -o /dev/null -w '%{http_code}' -m 6 --resolve "$1:443:$2" "https://$1$3" 2>/dev/null; }

check() {
  local rc=0 line="" h dns fdns code
  for ip in "${INT_IP}" "${EXT_IP}"; do
    if nc -z -G 3 "${ip}" 443 >/dev/null 2>&1; then line+="${ip}:443=open "; else line+="${ip}:443=CLOSED "; rc=1; fi
  done
  for s in "${INT_SVC}" "${EXT_SVC}"; do
    h="$(lease_holder "${s}")"
    if [ -n "${h}" ]; then line+="lease(${s##*-envoy-})=${h} "; else line+="lease(${s##*-envoy-})=MISSING "; rc=1; fi
  done
  dns="$(dig @"${DNS_SERVER}" "${DNS_NAME}" A +short +time=2 +tries=2 2>/dev/null | tail -1)"
  [ "${dns}" = "${INT_IP}" ] && line+="dns(grafana)=${dns} " || { line+="dns(grafana)=BAD(${dns:-none}) "; rc=1; }
  fdns="$(dig @"${DNS_SERVER}" "${FORGE_HOST}" A +short +time=2 +tries=2 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ "${fdns}" = "${INT_IP}" ] && line+="dns(forge)=${fdns} " || { line+="dns(forge)=BAD(${fdns:-none}) "; rc=1; }
  code="$(http_code "${FORGE_HOST}" "${INT_IP}" /api/healthz)"
  [ "${code}" = 200 ] && line+="forge@241=200 " || { line+="forge@241=${code} "; rc=1; }
  log "CHECK rc=${rc} ${line}"
  return "${rc}"
}

forge_check() {
  local rc=0 line="" code gcode n
  code="$(http_code "${FORGE_HOST}" "${FORGE_IP}" /api/healthz)"
  [ "${code}" = 200 ] && line+="forge@251=200 " || { line+="forge@251=${code} "; rc=1; }
  gcode="$(http_code "${DNS_NAME}" "${FORGE_IP}" /)"
  case "${gcode}" in 2*|3*) line+="grafana@251=SERVED(${gcode}) "; rc=1 ;; *) line+="grafana@251=not-served(${gcode:-tls-refused}) " ;; esac
  if nc -z -G 3 "${FORGE_IP}" 80 >/dev/null 2>&1; then line+="251:80=OPEN "; rc=1; else line+="251:80=closed "; fi
  n="$(owner_svcs envoy-forge | grep -c .)"
  [ "${n}" = 1 ] && line+="owner(envoy-forge)=1 " || { line+="owner(envoy-forge)=${n} "; rc=1; }
  for g in envoy-internal envoy-external; do
    n="$(owner_svcs "${g}" | grep -c .)"; [ "${n}" = 1 ] || { line+="owner(${g})=${n} "; rc=1; }
  done
  [ "$(gw_status envoy-internal)" = "${INT_IP}" ] && [ "$(gw_status envoy-external)" = "${EXT_IP}" ] \
    || { line+="status(int/ext)='$(gw_status envoy-internal)/$(gw_status envoy-external)' "; rc=1; }
  log "FORGE rc=${rc} ${line}"
  return "${rc}"
}

green_streak() { # $1 needed consecutive greens, $2 max attempts, 10s apart, $3 = also forge_check?
  local need="$1" max="$2" withforge="${3:-no}" streak=0 ok
  for _ in $(seq 1 "${max}"); do
    ok=0; check || ok=1
    if [ "${withforge}" = yes ]; then forge_check || ok=1; fi
    if [ "${ok}" = 0 ]; then streak=$((streak + 1)); else streak=0; fi
    [ "${streak}" -ge "${need}" ] && return 0
    sleep 10
  done
  return 1
}

capture() {
  local p="${EV}/${RUN}-$1"
  kubectl -n network get gateway -o yaml >"${p}-gateways.yaml" 2>&1
  kubectl -n network get svc -l gateway.envoyproxy.io/owning-gateway-namespace=network -o wide >"${p}-services.txt" 2>&1
  kubectl -n devtools get httproute forgejo -o yaml >"${p}-httproute.yaml" 2>&1
  kubectl -n kube-system get lease 2>&1 | grep -E 'NAME|l2announce' >"${p}-leases.txt"
  flux get ks -n flux-system envoy-gateway-gateways forgejo >"${p}-flux.txt" 2>&1
}

# ---------- wait for the 01:05 runner ----------------------------------------
wait_previous() {
  local deadline_hm=0330 hm prevlog running
  while :; do
    prevlog="$(find "${PREV_EV}" -name '*-execute-run.log' -mmin -180 2>/dev/null | sort | tail -1)"
    running="$(launchctl list 2>/dev/null | awk -v l="${PREV_LABEL}" '$3==l{print $1}')"
    if [ -e "${PREV_EV}/DONE-executed-ok" ] && [ -n "$(find "${PREV_EV}/DONE-executed-ok" -mmin -180 2>/dev/null)" ]; then
      log "PREV chg-2026-10-13-002 DONE ($(cat "${PREV_EV}/DONE-executed-ok"))"; PREV_RESULT="done"; return 0
    fi
    if [ -n "${prevlog}" ] && [ "${running}" = "-" ]; then
      if grep -q 'ROLLBACK checks STILL RED' "${prevlog}"; then PREV_RESULT=rollback-red; log "PREV chg-2026-10-13-002 rolled back and is STILL RED (${prevlog##*/})"; return 1; fi
      if grep -q 'ROLLBACK' "${prevlog}"; then PREV_RESULT=rolled-back-green; else PREV_RESULT="$(tail -1 "${prevlog}" | cut -c22-80)"; fi
      log "PREV chg-2026-10-13-002 finished: ${PREV_RESULT} (${prevlog##*/})"; return 0
    fi
    hm="$(TZ=Europe/Amsterdam date +%H%M)"
    if [ "${MODE}" != execute ]; then log "DRY-RUN: previous runner not finished (log='${prevlog##*/}' launchd pid='${running}'); not waiting"; PREV_RESULT=dry-run; return 0; fi
    if [ "${hm}" -ge "${deadline_hm}" ]; then
      if [ -z "${prevlog}" ] && [ "${running}" = "-" ]; then log "PREV no 01:05 run log by 03:30 and launchd idle; proceeding on own checks"; PREV_RESULT=none; return 0; fi
      log "PREV still not finished at 03:30; aborting"; PREV_RESULT=timeout; return 1
    fi
    sleep 30
  done
}

# ---------- gates -----------------------------------------------------------
env_selftest() {
  nc -z -G 3 "${CONTROL_HOST}" "${CONTROL_PORT}" >/dev/null 2>&1 || { log "SELFTEST FAIL: control port ${CONTROL_HOST}:${CONTROL_PORT} unreachable (macOS local-network block?)"; return 1; }
  kubectl -n network get gateway envoy-internal -o name >/dev/null 2>&1 || { log "SELFTEST FAIL: kubectl"; return 1; }
  [ -n "$(dig @"${DNS_SERVER}" "${DNS_NAME}" A +short +time=2 +tries=2 2>/dev/null)" ] || { log "SELFTEST FAIL: dig"; return 1; }
  log "SELFTEST ok (nc control port, kubectl, dig)"
}

gate() {
  local fail=0 hm mins rej g n holder
  hm="$(TZ=Europe/Amsterdam date +%H%M)"; mins=$((10#${hm:0:2} * 60 + 10#${hm:2:2}))
  if [ "${mins}" -ge 60 ] && [ "${mins}" -le 330 ]; then log "GATE time ok (${hm})"; else log "GATE time FAIL (${hm}, need 01:00-05:30)"; fail=1; fi
  rej="$(jq -r --arg c "${CHG}" 'select(.chg==$c and .event=="rejected") | .ts' ops/changes.jsonl | tail -1)"
  if [ -z "${rej}" ]; then log "GATE not-rejected ok"; else log "GATE FAIL: rejected at ${rej}"; fail=1; fi
  if ops freeze status 2>&1 | grep -E "blocks=.*'high'" >/dev/null; then log "GATE freeze FAIL"; fail=1; else log "GATE freeze ok"; fi
  if grep -q "${CHG}" "${REPO}/ops/locks/k8s.gateway.envoy-forge" 2>/dev/null; then log "GATE lock k8s.gateway.envoy-forge ok"; else log "GATE lock k8s.gateway.envoy-forge FAIL"; fail=1; fi
  for g in envoy-internal envoy-external; do
    n="$(owner_svcs "${g}" | grep -c .)"
    if [ "${n}" = 1 ]; then log "GATE owner lookup ${g} unique ok"; else log "GATE owner lookup ${g} FAIL (${n})"; fail=1; fi
  done
  holder="$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.loadBalancer.ingress[*].ip}{"\n"}{end}' 2>/dev/null | awk -v ip="${FORGE_IP}" '$2==ip{print $1}')"
  if [ -n "$(kubectl -n network get gateway envoy-forge -o name 2>/dev/null)" ]; then
    log "GATE envoy-forge Gateway already exists (verify-only run)"
  elif [ -n "${holder}" ]; then log "GATE FAIL: ${FORGE_IP} already held by ${holder}"; fail=1
  elif ping -c1 -t1 "${FORGE_IP}" >/dev/null 2>&1; then log "GATE FAIL: ${FORGE_IP} answers ping (in use)"; fail=1
  else log "GATE ${FORGE_IP} free (no LB Service, no ping)"; fi
  return "${fail}"
}

# ---------- git -------------------------------------------------------------
new_worktree() {
  local wt="${WT_BASE}/wt-${RUN}-$1"
  git -C "${REPO}" fetch -q origin main "${FIX_BRANCH}" >>"${LOG}" 2>&1 || return 1
  git -C "${REPO}" worktree add -q --detach "${wt}" origin/main >>"${LOG}" 2>&1 || return 1
  echo "${wt}"
}
main_has_fix() { git -C "${REPO}" fetch -q origin main >>"${LOG}" 2>&1; git -C "${REPO}" cat-file -e "origin/main:${GW_FILE}" 2>/dev/null; }

push_fix() {
  local wt attempt
  wt="$(new_worktree apply)" || { log "APPLY worktree failed"; return 1; }
  for attempt in 1 2 3; do
    git -C "${wt}" fetch -q origin main >>"${LOG}" 2>&1
    git -C "${wt}" reset -q --hard origin/main >>"${LOG}" 2>&1
    if ! git -C "${wt}" cherry-pick "${FIX_SHA}" >>"${LOG}" 2>&1; then
      git -C "${wt}" cherry-pick --abort >>"${LOG}" 2>&1
      log "APPLY cherry-pick conflict on attempt ${attempt}; aborting without change"; return 1
    fi
    if [ "${MODE}" != "execute" ]; then
      log "DRY-RUN would push $(git -C "${wt}" rev-parse HEAD) on top of $(git -C "${wt}" rev-parse origin/main)"
      git -C "${wt}" show --stat HEAD >>"${LOG}" 2>&1
      if git -C "${wt}" push --dry-run origin HEAD:main >>"${LOG}" 2>&1; then log "DRY-RUN push auth ok"; else log "DRY-RUN push auth FAILED"; fi
      return 0
    fi
    if git -C "${wt}" push -q origin HEAD:main >>"${LOG}" 2>&1; then
      APPLIED_SHA="$(git -C "${wt}" rev-parse HEAD)"; log "APPLY pushed ${APPLIED_SHA} to main"; return 0
    fi
    log "APPLY push attempt ${attempt} rejected (main moved); retrying"
  done
  return 1
}

flux_sync() {
  flux reconcile source git flux-system -n flux-system >>"${LOG}" 2>&1
  flux reconcile ks envoy-gateway-gateways -n flux-system >>"${LOG}" 2>&1
  flux reconcile ks forgejo -n flux-system >>"${LOG}" 2>&1
}

# ---------- rollback --------------------------------------------------------
rollback() {
  local why="$1" wt attempt pushed=0
  STATE=rolling_back
  log "ROLLBACK start: ${why}"
  capture "rollback-before"
  if [ -n "${APPLIED_SHA}" ]; then
    wt="$(new_worktree rollback)"
    for attempt in 1 2 3; do
      [ -n "${wt}" ] || break
      git -C "${wt}" fetch -q origin main >>"${LOG}" 2>&1
      git -C "${wt}" reset -q --hard origin/main >>"${LOG}" 2>&1
      if git -C "${wt}" revert --no-edit "${APPLIED_SHA}" >>"${LOG}" 2>&1 && git -C "${wt}" push -q origin HEAD:main >>"${LOG}" 2>&1; then
        pushed=1; log "ROLLBACK pushed revert $(git -C "${wt}" rev-parse HEAD)"; break
      fi
      git -C "${wt}" revert --abort >>"${LOG}" 2>&1
      log "ROLLBACK revert/push attempt ${attempt} failed"
    done
  fi
  if [ "${pushed}" = 1 ]; then
    flux_sync
  else
    log "ROLLBACK fallback: suspend envoy-gateway-gateways + forgejo, remove envoy-forge Gateway and the second parentRef in-cluster"
    flux suspend ks envoy-gateway-gateways -n flux-system >>"${LOG}" 2>&1
    flux suspend ks forgejo -n flux-system >>"${LOG}" 2>&1
    kubectl -n devtools patch httproute forgejo --type=json -p='[{"op":"test","path":"/spec/parentRefs/1/name","value":"envoy-forge"},{"op":"remove","path":"/spec/parentRefs/1"}]' >>"${LOG}" 2>&1
    kubectl -n network delete gateway envoy-forge --wait=false >>"${LOG}" 2>&1
  fi
  if green_streak 3 30 no; then log "ROLLBACK household checks green"; else log "ROLLBACK household checks STILL RED after 5 min"; fi
  capture "rollback-after"
  ev rolled_back "{\"step\":\"envoy-forge window\",\"why\":\"${why}\",\"revert_pushed\":${pushed},\"log\":\"${LOG#${REPO}/}\",\"regime\":\"AGR-109: tests are the gate\"}"
  milestone "envoy-forge ROLLED BACK (${why}); household gateways checked after rollback; the runner cannot take jobs tonight. Heph reports in the morning."
  STATE=rolled_back
}

on_exit() { if [ "${STATE}" = "applied_unverified" ]; then rollback "runner exited unexpectedly after apply"; fi; }
trap on_exit EXIT
trap 'log "signal received"; exit 4' INT TERM HUP

# ---------- main ------------------------------------------------------------
PREV_RESULT=unknown
log "RUN ${RUN} mode=${MODE} chg=${CHG} fix=${FIX_SHA} ip=${FORGE_IP}"
if [ "${MODE}" = "execute" ] && [ -e "${DONE_MARKER}" ]; then log "already done ($(cat "${DONE_MARKER}")); nothing to do"; exit 0; fi

if ! wait_previous; then
  log "not applying: previous gateway runner state '${PREV_RESULT}'"
  [ "${MODE}" = execute ] && { ev requested "{\"note\":\"envoy-forge window: not applied, previous gateway runner ${PREV_RESULT}\"}"; milestone "envoy-forge NOT applied: the 01:05 gateway run ended '${PREV_RESULT}'. No change made."; }
  exit 3
fi

env_selftest || { milestone "envoy-forge NOT applied: Mini self-test failed (no change made)."; exit 3; }
if [ "${MODE}" = "execute" ]; then gate || { log "GATES not met; no change made"; milestone "envoy-forge NOT applied: gates not met (no change made)."; exit 3; }; else gate; log "DRY-RUN: gate result above is informational"; fi

capture "pre"
log "PREFLIGHT: need 3 consecutive green household checks (max 3 min)"
if ! green_streak 3 18 no; then log "PREFLIGHT red; no change made"; [ "${MODE}" = execute ] && { ev requested '{"note":"envoy-forge window: preflight red, no change made"}'; milestone "envoy-forge NOT applied: household pre-checks red (no change made)."; }; exit 3; fi

if main_has_fix; then log "origin/main already has ${GW_FILE}; verifying only"; else push_fix || { log "APPLY failed before any change reached main"; milestone "envoy-forge NOT applied: push failed (no change made)."; exit 3; }; fi

if [ "${MODE}" != "execute" ]; then log "DRY-RUN complete; no writes made"; exit 0; fi

STATE=applied_unverified
ev executed "{\"step\":\"envoy-forge window\",\"commit_on_main\":\"${APPLIED_SHA:-already-on-main}\",\"cherry_picked_from\":\"${FIX_SHA}\",\"prev_gateway_run\":\"${PREV_RESULT}\",\"run\":\"${RUN}\",\"regime\":\"AGR-109: tests are the gate\"}"
flux_sync

log "CONVERGE: up to 5 min for household green + forge-only on ${FORGE_IP}"
conv=1
for _ in $(seq 1 30); do
  if check && forge_check; then conv=0; break; fi
  sleep 10
done
capture "converged"
[ "${conv}" = 0 ] || { rollback "did not converge within 5 min"; exit 1; }

log "SOAK ${SOAK_SECONDS}s: fail on 2 consecutive red rounds"
red=0; end=$(( $(date +%s) + SOAK_SECONDS ))
while [ "$(date +%s)" -lt "${end}" ]; do
  if check && forge_check; then red=0; else red=$((red + 1)); fi
  if [ "${red}" -ge 2 ]; then capture "soak-fail"; rollback "2 consecutive red rounds during soak"; exit 1; fi
  sleep 15
done
capture "post"

STATE=validated
ev validated "{\"step\":\"envoy-forge window\",\"soak_s\":${SOAK_SECONDS},\"checks\":\"household: nc 241/243:443, both leases, dig grafana+forge==.241, forge 200 via .241; forge: 200 via ${FORGE_IP}, grafana not served via ${FORGE_IP}, :80 closed, owner lookup 1 per gateway, int/ext status = LB IP; every 15s, all green\",\"evidence_dir\":\"${EV#${REPO}/}\",\"run\":\"${RUN}\",\"regime\":\"AGR-109: tests are the gate\"}"
echo "${RUN} ${APPLIED_SHA:-already-on-main}" >"${DONE_MARKER}"
milestone "envoy-forge live on ${FORGE_IP}: post-checks + 10-min soak green (forge only, household gateways unaffected). The runner can now take jobs."
log "DONE ok"
exit 0
