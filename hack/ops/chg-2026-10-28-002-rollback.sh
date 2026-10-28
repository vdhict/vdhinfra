#!/usr/bin/env bash
# chg-2026-10-28-002 rollback for cursus-gast, in the order Argus set (C7):
#   1. dns   delete the tunnel's public DNS route (Cloudflare API): the
#            proxied CNAME cursus-gast.<domain> -> <tunnel-id>.cfargotunnel.com
#   2. kill  suspend Flux (Kustomization + HelmRelease) and scale cloudflared
#            to 0, wait until no connector pod is left, then require the
#            Cloudflare API to show 0 connections for the tunnel. THE KILL
#            SWITCH: the cluster part runs without any Cloudflare token.
#   3.       git revert of the deploy commit (prints the command, or runs it
#            locally with --revert <sha>; never pushes).
#
# FAIL CLOSED (Argus G1): any kubectl/flux/API error is a failure, never
# "0 connectors". `kill` only reports DONE (exit 0) when the cluster shows 0
# pods AND the Cloudflare API shows 0 connections. Without CF_API_TOKEN the
# cluster part still runs, but the result is UNVERIFIED and the exit is 3.
#
# NEVER disable the Access app while a connector is up. This script never
# touches the Access app; only after a DONE may it be disabled.
#
# Usage:
#   chg-2026-10-28-002-rollback.sh kill
#   chg-2026-10-28-002-rollback.sh dns [--dry-run]
#   chg-2026-10-28-002-rollback.sh all [--revert <sha>]
# Environment (values never printed, never read from a file):
#   CF_API_TOKEN   Cloudflare API token (dns, and the kill verification)
#   CF_ACCOUNT_ID  32-hex account id (kill verification)
#   TUNNEL_ID      tunnel UUID of `cursus-gast` (kill verification)
#   CF_ZONE_ID     optional (else looked up from the hostname's zone name)
# curl gets the token through a process-substituted config (printf is a
# builtin, so it never appears in a process list). The hostname is read
# from the live ConfigMap cursus-gast/cloudflared-config and not printed.
#
# Exit: 0 done+verified, 1 failed, 3 cluster part done but UNVERIFIED,
# 64 usage. No rm/unlink/find -delete anywhere (AGR-121).
set -euo pipefail
# xtrace would echo CF_API_TOKEN (variable tests, printf). Refuse it.
case "$-" in *x*) echo "refusing to run with xtrace on: it would print the token" >&2; exit 64 ;; esac

NS=cursus-gast
KS=cloudflared-cursus-gast
HR=cloudflared
SEL="app.kubernetes.io/name=cloudflared,app.kubernetes.io/instance=cloudflared"
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="${REPO}/ops/evidence/chg-2026-10-28-002"
EV="${EVDIR}/rollback-${TS}.txt"
CF_WAIT_SECONDS="${CF_WAIT_SECONDS:-120}"

MODE="${1:-}"
shift || true
DRY=0
REVERT_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --revert) REVERT_SHA="${2:?--revert needs a sha}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

case "${MODE}" in
  kill|dns|all) ;;
  *) sed -n '2,35p' "$0"; exit 64 ;;
esac

mkdir -p "${EVDIR}"
if [ -e "${EV}" ]; then
  echo "evidence file exists, refusing to overwrite: ${EV}" >&2
  exit 1
fi
log() { echo "$(date -u +%H:%M:%SZ) $*" | tee -a "${EV}"; }
log "chg-2026-10-28-002 rollback mode=${MODE} dry_run=${DRY}"

cf() {
  # cf <METHOD> <path>  -> JSON on stdout. Fails on HTTP or transport error.
  curl -sS --fail-with-body --max-time 20 -X "$1" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${CF_API_TOKEN}") \
    -H 'Content-Type: application/json' \
    "https://api.cloudflare.com/client/v4$2"
}

