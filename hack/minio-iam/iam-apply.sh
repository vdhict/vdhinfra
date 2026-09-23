#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MinIO IAM: scoped identities for the forge (chg-2026-09-23-002).
#
# WHY THIS EXISTS
#   Until this change MinIO IAM was EMPTY and every S3 consumer authenticated as
#   MinIO root. Root reads every bucket, including s3://cnpg-backups, which holds
#   UNENCRYPTED barman dumps of authelia/lldap/home_assistant/grafana. The forge
#   (devtools ns) becomes CI-reachable at P7, so it gets one named user per bucket
#   and nothing else (Argus sec-01/sec-04 on chg-2026-09-18-002).
#
# WHY IT IS NOT GITOPS
#   MinIO keeps IAM state on its /data backend (/data/.minio.sys/config/iam/ on
#   the Synology NFS export), not in Kubernetes. Flux cannot reconcile it. This
#   script is therefore the source of truth, and it is idempotent: it is run once
#   now and again after any MinIO rebuild from an empty volume (DR runbook §A.4b,
#   hack/disaster-recovery/00-prereqs.sh).
#
# MODES
#   apply  (default) create buckets if absent, create/refresh policies and users,
#          attach exactly one policy per user, verify, print inventory.
#   remove detach + delete the two users and two policies. Buckets are NOT
#          removed unless empty (mc rb without --force), so no backup data can
#          be deleted by a rollback.
#
# CONSTRAINTS (runs in quay.io/minio/mc, which has bash + coreutils but NO
# grep/sed/awk/jq): bash builtins + coreutils + mc only. Must also run on
# macOS bash 3.2 for the local rehearsal, so no bash-4 features.
#
# SECRETS: never echoed. mc output is passed through redact() before printing.
# Exposures, all inside this single-use pod: argv of `mc admin user add`, and
# mc's config.json in $MC_CONFIG_DIR (memory-backed volume mounted in this
# container only; deleted by the EXIT trap).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MODE="${1:-apply}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.storage.svc.cluster.local:9000}"
POLICY_DIR="${POLICY_DIR:-/iam}"
export MC_CONFIG_DIR="${MC_CONFIG_DIR:-/tmp/mc}"
export MC_NO_COLOR=1
A=root

# identity table: policy-name bucket env-prefix expected-access-key
IDENTITIES="forge-backups-rw:forge-backups:FORGE_PG:forge-pg forge-volsync-rw:forge-volsync:FORGE_VOLSYNC:forge-volsync"

fail() { echo "FATAL: $*"; exit 2; }

redact() {
  local s="$1" v
  for v in MINIO_ROOT_PASSWORD FORGE_PG_SECRET_KEY FORGE_VOLSYNC_SECRET_KEY; do
    if [ -n "${!v:-}" ]; then s="${s//"${!v}"/<redacted:$v>}"; fi
  done
  printf '%s\n' "$s"
}

# ── input guards ────────────────────────────────────────────────────────────
[ -n "${MINIO_ROOT_USER:-}" ] || fail "MINIO_ROOT_USER empty"
[ -n "${MINIO_ROOT_PASSWORD:-}" ] || fail "MINIO_ROOT_PASSWORD empty"
if [ "$MODE" = "apply" ]; then
  for id in $IDENTITIES; do
    IFS=: read -r pol bucket pfx expect <<<"$id"
    ak_var="${pfx}_ACCESS_KEY"; sk_var="${pfx}_SECRET_KEY"
    ak="${!ak_var:-}"; sk="${!sk_var:-}"
    [ -n "$ak" ] || fail "$ak_var empty (1Password item missing or label wrong?)"
    [ -n "$sk" ] || fail "$sk_var empty (1Password item missing or label wrong?)"
    # Catches two 1Password items swapped, or a copy-paste of the same value.
    [ "$ak" = "$expect" ] || fail "$ak_var is '$ak', expected '$expect' - items swapped or mislabelled?"
    [ "$ak" != "$MINIO_ROOT_USER" ] || fail "$ak_var equals the root user"
    case "$sk" in *[!A-Za-z0-9]*) fail "$sk_var must be alphanumeric only";; esac
    # MinIO accepts 8..40; we require the top of that range.
    [ "${#sk}" -ge 32 ] && [ "${#sk}" -le 40 ] || fail "$sk_var length ${#sk} outside 32..40"
    [ "$sk" != "$MINIO_ROOT_PASSWORD" ] || fail "$sk_var equals the root password"
    [ -r "$POLICY_DIR/$pol.json" ] || fail "policy file $POLICY_DIR/$pol.json not readable"
  done
  [ "$FORGE_PG_SECRET_KEY" != "$FORGE_VOLSYNC_SECRET_KEY" ] || fail "both scoped users share one secret"
