#!/usr/bin/env bash
# chg-2026-10-28-002 rollback for cursus-gast, in the order Argus set (C7):
#   1. dns   delete the tunnel's public DNS route (Cloudflare API): the
#            proxied CNAME cursus-gast.<domain> -> <tunnel-id>.cfargotunnel.com
#   2. kill  suspend Flux (Kustomization + HelmRelease) and scale cloudflared
#            to 0, then wait until no connector pod is left. THE KILL SWITCH:
#            runnable on its own, needs no Cloudflare token.
#   3.       git revert of the deploy commit (prints the command, or runs it
#            locally with --revert <sha>; never pushes).
#
# NEVER disable the Access app while a connector is up: with the app off and
# a connector up, the hostname would be served without the edge login (the
# connector's own JWT check is then the only gate). This script never touches
# the Access app; it reports when 0 connectors are left, and only after that
# may the Access app be disabled.
#
# Usage:
#   chg-2026-10-28-002-rollback.sh kill                 # step 2 only
#   CF_API_TOKEN=... chg-2026-10-28-002-rollback.sh dns [--dry-run]
#   CF_API_TOKEN=... chg-2026-10-28-002-rollback.sh all [--revert <sha>]
# Optional: CF_ZONE_ID (else looked up from the hostname's zone name).
#
# The Cloudflare token is read ONLY from the CF_API_TOKEN variable, never
# from a file, never printed; curl gets it through a process-substituted
# config (printf is a builtin, so it never appears in a process list).
# The hostname is read from the live ConfigMap cursus-gast/cloudflared-config
# and is not printed either (the repo is public; it says ${SECRET_DOMAIN}).
#
# No rm/unlink/find -delete anywhere (AGR-121).
set -euo pipefail

NS=cursus-gast
KS=cloudflared-cursus-gast
HR=cloudflared
SEL="app.kubernetes.io/name=cloudflared,app.kubernetes.io/instance=cloudflared"
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="${REPO}/ops/evidence/chg-2026-10-28-002"
EV="${EVDIR}/rollback-${TS}.txt"

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
  *) sed -n '2,25p' "$0"; exit 64 ;;
esac

mkdir -p "${EVDIR}"
if [ -e "${EV}" ]; then
  echo "evidence file exists, refusing to overwrite: ${EV}" >&2
  exit 2
fi
log() { echo "$(date -u +%H:%M:%SZ) $*" | tee -a "${EV}"; }
log "chg-2026-10-28-002 rollback mode=${MODE} dry_run=${DRY}"

cf() {
  # cf <METHOD> <path>  -> JSON on stdout. Token only via process substitution.
  curl -sS --fail-with-body -X "$1" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${CF_API_TOKEN}") \
    -H 'Content-Type: application/json' \
    "https://api.cloudflare.com/client/v4$2"
}

step_dns() {
  : "${CF_API_TOKEN:?step 1 needs CF_API_TOKEN in the environment (run 'kill' alone without it)}"
  local host zone zone_id records count rid content
  host="$(kubectl -n "${NS}" get cm cloudflared-config -o jsonpath='{.data.config\.yaml}' \
    | sed -n 's/^ *- hostname: *//p' | head -n1 | tr -d '[:space:]')"
  case "${host}" in
    cursus-gast.*) ;;
    *) log "step 1: could not read the hostname from the live ConfigMap; abort"; return 1 ;;
  esac
  zone="${host#cursus-gast.}"
  if [ -n "${CF_ZONE_ID:-}" ]; then
    zone_id="${CF_ZONE_ID}"
  else
    zone_id="$(cf GET "/zones?name=${zone}" | jq -r '.result[0].id // empty')"
  fi
  [ -n "${zone_id}" ] || { log "step 1: zone not found; abort"; return 1; }
  records="$(cf GET "/zones/${zone_id}/dns_records?type=CNAME&name=${host}")"
  count="$(echo "${records}" | jq '.result | length')"
  log "step 1: CNAME records for cursus-gast.<domain>: ${count}"
  if [ "${count}" -eq 0 ]; then
    log "step 1: nothing to delete (already gone)"
    return 0
  fi
  if [ "${count}" -ne 1 ]; then
    log "step 1: expected exactly 1 record, found ${count}; abort, check by hand"
    return 1
  fi
  rid="$(echo "${records}" | jq -r '.result[0].id')"
  content="$(echo "${records}" | jq -r '.result[0].content')"
  case "${content}" in
    *.cfargotunnel.com) ;;
    *) log "step 1: record does not point at a tunnel (*.cfargotunnel.com); abort"; return 1 ;;
  esac
  if [ "${DRY}" -eq 1 ]; then
    log "step 1: DRY RUN, would delete 1 CNAME -> <tunnel-id>.cfargotunnel.com"
    return 0
  fi
  cf DELETE "/zones/${zone_id}/dns_records/${rid}" | jq -e '.success' >/dev/null
  count="$(cf GET "/zones/${zone_id}/dns_records?type=CNAME&name=${host}" | jq '.result | length')"
  log "step 1: deleted; read-back CNAME count=${count}"
  [ "${count}" -eq 0 ]
}

step_kill() {
  if [ "${DRY}" -eq 1 ]; then
    log "step 2: DRY RUN, would suspend ks/${KS}, hr/${NS}/${HR} and scale deploy/${HR} to 0"
    return 0
  fi
  # Suspend first, so neither Flux nor Helm scales it back up. The suspend
  # survives cluster-apps reconciles because install.yaml has no `suspend:`
  # field (see courseware-gast/install.yaml GO-LIVE note).
  flux -n flux-system suspend kustomization "${KS}" | tee -a "${EV}"
  flux -n "${NS}" suspend helmrelease "${HR}" | tee -a "${EV}"
  kubectl -n "${NS}" scale deployment "${HR}" --replicas=0 | tee -a "${EV}"
  local n i
  for i in $(seq 1 30); do
    n="$(kubectl -n "${NS}" get pods -l "${SEL}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n}" -eq 0 ] && break
    sleep 2
  done
  log "step 2: cloudflared pods left: ${n}"
  log "step 2: ks suspended=$(kubectl -n flux-system get kustomization "${KS}" -o jsonpath='{.spec.suspend}')"
  log "step 2: hr suspended=$(kubectl -n "${NS}" get helmrelease "${HR}" -o jsonpath='{.spec.suspend}')"
  if [ "${n}" -ne 0 ]; then
    log "step 2: connector pods still running; do NOT disable the Access app"
    return 1
  fi
  log "step 2: 0 connectors. The tunnel shows down in Cloudflare within ~1 min;"
  log "        only now may the Access app be disabled (by hand / Argus)."
}

step_revert() {
  if [ -n "${REVERT_SHA}" ]; then
    git -C "${REPO}" revert --no-edit "${REVERT_SHA}" | tee -a "${EV}"
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
    # Order per Argus C7. A failed step 1 must NOT block the kill switch.
    step_dns || { rc=$?; log "step 1 FAILED (rc=${rc}); continuing with the kill switch"; }
    step_kill || rc=$?
    step_revert
    ;;
esac
log "rollback rc=${rc}"
echo "evidence: ${EV}"
exit "${rc}"