step_dns() {
  if [ -z "${CF_API_TOKEN:-}" ]; then
    log "step 1: CF_API_TOKEN not set; cannot delete the DNS route (run 'kill' on its own)"
    return 1
  fi
  local host zone zone_id records count rid content cm
  cm="$(kubectl -n "${NS}" get cm cloudflared-config -o jsonpath='{.data.config\.yaml}')" \
    || { log "step 1: kubectl could not read the ConfigMap; abort"; return 1; }
  host="$(printf '%s\n' "${cm}" | sed -n 's/^ *- hostname: *//p' | head -n1 | tr -d '[:space:]')"
  case "${host}" in
    cursus-gast.*) ;;
    *) log "step 1: could not read the hostname from the live ConfigMap; abort"; return 1 ;;
  esac
  zone="${host#cursus-gast.}"
  if [ -n "${CF_ZONE_ID:-}" ]; then
    zone_id="${CF_ZONE_ID}"
  else
    zone_id="$(cf GET "/zones?name=${zone}" | jq -er '.result[0].id')" \
      || { log "step 1: zone lookup failed; abort"; return 1; }
  fi
  records="$(cf GET "/zones/${zone_id}/dns_records?type=CNAME&name=${host}")" \
    || { log "step 1: DNS record lookup failed; abort"; return 1; }
  count="$(printf '%s' "${records}" | jq -er '.result | length')" \
    || { log "step 1: unexpected API answer; abort"; return 1; }
  log "step 1: CNAME records for cursus-gast.<domain>: ${count}"
  if [ "${count}" -eq 0 ]; then
    log "step 1: nothing to delete (already gone)"
    return 0
  fi
  if [ "${count}" -ne 1 ]; then
    log "step 1: expected exactly 1 record, found ${count}; abort, check by hand"
    return 1
  fi
  rid="$(printf '%s' "${records}" | jq -er '.result[0].id')"
  content="$(printf '%s' "${records}" | jq -er '.result[0].content')"
  case "${content}" in
    *.cfargotunnel.com) ;;
    *) log "step 1: record does not point at a tunnel (*.cfargotunnel.com); abort"; return 1 ;;
  esac
  if [ "${DRY}" -eq 1 ]; then
    log "step 1: DRY RUN, would delete 1 CNAME -> <tunnel-id>.cfargotunnel.com"
    return 0
  fi
  cf DELETE "/zones/${zone_id}/dns_records/${rid}" | jq -e '.success == true' >/dev/null \
    || { log "step 1: DELETE failed"; return 1; }
  count="$(cf GET "/zones/${zone_id}/dns_records?type=CNAME&name=${host}" | jq -er '.result | length')" \
    || { log "step 1: read-back failed"; return 1; }
  log "step 1: deleted; read-back CNAME count=${count}"
  [ "${count}" -eq 0 ]
}

# Number of cloudflared pods, or a FAILURE. Never turns an error into 0.
count_pods() {
  local out
  out="$(kubectl -n "${NS}" get pods -l "${SEL}" -o name)" || return 1
  printf '%s\n' "${out}" | grep -c . || true
}

# 0 = API shows 0 connections, 1 = connections remain or API error,
# 3 = cannot verify (no token / ids).
verify_cloudflare() {
  if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ] || [ -z "${TUNNEL_ID:-}" ]; then
    log "step 2: UNVERIFIED - CF_API_TOKEN, CF_ACCOUNT_ID and TUNNEL_ID are all needed to read the tunnel's connections"
    return 3
  fi
  if ! printf '%s' "${CF_ACCOUNT_ID}" | grep -Eq '^[0-9a-f]{32}$'; then
    log "step 2: CF_ACCOUNT_ID is not 32 hex; refusing"; return 1
  fi
  if ! printf '%s' "${TUNNEL_ID}" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    log "step 2: TUNNEL_ID is not a UUID; refusing"; return 1
  fi
  local deadline body conns status
  deadline=$(( $(date +%s) + CF_WAIT_SECONDS ))
  while :; do
    if body="$(cf GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}")"; then
      # The connections field MUST be an array; a missing field is not "0".
      if conns="$(printf '%s' "${body}" | jq -er 'if (.success == true) and (.result.connections | type) == "array" then (.result.connections | length) else error("shape") end')"; then
        status="$(printf '%s' "${body}" | jq -r '.result.status // "unknown"')"
        log "step 2: Cloudflare API: connections=${conns} status=${status}"
        if [ "${conns}" -eq 0 ]; then
          return 0
        fi
      else
        log "step 2: Cloudflare API answer has no connections array; not verified"
      fi
    else
      log "step 2: Cloudflare API call failed"
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      log "step 2: Cloudflare still does not show 0 connections after ${CF_WAIT_SECONDS}s"
      return 1
    fi
    sleep 10
  done
}

