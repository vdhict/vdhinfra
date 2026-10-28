#!/usr/bin/env bash
# chg-2026-10-28-002 content gate (design 3.7, test T6, Argus C8).
# Runs before the first deploy and on EVERY image bump of courseware-gast.
#
#   chg-2026-10-28-002-content-gate.sh <image@sha256:digest>
#
# Required environment (lists live OUTSIDE this public repo; never commit
# them, never print them):
#   FAMILY_NAMES_FILE  one name per line, the list the pre-push checks use
#   CLIENT_NAMES_FILE  one name per line, the client-names list
# Optional:
#   SECRET_DOMAIN      the real domain; if unset it is read from the cluster
#                      Secret flux-system/cluster-secrets (into a variable,
#                      never printed). Needed for the internal-name check.
#   CONTENT_ROOT       path INSIDE the image to scope the text checks to
#                      (e.g. /usr/share/nginx/html). Default: the whole image.
#                      .git / *.map / gitleaks always cover the whole image.
#
# Checks (each prints a COUNT only, never a match, never a file name):
#   1 family names         grep -iwF against FAMILY_NAMES_FILE
#   2 client names         grep -iwF against CLIENT_NAMES_FILE
#   3 secrets              gitleaks dir (redacted report, count only)
#   4 internal IPs         172.16.x / 10.42.x / 10.43.x / 192.168.x
#   5 internal names       *.home.arpa, *.local hostnames, cluster node names
#                          (vdh...NN), cluster DNS (svc.cluster.local), and
#                          any <name>.<SECRET_DOMAIN> other than
#                          cursus-gast.<SECRET_DOMAIN>
#   6 file metadata        any EXIF block, PNG text chunk, SVG metadata, XMP
#                          creator/artist/owner/GPS, PDF /Author /Subject
#                          /Keywords, Office/ODF creator fields (+ exiftool
#                          when installed). Tool names (Producer,
#                          CreatorTool) are not personal and do not count.
#                          NOTE: checks 1-2 skip binary files (grep -I), so
#                          text INSIDE compressed PDFs/images is not name-
#                          checked; ship no PDFs, or check them by hand.
#   7 .git directories
#   8 *.map files          (source maps)
# Exit 0 only when every count is 0. Any missing input or tool: exit 2
# (fail closed).
#
# Image export: crane (go-containerregistry, via mise), else podman
# (~/.local/opt/podman-6.1.3, needs CONTAINERS_HELPER_BINARY_DIR). The
# exported filesystem stays in a fresh scratch dir (printed); this script
# deletes nothing (AGR-121: no rm/unlink/find -delete).
set -euo pipefail

IMAGE="${1:-}"
case "${IMAGE}" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "usage: $0 <image@sha256:<64 hex>>  (a digest pin is required)" >&2; exit 2 ;;
esac

fail_closed() { echo "content-gate: $*" >&2; exit 2; }

for v in FAMILY_NAMES_FILE CLIENT_NAMES_FILE; do
  f="${!v:-}"
  [ -n "${f}" ] || fail_closed "${v} is not set"
  [ -s "${f}" ] || fail_closed "${v} does not point at a non-empty file"
