#!/usr/bin/env bash
# chg-2026-10-28-002 go-live check (Argus G4). Read-only; scans
# kubernetes/main/apps/cursus-gast and fails while the tree is not ready.
#
#   chg-2026-10-28-002-golive-check.sh [--expect-suspended] [--ref <git-ref>]
#   chg-2026-10-28-002-golive-check.sh --live [--ref <git-ref>]
#
# Always FAIL while any non-comment line still holds a placeholder:
#   replace-team            Access team name (configmap + cloudflared CNP)
#   replace-aud             Access AUD tag (configmap)
#   registry.invalid        courseware-gast placeholder image
#   sha256:000...0 (64)     placeholder digest
# and on any `suspend: false` (go-live DELETES the suspend line; an explicit
# false would undo an emergency `flux suspend` on every reconcile).
#
# Suspend lines (courseware-gast/install.yaml, cloudflared/install.yaml):
#   default             FAIL while either `suspend: true` line exists (go-live)
#   --expect-suspended  FAIL unless BOTH lines exist (pre-go-live: placeholders
#                       filled, workloads still held)
#
# --ref <git-ref>  check that commit instead of the working tree, e.g.
#                  origin/main (what Flux deploys). Default: working tree.
#
# Access per rule (Argus F-T3, 29-10): T3 proved cloudflared ignores a
# top-level originRequest.access for the ingress rules. Every run also
# parses config.yaml out of cloudflared/app/configmap.yaml and FAILs unless
# EVERY hostname rule has its own access block (required: true, teamName
# bluejungle, audTag == the top-level AUD list); see
# chg-2026-10-28-002-access-rules.py. Prints OK/FAIL per rule with the first
# hostname label only, never the AUD.
#
# --live  read-only posture mode (Argus posture scan): the same rule check on
#         the LIVE ConfigMap cursus-gast/cloudflared-config, with the AUD
#         list expected from the git copy at --ref (default origin/main; a
#         drift FAILs), plus: every cloudflared pod started at or after the
#         ConfigMap's last change (managedFields time), else it runs a stale
#         config. Needs kubectl (KUBECTL=...) with get on that ConfigMap and
#         list on pods in cursus-gast. Skips the placeholder/suspend checks.
#
# Full-line YAML comments are ignored: they document the placeholders.
# Prints counts and file:line, never values. Exit 0 ready, 1 not ready,
# 64 usage. No rm/unlink/find -delete (AGR-121).
set -euo pipefail

EXPECT_SUSPENDED=0
LIVE=0
REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-suspended) EXPECT_SUSPENDED=1 ;;
    --ref) REF="${2:?--ref needs a git ref}"; shift ;;
    --live) LIVE=1 ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DIR=kubernetes/main/apps/cursus-gast
CM_FILE="${DIR}/cloudflared/app/configmap.yaml"
RULES="$(cd "$(dirname "$0")" && pwd)/chg-2026-10-28-002-access-rules.py"
PY="${PYTHON:-/usr/bin/python3}"
[ -x "${PY}" ] || PY=python3
[ "${LIVE}" -eq 1 ] && [ "${EXPECT_SUSPENDED}" -eq 1 ] && { echo "golive-check: --live and --expect-suspended exclude each other" >&2; exit 64; }
[ "${LIVE}" -eq 1 ] && [ -z "${REF}" ] && REF=origin/main
SUSPEND_FILES="${DIR}/courseware-gast/install.yaml ${DIR}/cloudflared/install.yaml"

# list_files / show_file abstract over working tree vs a git ref.
if [ -n "${REF}" ]; then
  git -C "${REPO}" rev-parse --verify --quiet "${REF}^{commit}" >/dev/null \
    || { echo "golive-check: unknown ref ${REF}" >&2; exit 64; }
  list_files() { git -C "${REPO}" ls-tree -r --name-only "${REF}" -- "${DIR}" | grep -E '\.ya?ml$' || true; }
  show_file() { git -C "${REPO}" show "${REF}:$1"; }
  WHERE="ref ${REF} ($(git -C "${REPO}" rev-parse --short "${REF}"))"
