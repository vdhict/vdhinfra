#!/usr/bin/env bash
# chg-2026-10-20-010 W2c GO, one STAGE per run (owner 30-10: one build, one test round, one go for profiel-2 + profiel-1,
# canary + automatic revert per profile; Argus 30-10 M1-M4, K7). Run from a worktree whose HEAD is the stage commit:
#
#   hack/ops/chg-2026-10-20-010-golive-w2c.sh --preflight <stage> <sha>
#   hack/ops/chg-2026-10-20-010-golive-w2c.sh --go        <stage> <sha> --w2-event <ts>
#
# Stages, pushed strictly in this order, each a fast-forward of origin/main by exactly one commit:
#   A   profiel-3 onto the shared ledger (guard moves its total once), interim budget_usd 99 in its bundle.
#       No cloud turn. RED -> revert A, then cloud-off (all cloud CNPs out: profiel-3 to the Studio).
#   B1  profiel-2 wired (key, HERMES_IMAGE, bundle with family-cloud, shared ledger) but NO egress (no CNP):
#       live FALLBACK turn (M3: cloud unreachable -> the Studio answers, exactly one cloud_failed, no retry; the
#       ledger holds exactly one reservation). RED -> revert B1.
#   B2  hermes-profiel-2-cloud CNP: W3 egress checks, ONE real cloud turn (M4: one logged cloud call checked against the
#       ledger), private turns vergeet/image (+ next turn) Studio-only (F6/F1), F2. RED -> revert B2 and B1.
#   C1, C2  the same for profiel-1 (adult); C2's cloud turn is a web question: the cloud call is admitted and the web
#       tool result goes on the Studio (studio/private_context after cloud_ok in the same turn).
# Every stage: W2 gate (golive.sh --gate-only, accepts the pinned 27-10 baseline, M1), wiring check for the stage,
# snapshots first, App token per push, Flux at the pushed sha, read-back, exit guard -> revert on any other end.
# Real cloud turns in the whole go: B2 1 + C2 1 (+ 1 spare, unused unless a stage is retried). Synthetic only: one
# temporary local OWUI account c010-canary-<n>@acceptatie.invalid in owui-profiel-<n>, deleted at the end. Answers
# are discarded unread (metadata only). Never prints a token or key. No rm. Evidence write-once.
set -uo pipefail
MODE="${1:?--preflight|--go}"; STAGE="${2:?stage A|B1|B2|C1|C2}"; SHA="${3:?stage sha}"; shift 3 || true
W2TS=""; [ "${1:-}" = --w2-event ] && W2TS="${2:-}"
case "$MODE" in --preflight|--go) ;; *) echo "mode must be --preflight or --go" >&2; exit 2;; esac
case "$STAGE" in A) PROF=3; CLOUDSET=3; EGOFF="";; B1) PROF=2; CLOUDSET=2,3; EGOFF=2;; B2) PROF=2; CLOUDSET=2,3; EGOFF="";;
  C1) PROF=1; CLOUDSET=1,2,3; EGOFF=1;; C2) PROF=1; CLOUDSET=1,2,3; EGOFF="";; *) echo "stage must be A, B1, B2, C1 or C2" >&2; exit 2;; esac
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "sha must be 40 hex" >&2; exit 2; }
CHG=chg-2026-10-20-010; NS=family-ai
SRC="$(git rev-parse --show-toplevel)"; HACK="$SRC/hack"; REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
TS=$(date -u +%Y%m%dT%H%M%SZ); RUN_ID="$TS-$STAGE-$$"
CACHE="$HOME/.cache/$CHG/golive-w2c-$TS-$STAGE"; mkdir -p "$CACHE"; chmod 700 "$CACHE"; : > "$CACHE/run-start"
EV="$REPO/ops/evidence/$CHG/k8s-golive-w2c-$TS-$STAGE-${MODE#--}.txt"; [ ! -e "$EV" ] || { echo "evidence exists" >&2; exit 1; }
log() { echo "$*" | tee -a "$EV"; }
RED=0; PUSHED=""; PUSH_E=""; OWUI_ADMIN_KEY=""; C4STATE=""
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
GL="$HACK/ops/$CHG-golive.sh"
blk() { sed -n "/^# >>> $1 /,/^# <<< $1\$/p" "$GL"; }   # the reviewed blocks, sourced as-is (as the tests do)
for b in c010-rev c010-chk c010-auth c010-exitguard; do eval "$(blk $b)"; done
# Stage rollback replaces golive's land-2 rollback_core (that one runs rollback.sh for profiel-3 only).
rollback_core() {
  ROLLED_BACK=1; log "ROLLBACK ($STAGE): $1"
  local w="$HOME/.cache/$CHG/wt-$TS-$STAGE-revert" revs="$SHA"
  [ "$STAGE" = B2 ] && revs="$SHA $(git -C "$SRC" rev-parse "$SHA^")"   # B2 red: the CNP and the B1 wiring
  [ "$STAGE" = C2 ] && revs="$SHA $(git -C "$SRC" rev-parse "$SHA^")"
  git -C "$REPO" fetch -q origin; git -C "$REPO" worktree add -q --detach "$w" origin/main
  local r; for r in $revs; do git -C "$w" -c user.name=k8s-engineer -c user.email=sheijden@vdh-ict.nl revert --no-edit "$r" >/dev/null || log "  RED  revert $r failed"; done
  fresh_token "rollback push" || log "  RED  rollback push continues with the caller's credential (if any)"
  git -C "$w" push -q origin HEAD:main && log "  ok   revert pushed $(git -C "$w" rev-parse HEAD)" || log "  RED  revert push failed"
  local rv; rv=$(git -C "$w" rev-parse HEAD)
  flux reconcile source git flux-system -n flux-system >/dev/null 2>&1
  for ks in family-ai-network-policies family-ai-hermes; do flux reconcile ks $ks -n flux-system --timeout=10m >/dev/null 2>&1
    rev_is "$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')" "$rv" && log "  ok   ks $ks at the revert" || log "  RED  ks $ks not at the revert"; done
  revoke_token "rollback push"
  if [ "$STAGE" = A ]; then   # revert alone would bring back budget 200 + the stale per-profile ledger: cloud off for p3
    fresh_token "cloud-off push" && bash "$HACK/ops/$CHG-cloud-off.sh" --execute "$rv" "W2c stage A red: $1" | tee -a "$EV"; revoke_token "cloud-off push"
  fi
  [ -n "${CLEANUP_HOOK:-}" ] && "$CLEANUP_HOOK"; CLEANUP_HOOK=""
}
gate() { [ "$RED" = 0 ] || { if [ -n "$PUSHED" ]; then rollback_core "$1"; log "RESULT go RED at $1 -> reverted"; exit 1; else log "RESULT ${MODE#--} RED at $1 (nothing pushed)"; exit 1; fi; }; }
pod() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
xp() { kubectl -n $NS exec "$1" -c app -- "${@:2}"; }
envnames() { xp "$1" sh -c 'env | cut -d= -f1'; }
tcp() { xp "$1" /opt/hermes/.venv/bin/python -c "import socket; socket.create_connection(('$2', $3), timeout=8)" >/dev/null 2>&1; }
ledger() { xp "$(pod "$PROF")" cat /cloud-spend/month.json; }
spend() { xp "$(pod "$PROF")" sha256sum /cloud-spend/month.json | cut -c1-64; }
num() { /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); k=sys.argv[1].split("."); v=d[k[0]] if len(k)==1 else d[k[0]][k[1]]; print(repr(float(v)))' "$1"; }
uid() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" -o jsonpath='{.items[0].metadata.uid}'; }
log "$CHG W2c go ${MODE#--} stage $STAGE profiel-$PROF $TS sha=$SHA (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"