done
REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
for v in FAMILY_NAMES_FILE CLIENT_NAMES_FILE; do
  case "$(cd "$(dirname "${!v}")" && pwd)/" in
    "${REPO}"/*) fail_closed "${v} lies inside the repo; keep the list outside it" ;;
  esac
done

if [ -z "${SECRET_DOMAIN:-}" ]; then
  SECRET_DOMAIN="$(kubectl -n flux-system get secret cluster-secrets \
    -o jsonpath='{.data.SECRET_DOMAIN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi
[ -n "${SECRET_DOMAIN}" ] || fail_closed "SECRET_DOMAIN unknown"

command -v gitleaks >/dev/null || fail_closed "gitleaks not on PATH (mise install)"
command -v python3 >/dev/null || fail_closed "python3 missing"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cursus-gast-gate-${TS}-XXXXXX")"
FS="${WORK}/fs"
mkdir -p "${FS}"
echo "content-gate: image ${IMAGE}"
echo "content-gate: work dir ${WORK} (left in place; nothing is deleted)"

# --- export -------------------------------------------------------------
export_ok=0
if mise exec aqua:google/go-containerregistry@0.22.1 -- crane version >/dev/null 2>&1; then
  if mise exec aqua:google/go-containerregistry@0.22.1 -- \
      crane export --platform linux/amd64 "${IMAGE}" "${WORK}/fs.tar"; then
    export_ok=1
  fi
fi
if [ "${export_ok}" -eq 0 ]; then
  PODMAN="${HOME}/.local/opt/podman-6.1.3/bin/podman"
  [ -x "${PODMAN}" ] || fail_closed "neither crane nor podman available"
  export CONTAINERS_HELPER_BINARY_DIR="${CONTAINERS_HELPER_BINARY_DIR:-${HOME}/.local/opt/podman-6.1.3/bin}"
  LABEL="chg-2026-10-28-002-content-gate=${TS}"
  cid="$("${PODMAN}" create --platform linux/amd64 --label "${LABEL}" "${IMAGE}" /nonexistent)"
  "${PODMAN}" export -o "${WORK}/fs.tar" "${cid}"
  # Remove only the container this run created (label filter), no rm.
  "${PODMAN}" container prune -f --filter "label=${LABEL}" >/dev/null
  export_ok=1
fi
tar -xf "${WORK}/fs.tar" -C "${FS}" 2>/dev/null || tar -xf "${WORK}/fs.tar" -C "${FS}"
[ -n "$(ls -A "${FS}")" ] || fail_closed "exported filesystem is empty"

SCAN="${FS}"
if [ -n "${CONTENT_ROOT:-}" ]; then
  SCAN="${FS}/${CONTENT_ROOT#/}"
  [ -d "${SCAN}" ] || fail_closed "CONTENT_ROOT not found in the image"
fi

# Count of FILES with at least one hit. grep prints file names into wc only.
# grep exits 1 on zero matches; under pipefail that must not end the run.
count_files() { { grep -rIl "$@" "${SCAN}" 2>/dev/null || true; } | wc -l | tr -d ' '; }

C_family_names="$(count_files -iwF -f "${FAMILY_NAMES_FILE}")"
C_client_names="$(count_files -iwF -f "${CLIENT_NAMES_FILE}")"

gitleaks dir "${FS}" --no-banner --redact --exit-code 0 \
  --report-format json --report-path "${WORK}/gitleaks.json" >/dev/null 2>&1 \
  || fail_closed "gitleaks failed to run"
C_secrets_gitleaks="$(python3 -I -c 'import json,sys;print(len(json.load(open(sys.argv[1])) or []))' "${WORK}/gitleaks.json")"

C_internal_ips="$(count_files -E '(^|[^0-9.])(172\.16|10\.4[23]|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)')"

DOM_RE="$(printf '%s' "${SECRET_DOMAIN}" | sed 's/[.[\*^$()+?{|]/\\&/g')"
c_local="$(count_files -iE '[a-z0-9-]+\.(home\.arpa|svc\.cluster\.local)|(^|[^a-z0-9-])vdh[a-z]{2,}[0-9]{2}|[a-z0-9-]+\.(lan|local)([^a-z0-9.-]|$)')"
c_dom="$({ grep -rIohiE "[a-z0-9.-]+\.${DOM_RE}" "${SCAN}" 2>/dev/null || true; } \
  | tr '[:upper:]' '[:lower:]' | { grep -viE "^cursus-gast\.${DOM_RE}\$" || true; } | wc -l | tr -d ' ')"
C_internal_names="$((c_local + c_dom))"

C_file_metadata="$(python3 -I - "${SCAN}" <<'PY'
import os, re, sys, zipfile
root = sys.argv[1]
hits = 0
pdf_re = re.compile(rb"/(Author|Subject|Keywords)\s*[(<]")
xmp_re = re.compile(rb"<(dc:creator|exif:GPS|tiff:Artist|xmpRights:Owner|photoshop:AuthorsPosition)", re.I)
png_re = re.compile(rb"(tEXt|iTXt|zTXt|eXIf)(Author|Artist|Copyright|Software|Comment|Description|Source|Raw profile type exif)?")
for d, dirs, files in os.walk(root):
    for n in files:
        p = os.path.join(d, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        ext = n.lower().rsplit(".", 1)[-1] if "." in n else ""
        try:
            if ext in ("jpg", "jpeg", "tif", "tiff", "webp", "heic", "avif", "gif"):
                b = open(p, "rb").read()
                if b"Exif\x00\x00" in b or xmp_re.search(b):
                    hits += 1
            elif ext == "png":
                b = open(p, "rb").read()
                if png_re.search(b) or xmp_re.search(b):
                    hits += 1
            elif ext == "pdf":
                b = open(p, "rb").read()
                if pdf_re.search(b) or xmp_re.search(b):
                    hits += 1
            elif ext == "svg":
                b = open(p, "rb").read()
                if xmp_re.search(b) or re.search(rb"<(metadata|rdf:RDF|sodipodi:docname|inkscape:export-filename)", b, re.I):
                    hits += 1
            elif ext in ("docx", "xlsx", "pptx", "odt", "ods", "odp", "epub"):
                with zipfile.ZipFile(p) as z:
                    for m in ("docProps/core.xml", "docProps/app.xml", "meta.xml"):
                        if m in z.namelist() and re.search(rb"<(dc:creator|cp:lastModifiedBy|meta:initial-creator|Company|Manager)>[^<]+<", z.read(m)):
                            hits += 1
                            break
        except Exception:
            hits += 1  # unreadable = not proven clean
print(hits)
PY
)"
if command -v exiftool >/dev/null; then
  c_exif="$({ exiftool -q -q -r -if '$Author or $Artist or $Creator or $OwnerName or $GPSLatitude or $XPAuthor' -p '1' "${SCAN}" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  C_file_metadata="$((C_file_metadata + c_exif))"
fi

C_git_dirs="$({ find "${FS}" -name .git 2>/dev/null || true; } | wc -l | tr -d ' ')"
C_source_maps="$({ find "${FS}" -type f -name '*.map' 2>/dev/null || true; } | wc -l | tr -d ' ')"

total=0
for k in family_names client_names secrets_gitleaks internal_ips internal_names file_metadata git_dirs source_maps; do
  v="C_${k}"
  printf 'content-gate: %-18s %s\n' "${k}" "${!v}"
  total=$((total + ${!v}))
done
if [ "${total}" -eq 0 ]; then
  echo "content-gate: RESULT PASS (0 hits)"
  exit 0
fi
echo "content-gate: RESULT FAIL (${total} hits) - no deploy"
exit 1
