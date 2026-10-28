#!/usr/bin/env bash
# chg-2026-10-28-002 content gate (design 3.7, test T6, Argus C8 + G2).
# Runs before the first deploy and on EVERY image bump of courseware-gast.
#
#   chg-2026-10-28-002-content-gate.sh <image@sha256:digest>
#
# Required environment (never printed):
#   FAMILY_NAMES_FILE  one name per line, the list the pre-push checks use;
#                      must live OUTSIDE this public repo
#   CLIENT_NAMES_FILE  one name per line, the client-names list; outside repo
#   CONTENT_ROOT       the web root INSIDE the image (e.g. /usr/share/nginx/html);
#                      the text and binary-file checks cover this tree
#   COSIGN_KEY                         key ref for `cosign verify --key`, OR
#   COSIGN_IDENTITY + COSIGN_ISSUER    keyless identity + OIDC issuer
#   TMPDIR             base for the work dir: the session scratchpad, never
#                      bare /tmp
# Optional:
#   SECRET_DOMAIN      the real domain; if unset it is read from the cluster
#                      Secret flux-system/cluster-secrets (into a variable,
#                      never printed)
#   COSIGN_EXTRA_ARGS  extra flags for cosign verify (word-split)
#
# Order: cosign verify -> export -> classify every file -> checks.
#
# Every file under CONTENT_ROOT is classified (Argus G2):
#   text       scanned directly
#   pdf        text extracted with pdftotext, then scanned
#   zip-like   zip/docx/xlsx/pptx/odt/ods/odp/epub/jar: every member
#              extracted (the unzip -p equivalent, Python zipfile) and
#              classified again
#   .gz / .br  decompressed (gzip -dc equivalent / brotli -dc) and
#              classified again
#   font       woff/woff2/ttf/otf/eot: exempt (no readable text)
#   image      png/jpg/jpeg/gif/webp/avif/ico/bmp/tif/tiff/heic: no text
#              scan possible; covered by the metadata check (6) only
#   other      any other binary, or an extractor that is missing, fails or
#              yields binary: counted as `unscanned` -> FAIL
#
# Checks (each a COUNT; never a match, never a file name):
#   1 family_names     grep -iwF against FAMILY_NAMES_FILE
#   2 client_names     grep -iwF against CLIENT_NAMES_FILE
#   3 secrets          gitleaks dir over the image and the extracted text
#   4 internal_ips     172.16.x / 10.42.x / 10.43.x / 192.168.x
#   5 internal_names   *.home.arpa, *.svc.cluster.local, *.lan/*.local
#                      hostnames, cluster node names (vdh...NN), and any
#                      <name>.<SECRET_DOMAIN> other than cursus-gast.<domain>
#   6 file_metadata    EXIF, PNG text chunks, SVG metadata, XMP creator/
#                      artist/owner/GPS, PDF /Author /Subject /Keywords,
#                      Office/ODF creator fields (+ exiftool when installed)
#   7 git_dirs         .git anywhere in the image
#   8 source_maps      *.map anywhere in the image
#   9 unscanned        binary files that could not be text-scanned
#
# Evidence: write-once ops/evidence/chg-2026-10-28-002/<NN>-content-gate-<UTC>.txt
# with the digest, the cosign mode and the counts. Exit 0 only when every
# count is 0; 1 on hits or a failed verify; 2 on missing input/tool (fail
# closed). Nothing is deleted (AGR-121: no rm/unlink/find -delete).
set -euo pipefail

IMAGE="${1:-}"
case "${IMAGE}" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "usage: $0 <image@sha256:<64 hex>>  (a digest pin is required)" >&2; exit 2 ;;
esac
DIGEST="${IMAGE##*@}"
printf '%s' "${DIGEST#sha256:}" | grep -Eq '^[0-9a-f]{64}$' || { echo "digest is not 64 hex" >&2; exit 2; }

fail_closed() { echo "content-gate: $*" >&2; exit 2; }

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