# ---------------------------------------------------------------- 0. gates before anything (read-only)
git -C "$REPO" fetch -q origin
chk "worktree HEAD is the stage commit" "[ \"\$(git -C '$SRC' rev-parse HEAD)\" = '$SHA' ] && [ -z \"\$(git -C '$SRC' status --porcelain)\" ]"
chk "stage = a fast-forward of origin/main by exactly this one commit" "[ \"\$(git -C '$SRC' rev-parse '$SHA^')\" = \"\$(git -C '$REPO' rev-parse origin/main)\" ]"
chk "wiring check for stage $STAGE (cloud=$CLOUDSET${EGOFF:+ egress-off=$EGOFF}) + mutation self-test" \
  "cd '$SRC' && python3 -I hack/family-ai/check-cloud-wiring.py --cloud $CLOUDSET ${EGOFF:+--egress-off $EGOFF} --self-test | tail -1 | grep -q '^PASS self-test'"
chk "shared ledger guard tests" "cd '$SRC' && python3 -I hack/family-ai/test_cloud_spend_shared.py >/dev/null 2>&1"
chk "server-side dry-run of hermes + network-policies (no Secrets)" "cd '$SRC' && for t in hermes network-policies/app; do kustomize build kubernetes/main/apps/family-ai/\$t | yq 'select(.kind != \"Secret\")' | kubectl apply -n $NS --dry-run=server -f - >/dev/null || exit 1; done"
chk "profiel-$PROF and OWUI pods Running" "[ -n \"\$(pod $PROF)\" ] && kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui --field-selector=status.phase=Running -o name | grep -q ."
if [ "$MODE" = --go ]; then
  [ -n "$W2TS" ] || { log "REFUSED: --w2-event missing"; exit 2; }
  GOUT=$(cd "$SRC" && bash "$GL" --gate-only "$SHA" --w2-event "$W2TS" 2>&1); GRC=$?
  log "  info $(printf '%s\n' "$GOUT" | grep -E 'W2 gate:|REFUSED' | tail -1)"
  chk "W2 gate GREEN for this stage's bundles (baseline M1 allowed; one budget for every cloud bundle)" "[ $GRC = 0 ]"
