#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Prove a scoped MinIO identity is scoped (chg-2026-09-23-002).
#
# Runs with ONLY the scoped credential in its environment - it refuses to run
# if root credentials are visible, so a PASS cannot be an artefact of root.
#
# usage: iam-verify.sh <own-bucket> <foreign-bucket>...
# env:   S3_ACCESS_KEY, S3_SECRET_KEY, MINIO_ENDPOINT (optional)
#
# Positive (own bucket): list, put, stat, get + sha256 compare, multipart put
#   (48 MiB, exercises the multipart actions barman/restic use), list prefix,
#   delete, confirm gone.
# Negative (every foreign bucket): list, stat(get), put, delete -> AccessDenied.
#   Content-free and non-destructive by construction: stat/delete target a key
#   that does not exist, so even a broken policy cannot print or remove real
#   backup data. A put that unexpectedly succeeds is removed immediately with
#   the same (then evidently over-privileged) credential and reported FAIL.
# Admin + bucket creation: admin info / user list / policy list, mb -> denied.
#
# Output: one RAW line per call (positive: mc --json; negative: HTTP status
# codes + mc's error line; secrets redacted) + PASS/FAIL, and
# a final VERDICT line. Exit 0 only if every assertion passed.
# bash builtins + coreutils + mc only (the mc image has no grep/sed/awk).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <own-bucket> <foreign-bucket>..."; exit 2; }
OWN="$1"; shift
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.storage.svc.cluster.local:9000}"
export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/mc-verify-$OWN}"
export MC_NO_COLOR=1
A=scoped
TS=$(date -u +%Y%m%dT%H%M%SZ)
PFX="_iam-verify/$TS"
WORK=$(mktemp -d)
PASS=0; FAILN=0

if [ -n "${MINIO_ROOT_USER:-}${MINIO_ROOT_PASSWORD:-}" ]; then
  echo "FATAL: root credentials visible in this environment - the test would prove nothing"; exit 2
fi
[ -n "${S3_ACCESS_KEY:-}" ] && [ -n "${S3_SECRET_KEY:-}" ] || { echo "FATAL: S3_ACCESS_KEY/S3_SECRET_KEY empty"; exit 2; }
# Root isolation (Argus sec-A1): iam-apply's mc config (which holds the root
# password) lives on a volume that must NOT be mounted here.
ROOT_MC_DIR="${ROOT_MC_DIR:-/tmp/mc-apply}"
if [ -e "$ROOT_MC_DIR" ]; then echo "FATAL: root-isolation: $ROOT_MC_DIR is VISIBLE to this container"; exit 2; fi
echo "root-isolation: $ROOT_MC_DIR absent"

redact() { local s="$1"; s="${s//"${S3_SECRET_KEY}"/<redacted>}"; printf '%s' "$s"; }
mkdir -p "$MC_CONFIG_DIR"
mc alias set "$A" "$MINIO_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 || { echo "FATAL: alias set"; exit 2; }
echo "identity=$S3_ACCESS_KEY own_bucket=$OWN foreign=[$*] ts=$TS endpoint=$MINIO_ENDPOINT"

OUT=""; RC=0
call() { RC=0; OUT=$(mc --json "$@" 2>&1) || RC=$?; }
raw()  { echo "RAW[$1] rc=$RC $(redact "$OUT")"; }
ok()   { PASS=$((PASS+1)); echo "PASS[$1] $2"; }
bad()  { FAILN=$((FAILN+1)); echo "FAIL[$1] $2"; }

# Denial is asserted at the HTTP layer, not from mc's exit code or wording:
# mc's rc is unreliable here (`mc admin info` exits 0 when denied, and
# `mc --json cp` prints a "success" start record before failing), and its
# wording varies ("Access Denied." vs "Insufficient permissions"). So the call
# runs with --debug and only the RESPONSE status lines are kept - never the
# request headers. PASS = at least one 403 and no 2xx at all.
HTTP=""; ERRLINE=""
call_http() {
  RC=0; HTTP=""; ERRLINE=""
  local out line
  out=$(mc --debug "$@" 2>&1) || RC=$?
  while IFS= read -r line; do
    case "$line" in
      *"<DEBUG> HTTP/1.1 "[0-9][0-9][0-9]*) line="${line#*HTTP/1.1 }"; HTTP="$HTTP${HTTP:+,}${line%% *}";;
      "mc: <ERROR>"*) ERRLINE="$line";;
    esac
  done <<<"$out"
}
expect_denied() { # id, description, mc args...
  local id="$1" d="$2"; shift 2
  call_http "$@"
  echo "RAW[$id] rc=$RC http=[$HTTP] $(redact "$ERRLINE")"
  case ",$HTTP," in
    *,2[0-9][0-9],*) bad "$id" "$d -> a 2xx response was returned";;
    *,403,*) ok "$id" "$d -> 403 AccessDenied";;
    *) bad "$id" "$d -> no 403 seen (http=[$HTTP])";;
  esac
}
expect_ok() {
  local id="$1" d="$2"; shift 2
  call "$@"; raw "$id"
  if [ $RC -eq 0 ]; then ok "$id" "$d"; else bad "$id" "$d -> rc=$RC"; fi
}

