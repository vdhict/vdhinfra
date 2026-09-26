#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Prove the scoped forge-volsync identity is SUFFICIENT for restic, using the
# restic binary from the VolSync mover image itself (quay.io/backube/volsync
# 0.13.1 ships restic 0.18.0), replaying the command sequence of the mover's
# own entry.sh: cat config (rc 10 = no repo) -> init -> backup -> backup ->
# snapshots -> forget -> prune -> check -> unlock -> restore + sha256 compare.
#
# Scratch repo under s3://forge-volsync/_iam-verify/restic-<ts>; iam-verify.sh
# removes the whole _iam-verify/ prefix afterwards. The repo password is
# random and in-memory only - this is a throwaway repository.
#
# env: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (scoped only), MINIO_ENDPOINT
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.storage.svc.cluster.local:9000}"
if [ -n "${MINIO_ROOT_USER:-}${MINIO_ROOT_PASSWORD:-}" ]; then
  echo "FATAL: root credentials visible - test would prove nothing"; exit 2; fi
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || { echo "FATAL: scoped creds empty"; exit 2; }
# Root isolation (Argus sec-A1): iam-apply's mc config (which holds the root
# password) lives on a volume that must NOT be mounted here.
ROOT_MC_DIR="${ROOT_MC_DIR:-/tmp/mc-apply}"
if [ -e "$ROOT_MC_DIR" ]; then echo "FATAL: root-isolation: $ROOT_MC_DIR is VISIBLE to this container"; exit 2; fi
echo "root-isolation: $ROOT_MC_DIR absent"

TS=$(date -u +%Y%m%dT%H%M%SZ)
RESTIC_BUCKET="${RESTIC_BUCKET:-forge-volsync}"
export RESTIC_REPOSITORY="s3:${MINIO_ENDPOINT}/${RESTIC_BUCKET}/_iam-verify/restic-$TS"
RESTIC_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '\n'); export RESTIC_PASSWORD
RESTIC_CACHE_DIR=$(mktemp -d); export RESTIC_CACHE_DIR
export RESTIC_PROGRESS_FPS=0
SRC=$(mktemp -d); DST=$(mktemp -d)
PASS=0; FAILN=0
echo "identity=$AWS_ACCESS_KEY_ID repo=$RESTIC_REPOSITORY"
restic version

step() { # id, expected-rc, restic args...
  local id="$1" want="$2" rc=0 out; shift 2
  out=$(restic "$@" 2>&1) || rc=$?
  out="${out//"${AWS_SECRET_ACCESS_KEY}"/<redacted>}"; out="${out//"${RESTIC_PASSWORD}"/<redacted>}"
  echo "RAW[$id] rc=$rc restic $*"; printf '%s\n' "$out" | tail -n 6 | while IFS= read -r l; do echo "    $l"; done
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); echo "PASS[$id] rc=$rc"; else FAILN=$((FAILN+1)); echo "FAIL[$id] rc=$rc want=$want"; fi
}

mkdir -p "$SRC/data/sub"
dd if=/dev/urandom of="$SRC/data/a.bin" bs=1048576 count=24 status=none
printf 'hello forge %s\n' "$TS" > "$SRC/data/sub/b.txt"
cd "$SRC/data" || { echo "FATAL: cd"; exit 2; }

step R1-catconfig 10 cat config                       # mover: rc 10 => repo absent, go init
step R2-init       0 init
step R3-backup1    0 backup --host volsync --exclude=lost+found .
printf 'second %s\n' "$TS" >> "$SRC/data/sub/b.txt"
step R4-backup2    0 backup --host volsync --exclude=lost+found .
step R5-snapshots  0 snapshots
step R6-forget     0 forget --host volsync --keep-last 1   # mover do_forget (deletes snapshot objects)
step R6b-prune     0 prune                                  # mover do_prune (repacks + deletes packs)
step R7-check      0 check
step R8-unlock     0 unlock                           # mover runs this every cycle (lock objects)
step R9-restore    0 restore latest -t "$DST" --host volsync
if [ "$(cd "$SRC/data" && sha256sum a.bin sub/b.txt)" = "$(cd "$DST" && sha256sum a.bin sub/b.txt)" ]; then
  PASS=$((PASS+1)); echo "PASS[R10-compare] restored files sha256-identical"
else FAILN=$((FAILN+1)); echo "FAIL[R10-compare] restored content differs"; fi

cd / || exit 2; rm -rf "$SRC" "$DST" "$RESTIC_CACHE_DIR"
echo "VERDICT restic identity=$AWS_ACCESS_KEY_ID pass=$PASS fail=$FAILN"
[ $FAILN -eq 0 ]