fi
gate "pre-checks"
[ "$MODE" = --preflight ] && { log "RESULT preflight GREEN (stage $STAGE; nothing written)"; exit 0; }

# ---------------------------------------------------------------- 1. snapshots, then push
log "== snapshots"
SNAPS="hermes-profiel-data-$PROF open-webui-data"; [ "$STAGE" = A ] && SNAPS="$SNAPS hermes-profiel-cloud-spend-3"
kubectl -n $NS get pvc hermes-cloud-spend-shared >/dev/null 2>&1 && SNAPS="$SNAPS hermes-cloud-spend-shared"
for p in $SNAPS; do
  n="c010-w2c-$(echo "$TS-$STAGE" | tr 'A-Z' 'a-z')-$p"
  cls=csi-ceph-blockpool; [ "$p" = hermes-cloud-spend-shared ] && cls=csi-ceph-filesystem
  printf 'apiVersion: snapshot.storage.k8s.io/v1\nkind: VolumeSnapshot\nmetadata: {name: %s, namespace: %s}\nspec: {volumeSnapshotClassName: %s, source: {persistentVolumeClaimName: %s}}\n' "$n" "$NS" "$cls" "$p" | kubectl apply -f - >/dev/null
  chk "snapshot $n readyToUse" "kubectl -n $NS wait volumesnapshot/$n --for=jsonpath='{.status.readyToUse}'=true --timeout=5m >/dev/null"
done
gate "snapshots"
U1=$(uid 1); U2=$(uid 2); U3=$(uid 3)
L0=""; [ "$STAGE" != A ] && L0=$(ledger)
fresh_token "deploy push" && git -C "$SRC" push -q origin "$SHA:main"; PRC=$?; revoke_token "deploy push"
[ $PRC = 0 ] || { log "RESULT go RED: push failed (nothing pushed)"; exit 1; }
PUSHED=$SHA; PUSH_E=$(date +%s); log "  ok   pushed $SHA to main"
flux reconcile source git flux-system -n flux-system >/dev/null 2>&1
for ks in family-ai-network-policies family-ai-hermes; do flux reconcile ks $ks -n flux-system --timeout=10m >/dev/null 2>&1
  chk "ks $ks Ready at $SHA" "rev_is \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')\" '$SHA' && kubectl -n flux-system wait ks/$ks --for=condition=Ready --timeout=5m >/dev/null"; done
chk "profiel-$PROF rollout complete" "kubectl -n $NS rollout status deploy/hermes-profiel-$PROF --timeout=10m >/dev/null"
gate "flux"
PP=$(pod "$PROF")
for n in 1 2 3; do [ $n = $PROF ] && continue; chk "profiel-$n pod untouched" "[ \"\$(uid $n)\" = \"\$U$n\" ]"; done