for v in FAMILY_NAMES_FILE CLIENT_NAMES_FILE; do
  f="${!v:-}"
  [ -n "${f}" ] || fail_closed "${v} is not set"
  [ -s "${f}" ] || fail_closed "${v} does not point at a non-empty file"
  case "$(cd "$(dirname "${f}")" && pwd)/" in
    "${REPO}"/*) fail_closed "${v} lies inside the repo; keep the list outside it" ;;
  esac
done
[ -n "${CONTENT_ROOT:-}" ] || fail_closed "CONTENT_ROOT is not set (the web root inside the image)"

if [ -n "${COSIGN_KEY:-}" ]; then
  COSIGN_MODE="key"
  COSIGN_ARGS=(--key "${COSIGN_KEY}")
elif [ -n "${COSIGN_IDENTITY:-}" ] && [ -n "${COSIGN_ISSUER:-}" ]; then
  COSIGN_MODE="keyless identity=${COSIGN_IDENTITY} issuer=${COSIGN_ISSUER}"
  COSIGN_ARGS=(--certificate-identity "${COSIGN_IDENTITY}" --certificate-oidc-issuer "${COSIGN_ISSUER}")
else
  fail_closed "set COSIGN_KEY, or COSIGN_IDENTITY and COSIGN_ISSUER"
fi

BASE="${TMPDIR:-}"
BASE="${BASE%/}"
case "${BASE}" in
  ""|/tmp|/private/tmp|/var/tmp) fail_closed "TMPDIR must point at the session scratchpad, not '${BASE:-unset}'" ;;
esac
[ -d "${BASE}" ] || fail_closed "TMPDIR does not exist"

if [ -z "${SECRET_DOMAIN:-}" ]; then
  SECRET_DOMAIN="$(kubectl -n flux-system get secret cluster-secrets \
    -o jsonpath='{.data.SECRET_DOMAIN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi
[ -n "${SECRET_DOMAIN}" ] || fail_closed "SECRET_DOMAIN unknown"

command -v gitleaks >/dev/null || fail_closed "gitleaks not on PATH (mise install)"
command -v python3 >/dev/null || fail_closed "python3 missing"
if command -v cosign >/dev/null; then
  COSIGN=(cosign)
elif mise exec aqua:sigstore/cosign@3.1.4 -- cosign version >/dev/null 2>&1; then
  COSIGN=(mise exec aqua:sigstore/cosign@3.1.4 -- cosign)
else
  fail_closed "cosign not available"
fi

# --- evidence (write-once, numbered) -----------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVDIR="${REPO}/ops/evidence/chg-2026-10-28-002"
mkdir -p "${EVDIR}"
last="$(find "${EVDIR}" -maxdepth 1 -type f -name '[0-9][0-9]-*' 2>/dev/null \
  | sed -E 's#.*/([0-9]{2})-.*#\1#' | sort -n | tail -n1 || true)"
NN="$(printf '%02d' $(( 10#${last:-0} + 1 )))"
EV="${EVDIR}/${NN}-content-gate-${TS}.txt"
( set -o noclobber; : > "${EV}" ) 2>/dev/null || fail_closed "evidence file exists, refusing to overwrite: ${EV}"
ev() { echo "$*" | tee -a "${EV}"; }

WORK="$(mktemp -d "${BASE}/cursus-gast-gate-${TS}-XXXXXX")"
FS="${WORK}/fs"
EXTRACT="${WORK}/extract"
mkdir -p "${FS}" "${EXTRACT}"

ev "chg-2026-10-28-002 content gate ${TS}"
ev "image ${IMAGE}"
ev "digest ${DIGEST}"
ev "cosign ${COSIGN_MODE}"
ev "content_root ${CONTENT_ROOT}"
echo "content-gate: work dir ${WORK} (left in place; move it away with mv when done)"

finish() {
  ev "RESULT $1"
  echo "evidence: ${EV}"
  exit "$2"
}

# --- 0. signature ------------------------------------------------------
# shellcheck disable=SC2086
if "${COSIGN[@]}" verify "${COSIGN_ARGS[@]}" ${COSIGN_EXTRA_ARGS:-} "${IMAGE}" \
     > "${WORK}/cosign-verify.json" 2> "${WORK}/cosign-verify.err"; then
  ev "cosign_verify ok ($(python3 -I -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "${WORK}/cosign-verify.json" 2>/dev/null || echo '?') signature(s))"
else
  ev "cosign_verify FAILED (details in ${WORK}/cosign-verify.err)"
  finish "FAIL (signature not verified) - no deploy" 1
fi

# --- export --------------------------------------------------------------
export_ok=0
if mise exec aqua:google/go-containerregistry@0.22.1 -- crane version >/dev/null 2>&1; then
  if mise exec aqua:google/go-containerregistry@0.22.1 -- \
      crane export --platform linux/amd64 "${IMAGE}" "${WORK}/fs.tar"; then
    export_ok=1
  fi