step_kill() {
  if [ "${DRY}" -eq 1 ]; then
    log "step 2: DRY RUN, would suspend ks/${KS}, hr/${NS}/${HR} and scale deploy/${HR} to 0"
    return 0
  fi
  local failed=0 n i ks_s hr_s
  # Suspend first, so neither Flux nor Helm scales it back up. Each call is
  # checked; a failure is recorded and the remaining actions still run
  # (stopping the connector matters more than a clean log).
  flux -n flux-system suspend kustomization "${KS}" 2>&1 | tee -a "${EV}" \
    || { log "step 2: suspend kustomization FAILED"; failed=1; }
  flux -n "${NS}" suspend helmrelease "${HR}" 2>&1 | tee -a "${EV}" \
    || { log "step 2: suspend helmrelease FAILED"; failed=1; }
  kubectl -n "${NS}" scale deployment "${HR}" --replicas=0 2>&1 | tee -a "${EV}" \
    || { log "step 2: scale to 0 FAILED"; failed=1; }

  n=""
  for i in $(seq 1 30); do
    if n="$(count_pods)"; then
      [ "${n}" -eq 0 ] && break
    else
      n="ERROR"
    fi
    sleep 2
  done
  log "step 2: cloudflared pods left: ${n}"
  if [ "${n}" != 0 ]; then
    log "step 2: FAILED - pods not proven gone (${n}); do NOT disable the Access app"
    return 1
  fi
  ks_s="$(kubectl -n flux-system get kustomization "${KS}" -o jsonpath='{.spec.suspend}')" || ks_s=ERROR
  hr_s="$(kubectl -n "${NS}" get helmrelease "${HR}" -o jsonpath='{.spec.suspend}')" || hr_s=ERROR
  log "step 2: ks suspended=${ks_s} hr suspended=${hr_s}"
  if [ "${ks_s}" != true ] || [ "${hr_s}" != true ]; then
    log "step 2: FAILED - suspend not confirmed; Flux could scale it back"
    failed=1
  fi
  [ "${failed}" -eq 0 ] || return 1

  local vrc=0
  verify_cloudflare || vrc=$?
  case "${vrc}" in
    0) log "step 2: DONE - 0 pods, suspended, 0 Cloudflare connections. The Access app may now be disabled."
       return 0 ;;
    3) log "step 2: cluster part done, Cloudflare side UNVERIFIED; keep the Access app ON"
       return 3 ;;
    *) log "step 2: FAILED - Cloudflare still shows connections or could not be read; keep the Access app ON"
       return 1 ;;
  esac
}

step_revert() {
  if [ -n "${REVERT_SHA}" ]; then
    git -C "${REPO}" revert --no-edit "${REVERT_SHA}" 2>&1 | tee -a "${EV}" \
      || { log "step 3: git revert FAILED"; return 1; }
    log "step 3: reverted ${REVERT_SHA} locally; NOT pushed. Push to main to make it durable."
  else
    log "step 3: run: git -C ${REPO} revert --no-edit <deploy-commit> && push to main"
  fi
}

rc=0
case "${MODE}" in
  kill) step_kill || rc=$? ;;
  dns)  step_dns || rc=$? ;;
  all)
    # Order per Argus C7. A failed step 1 must NOT block the kill switch,
    # but it does make the overall result a failure.
    d=0; step_dns || d=$?
    [ "${d}" -eq 0 ] || log "step 1 FAILED (rc=${d}); continuing with the kill switch"
    k=0; step_kill || k=$?
    step_revert || k=1
    if [ "${d}" -ne 0 ] || [ "${k}" -eq 1 ]; then rc=1; else rc="${k}"; fi
    ;;
esac
log "rollback rc=${rc}"
echo "evidence: ${EV}"
exit "${rc}"