# ---------------------------------------------------------------- 2. read-back per stage
SET=/opt/data/plugins/model-providers/family-cloud/settings.json
if [ "$STAGE" = A ] || [ "$STAGE" = B1 ] || [ "$STAGE" = C1 ]; then
  chk "C3/W5 HERMES_IMAGE == pod image" "[ \"\$(xp $PP printenv HERMES_IMAGE)\" = \"\$(kubectl -n $NS get pod $PP -o jsonpath='{.spec.containers[?(@.name==\"app\")].image}')\" ]"
  chk "W4 Secret has CLOUD_API_KEY, length >= 47 (value not read out)" "[ \"\$(kubectl -n $NS get secret family-ai-hermes-profiel-$PROF -o json | jq -r '.data.CLOUD_API_KEY // \"\"' | base64 -d | wc -c | tr -d ' ')\" -ge 47 ]"
  chk "W4 init containers: no envFrom / secret env" "[ \"\$(kubectl -n $NS get pod $PP -o json | jq '[.spec.initContainers[] | select(.envFrom or ([.env[]?.valueFrom.secretKeyRef] | length > 0))] | length')\" = 0 ]"
  chk "pod settings: budget_usd 99, price_confirmed true, person profiel-$PROF (numbers only)" "[ \"\$(xp $PP cat $SET | jq -c '[.budget_usd, .price_confirmed, .person]')\" = '[99,true,\"profiel-$PROF\"]' ]"
  chk "W2c shared ledger mounted, numbers-only schema" "ledger | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert set(d)=={\"month\",\"usd\",\"input_tokens\",\"output_tokens\",\"cache_read_tokens\",\"cache_write_tokens\",\"person_usd\"} and set(d[\"person_usd\"])=={\"profiel-1\",\"profiel-2\",\"profiel-3\"}'"
  chk "W2c seed present (source migrated)" "xp $PP cat /cloud-spend/.ledger-seeded | jq -e '.source == \"migrated\"' >/dev/null"
fi
if [ "$STAGE" = A ]; then
  GL0=$(kubectl -n $NS logs "$PP" -c cloud-spend-init 2>/dev/null); log "  info guard: $(printf '%s' "$GL0" | tr -d '\n' | cut -c1-200)"
  chk "W2c guard moved profiel-3's ledger on this first start (no refusal)" "grep -q 'moved: month.json' <<< \"\$GL0\" && ! grep -q REFUSED <<< \"\$GL0\""
  chk "W2c moved total == seed total (numbers only)" "[ \"\$(ledger | num usd)\" = \"\$(xp $PP cat /cloud-spend/.ledger-seeded | num usd)\" ]"
  chk "W3 hermes-profiel-3-cloud unchanged and still the only cloud CNP" "[ \"\$(kubectl -n $NS get cnp -o name | grep -c -- '-cloud\$')\" = 1 ] && tcp $PP api.anthropic.com 443"
  MJ=$(spend); kubectl -n $NS rollout restart deploy/hermes-profiel-3 >/dev/null
  chk "p3 restart rollout" "kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=10m >/dev/null"; PP=$(pod 3)
  chk "W2c second start: guard kept the shared ledger byte-for-byte" "kubectl -n $NS logs $PP -c cloud-spend-init | grep -q 'present, kept' && [ \"\$(spend)\" = '$MJ' ] && [ \"\$(xp $PP cat $SET | jq .price_confirmed)\" = true ]"
  gate "stage A read-back"
fi
if [ "$STAGE" = B1 ] || [ "$STAGE" = C1 ]; then
  chk "W2c guard kept the shared ledger (no refusal)" "kubectl -n $NS logs $PP -c cloud-spend-init | grep -q 'present, kept' && ! kubectl -n $NS logs $PP -c cloud-spend-init | grep -q REFUSED"
  chk "W3 no cloud CNP for profiel-$PROF yet" "! kubectl -n $NS get cnp hermes-profiel-$PROF-cloud >/dev/null 2>&1"
  chk "W3 profiel-$PROF cannot reach api.anthropic.com:443 (fallback precondition)" "! tcp $PP api.anthropic.com 443"
  chk "W3 profiel-$PROF -> Studio 172.16.2.200:443 connects" "tcp $PP 172.16.2.200 443"
  gate "stage $STAGE read-back"