fi
if [ "${export_ok}" -eq 0 ]; then
  PODMAN="${HOME}/.local/opt/podman-6.1.3/bin/podman"
  [ -x "${PODMAN}" ] || { ev "export FAILED: neither crane nor podman"; finish "FAIL (no export)" 2; }
  export CONTAINERS_HELPER_BINARY_DIR="${CONTAINERS_HELPER_BINARY_DIR:-${HOME}/.local/opt/podman-6.1.3/bin}"
  LABEL="chg-2026-10-28-002-content-gate=${TS}"
  cid="$("${PODMAN}" create --platform linux/amd64 --label "${LABEL}" "${IMAGE}" /nonexistent)"
  "${PODMAN}" export -o "${WORK}/fs.tar" "${cid}"
  # Remove only the container this run created (label filter), no rm.
  "${PODMAN}" container prune -f --filter "label=${LABEL}" >/dev/null
fi
tar -xf "${WORK}/fs.tar" -C "${FS}" 2>/dev/null || tar -xf "${WORK}/fs.tar" -C "${FS}"
[ -n "$(ls -A "${FS}")" ] || { ev "export FAILED: empty filesystem"; finish "FAIL (empty export)" 2; }

SCAN="${FS}/${CONTENT_ROOT#/}"
[ -d "${SCAN}" ] || { ev "CONTENT_ROOT not found in the image"; finish "FAIL (no content root)" 2; }

# --- classify + extract ------------------------------------------------
# Writes TEXTLIST (NUL-separated paths of every text file to scan: the
# originals and the extracted text) and prints KEY=VALUE counts.
TEXTLIST="${WORK}/textfiles.nul"
python3 -I - "${SCAN}" "${EXTRACT}" "${TEXTLIST}" > "${WORK}/classify.txt" <<'PY'
import gzip, io, os, shutil, subprocess, sys, zipfile
scan, extract, textlist = sys.argv[1:4]
FONTS = {"woff", "woff2", "ttf", "otf", "eot"}
IMAGES = {"png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp", "tif", "tiff", "heic"}
ZIPS = {"zip", "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "jar"}
MAX_TOTAL = 512 * 1024 * 1024   # extracted bytes, zip-bomb guard
c = {k: 0 for k in ("text", "pdf", "zip", "gz", "br", "font", "image", "unscanned", "members")}
total = [0]
texts = []
seq = [0]
pdftotext = shutil.which("pdftotext")
brotli = shutil.which("brotli")

def is_text(b):
    if b"\x00" in b:
        return False
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False

def ext_of(name):
    n = name.lower()
    return n.rsplit(".", 1)[-1] if "." in os.path.basename(n) else ""

def out_path(name):
    seq[0] += 1
    safe = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in os.path.basename(name))[-80:]
    return os.path.join(extract, "%06d-%s" % (seq[0], safe or "x"))

def keep(name, data, depth):
    """Write extracted bytes to the extract dir, then classify them."""
    total[0] += len(data)
    if total[0] > MAX_TOTAL:
        c["unscanned"] += 1
        return
    p = out_path(name)
    with open(p, "wb") as f:
        f.write(data)
    classify(p, name, data, depth)

def classify(path, name, data, depth):
    if len(data) == 0:
        return
    if depth > 4:
        c["unscanned"] += 1
        return
    e = ext_of(name)
    if is_text(data):
        c["text"] += 1
        texts.append(path)
        return
    if e in FONTS:
        c["font"] += 1
        return
    if e in IMAGES:
        c["image"] += 1
        return
    try:
        if e == "pdf":
            if not pdftotext:
                c["unscanned"] += 1
                return
            r = subprocess.run([pdftotext, "-q", "-enc", "UTF-8", path, "-"], capture_output=True, timeout=120)
            if r.returncode != 0:
                c["unscanned"] += 1
                return
            c["pdf"] += 1
            keep(name + ".txt", r.stdout, depth + 1)
            return
        if e in ZIPS:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                c["zip"] += 1
                for m in z.infolist():
                    if m.is_dir():
                        continue
                    c["members"] += 1
                    keep(m.filename, z.read(m), depth + 1)
            return
        if e == "gz":
            c["gz"] += 1
            keep(name[:-3], gzip.decompress(data), depth + 1)
            return
        if e == "br":
            if not brotli:
                c["unscanned"] += 1
                return
            r = subprocess.run([brotli, "-dc"], input=data, capture_output=True, timeout=120)
            if r.returncode != 0:
                c["unscanned"] += 1
                return
            c["br"] += 1
            keep(name[:-3], r.stdout, depth + 1)
            return
    except Exception:
        c["unscanned"] += 1
        return
    c["unscanned"] += 1

