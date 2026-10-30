#!/usr/bin/env bash
# chg-2026-10-20-010 W2c cloud OFF for EVERY family-ai profile (the cut-off action; replaces the land-2 rollback.sh in
# the cut-off, because after W2c a revert of the land-2 deploy commit no longer applies cleanly; Argus C2 class).
#
#   hack/ops/chg-2026-10-20-010-cloud-off.sh --dry-run  <armed-sha> [<ref-containing-it>]
#   hack/ops/chg-2026-10-20-010-cloud-off.sh --execute  <armed-sha> [<reason>]
#
# Same command line, RESULT line and evidence name pattern as chg-2026-10-20-010-rollback.sh, so the reviewed cut-off
# keeps its flow. What it does (execute):
#   1. fresh detached worktree at origin/main (never the caller's tree); in
#      kubernetes/main/apps/family-ai/network-policies/app/kustomization.yaml remove every resource line
#      "- ./hermes-profiel-[123]-cloud.yaml" (nothing else); prove: that is the only changed file, only those lines
#      went, and the rendered network-policies tree has NO CiliumNetworkPolicy that mentions anthropic;
#   2. push to main, flux reconcile family-ai-network-policies (prune: true deletes the cloud CNPs), wait Ready at
#      the pushed revision;
#   3. read back: no hermes-profiel-N-cloud CNP in the cluster; every hermes-profiel-N pod that has HERMES_IMAGE
#      cannot open TCP to api.anthropic.com:443 (default-deny); the shared ledger PVC kept;
#   4. one change-log line.
# Why the network: every cloud call then fails and the router answers on the Studio (fallback, tested:
# hack/family-ai/test_cloud_router_w2c.py); the plugin pins its own client to api.anthropic.com, so there is no other
# path. Bundles (price_confirmed) and keys stay as they are; switching the cloud on again needs a new commit that
# re-adds the CNP lines, i.e. a new go.
# --dry-run does 1 in a scratch worktree on <ref> (default origin/main) plus a server-side dry-run of the edited
# network-policies render; it pushes and writes nothing. Never prints secrets. No rm.
set -euo pipefail
MODE="${1:?--dry-run|--execute}"; SHA="${2:?armed sha}"; ARG3="${3:-}"
case "$MODE" in --dry-run|--execute) ;; *) echo "mode must be --dry-run or --execute" >&2; exit 2;; esac
REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
OPS="$REPO/ops/ops"; NS=family-ai
K=kubernetes/main/apps/family-ai/network-policies/app/kustomization.yaml
TS=$(date -u +%Y%m%dT%H%M%SZ)
CACHE="$HOME/.cache/chg-2026-10-20-010"; WT="$CACHE/wt-$TS-cloudoff-${MODE#--}"
EV="$REPO/ops/evidence/chg-2026-10-20-010/k8s-rollback-$TS-cloudoff-${MODE#--}.txt"
mkdir -p "$CACHE" "$(dirname "$EV")"; [ ! -e "$EV" ] || { echo "evidence file exists" >&2; exit 1; }
log() { echo "$*" | tee -a "$EV"; }
# >>> c010-rev (Flux lastAppliedRevision check; identical in golive.sh and rollback.sh; tested by test-rev.sh)
rev_is() { # $1 = ks .status.lastAppliedRevision, $2 = full 40-hex sha: exactly main@sha1:<sha> or refs/heads/main@sha1:<sha>
  [[ "$2" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "$1" = "main@sha1:$2" ] || [ "$1" = "refs/heads/main@sha1:$2" ]
}
# <<< c010-rev
red=0; chk() { if eval "$2"; then log "  ok   $1"; else log "  RED  $1"; red=1; fi; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
log "chg-2026-10-20-010 cloud-off $MODE $TS armed=$SHA (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"
git -C "$REPO" fetch -q origin
if [ "$MODE" = --execute ]; then BASE=origin/main; REASON="${ARG3:-unspecified}"; else BASE="${ARG3:-origin/main}"; REASON=dry-run; fi
git -C "$REPO" merge-base --is-ancestor "$SHA" "$BASE" || { log "armed $SHA is not in $BASE"; exit 1; }

# 1. edit in a fresh worktree
git -C "$REPO" worktree add -q --detach "$WT" "$BASE"
listed=$(grep -c -E '^  - (\./)?hermes-profiel-[123]-cloud\.yaml( |$)' "$WT/$K" || true)
log "cloud CNP entries listed on $(git -C "$WT" rev-parse --short HEAD): $listed"
if [ "$listed" = 0 ]; then log "nothing to switch off: no cloud CNP listed"; log "RESULT ${MODE#--} GREEN"; exit 0; fi
grep -v -E '^  - (\./)?hermes-profiel-[123]-cloud\.yaml( |$)' "$WT/$K" > "$WT/$K.new"; mv "$WT/$K.new" "$WT/$K"
chk "only $K changed" "[ \"\$(git -C '$WT' diff --name-only)\" = '$K' ]"
chk "only the $listed cloud CNP lines removed, nothing added" "[ \"\$(git -C '$WT' diff --numstat -- '$K')\" = \"\$(printf '0\t%s\t%s' '$listed' '$K')\" ]"
R="$CACHE/render-$TS-cloudoff"; mkdir -p "$R"
kustomize build "$WT/kubernetes/main/apps/family-ai/network-policies/app" > "$R/np.yaml"
chk "rendered network-policies: no CNP mentions anthropic" "! yq -o=json -I=0 'select(.kind == \"CiliumNetworkPolicy\")' '$R/np.yaml' | grep -q anthropic"
chk "rendered network-policies: base hermes CNP still present" "yq -e 'select(.kind == \"CiliumNetworkPolicy\" and .metadata.name == \"hermes\") | .metadata.name' '$R/np.yaml' >/dev/null"
git -C "$WT" add "$K"
git -C "$WT" -c user.name="k8s-engineer" -c user.email="sheijden@vdh-ict.nl" commit -q -F - <<EOF
revert(family-ai): cloud egress OFF for every Hermes profile (chg-2026-10-20-010 cloud-off)

Armed $SHA. Reason: $REASON. Removes the $listed hermes-profiel-N-cloud CNP entries from the network-policies
kustomization (prune deletes them): no profile can reach api.anthropic.com; every cloud call falls back to the
Studio. Spend ledger kept (prune disabled). Switching on again = a new go.

Uitgevoerd onder programmagoedkeuring family-ai. AGR-109: tests are the gate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
REV=$(git -C "$WT" rev-parse HEAD); log "cloud-off commit $REV (local) over $(git -C "$REPO" rev-parse --short "$BASE")"

if [ "$MODE" = --dry-run ]; then
  yq 'select(.kind != "Secret")' "$R/np.yaml" | kubectl apply -n $NS --server-side --dry-run=server --field-manager=kustomize-controller -f - >> "$EV" 2>&1 \
    && log "  ok   server dry-run network-policies" || { log "  RED  server dry-run network-policies"; red=1; }
  log "dry-run: would push $REV to main, reconcile family-ai-network-policies, then read back"
  log "RESULT dry-run $([ $red = 0 ] && echo GREEN || echo RED)"; exit $red
fi

# 2. push + reconcile
git -C "$WT" push -q origin HEAD:main || { git -C "$WT" pull -q --rebase origin main && git -C "$WT" push -q origin HEAD:main; }
PUSHED=$(git -C "$WT" rev-parse HEAD); log "pushed $PUSHED to main"
flux reconcile source git flux-system -n flux-system >/dev/null
flux reconcile ks family-ai-network-policies -n flux-system --timeout=10m >/dev/null || true
chk "ks family-ai-network-policies Ready at $PUSHED" "rev_is \"\$(kubectl -n flux-system get ks family-ai-network-policies -o jsonpath='{.status.lastAppliedRevision}')\" '$PUSHED' && kubectl -n flux-system wait ks/family-ai-network-policies --for=condition=Ready --timeout=5m >/dev/null"
# 3. read back
chk "no hermes-profiel-N-cloud CNP in the cluster" "[ -z \"\$(kubectl -n $NS get cnp -o name | grep -E 'hermes-profiel-[123]-cloud')\" ]"
for n in 1 2 3; do
  P=$(kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$n" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$P" ] || { log "  info p$n: no running pod"; continue; }
  if kubectl -n $NS exec "$P" -c app -- sh -c 'env | cut -d= -f1' | grep -qx HERMES_IMAGE; then
    chk "p$n cannot reach api.anthropic.com:443" "! kubectl -n $NS exec '$P' -c app -- /opt/hermes/.venv/bin/python -c 'import socket; socket.create_connection((\"api.anthropic.com\", 443), timeout=8)' >/dev/null 2>&1"
  fi
done
chk "shared spend ledger PVC kept" "kubectl -n $NS get pvc hermes-cloud-spend-shared >/dev/null 2>&1 || kubectl -n $NS get pvc hermes-profiel-cloud-spend-3 >/dev/null 2>&1"
RES=$([ $red = 0 ] && echo GREEN || echo RED)
log "RESULT execute $RES"
"$OPS" change event chg-2026-10-20-010 executed --actor k8s-engineer --payload-json "$(jq -nc \
  --arg r "$PUSHED" --arg s "$SHA" --arg why "$REASON" --arg res "$RES" --arg ev "${EV#$REPO/}" --arg n "$listed" \
  '{step:"cloud-off (W2c): cloud CNP entries removed for every profile", commit:$r, armed:$s, reason:$why, cnp_entries_removed:$n,
    readback:$res, evidence:$ev, authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
exit $red
