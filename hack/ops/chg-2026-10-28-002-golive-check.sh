#!/usr/bin/env bash
# chg-2026-10-28-002 go-live check (Argus G4). Read-only; scans
# kubernetes/main/apps/cursus-gast and fails while the tree is not ready.
#
#   chg-2026-10-28-002-golive-check.sh [--expect-suspended] [--ref <git-ref>]
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
# Full-line YAML comments are ignored: they document the placeholders.
# Prints counts and file:line, never values. Exit 0 ready, 1 not ready,
# 64 usage. No rm/unlink/find -delete (AGR-121).
set -euo pipefail

EXPECT_SUSPENDED=0
REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-suspended) EXPECT_SUSPENDED=1 ;;
    --ref) REF="${2:?--ref needs a git ref}"; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DIR=kubernetes/main/apps/cursus-gast
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

for f in ${SUSPEND_FILES}; do
  if printf '%s\n' ${FILES} | grep -qxF "${f}"; then
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
