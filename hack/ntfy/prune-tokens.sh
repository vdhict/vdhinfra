#!/usr/bin/env bash
# ntfy token prune + rotation step (chg-2026-10-13-005, Argus F1).
#
# The ntfy account API lets any authenticated user mint extra tokens
# (POST /v1/account/token). Envoy blocks /v1/account* on the route, but the
# in-cluster path (Alertmanager -> Service) bypasses Envoy, and startup
# provisioning removes only PROVISIONED tokens. This script deletes every
# token that is NOT provisioned from the ntfy-auth Secret ("(server config)"
# in `ntfy token list`).
#
# Never prints a token value: only per-user counts.
#
# Usage:
#   hack/ntfy/prune-tokens.sh            dry run: count provisioned / extra tokens
#   hack/ntfy/prune-tokens.sh --apply    remove the extra tokens, then re-count
#
# Rotation (a token leaked or a sender is retired):
#   1. regenerate the user's token in kubernetes/main/apps/ntfy/ntfy/app/secret.sops.yaml
#      (`sops` edit; token = tk_ + 29 chars [A-Za-z0-9]), commit, push to main;
#   2. reloader restarts ntfy on the Secret change; the start-up sync drops the
#      old provisioned token and adds the new one;
#   3. run this script with --apply to drop any non-provisioned extras;
#   4. hand the new token to the sender (never paste it in a chat or log).
set -euo pipefail
NS=ntfy
MODE="${1:-dry-run}"
[ "$MODE" = "dry-run" ] || [ "$MODE" = "--apply" ] || { echo "usage: $0 [--apply]" >&2; exit 2; }

list() { kubectl -n "$NS" exec deploy/ntfy -c app -- ntfy token list 2>/dev/null; }

# Parse `ntfy token list`: "user NAME" headers, then "- tk_... ... (server config)?" lines.
# Emits "NAME<TAB>TOKEN<TAB>p|x" on stdout of the parser only; never echoed.
parse() {
  awk '
    /^user / { u=$2; next }
    /^- tk_/ { t=$2; sub(/,$/, "", t); p = ($0 ~ /\(server config\)$/) ? "p" : "x"; print u "\t" t "\t" p }
  '
}

summary() {
  awk -F'\t' '{ n[$1 FS $3]++ } END { for (k in n) { split(k, a, FS); printf "  %-14s %s %d\n", a[1], (a[2]=="p" ? "provisioned" : "EXTRA      "), n[k] } }' | sort
}

ROWS="$(list | parse)"
echo "ntfy tokens before ($MODE):"
printf '%s\n' "$ROWS" | grep -v '^$' | summary || true
EXTRA="$(printf '%s\n' "$ROWS" | awk -F'\t' '$3=="x"' | grep -c . || true)"
echo "extra (non-provisioned) tokens: $EXTRA"

if [ "$MODE" = "--apply" ] && [ "$EXTRA" -gt 0 ]; then
  printf '%s\n' "$ROWS" | awk -F'\t' '$3=="x" { print $1 "\t" $2 }' | while IFS=$'\t' read -r u t; do
    kubectl -n "$NS" exec deploy/ntfy -c app -- ntfy token remove "$u" "$t" >/dev/null 2>&1 \
      && echo "  removed 1 extra token of user $u" || echo "  FAILED to remove an extra token of user $u"
  done
  echo "ntfy tokens after:"
  list | parse | summary || true
fi