fi

mkdir -p "$MC_CONFIG_DIR"
# mc persists the alias - i.e. the ROOT password - in plaintext in
# $MC_CONFIG_DIR/config.json(.old). Remove it on every exit path (Argus sec-A1).
trap 'rm -rf "$MC_CONFIG_DIR"' EXIT
mc alias set "$A" "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null \
  || fail "cannot set root alias"

run() { # run and print (redacted); return mc's rc
  local out rc=0
  out=$(mc --json "$@" 2>&1) || rc=$?
  redact "  \$ mc $* -> rc=$rc $out" >&2
  return $rc
}

inventory() {
  echo "── IAM inventory ($1) ──"
  local out
  out=$(mc --json admin user list "$A" 2>&1) || true
  if [ -z "$out" ]; then echo "  users: (none)"; else redact "$out" | while IFS= read -r l; do echo "  user: $l"; done; fi
  out=$(mc --json admin policy list "$A" 2>&1) || true
  redact "$out" | while IFS= read -r l; do echo "  policy: $l"; done
}

server_info() {
  local out
  out=$(mc --json admin info "$A" 2>&1) || fail "root alias cannot reach admin API"
  case "$out" in *'"status":"success"'*) echo "── server reachable as root (admin info ok) ──";; *) fail "admin info not success";; esac
}

# ── apply ───────────────────────────────────────────────────────────────────
do_apply() {
  server_info
  inventory before
  for id in $IDENTITIES; do
    IFS=: read -r pol bucket pfx expect <<<"$id"
    ak_var="${pfx}_ACCESS_KEY"; sk_var="${pfx}_SECRET_KEY"
    ak="${!ak_var}"; sk="${!sk_var}"
    echo "── identity $ak -> policy $pol -> bucket $bucket ──"

    # Bucket pre-created with root so the scoped user needs no s3:CreateBucket.
    run mb --ignore-existing "$A/$bucket" >/dev/null || fail "mb $bucket"

    # policy create overwrites an existing policy of the same name (idempotent).
    run admin policy create "$A" "$pol" "$POLICY_DIR/$pol.json" >/dev/null || fail "policy create $pol"

    # user add on an existing user resets its secret to the 1P value (idempotent).
    mc admin user add "$A" "$ak" "$sk" >/dev/null 2>&1 || fail "user add $ak"
    echo "  user $ak present (secret set from 1Password, not printed)"

    info=$(mc --json admin user info "$A" "$ak" 2>&1) || fail "user info $ak"
    case "$info" in
      *"\"policyName\":\"$pol\""*) echo "  policy $pol already attached - no change";;
      *'"policyName":"'*) fail "$ak already carries a DIFFERENT policy set - refusing to guess, fix by hand: $(redact "$info")";;
      *) run admin policy attach "$A" "$pol" --user "$ak" >/dev/null || fail "attach $pol to $ak";;
    esac

    # Post-condition: exactly this one policy, user enabled. Exact-match on the
    # quoted value, so "a,b" multi-policy strings fail.
    info=$(mc --json admin user info "$A" "$ak" 2>&1) || fail "user info $ak"
    case "$info" in *"\"policyName\":\"$pol\""*) ;; *) fail "post-check: $ak policy is not exactly $pol: $(redact "$info")";; esac
    case "$info" in *'"userStatus":"enabled"'*) ;; *) fail "post-check: $ak not enabled";; esac
    echo "  POSTCHECK OK: $ak policyName=$pol userStatus=enabled"
  done
  inventory after
  echo "APPLY: OK"
}

# ── remove (rollback) ───────────────────────────────────────────────────────
do_remove() {
  server_info
  inventory before
  for id in $IDENTITIES; do
    IFS=: read -r pol bucket pfx expect <<<"$id"
    ak="$expect"
    echo "── removing $ak / $pol ──"
    run admin policy detach "$A" "$pol" --user "$ak" >/dev/null || echo "  (detach: not attached or user absent)"
    run admin user remove "$A" "$ak" >/dev/null || echo "  (user absent)"
    run admin policy remove "$A" "$pol" >/dev/null || echo "  (policy absent)"
  done
  # forge-volsync was created by this change; remove it ONLY if empty.
  # forge-backups pre-dates this change (created 2026-09-20) and is left alone.
  run rb "$A/forge-volsync" >/dev/null || echo "  forge-volsync NOT removed (absent or not empty - by design)"
  inventory after
  echo "REMOVE: OK"
}

case "$MODE" in
  apply) do_apply ;;
  remove) do_remove ;;
  *) fail "usage: $0 [apply|remove]" ;;
esac