else
  list_files() { (cd "${REPO}" && find "${DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort); }
  show_file() { cat "${REPO}/$1"; }
  WHERE="working tree"
fi

FILES="$(list_files)"
[ -n "${FILES}" ] || { echo "golive-check: no YAML under ${DIR} in ${WHERE}" >&2; exit 1; }

if [ "${LIVE}" -eq 1 ]; then
  # Read-only posture mode. Values stay in shell variables, never printed.
  K="${KUBECTL:-kubectl}"
  fail=0
  echo "golive-check: LIVE cursus-gast/cloudflared-config, AUD expected from ${WHERE}"
  if ! CM_JSON="$("${K}" -n cursus-gast get configmap cloudflared-config -o json --show-managed-fields 2>/dev/null)"; then
    echo "golive-check: FAIL cannot read live ConfigMap cursus-gast/cloudflared-config"; CM_JSON=""; fail=1
  fi
  if ! PODS_JSON="$("${K}" -n cursus-gast get pods -l app.kubernetes.io/controller=cloudflared -o json 2>/dev/null)"; then
    echo "golive-check: FAIL cannot list cloudflared pods in cursus-gast"; PODS_JSON=""; fail=1
  fi
  if ! GIT_CM="$(show_file "${CM_FILE}" 2>/dev/null)"; then
    echo "golive-check: FAIL ${CM_FILE} missing in ${WHERE}"; GIT_CM=""; fail=1
  fi
  if [ "${fail}" -eq 0 ]; then
    "${PY}" -I "${RULES}" rules --cm-json <(printf '%s' "${CM_JSON}") --expect-from-cm-yaml <(printf '%s\n' "${GIT_CM}") \
      | sed 's/^access-rules:/golive-check: rules/' || fail=1
    "${PY}" -I "${RULES}" fresh --cm-json <(printf '%s' "${CM_JSON}") --pods-json <(printf '%s' "${PODS_JSON}") \
      | sed 's/^access-rules:/golive-check: fresh/' || fail=1
  fi
  CM_JSON=""; GIT_CM=""; PODS_JSON=""
  if [ "${fail}" -eq 0 ]; then echo "golive-check: RESULT LIVE OK"; exit 0; fi
  echo "golive-check: RESULT LIVE FAIL"; exit 1
fi

# hits <ERE>: "file:line" for every NON-comment line matching, one per line.
hits() {
  local re="$1" f
  for f in ${FILES}; do
    show_file "${f}" | awk -v re="${re}" -v f="${f}" '
      /^[[:space:]]*#/ { next }
      $0 ~ re { print f ":" NR }'
  done
}

fail=0
check() {
  # check <label> <ERE>: every hit is a failure.
  local label="$1" re="$2" out n
  out="$(hits "${re}")"
  n="$(printf '%s' "${out}" | grep -c . || true)"
  if [ "${n}" -eq 0 ]; then
    printf 'golive-check: %-20s 0\n' "${label}"
  else
    printf 'golive-check: %-20s %s  FAIL\n' "${label}" "${n}"
    printf '%s\n' "${out}" | sed 's/^/    /'
    fail=1
  fi
}

echo "golive-check: ${WHERE}, mode $([ "${EXPECT_SUSPENDED}" -eq 1 ] && echo expect-suspended || echo go-live)"
check "replace-team"     'replace-team'
check "replace-aud"      'replace-aud'
check "registry.invalid" 'registry\.invalid'
check "zero-digest"      'sha256:0{64}'
check "suspend-false"    '^[[:space:]]*suspend:[[:space:]]*false'

# Access block on every hostname rule (Argus F-T3); top-level only = FAIL.
if printf '%s\n' "${FILES}" | grep -qxF "${CM_FILE}"; then
  show_file "${CM_FILE}" | "${PY}" -I "${RULES}" rules --cm-yaml - \
    | sed 's/^access-rules:/golive-check: access/' || fail=1
else
  echo "golive-check: ${CM_FILE} missing  FAIL"; fail=1
fi

for f in ${SUSPEND_FILES}; do
  if printf '%s\n' "${FILES}" | grep -qxF "${f}"; then
    n="$(show_file "${f}" | awk '/^[[:space:]]*#/ {next} /^[[:space:]]*suspend:[[:space:]]*true[[:space:]]*$/ {c++} END {print c+0}')"
  else
    echo "golive-check: ${f} missing"; fail=1; continue
  fi
  if [ "${EXPECT_SUSPENDED}" -eq 1 ]; then
    if [ "${n}" -ge 1 ]; then
      printf 'golive-check: suspended            yes  %s\n' "${f}"
    else
      printf 'golive-check: suspended            NO   %s  FAIL (expected suspended)\n' "${f}"; fail=1
    fi
  else
    if [ "${n}" -ge 1 ]; then
      printf 'golive-check: suspended            yes  %s  FAIL (delete the line to go live)\n' "${f}"; fail=1
    else
      printf 'golive-check: suspended            no   %s\n' "${f}"
    fi
  fi
done

if [ "${fail}" -eq 0 ]; then
  echo "golive-check: RESULT READY"
  exit 0
fi
echo "golive-check: RESULT NOT READY"
exit 1
