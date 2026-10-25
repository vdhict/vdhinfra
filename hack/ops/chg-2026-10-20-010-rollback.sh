#!/usr/bin/env bash
# chg-2026-10-20-010 land 2 rollback (Argus C8 / K6): cloud OFF for hermes-profiel-3.
#
#   hack/ops/chg-2026-10-20-010-rollback.sh --dry-run  <deploy-sha> [<ref-containing-it>]
#   hack/ops/chg-2026-10-20-010-rollback.sh --execute  <deploy-sha> [<reason>]
#
# What it does (execute):
#   1. git revert <deploy-sha> on top of origin/main in a fresh detached worktree (never the caller's tree),
#      and proves the reverted family-ai renders are byte-identical to <deploy-sha>^ (the pre-deploy state);
#   2. family-ai repo: content/cloudmodel.json price_confirmed -> false as a local commit on
#      land2-cloud-v0225 (the branch the deployed render comes from), so no later render can switch the cloud on without a new owner-confirmed commit;
#   3. push the revert to main, flux reconcile family-ai-network-policies + family-ai-hermes, wait Ready
#      at the pushed revision;
#   4. read back: CNP hermes-profiel-3-cloud gone; profiel-3 pod Ready, no family-cloud plugin dir, no
#      CLOUD_API_KEY / HERMES_IMAGE env (names only), seeded bundle = the pre-deploy outer sha256;
#      profiel-1/2 pods untouched (same uid as before) and without family-cloud/CLOUD env (K7);
#   5. one change-log line (ops change event executed).
# The spend PVC hermes-profiel-cloud-spend-3 is kept (prune disabled): it holds this month's total.
# --dry-run does 1, 2 (in a scratch clone, no commit in the real repo) and the read-only half of 4 plus a
# server-side dry-run of the reverted manifests; it pushes, reconciles and writes nothing.
# Never prints secret values (env NAMES only). No rm: worktrees stay under ~/.cache/chg-2026-10-20-010/.
set -euo pipefail
MODE="${1:?--dry-run|--execute}"; SHA="${2:?deploy sha}"; ARG3="${3:-}"
case "$MODE" in --dry-run|--execute) ;; *) echo "mode must be --dry-run or --execute" >&2; exit 2;; esac
REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
FAI="${FAMILY_AI_REPO:-/Users/sheijden/Code/pka-wires/family-ai-familie-2026-10-19}"
FAI_BRANCH=land2-cloud-v0225
OPS="$REPO/ops/ops"
NS=family-ai
PRE_OUTER=fe64b2a128258e45d23c70b1cb642ceae1750ce901891f59b667cc3e860274f2   # live p3 bundle before land 2 (F4, main 1014ab1a)
TS=$(date -u +%Y%m%dT%H%M%SZ)
CACHE="$HOME/.cache/chg-2026-10-20-010"; WT="$CACHE/wt-$TS-rollback-${MODE#--}"
EV="$REPO/ops/evidence/chg-2026-10-20-010/k8s-rollback-$TS-${MODE#--}.txt"
mkdir -p "$CACHE"; [ ! -e "$EV" ] || { echo "evidence file exists" >&2; exit 1; }
log() { echo "$*" | tee -a "$EV"; }
red=0; chk() { if eval "$2"; then log "  ok   $1"; else log "  RED  $1"; red=1; fi; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
log "chg-2026-10-20-010 rollback $MODE $TS deploy=$SHA (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"

git -C "$REPO" fetch -q origin
if [ "$MODE" = --execute ]; then BASE=origin/main; REASON="${ARG3:-unspecified}"; else BASE="${ARG3:-origin/main}"; REASON=dry-run; fi
git -C "$REPO" merge-base --is-ancestor "$SHA" "$BASE" || { log "deploy $SHA is not in $BASE"; exit 1; }

# 1. revert in a fresh worktree + prove it equals the pre-deploy tree for every path the deploy touched
git -C "$REPO" worktree add -q --detach "$WT" "$BASE"
git -C "$WT" -c user.name="k8s-engineer" -c user.email="sheijden@vdh-ict.nl" revert --no-edit "$SHA" >/dev/null
git -C "$WT" commit -q --amend -F - <<EOF
revert(family-ai): land 2 cloud canary off for hermes-profiel-3 (chg-2026-10-20-010 rollback)

Reverts $SHA. Reason: $REASON. Argus C8/K6: cloud off (no family-cloud plugin, no CNP, no key);
spend PVC kept (prune disabled).

Uitgevoerd onder programmagoedkeuring family-ai. AGR-109: tests are the gate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
REV=$(git -C "$WT" rev-parse HEAD)
paths=$(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$SHA")
log "revert commit $REV (local) over $(git -C "$REPO" rev-parse --short "$BASE"); paths in deploy: $(echo "$paths" | wc -l | tr -d ' ')"
chk "revert restores every deploy path to $SHA^" "git -C '$WT' diff --quiet '$SHA^' HEAD -- $(echo $paths)"
R="$CACHE/render-$TS"; mkdir -p "$R/pre" "$R/rev"
git -C "$REPO" archive "$SHA^" kubernetes/main/apps/family-ai | tar -x -C "$R/pre"
for t in hermes network-policies/app open-webui/app gezinsdienst/app kennisdienst/app; do
  n=$(echo "$t" | tr / _)
  kustomize build "$R/pre/kubernetes/main/apps/family-ai/$t" > "$R/pre/$n.yaml"
  kustomize build "$WT/kubernetes/main/apps/family-ai/$t" > "$R/rev/$n.yaml"
  chk "render $t after revert == pre-deploy" "cmp -s '$R/pre/$n.yaml' '$R/rev/$n.yaml'"
done

# 2. price_confirmed=false in family-ai (dry-run: scratch clone, no commit in the real repo)
if [ "$MODE" = --execute ]; then F="$FAI"; else F="$CACHE/fai-$TS"; git clone -q --branch "$FAI_BRANCH" "$FAI" "$F"; fi
[ "$(git -C "$F" rev-parse --abbrev-ref HEAD)" = "$FAI_BRANCH" ] || { log "family-ai repo is not on $FAI_BRANCH"; exit 1; }
[ -z "$(git -C "$F" status --porcelain -- content/cloudmodel.json)" ] || { log "family-ai cloudmodel.json has local edits"; exit 1; }
n_true=$(grep -c '"price_confirmed": true' "$F/content/cloudmodel.json" || true)
if [ "$n_true" = 1 ]; then
  sed -i '' 's/"price_confirmed": true/"price_confirmed": false/' "$F/content/cloudmodel.json"
  chk "family-ai price_confirmed now false (exactly one line changed)" \
    "[ \"\$(git -C '$F' diff --numstat -- content/cloudmodel.json)\" = \"\$(printf '1\t1\tcontent/cloudmodel.json')\" ] && grep -q '\"price_confirmed\": false' '$F/content/cloudmodel.json'"
  git -C "$F" -c user.name="k8s-engineer" -c user.email="sheijden@vdh-ict.nl" commit -q -m "cloudmodel: price_confirmed=false after chg-2026-10-20-010 rollback ($REASON)

Argus C8/K6. Switching the cloud on again needs a new owner-confirmed commit and re-review.

Uitgevoerd onder programmagoedkeuring family-ai. AGR-109: tests are the gate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- content/cloudmodel.json
  log "family-ai: price_confirmed=false committed $(git -C "$F" rev-parse --short HEAD) on $FAI_BRANCH ($([ "$MODE" = --execute ] && echo real repo || echo scratch clone $F))"
else
  log "family-ai: price_confirmed already not true (count true=$n_true), nothing to change"
fi

# 3. state before (read-only)
uid() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" -o jsonpath='{.items[0].metadata.uid}'; }
U1=$(uid 1); U2=$(uid 2)
log "before: p1 uid ${U1:0:8} p2 uid ${U2:0:8}; cloud CNP present: $(kubectl -n $NS get cnp hermes-profiel-3-cloud -o name 2>/dev/null | wc -l | tr -d ' ')"

if [ "$MODE" = --dry-run ]; then
  log "dry-run: server-side dry-run of the reverted manifests (no bundle Secrets: SOPS)"
  for n in hermes network-policies_app; do
    yq 'select(.kind != "Secret" or (.metadata.name | test("bundle") | not))' "$R/rev/$n.yaml" |
      kubectl apply -n $NS --server-side --dry-run=server --field-manager=kustomize-controller -f - >> "$EV" 2>&1 \
      && log "  ok   server dry-run $n" || { log "  RED  server dry-run $n"; red=1; }
  done
  log "dry-run: would push $REV to main, reconcile family-ai-network-policies + family-ai-hermes, then read back"
  log "RESULT dry-run $([ $red = 0 ] && echo GREEN || echo RED)"; exit $red
fi

# 4. execute: push, reconcile, read back
git -C "$WT" push -q origin HEAD:main || { git -C "$WT" pull -q --rebase origin main && git -C "$WT" push -q origin HEAD:main; }
PUSHED=$(git -C "$WT" rev-parse HEAD); log "pushed $PUSHED to main"
flux reconcile source git flux-system -n flux-system >/dev/null
for ks in family-ai-network-policies family-ai-hermes; do
  flux reconcile ks "$ks" -n flux-system --timeout=10m >/dev/null || true
  chk "ks $ks Ready at $PUSHED" "[ \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')\" = 'main@sha1:$PUSHED' ] && kubectl -n flux-system wait ks/$ks --for=condition=Ready --timeout=5m >/dev/null"
done
kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=10m >/dev/null || true
P3=$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-3 --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
chk "CNP hermes-profiel-3-cloud gone" "! kubectl -n $NS get cnp hermes-profiel-3-cloud >/dev/null 2>&1"
chk "p3 pod Ready" "kubectl -n $NS wait pod/$P3 --for=condition=Ready --timeout=5m >/dev/null"
chk "p3 has no family-cloud plugin dir" "! kubectl -n $NS exec $P3 -c app -- test -e /opt/data/plugins/model-providers/family-cloud"
chk "p3 env has no CLOUD_API_KEY / HERMES_IMAGE (names only)" "! kubectl -n $NS exec $P3 -c app -- sh -c 'env | cut -d= -f1' | grep -qx 'CLOUD_API_KEY\|HERMES_IMAGE'"
chk "p3 Secret has no CLOUD_API_KEY key" "! kubectl -n $NS get secret family-ai-hermes-profiel-3 -o jsonpath='{.data}' | jq -e 'has(\"CLOUD_API_KEY\")' >/dev/null"
chk "p3 seeded bundle = pre-deploy $PRE_OUTER" "[ \"\$(kubectl -n $NS exec $P3 -c app -- cat /opt/data/.family-ai-seeded)\" = '$PRE_OUTER' ]"
chk "p1 pod untouched" "[ \"\$(uid 1)\" = '$U1' ]"
chk "p2 pod untouched" "[ \"\$(uid 2)\" = '$U2' ]"
for n in 1 2; do
  Pn=$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-$n -o jsonpath='{.items[0].metadata.name}')
  chk "K7 p$n no family-cloud dir, no CLOUD env" "! kubectl -n $NS exec $Pn -c app -- test -e /opt/data/plugins/model-providers/family-cloud && ! kubectl -n $NS exec $Pn -c app -- sh -c 'env | cut -d= -f1' | grep -q '^CLOUD_'"
done
chk "spend PVC kept" "kubectl -n $NS get pvc hermes-profiel-cloud-spend-3 >/dev/null"
RES=$([ $red = 0 ] && echo GREEN || echo RED)
log "RESULT execute $RES"
"$OPS" change event chg-2026-10-20-010 executed --actor k8s-engineer --payload-json "$(jq -nc \
  --arg r "$REV" --arg s "$SHA" --arg why "$REASON" --arg res "$RES" --arg ev "${EV#$REPO/}" \
  '{step:"rollback land 2 (C8/K6): git revert + Flux + price_confirmed=false", revert:$r, reverted:$s, reason:$why,
    readback:$res, evidence:$ev, authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
exit $red