for d, dirs, files in os.walk(scan):
    for n in files:
        p = os.path.join(d, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        with open(p, "rb") as f:
            data = f.read()
        classify(p, n, data, 0)

with open(textlist, "wb") as f:
    for t in texts:
        f.write(t.encode() + b"\x00")
for k, v in c.items():
    print("%s=%d" % (k, v))
PY
cls() { sed -n "s/^$1=//p" "${WORK}/classify.txt"; }
ev "classified: text=$(cls text) pdf=$(cls pdf) zip=$(cls zip) members=$(cls members) gz=$(cls gz) br=$(cls br) font=$(cls font) image=$(cls image) unscanned=$(cls unscanned)"

# --- checks ----------------------------------------------------------------
# Files with >= 1 hit, over the text list only. /dev/null keeps grep from
# reading stdin when the list is empty; `|| true` because grep/xargs exit
# non-zero on zero matches, which under pipefail must not end the run.
count_files() { { xargs -0 grep -a -l "$@" /dev/null < "${TEXTLIST}" 2>/dev/null || true; } | wc -l | tr -d ' '; }

C_family_names="$(count_files -iwF -f "${FAMILY_NAMES_FILE}")"
C_client_names="$(count_files -iwF -f "${CLIENT_NAMES_FILE}")"

gitleaks dir "${FS}" --no-banner --redact --exit-code 0 \
  --report-format json --report-path "${WORK}/gitleaks-fs.json" >/dev/null 2>&1 \
  || { ev "gitleaks FAILED to run"; finish "FAIL (gitleaks)" 2; }
gitleaks dir "${EXTRACT}" --no-banner --redact --exit-code 0 \
  --report-format json --report-path "${WORK}/gitleaks-extract.json" >/dev/null 2>&1 \
  || { ev "gitleaks FAILED to run"; finish "FAIL (gitleaks)" 2; }
C_secrets_gitleaks="$(python3 -I -c 'import json,sys;print(sum(len(json.load(open(a)) or []) for a in sys.argv[1:]))' \
  "${WORK}/gitleaks-fs.json" "${WORK}/gitleaks-extract.json")"

C_internal_ips="$(count_files -E '(^|[^0-9.])(172\.16|10\.4[23]|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)')"

DOM_RE="$(printf '%s' "${SECRET_DOMAIN}" | sed 's/[.[\*^$()+?{|]/\\&/g')"
c_local="$(count_files -iE '[a-z0-9-]+\.(home\.arpa|svc\.cluster\.local)|(^|[^a-z0-9-])vdh[a-z]{2,}[0-9]{2}|[a-z0-9-]+\.(lan|local)([^a-z0-9.-]|$)')"
c_dom="$({ xargs -0 grep -a -ohiE "[a-z0-9.-]+\.${DOM_RE}" /dev/null < "${TEXTLIST}" 2>/dev/null || true; } \
  | tr '[:upper:]' '[:lower:]' | { grep -viE "^cursus-gast\.${DOM_RE}\$" || true; } | wc -l | tr -d ' ')"
C_internal_names="$((c_local + c_dom))"

C_file_metadata="$(python3 -I - "${SCAN}" "${EXTRACT}" <<'PY'
import os, re, sys, zipfile
hits = 0
pdf_re = re.compile(rb"/(Author|Subject|Keywords)\s*[(<]")
xmp_re = re.compile(rb"<(dc:creator|exif:GPS|tiff:Artist|xmpRights:Owner|photoshop:AuthorsPosition)", re.I)
png_re = re.compile(rb"(tEXt|iTXt|zTXt|eXIf)")
for root in sys.argv[1:]:
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
C_unscanned="$(cls unscanned)"

total=0
for k in family_names client_names secrets_gitleaks internal_ips internal_names file_metadata git_dirs source_maps unscanned; do
  v="C_${k}"
  ev "$(printf '%-18s %s' "${k}" "${!v}")"
  total=$((total + ${!v}))
done
if [ "${total}" -eq 0 ]; then
  finish "PASS (0 hits)" 0
fi
finish "FAIL (${total} hits) - no deploy" 1
