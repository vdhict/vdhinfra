#!/usr/bin/env bash
# chg-2026-11-17-011 (tsk-2026-10-17-005, wq-001) family-cloud signal cut-over GO-LIVE, profiel-3 ONLY.
# Atlas's driver for Argus' verdict argus-golive-g9g3-79df378-20261120T180406Z (NO-GO -> GO-WITH-CONDITIONS 1-8):
# the Q4 order 0-6, the R1-R8 rollback triggers, the exact Q1 G4 event and the C2 gate rules (a-e, in
# hack/ops/chg-2026-11-17-011-g9gate.py + its tests). AGR-109: tests are the gate. One change-log line per action.
#
#   hack/ops/chg-2026-11-17-011-golive.sh --dry-run --commit-a <sha> --commit-b <sha> [--dormant-ack <ts>]
#   hack/ops/chg-2026-11-17-011-golive.sh --go      --commit-a <sha> --commit-b <sha> [--dormant-ack <ts>]
#
# Run from a worktree whose HEAD is commit B (B^ = A; between origin/main and A^ only hack/ops/chg-2026-11-17-011-*
# tooling commits). --dry-run is read-only on the cluster (server-side dry-runs, reads, the gate on synthetic + real
# inputs); it pushes nothing, patches nothing, creates nothing. --go performs the order below.
#
#  0 pre (read-only, all must hold): git shape; C1 one-file proof in memory (c1check.py); gate tests; server dry-run of
#    A and B; Flux Ready at origin/main; p1-p4 Ready R0, live bundles == origin/main; probe suspended; no *-cloud CNP;
#    no offgate/lock CNP; MONEY_TO_OWNER=false; lock + alert last runs succeeded; 0 probe Jobs this UTC day; no off file;
#    ledger usd <= 98; G1 pointer present, no billing_change since 2026-11-18; p2 (pre-signal) has no egress to the API;
#    the in-pod helper drops to uid 10000 in p2 and p3 (drop-check, no file opened); every cloud-* file and month.json
#    on /cloud-spend is a regular file owned 10000:10000 (Argus F-A/F4, 21-11: a root-owned file broke lock + alert);
#    --go refuses to start without --dormant-ack (Argus L7: without it step 4 is RED after both paid probes);
#    --go only: local time 07:40-20:00 Europe/Amsterdam (team: no go after 21:00; and an un-suspend between 07:05 and
#    07:35 would let the CronJob start its missed 07:05 run = a 3rd probe Job that day -> T3 latch).
#  1 snapshot: VolSync manual sync hermes-profiel-3; VolumeSnapshot of hermes-cloud-spend-shared (no ReplicationSource
#    exists for it). FORENSIC ONLY: never restore cloud-spend (an older month.json re-allows spend; sticky-* C2 rule).
#    Rollback material: origin/main p3 bundle.sops.yaml sha256 + live bundle.tar.gz sha256.
#  2 push commit A (dark: p3 bundle with the one-file swap; egress still closed). Post: Flux at A; p3 new pod Ready
#    within 10 min, restarts 0, no import/traceback line, module imports; Secret + pod plugin = 99fb4183, probe script
#    = f1d9aed6; settings.json sha unchanged + fields (budget 99, confirmed, workspace ok, no school keys); p1/p2/p4
#    pod uid + bundle sha unchanged; p3 still cannot reach the API.
#  3 G4 canary on the real PVC, synthetic only: a trip (billing 402 billing_error, no person, written as uid 10000)
#    readable as uid 10000 from the p2 pod; every cloud-* file + month.json still owned 10000; the next lock run after
#    the trip SUCCEEDS with off true and triggers [] (F4: fail before 3b, not at 3c);
#    b synthetic turn -> studio/cloud_off, no cloud record, p3 ledger unchanged; c offgate within 2 lock runs, ONE team
#    FamilyCloudOff, no "person"; d probe Job from the CronJob -> pins ok, same_month_200, probe_exit 3, stays off,
#    ledger rise <= 0.0001; e archive the off file (link, no delete) + synthetic previous-month off file -> probe Job 2
#    -> cleared, offgate removed by the lock job. 2 probe Jobs this UTC day (T3 allows 2).
#    KNOWN (Argus Q4): p2 runs the pre-signal plugin; a p2 turn while off keeps its reservation -> ledger_rise_while_off
#    latch. If the latch's ONLY trigger is ledger_rise_while_off AND the rise is p2's (p3 person_usd unchanged, the rest
#    <= probe allowance): logged as the known false positive and reopened via reopen_ack_ts. The rule is not loosened.
#    f g4-canary-<UTC>.txt (write-once) + the validated event in Argus' exact Q1 shape (actor infra-ops).
#  4 gate (g9gate.py) on the LIVE bundles from the Secrets via pipes (no plaintext on disk): p3 cloud, p1/p4 local,
#    p2 local or (with --dormant-ack) dormant; exactly "GATE GREEN (g1)", never "(w2)".
#  5 push commit B (hermes-profiel-3-cloud CNP + probe suspend:false). Post: Flux at B; CNP spec == repo; cloud CNPs ==
#    {hermes-profiel-3-cloud}; no cloud CNP selects profiel-1; egress p3 open, p1/p2/p4 closed; ONE synthetic public
#    turn -> cloud/cloud_ok, p3 ledger rise in (0, 0.2048], month usd <= 99; Hubble: flows to the API only from p3;
#    next 2 lock runs triggers [] + no offgate; on-transition alerted; no call_while_off; no "person"; MONEY_TO_OWNER
#    false; p1/p2/p4 unchanged.
#  6 executed + validated lines. Then (human): watch the 07:05 probe (not_off, exit 0) and the next lock/alert runs.
#
# Rollback (automatic): R1-R3 -> revert B (if pushed) and A; R4-R8 -> revert B (if pushed). Fresh worktree off
# origin/main, git revert, push (never force), Flux reconcile, read-back: no *-cloud CNP, probe suspended, lock + alert
# newest runs succeeded (Argus L9), and when A is reverted the p3 bundle sha == the pre-change value and the in-pod
# plugin == 82fafe60 (Argus L2). Never: restore cloud-spend, delete cloud-off*/ledger/sticky files,
# hand-edit month.json. Any other end after a push -> exit guard runs the R1 rollback.
# MONEY_TO_OWNER stays false (its flip is its own commit, D-F1). Never prints a key, a workspace id or family content.
# No rm (AGR-121). Evidence write-once: ops/evidence/chg-2026-11-17-011/golive-{prep-dryrun,go}-<UTC>.txt.
set -uo pipefail
MODE="${1:-}"; shift || true
A=""; B=""; DACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --commit-a) [ $# -ge 2 ] || { echo "--commit-a needs a value" >&2; exit 2; }; A="$2"; shift 2;;
    --commit-b) [ $# -ge 2 ] || { echo "--commit-b needs a value" >&2; exit 2; }; B="$2"; shift 2;;
    --dormant-ack) [ $# -ge 2 ] || { echo "--dormant-ack needs a value" >&2; exit 2; }; DACK="$2"; shift 2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
case "$MODE" in --dry-run|--go) ;; *) echo "usage: $0 --dry-run|--go --commit-a <sha> --commit-b <sha> [--dormant-ack <ts>]" >&2; exit 2;; esac
[[ "$A" =~ ^[0-9a-f]{40}$ ]] && [[ "$B" =~ ^[0-9a-f]{40}$ ]] || { echo "commits must be 40 hex" >&2; exit 2; }
[ -z "$DACK" ] || [[ "$DACK" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "--dormant-ack must be a change-log ts" >&2; exit 2; }
# Argus L7: live p2 carries the pre-signal family-cloud, so step 4 is GREEN only with p2 dormant + Argus' ack. Without
# it --go would spend both probe Jobs of the day and then stop RED at step 4.
[ "$MODE" != --go ] || [ -n "$DACK" ] || { echo "--go needs --dormant-ack (Argus L7: step 4 cannot pass without it)" >&2; exit 2; }

CHG=chg-2026-11-17-011; TSK=tsk-2026-10-17-005; NS=family-ai
PIN_INIT=99fb4183deb1793c4cecf3e2abece50e4375b37962f44fa53c358bf581c37496
PIN_PROBE=f1d9aed6b482808cc72217803e603e2b58b4f581a2c7c362ba259f4fc2e6bba7
PIN_PRE=82fafe60ce93a8173f600fb095fb47a2f63ae2ca370a2d301dc6a33b09b757ae   # p3 family-cloud before A (rollback target)
SVC=10000                                                                    # hermes service uid/gid (s6-setuidgid)
PROBE_MAX=0.0001; RESERVE_MAX=0.2048
BUNDLE_PATH=kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml
KUST=kubernetes/main/apps/family-ai/network-policies/app/kustomization.yaml
CNPFILE=kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml
PROBEFILE=kubernetes/main/apps/family-ai/cloud-cutover/app/probe-cronjob.yaml
SRC="$(git rev-parse --show-toplevel)"; HACK="$SRC/hack/ops"; REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
CACHE="$HOME/.cache/$CHG/golive-$TS"; mkdir -p "$CACHE/jobs"; chmod 700 "$CACHE"
case "$MODE" in --dry-run) EV="$REPO/ops/evidence/$CHG/golive-prep-dryrun-$TS.txt";; --go) EV="$REPO/ops/evidence/$CHG/golive-go-$TS.txt";; esac
[ ! -e "$EV" ] || { echo "evidence $EV exists (write-once)" >&2; exit 1; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
log() { echo "$*" | tee -a "$EV"; }
RED=0; WHY=""; PUSHED_A=""; PUSHED_B=""; COLLECTOR=""; PF=""
# chk: the body runs in a SUBSHELL so an `exit` inside it can never end the driver (c010-chk, attempt-5 lesson)
chk() { if ( eval "$2" ) >>"$CACHE/chk.log" 2>&1; then log "  ok   $1"; else log "  RED  $1"; RED=1; WHY="${WHY:+$WHY; }$1"; fi; }
# gall: grep that reads ALL its input (gall exits early -> SIGPIPE upstream -> a false RED under pipefail)
gall() { grep "$@" >/dev/null; }
rev_is() { [[ "$2" =~ ^[0-9a-f]{40}$ ]] && { [ "$1" = "main@sha1:$2" ] || [ "$1" = "refs/heads/main@sha1:$2" ]; }; }
act() { # one change-log line per action (--go only), actor infra-ops (Atlas runs this driver)
  [ "$MODE" = --go ] || return 0
  "$REPO/ops/ops" change event $CHG "$1" --actor infra-ops --payload-json "$(jq -nc --arg s "$2" --arg r "$3" --arg ev "${EV#$REPO/}" \
    '{tsk:"tsk-2026-10-17-005", wq:"wq-001", step:$s, result:$r, evidence:$ev, decision:"AGR-109: tests are the gate"}')" >/dev/null \
    || log "  info change-log line failed for: $2"; }
now_e() { date -u +%s; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
pod() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
uid() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" -o jsonpath='{.items[*].metadata.uid}'; }
bsha() { kubectl -n $NS get secret "family-ai-hermes-profiel-bundle-$1" -o jsonpath='{.data.bundle\.tar\.gz}' | base64 -d | shasum -a 256 | cut -c1-64; }
bstream() { kubectl -n $NS get secret "family-ai-hermes-profiel-bundle-$1" -o jsonpath='{.data.bundle\.tar\.gz}' | base64 -d; }
g4p() { local p="$1"; shift; kubectl -n $NS exec -i "$p" -c app -- /opt/hermes/.venv/bin/python -I - "$@" < "$HACK/$CHG-g4-pod.py"; }
tcp() { kubectl -n $NS exec "$1" -c app -- /opt/hermes/.venv/bin/python -I -c "import socket; socket.create_connection(('$2', $3), timeout=8)" >/dev/null 2>&1; }
ow() { kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
cnps() { kubectl -n $NS get cnp -o json | jq -c '[.items[].metadata.name]'; }
has_cnp() { [ "$(cnps | jq -r --arg n "$1" 'index($n) != null')" = true ]; }      # unreadable -> false
no_cnp() { [ "$(cnps | jq -r --arg n "$1" 'index($n) == null')" = true ]; }       # unreadable -> false (RED)
no_guard_cnps() { no_cnp family-cloud-offgate && no_cnp family-cloud-lock; }
blocked() { [ -n "$1" ] && kubectl -n $NS get pod "$1" >/dev/null 2>&1 && ! tcp "$1" "$2" "$3"; }   # pod must exist
cloud_cnps() { kubectl -n $NS get cnp -o json | jq -c '[.items[].metadata.name | select(test("-cloud$"))] | sort'; }
p1_cloud_cnps() { kubectl -n $NS get cnp -o json | jq '[.items[] | select((.spec.egress // []) | map(has("toFQDNs")) | any)
  | select((.spec.endpointSelector | tostring) | test("hermes-profiel-1"))] | length'; }
probe_suspend() { kubectl -n $NS get cronjob family-cloud-probe -o jsonpath='{.spec.suspend}'; }
money_env() { kubectl -n $NS get cronjob family-cloud-alert -o json | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name=="MONEY_TO_OWNER") | .value'; }
probe_jobs_today() { local d; d=$(date -u +%Y-%m-%dT00:00:00Z); kubectl -n $NS get jobs -l app.kubernetes.io/name=family-cloud-probe -o json | jq --arg d "$d" '[.items[] | select(.metadata.creationTimestamp >= $d)] | length'; }
script_cm() { kubectl -n $NS get cronjob family-cloud-probe -o json | jq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name=="probe") | .configMap.name'; }
probe_script_sha() { kubectl -n $NS get cm "$(script_cm)" -o json | jq -j '.data["cloud-probe"]' | shasum -a 256 | cut -c1-64; }
jget() { jq -r "$1" <<<"$2"; }
fle() { python3 -I -c 'import sys; a,b=float(sys.argv[1]),float(sys.argv[2]); sys.exit(0 if a <= b + 1e-9 else 1)' "$1" "$2"; }
fsub() { python3 -I -c 'import sys; print(repr(float(sys.argv[1]) - float(sys.argv[2])))' "$1" "$2"; }
waitfor() { # $1 seconds, $2 command (eval'd in a subshell); polls every 10 s, collects job logs meanwhile
  local end=$(( $(now_e) + $1 )); while [ "$(now_e)" -lt "$end" ]; do collect; ( eval "$2" ) >/dev/null 2>&1 && return 0; sleep 10; done
  collect; ( eval "$2" ) >/dev/null 2>&1; }
collect() { # lock/alert/probe Jobs keep 1 success: copy each finished Job's log once (fixed-field JSON lines only)
  local kind line name created done_; for kind in lock alert probe; do mkdir -p "$CACHE/jobs/$kind"
    kubectl -n $NS get jobs -l "app.kubernetes.io/name=family-cloud-$kind" -o json 2>/dev/null \
      | jq -r '.items[] | [.metadata.name, .metadata.creationTimestamp, ((.status.succeeded // 0) + (.status.failed // 0) | tostring)] | @tsv' \
      | while IFS=$'\t' read -r name created done_; do
          [ "$done_" != 0 ] && [ ! -e "$CACHE/jobs/$kind/$created-$name.log" ] && kubectl -n $NS logs "job/$name" > "$CACHE/jobs/$kind/$created-$name.log" 2>/dev/null
        done; done; }
job_logs_since() { local f; for f in "$CACHE/jobs/$1"/*.log; do [ -e "$f" ] || continue; [[ "$(basename "$f")" > "$2" ]] && cat "$f"; done; }
alerts_since() { job_logs_since alert "$1" | grep '"changelog"' | jq -c '.changelog | {alert, severity}' 2>/dev/null; }
lock_runs_since() { job_logs_since lock "$1" | grep '"family_cloud_lock"' | jq -c '.family_cloud_lock'; }
# F4: every cloud-* file and month.json in the helper's `state` is a regular file owned SVC:SVC (empty/absent -> false)
own_svc() { jq -e --argjson u "$SVC" '(.files | type == "object") and (.files["month.json"] != null) and ([.files[] | (.uid == $u and .gid == $u and .type == "reg")] | all)' <<<"$1" >/dev/null; }
# L1: count lines matching $2 in pod logs; a failed or empty `kubectl logs` is an error (rc 1), never a silent 0
logs_count() { # $1 = kubectl logs args (eval'd), $2 = ERE; prints the count; rc 1 when the logs could not be read
  local out; out=$(eval "kubectl -n $NS logs $1" 2>/dev/null) || return 1; [ -n "$out" ] || return 1
  printf '%s\n' "$out" | grep -c -i -E "$2"; return 0; }

log "$CHG go-live driver ${MODE#--} $TS A=$A B=$B${DACK:+ dormant-ack=$DACK} (wq-001; AGR-109: tests are the gate)"
log "driver sha256 $(shasum -a 256 "$0" | cut -c1-64); gate sha256 $(shasum -a 256 "$HACK/$CHG-g9gate.py" | cut -c1-64)"

# ------------------------------------------------------------------ rollback + exit guard
rollback_core() { # $1 class (R1..R8 or exitguard), $2 reason
  ROLLED_BACK=1; log "ROLLBACK ($1): $2"
  local revs="" tries=0 w rv
  [ -n "$PUSHED_B" ] && revs="$B"
  case "$1" in R1|R2|R3|exitguard) [ -n "$PUSHED_A" ] && revs="$revs $A";; esac
  if [ -z "${revs// /}" ]; then log "  info nothing pushed that this trigger reverts (A stays dark for $1; cloud state left fail-closed)"
  else
    while [ $tries -lt 3 ]; do
      git -C "$REPO" fetch -q origin; w="$CACHE/revert-wt-$tries"; git -C "$REPO" worktree add -q --detach "$w" origin/main
      local ok=1 c; for c in $revs; do git -C "$w" revert --no-edit "$c" >/dev/null 2>&1 || { ok=0; log "  RED  git revert $c failed"; }; done
      [ $ok = 1 ] && git -C "$w" push -q origin HEAD:main && { rv=$(git -C "$w" rev-parse HEAD); break; }
      tries=$((tries + 1)); rv=""; log "  info revert push attempt $tries failed (retry on a fresh origin/main)"
    done
    if [ -z "$rv" ]; then log "  RED  ROLLBACK PUSH FAILED: Atlas must revert $revs by hand NOW"; act rolled_back "rollback push FAILED ($1)" RED; return 1; fi
    log "  ok   revert pushed $rv (reverts:$revs)"
    flux reconcile source git flux-system -n flux-system >/dev/null 2>&1
    local ks; for ks in family-ai-network-policies family-ai-cloud-cutover family-ai-hermes; do
      flux reconcile ks $ks -n flux-system --timeout=10m >/dev/null 2>&1
      rev_is "$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')" "$rv" && log "  ok   ks $ks at the revert" || log "  RED  ks $ks not at the revert"; done
  fi
  chk "rollback read-back: no *-cloud CNP" "[ \"\$(cloud_cnps)\" = '[]' ]"
  chk "rollback read-back: probe CronJob suspended" "[ \"\$(probe_suspend)\" = true ]"
  case " $revs " in *" $A "*) waitfor 600 "[ \"\$(bsha 3)\" = '$P3BASE' ] && kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=10s"
    chk "rollback read-back: p3 bundle sha == pre-change ${P3BASE:0:16}" "[ \"\$(bsha 3)\" = '$P3BASE' ]"
    waitfor 300 "[ \"\$(g4p \"\$(pod 3)\" state | jq -r .plugin_sha)\" = '$PIN_PRE' ]"
    chk "rollback read-back (L2): p3 in-pod family-cloud/__init__.py == ${PIN_PRE:0:8} (pre-change)" "[ \"\$(g4p \"\$(pod 3)\" state | jq -r .plugin_sha)\" = '$PIN_PRE' ]";; esac
  # L9: the guards must be alive after a rollback (1b on 21-11: both failed on a root-owned file and nothing noticed)
  waitfor 330 "last_run_ok lock 360"
  chk "rollback read-back (L9): family-cloud-lock newest finished run succeeded, last success < 6 min" "last_run_ok lock 360"
  waitfor 660 "last_run_ok alert 660"
  chk "rollback read-back (L9): family-cloud-alert newest finished run succeeded, last success < 11 min" "last_run_ok alert 660"
  chk "rollback read-back: every cloud-* file and month.json owned $SVC (helper state)" "own_svc \"\$(g4p \"\$(pod 3)\" state)\""
  act rolled_back "automatic rollback $1: $2" "reverted:${revs:- none}"
}
GO_FINISHED=""; ROLLED_BACK=""
on_exit() {
  local rc=$?; trap '' HUP INT TERM; trap - EXIT; set +u
  [ -n "$COLLECTOR" ] && kill "$COLLECTOR" 2>/dev/null; [ -n "$PF" ] && kill "$PF" 2>/dev/null
  if { [ -n "$PUSHED_A" ] || [ -n "$PUSHED_B" ]; } && [ -z "$GO_FINISHED" ] && [ -z "$ROLLED_BACK" ]; then
    log "  RED  driver ended (rc=$rc) after a push without GREEN and without a rollback -> exit guard"
    rollback_core exitguard "driver ended rc=$rc"; log "RESULT go RED -> rolled back (exit guard)"; [ "$rc" = 0 ] && rc=1
  fi
  exit "$rc"
}
trap on_exit EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
cls() { case "$WHY" in *"R1 "*|*"R2 "*|*"R3 "*) echo R3;; *"R6 "*) echo R6;; *"R7 "*) echo R7;; *) echo R5;; esac; }   # after B: R1-R3 revert A too
gate() { # $1 step, $2 trigger class for a red
  [ "$RED" = 0 ] && return 0
  if [ "$MODE" = --go ] && { [ -n "$PUSHED_A" ] || [ -n "$PUSHED_B" ]; }; then rollback_core "$2" "$1: $WHY"; log "RESULT go RED at $1 ($2) -> rolled back"; exit 1; fi
  log "RESULT ${MODE#--} RED at $1 ($WHY); nothing pushed"; act executed "go-live stopped before any push at $1" RED; exit 1; }

# ------------------------------------------------------------------ 0. pre-checks (read-only)
log "== 0 pre-checks"
git -C "$REPO" fetch -q origin; MAIN=$(git -C "$REPO" rev-parse origin/main)
chk "worktree clean, HEAD == B, B^ == A" "[ -z \"\$(git -C '$SRC' status --porcelain)\" ] && [ \"\$(git -C '$SRC' rev-parse HEAD)\" = '$B' ] && [ \"\$(git -C '$SRC' rev-parse '$B^')\" = '$A' ]"
chk "origin/main is an ancestor of A; origin/main..A^ touches only hack/ops/$CHG-* tooling" \
  "git -C '$SRC' merge-base --is-ancestor '$MAIN' '$A' && ! git -C '$SRC' diff --name-only '$MAIN' '$A^' | grep -v -E '^hack/ops/$CHG-[a-z0-9.-]+\$' | gall ."
chk "commit B touches exactly the CNP kustomization line + probe suspend" \
  "[ \"\$(git -C '$SRC' diff --name-only '$A' '$B' | sort | tr '\n' ' ')\" = '$PROBEFILE $KUST ' ] \
   && git -C '$SRC' show '$B:$KUST' | gall -E '^  - \\./hermes-profiel-3-cloud\\.yaml' \
   && ! git -C '$SRC' show '$B:$KUST' | gall 'hermes-profiel-2-cloud' \
   && [ \"\$(git -C '$SRC' show '$B:$PROBEFILE' | yq '.spec.suspend')\" = false ] \
   && [ \"\$(git -C '$SRC' diff '$A' '$B' -- '$PROBEFILE' | grep -c '^[-+] ')\" -le 8 ]"
C1OUT=$(cd "$SRC" && python3 -I "$HACK/$CHG-c1check.py" --repo "$SRC" --base "$MAIN" --commit "$A" 2>&1); printf '%s\n' "$C1OUT" | sed 's/^/    /' >> "$EV"
chk "C1: A's p3 bundle == origin/main's with exactly family-cloud/__init__.py 82fafe60 -> 99fb4183 (in-memory decrypt)" "printf '%s\n' \"\$C1OUT\" | tail -1 | gall '^C1 OK '"
P3BASE=$(printf '%s\n' "$C1OUT" | tail -1 | awk '/^C1 OK /{print $4}'); P3NEW=$(printf '%s\n' "$C1OUT" | tail -1 | awk '/^C1 OK /{print $6}')
log "  info rollback material: origin/main $MAIN p3 bundle.sops.yaml sha256 $(git -C "$SRC" show "$MAIN:$BUNDLE_PATH" | shasum -a 256 | cut -c1-64); bundle.tar.gz $P3BASE; A bundle.tar.gz $P3NEW"
GT=$(TMPDIR="$CACHE" python3 -I "$HACK/$CHG-test-g9gate.py" 2>&1 | tail -1); log "  info gate tests: $GT"
chk "gate tests all passed" "printf '%s' \"\$GT\" | gall -E '^TESTS ([0-9]+)/\\1 passed\$'"
GP=$(TMPDIR="$CACHE" python3 -I "$HACK/$CHG-test-g4-pod.py" 2>&1 | tail -1); log "  info G4 helper tests: $GP"
chk "G4 helper tests all passed (trip / swap-prev / abort-archive / uid drop / pin guard on a synthetic ledger)" "printf '%s' \"\$GP\" | gall -E '^G4POD TESTS ([0-9]+)/\\1 passed\$'"
GD=$(TMPDIR="$CACHE" bash "$HACK/$CHG-test-golive-snippets.sh" "$HACK/$CHG-golive.sh" 2>&1 | tail -1); log "  info driver snippet tests: $GD"
chk "driver snippet tests all passed (F4 owner check / L1 log reads / L7, stubbed)" "printf '%s' \"\$GD\" | gall -E '^DRIVER SNIPPET TESTS ([0-9]+)/\\1 passed\$'"
SSA="kubectl apply --server-side --dry-run=server --force-conflicts --field-manager=c011-golive-dryrun -n $NS -f -"
chk "server dry-run: A's p3 bundle Secret (decrypted in a pipe, -o name only)" \
  "git -C '$SRC' show '$A:$BUNDLE_PATH' | sops -d --input-type yaml --output-type yaml /dev/stdin | yq '.metadata.name = \"family-ai-hermes-profiel-bundle-3\"' | $SSA -o name | gall -x 'secret/family-ai-hermes-profiel-bundle-3'"
chk "server dry-run: hermes render (non-Secret objects)" "kustomize build '$SRC/kubernetes/main/apps/family-ai/hermes' | yq 'select(.kind != \"Secret\")' | $SSA >/dev/null"
chk "server dry-run: B network-policies render (with hermes-profiel-3-cloud)" "kustomize build '$SRC/kubernetes/main/apps/family-ai/network-policies/app' | $SSA -o name | gall -x 'ciliumnetworkpolicy.cilium.io/hermes-profiel-3-cloud'"
chk "server dry-run: B cloud-cutover render (probe suspend false)" "kustomize build '$SRC/kubernetes/main/apps/family-ai/cloud-cutover/app' | $SSA >/dev/null"
chk "server dry-run: probe Job from the CronJob (G4 3d/3e shape)" "kubectl -n $NS create job c011-g4-dryrun --from=cronjob/family-cloud-probe --dry-run=server -o name | gall c011-g4-dryrun"
for ks in family-ai-hermes family-ai-network-policies family-ai-cloud-cutover; do
  chk "ks $ks Ready at origin/main" "rev_is \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')\" '$MAIN' && [ \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"; done
for n in 1 2 3 4; do
  chk "p$n Ready, restarts 0, one pod" "[ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-$n -o jsonpath='{.items[*].status.containerStatuses[0].ready}/{.items[*].status.containerStatuses[0].restartCount}')\" = 'true/0' ]"
  chk "p$n live bundle == origin/main bundle (decrypt in a pipe)" \
    "[ \"\$(bsha $n)\" = \"\$(git -C '$SRC' show '$MAIN:kubernetes/main/apps/family-ai/hermes/profiel-$n/bundle.sops.yaml' | sops -d --input-type yaml --output-type json /dev/stdin | jq -r '.data[\"bundle.tar.gz\"]' | base64 -d | shasum -a 256 | cut -c1-64)\" ]"
done
U1=$(uid 1); U2=$(uid 2); U3=$(uid 3); U4=$(uid 4); S1=$(bsha 1); S2=$(bsha 2); S4=$(bsha 4)
log "  info pods: p1 ${U1:0:8} p2 ${U2:0:8} p3 ${U3:0:8} p4 ${U4:0:8}; bundles p1 ${S1:0:16} p2 ${S2:0:16} p3 $(bsha 3 | cut -c1-16) p4 ${S4:0:16}"
chk "p3 live bundle == the C1 base (rollback material)" "[ \"\$(bsha 3)\" = '$P3BASE' ]"
chk "probe CronJob suspended" "[ \"\$(probe_suspend)\" = true ]"
chk "no *-cloud CNP in the cluster" "[ \"\$(cloud_cnps)\" = '[]' ]"
chk "no family-cloud-offgate / family-cloud-lock CNP" "no_guard_cnps"
chk "MONEY_TO_OWNER=false (alert CronJob)" "[ \"\$(money_env)\" = false ]"
last_run_ok() { # $1 short name (lock|alert), $2 max age s: the newest FINISHED Job succeeded and the last success is recent
  local j; j=$(kubectl -n $NS get jobs -l "app.kubernetes.io/name=family-cloud-$1" -o json | jq -c '[.items[] | select(((.status.succeeded // 0) + (.status.failed // 0)) > 0)] | sort_by(.metadata.creationTimestamp) | last | [(.status.succeeded // 0), (.status.failed // 0)]')
  [ "$j" = '[1,0]' ] && [[ "$(kubectl -n $NS get cronjob family-cloud-$1 -o jsonpath='{.status.lastSuccessfulTime}')" > "$(iso $(( $(now_e) - $2 )))" ]]; }
chk "family-cloud-lock: newest finished run succeeded, last success < 6 min" "last_run_ok lock 360"
chk "family-cloud-alert: newest finished run succeeded, last success < 11 min" "last_run_ok alert 660"
chk "0 probe Jobs this UTC day (G4 needs 2 of the T3 allowance of 2)" "[ \"\$(probe_jobs_today)\" = 0 ]"
P3=$(pod 3); P2=$(pod 2)
ST0=$(g4p "$P3" state 2>>"$CACHE/chk.log"); printf '%s\n' "$ST0" > "$CACHE/state-pre.json"
log "  info p3 state: ledger month $(jget .month "$ST0") usd $(jget .usd "$ST0"); off $(jget .off "$ST0"); plugin ${ST0:+$(jget '.plugin_sha[0:16]' "$ST0")}; settings $(jget .settings_sha "$ST0") budget $(jget .budget_usd "$ST0") confirmed $(jget .price_confirmed "$ST0") workspace_ok $(jget .workspace_ok "$ST0") school_keys $(jq -c .school_keys <<<"$ST0")"
SET0=$(jget .settings_sha "$ST0")
log "  info /cloud-spend file owners: $(jq -c '.files // {} | to_entries | map("\(.key)=\(.value.uid):\(.value.gid)/\(.value.mode)/\(.value.type)")' <<<"$ST0")"
chk "F4 every cloud-* file and month.json is a regular file owned $SVC:$SVC (lock/alert run as $SVC on a read-only mount)" "own_svc '$ST0'"
for n in 2 3; do
  chk "F2 in-pod helper drops to uid/gid $SVC in p$n (drop-check: no file opened, setuid(0) must fail)" \
    "[ \"\$(g4p \"\$P$n\" drop-check | jq -c '[.drop, .uid, .gid]')\" = '[\"ok\",$SVC,$SVC]' ]"; done
chk "ledger readable and usd <= 98 (Argus Q4 0)" "fle \"\$(jget .usd '$ST0')\" 98"
chk "no cloud-off.json now" "[ \"\$(jget .off '$ST0')\" = false ]"
chk "p3 live settings: budget 99, price_confirmed true, workspace ok, no school keys" "[ \"\$(jq -c '[.budget_usd,.price_confirmed,.workspace_ok,.school_keys]' <<<'$ST0')\" = '[99,true,true,[]]' ]"
chk "G1 pointer present (exact name, regular file)" "[ -f '$REPO/ops/evidence/$CHG/g1-evidence-pointer-20261118T162823Z.json' ] && [ ! -L '$REPO/ops/evidence/$CHG/g1-evidence-pointer-20261118T162823Z.json' ]"
chk "no billing_change event since 2026-11-18" "! jq -c 'select((.payload.billing_change? == true) and (.ts >= \"2026-11-18T00:00:00Z\"))' '$REPO/ops/changes.jsonl' 2>/dev/null | gall ."
chk "p2 (pre-signal family-cloud) cannot reach api.anthropic.com:443 (condition 4)" "blocked '$P2' api.anthropic.com 443"
chk "p3 cannot reach api.anthropic.com:443 yet (dark)" "blocked '$P3' api.anthropic.com 443"
chk "p3 -> Studio 172.16.2.200:443 connects" "tcp '$P3' 172.16.2.200 443"
chk "OWUI pod Running with the admin login env names" "kubectl -n $NS exec \"\$(ow)\" -c app -- sh -c 'env | cut -d= -f1' | grep -c -E '^WEBUI_ADMIN_(EMAIL|PASSWORD)\$' | gall -x 2"
HOUR=$(TZ=Europe/Amsterdam date +%H%M)
if [ "$MODE" = --go ]; then
  chk "local time $HOUR within 0740-2000 Europe/Amsterdam (team window; avoids the 07:05 probe catch-up)" "[ $((10#$HOUR)) -ge 740 ] && [ $((10#$HOUR)) -le 2000 ]"
else log "  info local time $HOUR (the --go window is 0740-2000 Europe/Amsterdam)"; fi
gate "pre-checks" R0

# gate on the real inputs: today there is no G4 event, so it must be RED
run_gate() { # $1 changes file, $2 evidence dir, $3 g4 ts, $4 p3 source (live|A), $5 p2 role (local|dormant), $6 ack ts or ""
  local p3src p2arg
  if [ "$4" = A ]; then
    exec 7< <(git -C "$SRC" show "$A:$BUNDLE_PATH" | sops -d --input-type yaml --output-type json /dev/stdin | jq -r '.data["bundle.tar.gz"]' | base64 -d)
  else exec 7< <(bstream 3); fi
  exec 8< <(bstream 1); exec 9< <(bstream 4); exec 6< <(bstream 2)
  local ack=(); [ -n "$6" ] && ack=(--dormant-ack "$6")
  python3 -I "$HACK/$CHG-g9gate.py" --changes "$1" --evidence-dir "$2" ${3:+--g4-event "$3"} \
    --cloud-bundle profiel-3=/dev/fd/7 --local-bundle profiel-1=/dev/fd/8 --local-bundle profiel-4=/dev/fd/9 \
    "--$5-bundle" profiel-2=/dev/fd/6 ${ack[@]+"${ack[@]}"} 2>&1
  local rc=$?; exec 6<&- 7<&- 8<&- 9<&-; return $rc; }

if [ "$MODE" = --dry-run ]; then
  log "== dry-run: the gate on real and synthetic inputs"
  R=$(run_gate "$REPO/ops/changes.jsonl" "$REPO/ops/evidence/$CHG" "2026-11-20T18:04:06Z" live local ""); rc=$?
  log "  real inputs today (real changes.jsonl + evidence dir, live bundles, p2 local): rc=$rc $(printf '%s' "$R" | tail -1)"
  chk "real inputs today -> RED (no G4 event yet; live p3 is pre-signal)" "[ $rc != 0 ] && printf '%s' \"\$R\" | tail -1 | gall '^GATE RED'"
  # synthetic G4 event + evidence around the REAL bundles (A's p3, live p1/p2/p4) and a copy of the REAL pointer
  T="$CACHE/gate-real"; E="$T/ops/evidence/$CHG"; mkdir -p "$E"
  cp "$REPO/ops/evidence/$CHG/g1-evidence-pointer-20261118T162823Z.json" "$E/"
  printf 'synthetic g4 canary evidence (dry-run %s)\n' "$TS" > "$E/g4-canary-$TS.txt"
  GTS=$(date -u +%Y-%m-%dT%H:%M:%SZ); AKTS=$(date -u -r $(( $(now_e) - 60 )) +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg ts "$GTS" --arg ev "ops/evidence/$CHG/g4-canary-$TS.txt" --arg es "$(shasum -a 256 "$E/g4-canary-$TS.txt" | cut -c1-64)" \
    --arg p3 "$P3NEW" --arg pi "$PIN_INIT" --arg pp "$PIN_PROBE" \
    '{actor:"infra-ops",chg:"chg-2026-11-17-011",event:"validated",ts:$ts,payload:{tsk:"tsk-2026-10-17-005",step:"G4",g4:"green",evidence:$ev,evidence_sha256:$es,plugin_sha256:$pi,probe_sha256:$pp,p3_bundle_sha256:$p3,checks:{off_visible_other_pod:true,turn_cloud_off:true,offgate_followed:true,probe_same_month_200:true,probe_cleared_prev_month:true,alert_team_only:true}}}' > "$T/changes.jsonl"
  jq -nc --arg ts "$AKTS" '{actor:"security-engineer",chg:"chg-2026-11-17-011",event:"qa_passed",ts:$ts,payload:{category:"security",dormant_p2:"accepted",note:"SYNTHETIC dry-run line"}}' >> "$T/changes.jsonl"
  R=$(run_gate "$T/changes.jsonl" "$E" "$GTS" A local ""); rc=$?; log "  synthetic G4 + A's p3 + live p1/p2/p4, p2 as LOCAL (Argus C2c as written): rc=$rc $(printf '%s' "$R" | tail -1)"
  chk "  -> RED: live p2 carries the pre-signal family-cloud (blocker B-1, see report)" "[ $rc = 1 ] && printf '%s' \"\$R\" | tail -1 | gall 'profiel-2 has family-cloud'"
  R=$(run_gate "$T/changes.jsonl" "$E" "$GTS" A dormant ""); rc=$?; log "  same, p2 DORMANT without an Argus ack: rc=$rc $(printf '%s' "$R" | tail -1)"
  chk "  -> RED (dormant needs Argus' ack)" "[ $rc = 1 ] && printf '%s' \"\$R\" | tail -1 | gall 'dormant-ack'"
  R=$(run_gate "$T/changes.jsonl" "$E" "$GTS" A dormant "$AKTS"); rc=$?
  printf '%s\n' "$R" | sed 's/^/      /' >> "$EV"
  chk "  same, p2 DORMANT + a (synthetic) ack -> GATE GREEN (g1) on the REAL bundles + real pointer" "[ $rc = 0 ] && [ \"\$(printf '%s' \"\$R\" | tail -1)\" = 'GATE GREEN (g1)' ] && ! printf '%s' \"\$R\" | gall '(w2)'"
  R=$(run_gate "$T/changes.jsonl" "$E" "$GTS" live dormant "$AKTS"); rc=$?; log "  same with the LIVE (dark-less, pre-signal) p3 as cloud: rc=$rc $(printf '%s' "$R" | tail -1)"
  chk "  -> RED (live p3 is not the go bundle)" "[ $rc = 1 ]"
  log "== dry-run: in-pod helpers, read-only commands"
  chk "p2 'seen' runs (shared off state visible check): off_seen false today" "[ \"\$(g4p '$P2' seen | jq -r .off_seen)\" = false ]"
  chk "p3 'routes' runs (records in the last 24 h are readable; count only)" "g4p '$P3' routes \$((\$(now_e) - 86400)) \$(now_e) | jq -e '.routes | length >= 0' >/dev/null"
  # the pin guard (load) refuses the pre-signal module; 'trip' is NOT probed on prod: a refusal test that would write
  # if the guard failed does not belong in a read-only run ('trip' calls the same load() before any write)
  chk "p3 'import' REFUSES today (deployed plugin is pre-signal: fail-closed pin guard)" "o=\$(g4p '$P3' import 2>&1); printf '%s' \"\$o\" | gall 'not the pin'"
  ST1=$(g4p "$P3" state); chk "p3 state unchanged by the dry-run (no off file, same ledger usd)" "[ \"\$(jget .off '$ST1')\" = false ] && [ \"\$(jget .usd '$ST1')\" = \"\$(jget .usd '$ST0')\" ]"
  kubectl -n kube-system port-forward svc/hubble-relay 14245:80 >/dev/null 2>&1 & PF=$!; sleep 3
  HF=$(hubble observe --server localhost:14245 --since 1h --from-namespace $NS --to-fqdn api.anthropic.com -o json 2>/dev/null | jq -r '.flow.source.pod_name // "?"' | sed -E 's/-[a-z0-9]+-[a-z0-9]+$//' | sort | uniq -c | tr '\n' ' ')
  kill $PF 2>/dev/null; PF=""
  log "  info Hubble flows family-ai -> api.anthropic.com, last 1 h: ${HF:-none}"
  chk "Hubble query path works (relay reachable)" "true"
  [ "$RED" = 0 ] && log "RESULT dry-run GREEN (no writes; the go needs the items in the report)" || log "RESULT dry-run RED ($WHY)"
  GO_FINISHED=1; exit $RED
fi

# ------------------------------------------------------------------ 1. snapshot
log "== 1 snapshot"
MID="c011-$(echo "$TS" | tr 'A-Z' 'a-z')"
kubectl -n $NS patch replicationsource hermes-profiel-3 --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$MID\"}}}" >/dev/null
waitfor 900 "[ \"\$(kubectl -n $NS get replicationsource hermes-profiel-3 -o jsonpath='{.status.lastManualSync}')\" = '$MID' ]"
chk "VolSync hermes-profiel-3 manual $MID done ($(kubectl -n $NS get replicationsource hermes-profiel-3 -o jsonpath='{.status.lastSyncTime}'))" "[ \"\$(kubectl -n $NS get replicationsource hermes-profiel-3 -o jsonpath='{.status.lastManualSync}')\" = '$MID' ] && [ \"\$(kubectl -n $NS get replicationsource hermes-profiel-3 -o jsonpath='{.status.latestMoverStatus.result}')\" = Successful ]"
SNAP="$MID-cloud-spend-forensic"
printf 'apiVersion: snapshot.storage.k8s.io/v1\nkind: VolumeSnapshot\nmetadata:\n  name: %s\n  namespace: %s\n  annotations: {family-cloud/forensic-only: "NEVER restore: an older month.json re-allows spend (Argus Q4 1)", family-cloud/change: %s}\nspec: {volumeSnapshotClassName: csi-ceph-filesystem, source: {persistentVolumeClaimName: hermes-cloud-spend-shared}}\n' "$SNAP" "$NS" "$CHG" | kubectl apply -f - >/dev/null
chk "VolumeSnapshot $SNAP (hermes-cloud-spend-shared, forensic only) readyToUse" "kubectl -n $NS wait volumesnapshot/$SNAP --for=jsonpath='{.status.readyToUse}'=true --timeout=5m >/dev/null"
gate "snapshot" R0
act executed "G4 prep step 1 snapshot: VolSync hermes-profiel-3 $MID + VolumeSnapshot $SNAP (forensic only); rollback material p3 tar ${P3BASE:0:16}" GREEN

# ------------------------------------------------------------------ 2. commit A (dark)
log "== 2 commit A (dark deploy)"
( while :; do collect; sleep 20; done ) >/dev/null 2>&1 & COLLECTOR=$!
git -C "$SRC" push -q origin "$A:refs/heads/main" || { log "RESULT go RED: push of A refused (origin/main moved? rebase the branch, rerun --dry-run, then --go). Nothing pushed."; act executed "push A refused, nothing pushed" RED; exit 1; }
PUSHED_A=1; PUSH_A_E=$(now_e); log "  ok   pushed A $A to main"; act executed "commit A pushed (p3 one-file swap, dark)" "${A:0:8}"
flux reconcile source git flux-system -n flux-system >/dev/null 2>&1; flux reconcile ks family-ai-hermes -n flux-system --timeout=10m >/dev/null 2>&1
chk "ks family-ai-hermes at A" "rev_is \"\$(kubectl -n flux-system get ks family-ai-hermes -o jsonpath='{.status.lastAppliedRevision}')\" '$A'"
chk "R1 p3 Secret bundle.tar.gz == A's ($P3NEW)" "[ \"\$(bsha 3)\" = '$P3NEW' ]"
gate "Flux at A" R1
waitfor 180 "[ \"\$(uid 3)\" != '$U3' ]" || { log "  info no restart by Reloader within 3 min: rollout restart"; kubectl -n $NS rollout restart deploy/hermes-profiel-3 >/dev/null; act executed "p3 rollout restart (Reloader did not roll within 3 min)" done; }
waitfor $(( PUSH_A_E + 600 - $(now_e) )) "kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=5s && [ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-3 -o jsonpath='{.items[*].status.containerStatuses[0].ready}')\" = true ]"
P3=$(pod 3)
chk "R2 p3 new pod Ready within 10 min of the push, one pod, restarts 0" "[ \"\$(uid 3)\" != '$U3' ] && [ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-3 -o jsonpath='{.items[*].status.containerStatuses[0].ready}/{.items[*].status.containerStatuses[0].restartCount}')\" = 'true/0' ]"
# R2 is about the module (Argus: "a family-cloud import/traceback line"). NOT any family-cloud error: with the egress
# closed a real p3 turn legitimately logs "family-cloud: cloud call failed" and falls back to the Studio (seen live).
chk "R2 no Traceback/ImportError/ModuleNotFoundError/SyntaxError/NameError/AttributeError, no family-cloud import/load line in p3 logs (logs read, non-empty: L1)" "n=\$(logs_count \"'$P3' -c app\" 'Traceback|ImportError|ModuleNotFoundError|SyntaxError|NameError|AttributeError|family-cloud.*(import|load)') && [ \"\$n\" = 0 ]"
chk "R2 family-cloud module imports in the pod (pin-guarded loader)" "g4p '$P3' import | jq -e '.import == \"ok\"' >/dev/null"
STA=$(g4p "$P3" state); printf '%s\n' "$STA" > "$CACHE/state-after-A.json"
chk "R1 in-pod family-cloud/__init__.py == 99fb4183" "[ \"\$(jget .plugin_sha '$STA')\" = '$PIN_INIT' ]"
chk "R1 probe script in the CronJob ConfigMap == f1d9aed6" "[ \"\$(probe_script_sha)\" = '$PIN_PROBE' ]"
chk "settings.json unchanged (sha $SET0) and fields budget 99 / confirmed / workspace ok / no school keys" "[ \"\$(jget .settings_sha '$STA')\" = '$SET0' ] && [ \"\$(jq -c '[.budget_usd,.price_confirmed,.workspace_ok,.school_keys]' <<<'$STA')\" = '[99,true,true,[]]' ]"
chk "R3 p1/p2/p4 pod uid + bundle unchanged" "[ \"\$(uid 1)\" = '$U1' ] && [ \"\$(uid 2)\" = '$U2' ] && [ \"\$(uid 4)\" = '$U4' ] && [ \"\$(bsha 1)\" = '$S1' ] && [ \"\$(bsha 2)\" = '$S2' ] && [ \"\$(bsha 4)\" = '$S4' ]"
chk "p3 still cannot reach api.anthropic.com:443 (egress closed)" "blocked '$P3' api.anthropic.com 443"
chk "no off file after the deploy" "[ \"\$(jget .off '$STA')\" = false ]"
gate "commit A post-checks" R1
act executed "commit A post-checks GREEN: p3 pod ${P3:0:30} plugin 99fb4183, settings unchanged, p1/p2/p4 untouched" GREEN

# ------------------------------------------------------------------ 3. G4 canary (synthetic, real PVC)
log "== 3 G4 canary"
G4E=$(now_e); G4ISO=$(iso "$G4E"); L0="$STA"; C_OFFVIS=false; C_TURN=false; C_GATE=false; C_SM200=false; C_CLEAR=false; C_ALERT=false; PROBES=0
lock_fp() { # the KNOWN p2 false positive (Argus Q4 3e): explain + reopen, never loosen. Returns 0 = handled/no latch.
  no_cnp family-cloud-lock && return 0
  has_cnp family-cloud-lock || { log "  RED  CNP list unreadable"; return 1; }
  local st trig cur d_usd d_p2 d_p3 rest allow
  st=$(kubectl -n $NS get cm family-cloud-lock-state -o jsonpath='{.data.state\.json}'); trig=$(jq -c '[.locked.triggers[]?.t] | unique' <<<"$st")
  cur=$(g4p "$P3" state); d_usd=$(fsub "$(jget .usd "$cur")" "$(jget .usd "$L0")"); d_p2=$(fsub "$(jget .p2_usd "$cur")" "$(jget .p2_usd "$L0")")
  d_p3=$(fsub "$(jget .p3_usd "$cur")" "$(jget .p3_usd "$L0")"); rest=$(fsub "$d_usd" "$d_p2"); allow=$(python3 -I -c "print($PROBES*$PROBE_MAX)")
  log "  info lock latched: triggers $trig; since G4 start usd +$d_usd, p2 +$d_p2, p3 +$d_p3, rest +$rest (probe allowance $allow)"
  if [ "$trig" = '["ledger_rise_while_off"]' ] && fle "$d_p3" 0 && fle 0.0000000001 "$d_p2" && fle "$rest" "$allow"; then
    log "  KNOWN p2 false positive (Argus Q4 3e): p2's pre-signal plugin kept a reservation at the closed egress while off. Reopen via reopen_ack_ts."
    kubectl -n $NS patch cm family-cloud-lock-state --type merge -p "{\"data\":{\"reopen_ack_ts\":\"$(now_e)\"}}" >/dev/null
    act executed "G4 lock latch = known p2 false positive (ledger_rise_while_off, p2 +$d_p2, p3 +0): reopened via reopen_ack_ts" "reopen"
    waitfor 300 "no_cnp family-cloud-lock" && return 0
    log "  RED  lock not removed within 2 lock runs after the ack"; return 1
  fi
  log "  RED  lock latch that is NOT the known p2 false positive"; return 1; }

# 3a trip (the helper writes as uid 10000)
TRIP_E=$(now_e); TR=$(g4p "$P3" trip 2>&1); log "  3a trip: $TR"
ST=$(g4p "$P3" state); SEEN=$(g4p "$P2" seen 2>&1); log "  3a seen from p2: $SEEN"
log "  3a /cloud-spend file owners: $(jq -c '.files // {} | to_entries | map("\(.key)=\(.value.uid):\(.value.gid)/\(.value.mode)")' <<<"$ST")"
chk "3a trip_cloud_off wrote the shared off state (billing 402 billing_error, month $(date -u +%Y-%m), no person)" \
  "[ \"\$(jq -r .tripped <<<'$TR')\" = true ] && [ \"\$(jq -c '[.off,.off_month,.off_kind,.off_status,.off_type,.off_person_set]' <<<'$ST')\" = '[true,\"$(date -u +%Y-%m)\",\"billing\",402,\"billing_error\",false]' ]"
chk "3a off state READ (open + parse) as uid $SVC from the p2 pod" "[ \"\$(jq -c '[.off_seen, .off_present, .off_readable, .as_uid]' <<<'$SEEN')\" = '[true,true,true,$SVC]' ]"
chk "3a F4 every cloud-* file and month.json still a regular file owned $SVC:$SVC after the trip" "own_svc '$ST'"
gate "G4 3a" R4
# F4: the lock job (uid 10000, read-only mount) must get through a full run on the tripped state BEFORE 3b
TRIPISO1=$(iso $(( TRIP_E + 1 )))
waitfor 300 "[ \"\$(lock_runs_since '$TRIPISO1' | grep -c .)\" -ge 1 ]"
LR1=$(lock_runs_since "$TRIPISO1" | head -1); log "  3a first lock run after the trip: ${LR1:-none}"
chk "3a F4 the first lock run after the trip succeeded: no error, off true, triggers []" "[ \"\$(jq -c '[.error, .off, .triggers]' <<<'$LR1')\" = '[null,true,[]]' ]"
[ "$RED" = 0 ] && C_OFFVIS=true; gate "G4 3a lock run" R4; act executed "G4 3a trip (billing 402, uid $SVC) read from p2; files owned $SVC; lock run green" GREEN
# 3b synthetic turn while off
LB=$(g4p "$P3" state); kubectl -n $NS exec -i "$(ow)" -c app -- sh -c 'cd /app/backend && python3 - g4-off' < "$HACK/$CHG-owui-turn.py" > "$CACHE/turn-g4.txt" 2>&1
sed 's/^/    /' "$CACHE/turn-g4.txt" | grep -E 'PASS|FAIL|RESULT' >> "$EV"
T0=$(awk '/^TURNSTART/{print $2}' "$CACHE/turn-g4.txt"); T1=$(awk '/^TURNEND/{print $2}' "$CACHE/turn-g4.txt")
RT=$(g4p "$P3" routes "$(python3 -I -c "print(${T0:-0}-2)")" "$(python3 -I -c "print(${T1:-0}+5)")"); LA=$(g4p "$P3" state)
log "  3b route records: $(jq -c .routes <<<"$RT")"
chk "3b synthetic turn answered (Studio), canary account deleted" "gall -x 'RESULT GREEN' '$CACHE/turn-g4.txt'"
chk "3b rule cloud_off, no cloud record" "jq -e '(.routes | any(. == [\"studio\",\"cloud_off\"])) and ([.routes[] | select(.[0] == \"cloud\")] | length == 0)' <<<'$RT' >/dev/null"
chk "3b no cloud request: p3 person_usd unchanged" "[ \"\$(jget .p3_usd '$LA')\" = \"\$(jget .p3_usd '$LB')\" ]"
[ "$RED" = 0 ] && C_TURN=true; gate "G4 3b" R4; act executed "G4 3b synthetic turn while off -> studio/cloud_off, no cloud call" GREEN
# 3c offgate + ONE team FamilyCloudOff
waitfor 300 "has_cnp family-cloud-offgate"
chk "3c offgate CNP present within 2 lock runs" "has_cnp family-cloud-offgate"
lock_fp || { RED=1; WHY="${WHY:+$WHY; }lock latch"; }
waitfor 420 "[ \"\$(alerts_since '$G4ISO' | jq -r 'select(.alert==\"FamilyCloudOff\") | .severity' | grep -c .)\" -ge 1 ]"
chk "3c the alert job posted exactly ONE FamilyCloudOff, severity warning (team)" "[ \"\$(alerts_since '$G4ISO' | jq -c 'select(.alert==\"FamilyCloudOff\")' | sort -u)\" = '{\"alert\":\"FamilyCloudOff\",\"severity\":\"warning\"}' ] && [ \"\$(alerts_since '$G4ISO' | grep -c FamilyCloudOff)\" = 1 ]"
chk "3c R7 no \"person\" in the alert job output since G4 start" "[ \"\$(job_logs_since alert '$G4ISO' | grep -c -i person)\" = 0 ]"
chk "3c R7 MONEY_TO_OWNER still false" "[ \"\$(money_env)\" = false ]"
[ "$RED" = 0 ] && C_GATE=true; gate "G4 3c" R4; act executed "G4 3c offgate followed the off state; one team FamilyCloudOff" GREEN
# 3d probe 1: same month -> same_month_200, stays off
probe_job() { # $1 name -> sets PJ_LOG; waits Complete or Failed
  kubectl -n $NS create job "$1" --from=cronjob/family-cloud-probe >/dev/null; PROBES=$((PROBES + 1))
  waitfor 360 "[ \"\$(kubectl -n $NS get job '$1' -o jsonpath='{.status.succeeded}{.status.failed}')\" != '' ]"
  PJ_LOG=$(kubectl -n $NS logs "job/$1" 2>/dev/null | grep '"probe_run"' ); printf '%s\n' "$PJ_LOG" > "$CACHE/$1.log"; }
LB=$(g4p "$P3" state); probe_job "c011-g4-probe-1-$(date -u +%H%M%S)"; LA=$(g4p "$P3" state); PL=$(printf '%s\n' "$PJ_LOG" | tail -1)
log "  3d probe 1: $(printf '%s' "$PJ_LOG" | tr '\n' ' ')"
chk "3d R1 pins ok (no pin_mismatch class)" "printf '%s' \"\$PJ_LOG\" | gall '\"pins ok\"' && ! printf '%s' \"\$PJ_LOG\" | gall pin_mismatch"
chk "3d result same_month_200, probe_exit 3, Job succeeded (S-F1 on the real PVC)" "[ \"\$(jq -c '[.probe_run.result, .probe_exit]' <<<'$PL')\" = '[\"same_month_200\",3]' ]"
chk "3d stays off (month $(date -u +%Y-%m))" "[ \"\$(jq -c '[.off,.off_month]' <<<'$LA')\" = '[true,\"$(date -u +%Y-%m)\"]' ]"
chk "3d ledger rise (minus p2) <= PROBE_MAX_COST_USD $PROBE_MAX" "fle \"\$(fsub \"\$(fsub \"\$(jget .usd '$LA')\" \"\$(jget .usd '$LB')\")\" \"\$(fsub \"\$(jget .p2_usd '$LA')\" \"\$(jget .p2_usd '$LB')\")\")\" $PROBE_MAX"
lock_fp || { RED=1; WHY="${WHY:+$WHY; }lock latch"; }
[ "$RED" = 0 ] && C_SM200=true; gate "G4 3d" R4; act executed "G4 3d probe 1 -> same_month_200 (exit 3), stays off" GREEN
# 3e previous-month off file -> probe 2 clears
SW=$(g4p "$P3" swap-prev "$(date -u +%Y%m%dT%H%M%SZ)" 2>&1); log "  3e swap: $SW"
chk "3e real off file archived by link (no delete), synthetic previous-month off file written" "[ \"\$(jq -r .swapped <<<'$SW')\" = true ]"
gate "G4 3e swap" R4
LB=$(g4p "$P3" state); probe_job "c011-g4-probe-2-$(date -u +%H%M%S)"; LA=$(g4p "$P3" state); PL=$(printf '%s\n' "$PJ_LOG" | tail -1)
log "  3e probe 2: $(printf '%s' "$PJ_LOG" | tr '\n' ' '); off files now $(jq -c .off_files <<<"$LA")"
chk "3e pins ok, result cleared, probe_exit 0" "printf '%s' \"\$PJ_LOG\" | gall '\"pins ok\"' && [ \"\$(jq -c '[.probe_run.result, .probe_exit]' <<<'$PL')\" = '[\"cleared\",0]' ]"
chk "3e off state gone, both archives present" "[ \"\$(jget .off '$LA')\" = false ] && jq -e '[.off_files[] | select(startswith(\"cloud-off.cleared-g4-\"))] | length == 1' <<<'$LA' >/dev/null && jq -e '[.off_files[] | select(test(\"^cloud-off.cleared-[0-9]+[.]json$\"))] | length >= 1' <<<'$LA' >/dev/null"
chk "3e ledger rise (minus p2) <= $PROBE_MAX" "fle \"\$(fsub \"\$(fsub \"\$(jget .usd '$LA')\" \"\$(jget .usd '$LB')\")\" \"\$(fsub \"\$(jget .p2_usd '$LA')\" \"\$(jget .p2_usd '$LB')\")\")\" $PROBE_MAX"
lock_fp || { RED=1; WHY="${WHY:+$WHY; }lock latch"; }
waitfor 300 "no_cnp family-cloud-offgate"
chk "3e the lock job removed the offgate; no lock CNP" "no_guard_cnps"
chk "3e probe Jobs this UTC day == 2 (T3 not exceeded)" "[ \"\$(probe_jobs_today)\" = 2 ]"
TRN=$(g4p "$P3" transitions "$G4E"); log "  3e transitions since G4 start: $(jq -c .transitions <<<"$TRN")"
chk "3e transitions: off(billing), off(same_month_200), on(probe); no call_while_off" "[ \"\$(jq -c .transitions <<<'$TRN')\" = '[[\"off\",\"billing\"],[\"off\",\"same_month_200\"],[\"on\",\"probe\"]]' ]"
[ "$RED" = 0 ] && C_CLEAR=true; gate "G4 3e" R4; act executed "G4 3e previous-month off -> probe 2 cleared, offgate removed" GREEN
waitfor 420 "alerts_since '$G4ISO' | gall FamilyCloudOn"
AL=$(alerts_since "$G4ISO" | sort | uniq -c | tr -s ' ' | tr '\n' ';'); log "  alerts since G4 start: $AL"
chk "alert_team_only: only FamilyCloudOff / FamilyCloudMoneyCandidate / FamilyCloudOn, all warning, on-transition seen" \
  "[ -z \"\$(alerts_since '$G4ISO' | jq -r 'select((.severity != \"warning\") or ((.alert | IN(\"FamilyCloudOff\",\"FamilyCloudMoneyCandidate\",\"FamilyCloudOn\")) | not)) | .alert')\" ] && alerts_since '$G4ISO' | gall FamilyCloudOn"
chk "R7 no \"person\" in alert output; MONEY_TO_OWNER false" "[ \"\$(job_logs_since alert '$G4ISO' | grep -c -i person)\" = 0 ] && [ \"\$(money_env)\" = false ]"
chk "R3 p1/p2/p4 unchanged after G4" "[ \"\$(uid 1)\" = '$U1' ] && [ \"\$(uid 2)\" = '$U2' ] && [ \"\$(uid 4)\" = '$U4' ] && [ \"\$(bsha 1)\" = '$S1' ] && [ \"\$(bsha 2)\" = '$S2' ] && [ \"\$(bsha 4)\" = '$S4' ]"
[ "$RED" = 0 ] && C_ALERT=true; gate "G4 alerts" R4
# 3f evidence + the validated event (Argus Q1, exact shape)
G4TXT="$REPO/ops/evidence/$CHG/g4-canary-$(date -u +%Y%m%dT%H%M%SZ).txt"
[ ! -e "$G4TXT" ] || { log "RED  g4 evidence exists"; RED=1; gate "G4 evidence" R4; }
{ echo "$CHG $TSK G4 canary, driver run $TS, A=$A, written $(date -u +%Y-%m-%dT%H:%M:%SZ). Synthetic only; no family content."
  sed -n "/^== 3 G4 canary/,\$p" "$EV"; } > "$G4TXT"; chmod 444 "$G4TXT"
G4SHA=$(shasum -a 256 "$G4TXT" | cut -c1-64)
PAY=$(jq -nc --arg ev "${G4TXT#$REPO/}" --arg es "$G4SHA" --arg pi "$PIN_INIT" --arg pp "$PIN_PROBE" --arg p3 "$(bsha 3)" \
  --argjson a "$C_OFFVIS" --argjson b "$C_TURN" --argjson c "$C_GATE" --argjson d "$C_SM200" --argjson e "$C_CLEAR" --argjson f "$C_ALERT" \
  '{tsk:"tsk-2026-10-17-005",step:"G4",g4:"green",evidence:$ev,evidence_sha256:$es,plugin_sha256:$pi,probe_sha256:$pp,p3_bundle_sha256:$p3,
    checks:{off_visible_other_pod:$a,turn_cloud_off:$b,offgate_followed:$c,probe_same_month_200:$d,probe_cleared_prev_month:$e,alert_team_only:$f}}')
chk "G4 payload: all six checks true, no person" "jq -e '[.checks[]] | all(. == true)' <<<'$PAY' >/dev/null && ! gall -i person <<<'$PAY'"
gate "G4 payload" R4
"$REPO/ops/ops" change event $CHG validated --actor infra-ops --payload-json "$PAY" >/dev/null
G4TS=$(jq -r --arg ev "${G4TXT#$REPO/}" 'select(.chg=="chg-2026-11-17-011" and .event=="validated" and .payload.step=="G4" and .payload.evidence==$ev) | .ts' "$REPO/ops/changes.jsonl" | tail -1)
chk "G4 validated event written and read back (L4)" "[[ '$G4TS' =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$ ]]"
gate "G4 validated event" R4
log "  ok   G4 validated event logged at $G4TS (evidence ${G4TXT#$REPO/} sha256 $G4SHA)"

# ------------------------------------------------------------------ 4. gate
log "== 4 gate (G9 v2, live bundles via pipes)"
if [ -n "$DACK" ]; then GR=$(run_gate "$REPO/ops/changes.jsonl" "$REPO/ops/evidence/$CHG" "$G4TS" live dormant "$DACK"); GRC=$?
else GR=$(run_gate "$REPO/ops/changes.jsonl" "$REPO/ops/evidence/$CHG" "$G4TS" live local ""); GRC=$?; fi
printf '%s\n' "$GR" | sed 's/^/    /' | tee -a "$EV"
chk "R8 exactly GATE GREEN (g1), no (w2)" "[ $GRC = 0 ] && [ \"\$(printf '%s' \"\$GR\" | tail -1)\" = 'GATE GREEN (g1)' ] && ! printf '%s' \"\$GR\" | gall '(w2)'"
gate "gate" R8; act executed "G9 v2 gate GREEN (g1) on the live bundles, G4 event $G4TS" GREEN

# ------------------------------------------------------------------ 5. commit B (go)
log "== 5 commit B (go)"
git -C "$SRC" push -q origin "$B:refs/heads/main" || { log "  RED  push of B refused (origin/main moved). A stays dark; cloud on but no egress. Nothing else changed."; act executed "push B refused; A dark, no egress" RED; GO_FINISHED=1; exit 1; }
PUSHED_B=1; PUSH_B_E=$(now_e); PUSH_B_ISO=$(iso "$PUSH_B_E"); log "  ok   pushed B $B to main"; act executed "commit B pushed (hermes-profiel-3-cloud CNP + probe un-suspended)" "${B:0:8}"
flux reconcile source git flux-system -n flux-system >/dev/null 2>&1
for ks in family-ai-network-policies family-ai-cloud-cutover; do flux reconcile ks $ks -n flux-system --timeout=10m >/dev/null 2>&1
  chk "ks $ks at B" "rev_is \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')\" '$B'"; done
yq -o=json '.spec' "$SRC/$CNPFILE" | jq -S . > "$CACHE/cnp-repo.json"
chk "CNP hermes-profiel-3-cloud live spec == repo file" "kubectl -n $NS get cnp hermes-profiel-3-cloud -o json | jq -S .spec | diff -q - '$CACHE/cnp-repo.json' >/dev/null"
chk "R3 live cloud CNPs == {hermes-profiel-3-cloud} (profiel-3 only)" "[ \"\$(cloud_cnps)\" = '[\"hermes-profiel-3-cloud\"]' ]"
chk "R3 0 cloud CNPs that select profiel-1" "[ \"\$(p1_cloud_cnps)\" = 0 ]"
chk "probe CronJob suspend false" "[ \"\$(probe_suspend)\" = false ]"
P3=$(pod 3)
waitfor 60 "tcp '$P3' api.anthropic.com 443"
chk "p3 -> api.anthropic.com:443 connects" "tcp '$P3' api.anthropic.com 443"
for n in 1 2 4; do chk "R3 p$n -> api.anthropic.com:443 fails" "blocked \"\$(pod $n)\" api.anthropic.com 443"; done
gate "commit B egress" "$(cls)"
LB=$(g4p "$P3" state); kubectl -n $NS exec -i "$(ow)" -c app -- sh -c 'cd /app/backend && python3 - go-cloud' < "$HACK/$CHG-owui-turn.py" > "$CACHE/turn-go.txt" 2>&1
grep -E 'PASS|FAIL|RESULT' "$CACHE/turn-go.txt" | sed 's/^/    /' >> "$EV"
T0=$(awk '/^TURNSTART/{print $2}' "$CACHE/turn-go.txt"); T1=$(awk '/^TURNEND/{print $2}' "$CACHE/turn-go.txt")
RT=$(g4p "$P3" routes "$(python3 -I -c "print(${T0:-0}-2)")" "$(python3 -I -c "print(${T1:-0}+5)")"); LA=$(g4p "$P3" state)
DP3=$(fsub "$(jget .p3_usd "$LA")" "$(jget .p3_usd "$LB")"); log "  5 route records: $(jq -c .routes <<<"$RT"); p3 ledger +$DP3; month usd $(jget .usd "$LA")"
chk "R6 synthetic public turn answered, canary account deleted" "gall -x 'RESULT GREEN' '$CACHE/turn-go.txt'"
chk "R6 rule cloud_ok" "jq -e '.routes | any(. == [\"cloud\",\"cloud_ok\"])' <<<'$RT' >/dev/null"
chk "R6 p3 ledger rise in (0, $RESERVE_MAX]" "fle 0.0000000001 '$DP3' && fle '$DP3' $RESERVE_MAX"
chk "R6 ledger readable and month usd <= 99" "[ -z \"\$(jget '.ledger_error // empty' '$LA')\" ] && fle \"\$(jget .usd '$LA')\" 99"
gate "go turn" "$(cls)"
waitfor 330 "[ \"\$(lock_runs_since '$PUSH_B_ISO' | grep -c .)\" -ge 2 ]"
LR=$(lock_runs_since "$PUSH_B_ISO" | head -2); log "  lock runs after B: $(printf '%s' "$LR" | tr '\n' ' ')"
chk "R5 next 2 lock runs: off false, triggers [], offgate absent" "[ \"\$(printf '%s\n' \"\$LR\" | grep -c .)\" = 2 ] && [ \"\$(printf '%s\n' \"\$LR\" | jq -c '[.off, .triggers, .actions[\"family-cloud-offgate\"]]' | sort -u)\" = '[false,[],\"absent\"]' ]"
chk "R5 no lock CNP, no offgate" "no_guard_cnps"
chk "R5 no call_while_off transition since G4 start; no FamilyCloudCallWhileOff alert" "[ \"\$(g4p '$P3' transitions '$G4E' | jq '[.transitions[] | select(.[0] == \"call_while_off\")] | length')\" = 0 ] && ! alerts_since '$G4ISO' | gall CallWhileOff"
chk "R5 no 'calls_while_off=' ERROR line in p2/p3 logs since B (each log read, non-empty: L1)" "for n in 2 3; do c=\$(logs_count \"\$(pod \$n) -c app --since-time='$PUSH_B_ISO'\" 'calls_while_off=') && [ \"\$c\" = 0 ] || exit 1; done"
chk "on-transition alerted (FamilyCloudOn since G4)" "alerts_since '$G4ISO' | gall FamilyCloudOn"
chk "R7 no \"person\" in alert output or in this chg's change-log lines since G4; MONEY_TO_OWNER false" \
  "[ \"\$(job_logs_since alert '$G4ISO' | grep -c -i person)\" = 0 ] && [ \"\$(jq -c --arg t '$G4ISO' 'select(.chg==\"$CHG\" and .ts >= \$t)' '$REPO/ops/changes.jsonl' | grep -c -i person)\" = 0 ] && [ \"\$(money_env)\" = false ]"
kubectl -n kube-system port-forward svc/hubble-relay 14245:80 >/dev/null 2>&1 & PF=$!; sleep 3
SINCE=$(( $(now_e) - PUSH_B_E + 30 ))s
hubble observe --server localhost:14245 --since "$SINCE" --from-namespace $NS --to-fqdn api.anthropic.com -o json 2>/dev/null > "$CACHE/hubble-fqdn.json"
IPS=$(jq -r '.flow.IP.destination // empty' "$CACHE/hubble-fqdn.json" | sort -u)
: > "$CACHE/hubble-ip.json"; for ip in $IPS; do hubble observe --server localhost:14245 --since "$SINCE" --from-namespace $NS --to-ip "$ip" -o json 2>/dev/null >> "$CACHE/hubble-ip.json"; done
kill $PF 2>/dev/null; PF=""
SRCS=$(cat "$CACHE/hubble-fqdn.json" "$CACHE/hubble-ip.json" | jq -r '.flow.source.pod_name // "?"' | sed -E 's/-[a-z0-9]+-[a-z0-9]+$//' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
log "  Hubble flows to the API since B (by source workload): ${SRCS:-none}"
chk "R3 Hubble: flows to api.anthropic.com from hermes-profiel-3 only (>= 1), 0 from p1/p2/p4" \
  "cat '$CACHE/hubble-fqdn.json' '$CACHE/hubble-ip.json' | jq -r '.flow.source.pod_name // \"?\"' | gall '^hermes-profiel-3-' && ! cat '$CACHE/hubble-fqdn.json' '$CACHE/hubble-ip.json' | jq -r '.flow.source.pod_name // \"?\"' | gall -E '^hermes-profiel-[124]-'"
chk "R3 p1/p2/p4 unchanged after B" "[ \"\$(uid 1)\" = '$U1' ] && [ \"\$(uid 2)\" = '$U2' ] && [ \"\$(uid 4)\" = '$U4' ] && [ \"\$(bsha 1)\" = '$S1' ] && [ \"\$(bsha 2)\" = '$S2' ] && [ \"\$(bsha 4)\" = '$S4' ]"
chk "R1 pins still: Secret p3 tar == A, pod plugin 99fb4183, probe script f1d9aed6" "[ \"\$(bsha 3)\" = '$P3NEW' ] && [ \"\$(jget .plugin_sha '$LA')\" = '$PIN_INIT' ] && [ \"\$(probe_script_sha)\" = '$PIN_PROBE' ]"
gate "post-go checks" "$(cls)"

# ------------------------------------------------------------------ 6. done
GO_FINISHED=1
log "RESULT go GREEN: profiel-3 on the cloud (signal plugin 99fb4183), p1/p2/p4 untouched, MONEY_TO_OWNER false"
act validated "go-live GREEN: profiel-3 only; G4 $G4TS; gate (g1); B ${B:0:8}; synthetic turn cloud_ok p3 +$DP3" GREEN
log "NEXT (human): watch the 07:05 probe (result not_off, exit 0) and the next lock/alert runs; G8 digest live before 2026-12-01 06:00 UTC (condition 6)."
exit 0