fi
if [ "$STAGE" = B2 ] || [ "$STAGE" = C2 ]; then
  chk "W3 CNP live spec == repo file" "[ \"\$(kubectl -n $NS get cnp hermes-profiel-$PROF-cloud -o json | jq -cS .spec)\" = \"\$(yq -o=json '.spec' '$SRC/kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-$PROF-cloud.yaml' | jq -cS .)\" ]"
  chk "W3 profiel-$PROF -> api.anthropic.com:443 connects" "tcp $PP api.anthropic.com 443"
  chk "W3 profiel-$PROF -> api.anthropic.com:80 fails" "! tcp $PP api.anthropic.com 80"
  chk "W3 profiel-$PROF -> 1.1.1.1:443 fails" "! tcp $PP 1.1.1.1 443"
  chk "W3 profiel-$PROF -> Studio still connects" "tcp $PP 172.16.2.200 443"
  gate "stage $STAGE egress"
fi
if [ "$STAGE" = A ]; then
  GO_FINISHED=1; log "RESULT go GREEN (stage A: profiel-3 on the shared ledger, budget 99)"
  "$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$SHA" --arg ev "${EV#$REPO/}" '{step:"W2c stage A go: profiel-3 on the shared ledger, budget 99", deploy:$s, result:"GREEN", evidence:$ev, authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
  exit 0
fi