# ── positive: own bucket ────────────────────────────────────────────────────
printf 'iam-verify %s %s\n' "$S3_ACCESS_KEY" "$TS" > "$WORK/small"
dd if=/dev/urandom of="$WORK/big" bs=1048576 count=48 status=none
small_sum=$(sha256sum "$WORK/small" | cut -d' ' -f1)
big_sum=$(sha256sum "$WORK/big" | cut -d' ' -f1)

expect_ok  "P1-list"      "list $OWN"                         ls "$A/$OWN/"
expect_ok  "P2-put"       "put small object"                  cp "$WORK/small" "$A/$OWN/$PFX/small"
expect_ok  "P3-stat"      "stat small object"                 stat "$A/$OWN/$PFX/small"
call cp "$A/$OWN/$PFX/small" "$WORK/small.back"; raw "P4-get"
if [ $RC -eq 0 ] && [ "$(sha256sum "$WORK/small.back" | cut -d' ' -f1)" = "$small_sum" ]; then
  ok "P4-get" "get small object, sha256 matches"; else bad "P4-get" "get failed or sha256 mismatch"; fi
expect_ok  "P5-multipart" "put 48 MiB object (multipart)"     cp "$WORK/big" "$A/$OWN/$PFX/big"
call cp "$A/$OWN/$PFX/big" "$WORK/big.back"; raw "P6-getbig"
if [ $RC -eq 0 ] && [ "$(sha256sum "$WORK/big.back" | cut -d' ' -f1)" = "$big_sum" ]; then
  ok "P6-getbig" "get 48 MiB object, sha256 matches"; else bad "P6-getbig" "get failed or sha256 mismatch"; fi
expect_ok  "P7-listpfx"   "list test prefix"                  ls --recursive "$A/$OWN/$PFX/"
expect_ok  "P8-delete"    "delete test objects"               rm --recursive --force "$A/$OWN/$PFX/"
call stat "$A/$OWN/$PFX/small"; raw "P9-gone"
if [ $RC -ne 0 ] && case "$OUT" in *AccessDenied*) false;; *) true;; esac; then ok "P9-gone" "deleted object is gone (not-found, not denied)"; else bad "P9-gone" "object still present or denied"; fi
# Leftovers from a restic rehearsal (restic-check.sh) live under _iam-verify/ too.
call rm --recursive --force "$A/$OWN/_iam-verify/"; raw "P10-cleanup"
[ $RC -eq 0 ] && ok "P10-cleanup" "_iam-verify/ prefix removed" || bad "P10-cleanup" "cleanup rc=$RC"

# ── informational: what does bucket enumeration reveal? ─────────────────────
call ls "$A"; raw "I1-listbuckets"
leak=""
for b in "$@"; do
  case "$OUT" in *"\"key\":\"$b/\""*) leak="$leak $b";; esac
done
if [ -z "$leak" ]; then ok "I1-listbuckets" "no foreign bucket name visible in ListBuckets"
else bad "I1-listbuckets" "foreign bucket names visible in ListBuckets:$leak"; fi

# ── negative: every foreign bucket ──────────────────────────────────────────
for b in "$@"; do
  expect_denied "N-$b-list" "list $b"              ls "$A/$b/"
  expect_denied "N-$b-get"  "stat/get key in $b"   stat "$A/$b/_iam-verify-absent-$TS"
  expect_denied "N-$b-put"  "put into $b"          cp "$WORK/small" "$A/$b/_iam-verify-$TS"
  case ",$HTTP," in *,2[0-9][0-9],*)
    echo "  probe object may exist in $b - removing it with the same credential"
    call rm --force "$A/$b/_iam-verify-$TS"; raw "N-$b-put-cleanup";;
  esac
  expect_denied "N-$b-rm"   "delete key in $b"     rm --force "$A/$b/_iam-verify-absent-$TS"
done

# ── negative: admin API and bucket creation ─────────────────────────────────
expect_denied "N-admin-info"     "mc admin info"          admin info "$A"
expect_denied "N-admin-users"    "mc admin user list"     admin user list "$A"
expect_denied "N-admin-policies" "mc admin policy list"   admin policy list "$A"
MB="iam-verify-must-not-exist-$(date +%s)"
expect_denied "N-mb"             "create a new bucket"    mb "$A/$MB"
case ",$HTTP," in *,2[0-9][0-9],*) call rb "$A/$MB"; raw "N-mb-cleanup";; esac

rm -rf "$WORK"
echo "VERDICT identity=$S3_ACCESS_KEY pass=$PASS fail=$FAILN"
[ $FAILN -eq 0 ]