# ---------------------------------------------------------------- 3. canary turns (synthetic account in owui-profiel-N)
for b in c010-c6turn c010-f6 c010-canary-api; do eval "$(blk $b)"; done
OW=$(kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
owui_mint() { kubectl -n $NS exec -i "$OW" -c app -- sh -c 'cd /app/backend && python3 - 2>/dev/null' <<'PY' | grep '^C010TOKEN ' | tail -1
import os, sqlite3
from datetime import timedelta
c = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
rows = c.execute("select id, role from user where email = ?", (os.environ.get("WEBUI_ADMIN_EMAIL", "").strip(),)).fetchall()
if len(rows) == 1 and rows[0][1] == "admin":
    from open_webui.utils.auth import create_token
    print("C010TOKEN " + create_token({"id": rows[0][0]}, expires_delta=timedelta(minutes=60)))
PY
}
r="$(owui_mint)"; OWUI_ADMIN_KEY="${r#C010TOKEN }"; r=""
chk "OWUI admin token minted in-pod (service admin, 60 min, never printed)" "[ \${#OWUI_ADMIN_KEY} -ge 20 ]"
gate "owui admin token"
pf_up || { log "  RED  no port-forward to OWUI"; RED=1; }
MAIL="c010-canary-$PROF@acceptatie.invalid"; PW="c010-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"; CANARY_UID=""
cleanup() { if [ -n "$CANARY_UID" ]; then pf_ensure cleanup; c=$(api "$OWUI_ADMIN_KEY" DELETE "/api/v1/users/$CANARY_UID" "" -o /dev/null -w '%{http_code}'); log "  info cleanup: canary account DELETE http=$c"; CANARY_UID=""; fi; pf_kill_all; }
CLEANUP_HOOK=cleanup
CANARY_UID=$(api "$OWUI_ADMIN_KEY" POST /api/v1/auths/add '{"name":"c010-canary-'"$PROF"'","email":"'"$MAIL"'","password":"'"$PW"'","role":"user"}' | jq -r '.id // empty')
GID=$(api "$OWUI_ADMIN_KEY" GET /api/v1/groups/ | jq -r '.[] | select(.name=="owui-profiel-'"$PROF"'") | .id')
api "$OWUI_ADMIN_KEY" POST "/api/v1/groups/id/$GID/users/add" "{\"user_ids\":[\"$CANARY_UID\"]}" -o /dev/null
TOK=$(api - POST /api/v1/auths/signin '{"email":"'"$MAIL"'","password":"'"$PW"'"}' -H 'Authorization:' | jq -r '.token // empty')
chk "canary account in owui-profiel-$PROF sees only hermes-agent-profiel-$PROF" "[ -n '$CANARY_UID' ] && [ \"\$(api '$TOK' GET /api/models | jq -c '[.data[].id | select(startswith(\"hermes-agent\"))]')\" = '[\"hermes-agent-profiel-$PROF\"]' ]"
gate "canary account"
newchat() { api "$TOK" POST /api/v1/chats/new '{"chat":{"title":"c010-canary","models":["hermes-agent-profiel-'"$PROF"'"],"messages":[]}}' | jq -r '.id'; }
ask() { local c="$1" ms="$2"; shift 2
  api "$TOK" POST /api/chat/completions "{\"model\":\"hermes-agent-profiel-$PROF\",\"chat_id\":\"$c\",\"stream\":false,\"messages\":$ms,\"background_tasks\":{\"title_generation\":true,\"tags_generation\":false,\"follow_up_generation\":false}}" -m 240 "$@"; }
fails() { xp "$(pod "$PROF")" sh -c 'cat /opt/data/logs/agent.log* 2>/dev/null | grep -c "family-cloud: cloud call failed" || true'; }
RESERVE=$(xp "$PP" cat $SET | python3 -I -c 'import json,sys; s=json.load(sys.stdin); p=s["prices_usd_per_million"][s["model"]]; print(repr((s["input_token_ceiling"]*max(p["input"],p["cache_write"])+s["output_token_ceiling"]*p["output"])/1e6))')
one_turn() { # $1 tag $2 question -> sets T_HTTP T_META T_REC T_E0 T_E1 ; ledger before/after in T_L0/T_L1 ; never resent
  local cid r; pf_fresh "$1" && cid=$(newchat); T_L0=$(ledger); T_E0=$(pod_now); sdb "$((T_E0 - 2))" > "$CACHE/$1-s0.json" 2>/dev/null
  r=$(ask "$cid" "$(jq -nc --arg q "$2" '[{role:"user",content:$q}]')" -w '\n%{http_code}'); T_HTTP="${r##*$'\n'}"; T_META=$(printf '%s' "${r%$'\n'*}" | resp_meta); unset r
  sleep 3; c6_settle "$T_E0" "$CACHE/$1-s0.json" "$T_HTTP" "$1" || log "  info $1: server turn did not settle cleanly"
  T_E1=$(pod_now); T_REC=$(routes_all "$((T_E0 - 1))" "$((T_E1 + 1))"); T_L1=$(ledger)
  log "  $1: http=$T_HTTP $T_META; route records $(printf '%s' "$T_REC" | jq -c '[.records[] | (.[1] + "/" + .[2])]')"; }
if [ "$STAGE" = B1 ] || [ "$STAGE" = C1 ]; then
  F0=$(fails); one_turn "fallback" "Hoeveel dagen heeft een schrikkeljaar? Antwoord kort."
  chk "M3 fallback: HTTP 200 with an answer (cloud unreachable)" "[ '$T_HTTP' = 200 ] && grep -q 'content=yes' <<< '$T_META'"
  chk "M3 fallback: exactly one route record, studio/cloud_failed (no retry loop)" "[ \"\$(printf '%s' '$T_REC' | jq -c '[.records[] | (.[1] + \"/\" + .[2])]')\" = '[\"studio/cloud_failed\"]' ]"
  chk "M3 fallback: failure lines +1 exactly" "[ \$(( \$(fails) - $F0 )) = 1 ]"
  chk "M3 fallback: shared ledger rose by exactly one reservation, booked on profiel-$PROF (no billed call)" "python3 -I -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); r=float(sys.argv[3]); sys.exit(0 if abs((b[\"usd\"]-a[\"usd\"])-r) < 1e-9 and abs((b[\"person_usd\"][\"profiel-$PROF\"]-a[\"person_usd\"][\"profiel-$PROF\"])-r) < 1e-9 and b[\"input_tokens\"]==a[\"input_tokens\"] else 1)' '$T_L0' '$T_L1' '$RESERVE'"
  gate "M3 fallback ($STAGE)"
  GO_FINISHED=1; cleanup; CLEANUP_HOOK=""
  log "RESULT go GREEN (stage $STAGE: profiel-$PROF wired, egress off, fallback proven)"
  "$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$SHA" --arg st "$STAGE" --arg ev "${EV#$REPO/}" '{step:("W2c stage " + $st + " go: wired without egress, live fallback GREEN"), deploy:$s, result:"GREEN", evidence:$ev, cloud_turns:0, authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
  exit 0
fi
# B2 / C2: ONE real cloud turn (M4), then private turns + F1/F2
if [ "$STAGE" = B2 ]; then Q="Hoeveel poten heeft een spin? Antwoord kort."; else Q="Zoek op internet wat de hoofdstad van Australië is en noem je bron."; fi
one_turn "cloud" "$Q"; F2WIN="$((T_E0 - 1)):$((T_E1 + 1))"
RECS=$(printf '%s' "$T_REC" | jq -c '[.records[] | (.[1] + "/" + .[2])]')
chk "cloud turn: HTTP 200 with an answer" "[ '$T_HTTP' = 200 ] && grep -q 'content=yes' <<< '$T_META'"
if [ "$STAGE" = B2 ]; then
  chk "M4 cloud turn: exactly one route record, cloud/cloud_ok" "[ '$RECS' = '[\"cloud/cloud_ok\"]' ]"
else
  chk "C2 web turn: the first call cloud/cloud_ok, the web tool result answered on the Studio (private_context)" "printf '%s' '$RECS' | jq -e '.[0] == \"cloud/cloud_ok\" and (.[1:] | length >= 1) and all(.[1:][]; . == \"studio/private_context\")' >/dev/null"
fi
chk "M4 the cloud call is in the shared ledger: usd and person_usd profiel-$PROF rose, tokens counted" "python3 -I -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); sys.exit(0 if b[\"usd\"]>a[\"usd\"] and b[\"person_usd\"][\"profiel-$PROF\"]>a[\"person_usd\"][\"profiel-$PROF\"] and b[\"input_tokens\"]>a[\"input_tokens\"] else 1)' '$T_L0' '$T_L1'"
log "  info M4 ledger: usd $(printf '%s' "$T_L0" | num usd) -> $(printf '%s' "$T_L1" | num usd); person profiel-$PROF $(printf '%s' "$T_L1" | num person_usd.profiel-$PROF)"
gate "cloud turn ($STAGE)"
: > "$CACHE/f6.tsv"; SL7=$(spend)
c7() { local cid; pf_fresh "C7 $3 new chat" && cid=$(newchat)
  [ -n "${cid:-}" ] && [ "$cid" != null ] || { printf '%s\tprivate\tred\tno_chat\t-\n%s next\tnext\tred\tno_chat\t-\n' "$3" "$3" >> "$CACHE/f6.tsv"; return 1; }
  pturn "$3" private "$cid" "$1" "${4:-}"; pturn "$3 next" next "$cid" "$2"; }
MK="c010-kanarie-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
c7 '[{"role":"user","content":"Vergeet '"$MK"'."}]' '[{"role":"user","content":"Vergeet '"$MK"'."},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Hoe laat is het?"}]' vergeet
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
c7 '[{"role":"user","content":[{"type":"text","text":"Wat zie je?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'$PNG'"}}]}]' \
   '[{"role":"user","content":[{"type":"text","text":"Wat zie je?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'$PNG'"}}]},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Welke kleur?"}]' image
chk "C7 ledger unchanged over the private turns" "[ \"\$(spend)\" = '$SL7' ]"
chk "F6 private turns + next turns: route records == api_call_count increase, 0 cloud (4 rows ok)" "[ \$(awk -F'\t' '\$3==\"ok\"' '$CACHE/f6.tsv' | wc -l) = 4 ] && [ \$(wc -l < '$CACHE/f6.tsv') = 4 ]"
F2OUT=$(f2_check "$PUSH_E" "$F2WIN"); F2RC=$?; log "  $F2OUT"
chk "F2 no cloud_ok outside the cloud-turn window since the push" "[ $F2RC = 0 ]"
gate "C7/F ($STAGE)"
GO_FINISHED=1; cleanup; CLEANUP_HOOK=""
log "RESULT go GREEN (stage $STAGE: profiel-$PROF on the cloud; 1 cloud turn)"
"$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$SHA" --arg st "$STAGE" --arg ev "${EV#$REPO/}" --arg l1 "$(printf '%s' "$T_L1" | num usd)" '{step:("W2c stage " + $st + " go: cloud on, M4 cloud call in the ledger, F6/F1/F2 GREEN"), deploy:$s, result:"GREEN", evidence:$ev, cloud_turns:1, ledger_usd_after:$l1, authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
exit 0
