#!/usr/bin/env bash
# chg-2026-10-20-010 land 2 GO-LIVE runbook: cloud model on hermes-profiel-3 only.
#
#   hack/ops/chg-2026-10-20-010-golive.sh --preflight <deploy-sha>
#   OWUI_ADMIN_KEY=... hack/ops/chg-2026-10-20-010-golive.sh --go <deploy-sha> --w2-event <ISO ts>
#   hack/ops/chg-2026-10-20-010-golive.sh --gate-only <deploy-sha> --w2-event <ISO ts>   # W2 gate only, then exit
#
# --preflight  read-only: renders, wiring check (+mutations), bundle C2 offline, empty diffs for profiel-1/2 + OWUI,
#              server-side dry-run, cluster state (pods, VolSync freshness, quota), W2 gate presence. No writes.
# --go         HARD GATE W2 first (closed by MEASUREMENT, Argus 21-10 03:31:48Z; replaces the register/in-session
#              rule): a change-log event on chg-2026-10-20-010 at <ISO ts> by actor infra-ops whose payload has
#                w2_evidence     path of Mack's read-only Anthropic-console evidence in ops/evidence/chg-2026-10-20-010/;
#                                the file exists and its UTC timestamp field (captured_utc | ts_utc | ts) is <= 24 h old
#                                (older -> re-measure first);
#                w2_readback_by  "atlas" | "security-engineer" (who re-read the evidence);
#                w2a             "no_payment_method_no_autoreload" | "workspace_limit_usd=<n>" with n <= 200 |
#                                "prepaid_autoreload_off_purchased_usd=0_org_limit_usd=<n>" with 0 < n <= 200
#                                (Argus 25-10 09:42:10Z): then the evidence JSON must ALSO hold captured_utc and
#                                auto_reload "off", purchased_balance_usd 0, invoicing "none", org_monthly_limit_usd
#                                == n, key_scope "organization", key_hint_match true, promo_credit_usd > 0 and
#                                promo_credit_expires_utc (...Z) later than now, and the bundle's plugin budget_usd
#                                <= promo_credit_usd (Argus 09:56:03Z: the cap follows the grant)
#              -> else refuse. The cloud cut-off at THAT capture's promo_credit_expires_utc
#              (chg-2026-10-20-010-cutoff.sh arm <sha> --w2-event <ts>, launchd on the Mini) must be armed for this
#              deploy at exactly that time and read back before --go. W2b is read back in the pod after deploy (input ceiling 65536, the ledger guard never
#              overwrote an existing month.json). Then: preflight again, VolumeSnapshots of
#              hermes-profiel-data-3 + open-webui-data, push to main, Flux reconcile, checks C2 C3 W3 W4 W5 W6,
#              restart + W5/W6 again, C4 (owui-c4.sh --apply), C5, C6+W7 synthetic canary, C7 Studio turns.
#              ANY red after the push -> automatic rollback: owui-c4.sh --rollback (if applied) and
#              chg-2026-10-20-010-rollback.sh --execute (git revert + Flux + price_confirmed=false), exit 1.
#
# Synthetic only: one temporary local OWUI account (c010-canary@acceptatie.invalid) in group owui-profiel-3, deleted
# at the end (also on failure). Responses are discarded unread; only HTTP codes, counts and digests are recorded.
# Side effects that stay (documented, accepted by the canary design): the canary turns become sessions in the
# profiel-3 Hermes store and count in the hourly usage numbers; the spend file holds the canary's cost.
# TODO (Argus 03:31:48Z, monthly, NOT automated yet): compare the plugin's /cloud-spend month.json usd with the
#      console cost of the key's workspace for the same month; a deviation > 10 % means cloud off
#      (price_confirmed=false via chg-2026-10-20-010-rollback.sh or a settings change) until explained.
# Argus 16:58:12Z (qa_passed, deviations a/b/c):
#  (a) "wis mijn geheugen" is NEVER sent live (the gezin plugin wipes the real memory by code): hack/ops/
#      chg-2026-10-20-010-replay.py replays it in the pod on the deployed gezin + family-cloud bytes (sha256 = pins),
#      only wis_alles stubbed; that turn and the next must route Studio. "vergeet" runs live on a unique synthetic
#      marker; the memory file set hash must be equal before/after and the marker absent (hash + presence only).
#  (b) the same replay takes the system prompt this pod's own Hermes built (state.db, in memory only, never printed
#      or stored): sha256(system part) == sha256(cloud-SOUL + date line), no other system text; preflight (pre)
#      and after the canary C6 session (post).
#  (c) the cloud count is the /cloud-spend month.json delta per turn (rises on every cloud turn, unchanged on every
#      Studio turn) + family-cloud failure lines = 0; Hubble flows are logged as corroboration, never a pass criterion.
# Secrets: OWUI_ADMIN_KEY / user tokens go to curl on stdin only; the cloud key is checked by name and length only.
# No rm. Evidence: ops/evidence/chg-2026-10-20-010/k8s-golive-<ts>-<mode>.txt (write-once).
set -uo pipefail
MODE="${1:?--preflight|--go|--gate-only}"; SHA="${2:?deploy sha}"; shift 2 || true
W2TS=""; while [ $# -gt 0 ]; do case "$1" in --w2-event) W2TS="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
SRC="$(git rev-parse --show-toplevel)"            # the worktree holding the deploy commit
HACK="$SRC/hack"; NS=family-ai; CHG=chg-2026-10-20-010
# the automatic rollback needs a land2-cloud-on-live checkout; the main family-ai checkout may be on another branch
export FAMILY_AI_REPO="${FAMILY_AI_REPO:-$HOME/.cache/$CHG/fai-cutoff-wt}"
PIN_IMAGE="docker.io/nousresearch/hermes-agent:v2026.9.24@sha256:fca358f12efd65bfaaca05884166f15c0e2788375ca30d77061ac1ebc96452b7"
TS=$(date -u +%Y%m%dT%H%M%SZ); CACHE="$HOME/.cache/$CHG/golive-$TS"; mkdir -p "$CACHE"
EV="$REPO/ops/evidence/$CHG/k8s-golive-$TS-${MODE#--}.txt"; [ ! -e "$EV" ] || { echo "evidence $EV exists (write-once): retry in a second" >&2; exit 1; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
log() { echo "$*" | tee -a "$EV"; }
RED=0; PUSHED=""; C4STATE=""; CANARY_UID=""
chk() { if eval "$2" >>"$CACHE/chk.log" 2>&1; then log "  ok   $1"; else log "  RED  $1"; RED=1; fi; }
# >>> c010-auth (Argus G-b + L1; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-auth.sh)
# Every push gets a FRESH App token minted right before it (contents:write on vdhinfra only, 1 h), handed to git
# via GIT_CONFIG_* env (never argv, never printed) and revoked right after. A run longer than the token lifetime
# can therefore never lose its own rollback push. Test-only: C010_MINT_CMD / C010_REVOKE_CMD replace the minter.
_C010_TOK=""
fresh_token() { # $1 purpose
  local t
  if [ -n "${C010_MINT_CMD:-}" ]; then t="$("$C010_MINT_CMD" 2>>"$CACHE/mint.log")"
  else t="$(/usr/bin/python3 -I "$HACK/ops/$CHG-mint.py" mint 2>>"$CACHE/mint.log")"; fi
  [ "${#t}" -ge 20 ] || { log "  RED  fresh App token for $1: mint failed (see $CACHE/mint.log)"; return 1; }
  _C010_TOK="$t"
  export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$t" | base64 | tr -d '\n')"; export GIT_CONFIG_VALUE_0
  t=""; log "  ok   fresh App token for $1 (contents:write, vdhinfra, env only)"
}
revoke_token() { # $1 purpose
  [ -n "$_C010_TOK" ] || return 0
  if [ -n "${C010_REVOKE_CMD:-}" ]; then printf '%s' "$_C010_TOK" | "$C010_REVOKE_CMD" 2>>"$CACHE/mint.log"
  else printf '%s' "$_C010_TOK" | /usr/bin/python3 -I "$HACK/ops/$CHG-mint.py" revoke 2>>"$CACHE/mint.log"; fi \
    && log "  ok   App token revoked after $1" || log "  info App token revoke failed after $1 (it expires within 1 h)"
  _C010_TOK=""; unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}
deploy_push() { # fresh token -> push $SHA:main -> revoke
  fresh_token "deploy push" || return 1
  git -C "$SRC" push -q origin "$SHA:main"; local rc=$?
  revoke_token "deploy push"; return $rc
}
rollback() { # called on any red after the push
  log "ROLLBACK: $1"
  [ -n "$C4STATE" ] && OWUI_ADMIN_KEY="$OWUI_ADMIN_KEY" "$HACK/ops/$CHG-owui-c4.sh" --rollback "$C4STATE" | tee -a "$EV"
  fresh_token "rollback push" || log "  RED  rollback continues with the caller's credential (if any)"
  "$HACK/ops/$CHG-rollback.sh" --execute "$SHA" "golive red: $1" | tee -a "$EV"
  revoke_token "rollback push"
  log "RESULT go RED -> rolled back"; exit 1
}
# <<< c010-auth
gate() { [ "$RED" = 0 ] || { if [ -n "$PUSHED" ]; then rollback "$1"; else log "RESULT ${MODE#--} RED at $1 (nothing pushed)"; exit 1; fi; }; }
pod() { kubectl -n $NS get pod -l "app.kubernetes.io/instance=hermes-profiel-$1" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
xp() { kubectl -n $NS exec "$1" -c app -- "${@:2}"; }   # exec in a hermes app container
envnames() { xp "$1" sh -c 'env | cut -d= -f1'; }
log "$CHG go-live ${MODE#--} $TS deploy=$SHA (k8s-engineer; uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate)"

# ---------------------------------------------------------------- W2 hard gate (go only, before anything else)
if [ "$MODE" = --go ] || [ "$MODE" = --gate-only ]; then
  [ -n "$W2TS" ] || { log "REFUSED: --w2-event <ts> missing (W2 closes by the console evidence, Argus 03:31:48Z)"; exit 2; }
  # test-only overrides (scratch copies): C010_CHANGES, C010_EVIDENCE_DIR, C010_SETTINGS; never set them for a real go
  # budget_usd comes from the family-cloud settings.json inside THIS deploy commit's profiel-3 bundle (Argus 09:56:03Z)
  W2SET="${C010_SETTINGS:-$CACHE/gate-settings.json}"
  [ -n "${C010_SETTINGS:-}" ] || sops -d --extract '["data"]["bundle.tar.gz"]' \
      "$SRC/kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml" 2>/dev/null | base64 -d 2>/dev/null |
      tar -xzO plugins/model-providers/family-cloud/settings.json > "$W2SET" 2>/dev/null
  W2OUT=$(python3 -I - "${C010_CHANGES:-$REPO/ops/changes.jsonl}" "$CHG" "$W2TS" \
      "${C010_EVIDENCE_DIR:-$REPO/ops/evidence/$CHG}" "$REPO" "$W2SET" 2>&1 <<'PY'
import datetime as dt, json, os, re, sys
path, chg, ts, evdir, repo, settings_path = sys.argv[1:7]
evs = [e for e in map(json.loads, filter(str.strip, open(path)))
       if e.get("chg") == chg and e.get("ts") == ts and e.get("actor") == "infra-ops"]
if not evs:
    sys.exit("no infra-ops event on %s at %s" % (chg, ts))
p = evs[-1].get("payload") or {}
ev = p.get("w2_evidence")
if not isinstance(ev, str) or not ev.strip():
    sys.exit("w2_evidence missing")
real_dir = os.path.realpath(evdir)
cand = ev if os.path.isabs(ev) else os.path.join(repo, ev)
if not os.path.isfile(cand) and not os.path.isabs(ev):
    cand = os.path.join(evdir, os.path.basename(ev))
f = os.path.realpath(cand)
if os.path.dirname(f) != real_dir or not os.path.isfile(f):
    sys.exit("w2_evidence is not an existing file directly in " + os.path.basename(real_dir) + "/")
try:
    doc = json.load(open(f))
    stamp = next(doc[k] for k in ("captured_utc", "ts_utc", "ts") if isinstance(doc.get(k), str))
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z", stamp):
        raise ValueError
    t = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
except Exception:
    sys.exit("w2_evidence has no UTC timestamp field (captured_utc | ts_utc | ts, ...Z)")
age = (dt.datetime.now(dt.timezone.utc) - t).total_seconds()
if age > 24 * 3600 or age < -300:
    sys.exit("w2_evidence is %.1f h old (> 24 h or in the future): re-measure the console first" % (age / 3600))
if p.get("w2_readback_by") not in ("atlas", "security-engineer"):
    sys.exit("w2_readback_by must be atlas or security-engineer")
w2a = p.get("w2a")
W2A_HELP = ("w2a must be no_payment_method_no_autoreload, workspace_limit_usd=<n> or "
            "prepaid_autoreload_off_purchased_usd=0_org_limit_usd=<n>, with 0 < n <= 200")
m = re.fullmatch(r"workspace_limit_usd=(\d+(\.\d+)?)", w2a) if isinstance(w2a, str) else None
pp = re.fullmatch(r"prepaid_autoreload_off_purchased_usd=0_org_limit_usd=(\d+(\.\d+)?)", w2a) if isinstance(w2a, str) else None
extra = ""
if pp:
    # Argus 25-10 09:42:10Z pre-go item 1: prepaid account, the evidence JSON itself must show every bound
    n = float(pp.group(1))
    if not 0 < n <= 200:
        sys.exit(W2A_HELP)
    import math
    def num(k):
        v = doc.get(k)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
            sys.exit("w2_evidence field %s missing or not a finite number" % k)
        return float(v)
    def txt(k):
        v = doc.get(k)
        if not isinstance(v, str):
            sys.exit("w2_evidence field %s missing or not a string" % k)
        return v
    if not isinstance(doc.get("captured_utc"), str):
        sys.exit("w2_evidence field captured_utc missing (required for the prepaid w2a)")
    if txt("auto_reload") != "off":
        sys.exit("w2_evidence auto_reload is not 'off'")
    if num("purchased_balance_usd") != 0:
        sys.exit("w2_evidence purchased_balance_usd is not 0 (purchased credit is new money: owner directly)")
    if txt("invoicing") != "none":
        sys.exit("w2_evidence invoicing is not 'none'")
    if num("org_monthly_limit_usd") != n:
        sys.exit("w2_evidence org_monthly_limit_usd does not equal the w2a limit")
    if txt("key_scope") != "organization":
        sys.exit("w2_evidence key_scope is not 'organization'")
    if "key_hint_match" not in doc:
        sys.exit("w2_evidence field key_hint_match missing")
    if doc["key_hint_match"] is not True:
        sys.exit("w2_evidence key_hint_match is not true")
    if not num("promo_credit_usd") > 0:
        sys.exit("w2_evidence promo_credit_usd is not > 0")
    exp_s = txt("promo_credit_expires_utc")
    try:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z", exp_s):
            raise ValueError
        exp = dt.datetime.fromisoformat(exp_s.replace("Z", "+00:00"))
    except Exception:
        sys.exit("w2_evidence promo_credit_expires_utc is not a UTC timestamp (...Z)")
    if not dt.datetime.now(dt.timezone.utc) < exp:
        sys.exit("w2_evidence promotional credit expired at %s: cloud stays off" % exp_s)
    # the plugin cap follows the grant (Argus 09:56:03Z): settings budget_usd <= promo_credit_usd
    try:
        budget = json.load(open(settings_path)).get("budget_usd")
    except Exception:
        budget = None
    if isinstance(budget, bool) or not isinstance(budget, (int, float)) or not math.isfinite(budget):
        sys.exit("plugin settings budget_usd unreadable (bundle settings.json of this deploy)")
    if budget > num("promo_credit_usd"):
        sys.exit("plugin budget_usd %g > promo_credit_usd %g: the cap must follow the grant" % (budget, num("promo_credit_usd")))
    # cut-off time for chg-2026-10-20-010-cutoff.sh: the expiry of THIS accepted grant, floored to whole seconds
    extra = ", budget_usd %g <= promo %g, promo_credit_expires_utc=%s" % (budget, num("promo_credit_usd"), exp.strftime("%Y-%m-%dT%H:%M:%SZ"))
elif not (w2a == "no_payment_method_no_autoreload" or (m and 0 < float(m.group(1)) <= 200)):
    sys.exit(W2A_HELP)
print("evidence %s (%.1f h old), readback %s, w2a %s%s" % (os.path.basename(f), age / 3600, p["w2_readback_by"], w2a, extra))
PY
) || { log "REFUSED W2: $W2OUT"; exit 2; }
  log "W2 gate: event $W2TS by infra-ops: $W2OUT"
  [ "$MODE" = --gate-only ] && { log "RESULT gate-only GREEN (stopped before preflight; nothing done)"; exit 0; }
  [ -n "${OWUI_ADMIN_KEY:-}" ] || { log "REFUSED: OWUI_ADMIN_KEY missing (C4/C5/C6/C7)"; exit 2; }
fi

# ---------------------------------------------------------------- preflight (read-only)
log "== preflight"
git -C "$REPO" fetch -q origin
chk "deploy commit is HEAD of $SRC and descends from origin/main" \
  "[ \"\$(git -C '$SRC' rev-parse HEAD)\" = \"\$(git -C '$SRC' rev-parse '$SHA')\" ] && git -C '$SRC' merge-base --is-ancestor origin/main '$SHA'"
chk "worktree clean" "[ -z \"\$(git -C '$SRC' status --porcelain)\" ]"
# rollback.sh reverts exactly <deploy-sha>: it must be the wiring commit (adds the cloud CNP), never a tooling commit
chk "deploy commit is the one that adds the cloud CNP (what rollback/cut-off revert)" \
  "git -C '$SRC' diff-tree --no-commit-id --name-status -r '$SHA' | grep -qxF \"A\$(printf '\t')kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml\""
chk "rollback prerequisite: FAMILY_AI_REPO is a clean land2-cloud-on-live checkout" \
  "[ \"\$(git -C '$FAMILY_AI_REPO' rev-parse --abbrev-ref HEAD)\" = land2-cloud-on-live ] && [ -z \"\$(git -C '$FAMILY_AI_REPO' status --porcelain -- content/cloudmodel.json)\" ]"
chk "push auth: a fresh scoped App token can push (git push --dry-run, no ref changes), then revoked" \
  "fresh_token preflight && GIT_TERMINAL_PROMPT=0 git -C '$REPO' push --dry-run -q origin origin/main:refs/heads/main; r=\$?; revoke_token preflight; [ \$r = 0 ]"
if [ "$MODE" = --go ]; then
  W2EXP=$(printf '%s\n' "$W2OUT" | sed -n 's/.*promo_credit_expires_utc=\([0-9TZ:-]*\).*/\1/p')
  chk "cut-off armed for $SHA at the accepted grant expiry ${W2EXP:-(no grant in this w2a)} and read back (launchd, Argus item 3)" \
    "'$SRC/hack/ops/$CHG-cutoff.sh' readback '$SHA' | tee -a '$EV' | grep \"trigger_utc=${W2EXP:-[0-9]}\" >/dev/null"
else
  log "  info cut-off: $("$SRC/hack/ops/$CHG-cutoff.sh" readback "$SHA" 2>&1 | head -1) (--go refuses unless armed for $SHA)"
fi
# plugin from the deployed bundle -> PINNED_IMAGE source for the wiring check
B="$SRC/kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml"; mkdir -p "$CACHE/new" "$CACHE/main"
sops -d --extract '["data"]["bundle.tar.gz"]' "$B" | base64 -d > "$CACHE/new.tgz"
git -C "$SRC" show origin/main:kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml > "$CACHE/main.sops.yaml"
sops -d --extract '["data"]["bundle.tar.gz"]' "$CACHE/main.sops.yaml" | base64 -d > "$CACHE/main.tgz"
tar -xzf "$CACHE/new.tgz" -C "$CACHE/new"; tar -xzf "$CACHE/main.tgz" -C "$CACHE/main"
NEW_OUTER=$(shasum -a 256 "$CACHE/new.tgz" | cut -d' ' -f1); MAIN_OUTER=$(shasum -a 256 "$CACHE/main.tgz" | cut -d' ' -f1)
log "  bundle outer: main ${MAIN_OUTER:0:12} -> new ${NEW_OUTER:0:12}"
chk "C2 offline: new inner SHA256SUMS verify" "(cd '$CACHE/new' && shasum -a 256 -c --strict --quiet SHA256SUMS)"
chk "C2 offline: vs main only config.yaml changed + 4 family-cloud added" \
  "[ \"\$(diff -rq '$CACHE/main' '$CACHE/new' | sed 's#$CACHE/##g' | LC_ALL=C sort)\" = \"\$(printf '%s\n' 'Files main/SHA256SUMS and new/SHA256SUMS differ' 'Files main/config.yaml and new/config.yaml differ' 'Only in new/plugins/model-providers: family-cloud' | LC_ALL=C sort)\" ] && [ \"\$(ls '$CACHE/new/plugins/model-providers/family-cloud' | tr '\n' ' ')\" = '__init__.py cloud-SOUL.md plugin.yaml settings.json ' ]"
chk "C2 offline: pins" "cd '$CACHE/new' && printf '%s\n' \
  'fdd58658371d2ceb9226620739a004545a20fa5902cc4c4e16b6a22ffff67780  config.yaml' \
  'b75a620fd26198edc665d4b9b05f60a768d7fb667400b3ecf110b395cd31b827  plugins/model-providers/family-cloud/__init__.py' \
  'ba0794c5647d780f2edfddc806ba58f7519e80cc9975c86be7f0c7e950af4046  plugins/model-providers/family-cloud/plugin.yaml' \
  'd3ea565e3280419b44567f57b87050d644cb25e26b015091eadb71ea99b7c542  plugins/model-providers/family-cloud/settings.json' \
  'b67506a71c1f29cbbacee91e487ad74c5a8736a32047cf6575ac61c70b356fd0  plugins/model-providers/family-cloud/cloud-SOUL.md' | shasum -a 256 -c --strict --quiet"
chk "W3/W4/W5/W6 render check + mutation self-test" \
  "(cd '$SRC' && python3 -I hack/family-ai/check-cloud-wiring.py --plugin '$CACHE/new/plugins/model-providers/family-cloud/__init__.py' --self-test)"
chk "W2b ledger guard offline tests (fresh, mid-month refuse, month change, corrupt refuse, race)" "python3 -I '$SRC/hack/family-ai/test_cloud_spend_init.py'"
mkdir -p "$CACHE/r/main" "$CACHE/r/new"; git -C "$SRC" archive origin/main kubernetes/main/apps/family-ai | tar -x -C "$CACHE/r/main"
for t in hermes/profiel-1 hermes/profiel-2 open-webui/app open-webui/route gezinsdienst/app kennisdienst/app huiswerk-refresh/app; do
  n=$(echo $t | tr / _)
  kustomize build "$CACHE/r/main/kubernetes/main/apps/family-ai/$t" > "$CACHE/r/main/$n.yaml"
  kustomize build "$SRC/kubernetes/main/apps/family-ai/$t" > "$CACHE/r/new/$n.yaml"
  chk "empty render diff $t" "cmp -s '$CACHE/r/main/$n.yaml' '$CACHE/r/new/$n.yaml'"
done
for t in hermes network-policies/app; do n=$(echo $t | tr / _); kustomize build "$SRC/kubernetes/main/apps/family-ai/$t" > "$CACHE/r/new/$n.yaml"; done
chk "network-policies diff is additive only" "! diff <(kustomize build '$CACHE/r/main/kubernetes/main/apps/family-ai/network-policies/app') '$CACHE/r/new/network-policies_app.yaml' | grep -q '^<'"
chk "server-side dry-run hermes (non-bundle) + network-policies" \
  "yq 'select(.kind != \"Secret\" or (.metadata.name | test(\"bundle\") | not))' '$CACHE/r/new/hermes.yaml' | kubectl apply -n $NS --server-side --dry-run=server --field-manager=kustomize-controller -f - && kubectl apply -n $NS --server-side --dry-run=server --field-manager=kustomize-controller -f '$CACHE/r/new/network-policies_app.yaml'"
for n in 1 2 3; do chk "hermes-profiel-$n Running+Ready" "kubectl -n $NS wait pod/\$(pod $n) --for=condition=Ready --timeout=10s"; done
chk "open-webui Ready" "kubectl -n $NS wait pod -l app.kubernetes.io/name=open-webui --for=condition=Ready --timeout=10s"
for rs in hermes-profiel-3 open-webui; do
  chk "VolSync $rs synced < 65 min ago" "python3 -I -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace(\"Z\",\"+00:00\")); sys.exit(0 if (d.datetime.now(d.timezone.utc)-t).total_seconds()<3900 else 1)' \"\$(kubectl -n $NS get replicationsource $rs -o jsonpath='{.status.lastSyncTime}')\""
done
chk "quota: >= 1 PVC and 64Mi limits.memory headroom" "kubectl -n $NS get resourcequota -o json | python3 -I -c 'import sys,json; q=json.load(sys.stdin)[\"items\"][0][\"status\"]; mi=lambda v: float(v[:-2])*(1024 if v.endswith(\"Gi\") else 1) if v[-2:] in (\"Gi\",\"Mi\") else float(v)/2**20; sys.exit(0 if int(q[\"hard\"][\"persistentvolumeclaims\"])-int(q[\"used\"][\"persistentvolumeclaims\"])>=1 and mi(q[\"hard\"][\"limits.memory\"])-mi(q[\"used\"][\"limits.memory\"])>=64 else 1)'"
P3=$(pod 3); P1=$(pod 1); P2=$(pod 2)
replay_in() { # $1 = pre|post, $2 = since epoch : JSON for the replay (pins from the bundle; pre also ships family-cloud)
  python3 -I - "$CACHE/new/plugins" "$1" "$2" <<'PY'
import base64, hashlib, json, sys
d, mode, since = sys.argv[1] + "/", sys.argv[2], float(sys.argv[3])
rels = ["model-providers/family-cloud/__init__.py", "model-providers/family-cloud/settings.json",
        "model-providers/family-cloud/cloud-SOUL.md", "gezin/__init__.py"]
pins = {r: hashlib.sha256(open(d + r, "rb").read()).hexdigest() for r in rels}
files = {r: base64.b64encode(open(d + r, "rb").read()).decode() for r in rels if mode == "pre" and r.startswith("model-providers/")}
json.dump({"mode": mode, "since": since, "pins": pins, "files": files}, sys.stdout)
PY
}
replay() { replay_in "$1" "$2" | kubectl -n $NS exec -i "$(pod 3)" -c app -- env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c "$(cat "$HACK/ops/$CHG-replay.py")" > "$CACHE/replay-$1.json"; local rc=$?; jq -c '{mode, result, system_sha, want_sha, prompt_sha}' "$CACHE/replay-$1.json" | sed 's/^/  replay /' | tee -a "$EV"; return $rc; }
chk "(a)+(b) replay pre-deploy: wis -> Studio x2 (only wis_alles stubbed), Hermes prompt -> cloud-SOUL + date only" "replay pre 0"
chk "cloud CNP not yet present" "! kubectl -n $NS get cnp hermes-profiel-3-cloud"
chk "p3 has no CLOUD_API_KEY yet (name only)" "! envnames $P3 | grep -qx CLOUD_API_KEY"
if [ "$MODE" = --preflight ]; then
  w2=$(python3 -I -c 'import json,sys; print(sum(1 for e in map(json.loads, filter(str.strip, open(sys.argv[1]))) if e.get("chg")==sys.argv[2] and isinstance((e.get("payload") or {}).get("w2_source"), str)))' "$REPO/ops/changes.jsonl" $CHG)
  log "  info W2 events recorded on $CHG: $w2 (go refuses without one)"
  log "RESULT preflight $([ $RED = 0 ] && echo GREEN || echo RED)"; exit $RED
fi
gate "preflight"

# ---------------------------------------------------------------- snapshots + pre-state
log "== snapshots + pre-state"
for p in hermes-profiel-data-3 open-webui-data; do
  kubectl -n $NS apply -f - >/dev/null <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: c010-golive-$(echo $TS | tr 'TZ' 'tz')-$p, labels: {app.kubernetes.io/part-of: family-ai-test, change: $CHG}}
spec: {volumeSnapshotClassName: csi-ceph-blockpool, source: {persistentVolumeClaimName: $p}}
EOF
  chk "VolumeSnapshot $p readyToUse" "kubectl -n $NS wait volumesnapshot/c010-golive-$(echo $TS | tr 'TZ' 'tz')-$p --for=jsonpath='{.status.readyToUse}'=true --timeout=5m"
done
export OWUI_SNAPSHOT="c010-golive-$(echo $TS | tr 'TZ' 'tz')-open-webui-data"
U1=$(kubectl -n $NS get pod $P1 -o jsonpath='{.metadata.uid}'); U2=$(kubectl -n $NS get pod $P2 -o jsonpath='{.metadata.uid}')
M1=$(xp $P1 cat /opt/data/.family-ai-seeded); M2=$(xp $P2 cat /opt/data/.family-ai-seeded)
HSPEC=$(kubectl -n $NS get cnp hermes -o jsonpath='{.spec}' | shasum -a 256 | cut -c1-16)
log "  p1 ${U1:0:8} seeded ${M1:0:12}; p2 ${U2:0:8} seeded ${M2:0:12}; base CNP hermes spec ${HSPEC}"
gate "snapshots"

# ---------------------------------------------------------------- push + reconcile
log "== push + reconcile"
deploy_push || { log "RED push refused or no token (main moved?): rebase + re-run preflight; nothing pushed"; exit 1; }
PUSHED="$SHA"; log "  pushed $SHA to main"
flux reconcile source git flux-system -n flux-system >>"$CACHE/chk.log" 2>&1
for ks in family-ai-network-policies family-ai-hermes; do
  flux reconcile ks $ks -n flux-system --timeout=10m >>"$CACHE/chk.log" 2>&1
  chk "ks $ks Ready at $SHA" "[ \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')\" = 'main@sha1:$SHA' ] && kubectl -n flux-system wait ks/$ks --for=condition=Ready --timeout=5m"
done
chk "p3 rollout complete" "kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=10m"
gate "reconcile"
P3=$(pod 3)

# ---------------------------------------------------------------- C2 C3 W3 W4 W5 W6
post_checks() {
  local tag="$1"; P3=$(pod 3)
  log "== checks ($tag) on $P3"
  chk "C2 p3 seeded bundle = new outer" "[ \"\$(xp $P3 cat /opt/data/.family-ai-seeded)\" = '$NEW_OUTER' ]"
  chk "C2 p3 deployed files == bundle SHA256SUMS (18)" "xp $P3 sh -c 'cd /opt/data && sha256sum -c --strict --quiet -' < '$CACHE/new/SHA256SUMS' && [ \"\$(xp $P3 sh -c 'cd /opt/data && { ls config.yaml SOUL.md; find plugins -type f ! -path \"*/__pycache__/*\"; } | LC_ALL=C sort')\" = \"\$(awk '{print \$2}' '$CACHE/new/SHA256SUMS' | LC_ALL=C sort)\" ]"
  chk "C2 p1/p2 untouched (pod uid + seeded bundle)" "[ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-1 -o jsonpath='{.items[0].metadata.uid}')\" = '$U1' ] && [ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-2 -o jsonpath='{.items[0].metadata.uid}')\" = '$U2' ] && [ \"\$(xp $P1 cat /opt/data/.family-ai-seeded)\" = '$M1' ] && [ \"\$(xp $P2 cat /opt/data/.family-ai-seeded)\" = '$M2' ]"
  chk "C3/W5 env HERMES_IMAGE == pod image == PINNED_IMAGE" "[ \"\$(xp $P3 printenv HERMES_IMAGE)\" = \"\$(kubectl -n $NS get pod $P3 -o jsonpath='{.spec.containers[?(@.name==\"app\")].image}')\" ] && [ \"\$(xp $P3 printenv HERMES_IMAGE)\" = '$PIN_IMAGE' ]"
  chk "C3/W5 runtime_pinned()=True in the pod" "xp $P3 env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c '
import importlib.util, os, sys
os.chdir(\"/opt/hermes\"); sys.path.insert(0, \"/opt/hermes\")
import hermes_cli, agent.chat_completion_helpers, gateway.platforms.api_server
s = importlib.util.spec_from_file_location(\"c010_probe\", \"/opt/data/plugins/model-providers/family-cloud/__init__.py\")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
sys.exit(0 if m.runtime_pinned() is True else 1)'"
  chk "C3 p1/p2 no family-cloud dir, no CLOUD_* / HERMES_IMAGE env" "for p in $P1 $P2; do ! xp \$p test -e /opt/data/plugins/model-providers/family-cloud || exit 1; ! envnames \$p | grep -q '^CLOUD_\|^HERMES_IMAGE$' || exit 1; done"
  # W3
  chk "W3 CNP live spec == repo file" "[ \"\$(kubectl -n $NS get cnp hermes-profiel-3-cloud -o json | jq -cS .spec)\" = \"\$(yq -o=json '.spec' '$SRC/kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml' | jq -cS .)\" ]"
  chk "W3 base CNP hermes unchanged" "[ \"\$(kubectl -n $NS get cnp hermes -o jsonpath='{.spec}' | shasum -a 256 | cut -c1-16)\" = '$HSPEC' ]"
  tcp() { xp "$1" /opt/hermes/.venv/bin/python -c "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=6).close()" "$2" "$3"; }
  AIP=$(xp $P3 /opt/hermes/.venv/bin/python -c 'import socket; print(socket.gethostbyname("api.anthropic.com"))' 2>/dev/null)
  chk "W3 p3 -> api.anthropic.com:443 connects" "tcp $P3 api.anthropic.com 443"
  chk "W3 p3 -> api.anthropic.com:80 fails" "! tcp $P3 api.anthropic.com 80"
  chk "W3 p3 -> other public host 1.1.1.1:443 fails" "! tcp $P3 1.1.1.1 443"
  chk "W3 p3 -> www.example.com:443 fails" "! tcp $P3 www.example.com 443"
  chk "W3 p3 -> Studio 172.16.2.200:443 still connects" "tcp $P3 172.16.2.200 443"
  for p in $P1 $P2; do
    chk "W3 $p -> api.anthropic.com:443 fails (name)" "! tcp $p api.anthropic.com 443"
    chk "W3 $p -> api.anthropic.com IP ($AIP):443 fails" "[ -n '$AIP' ] && ! tcp $p '$AIP' 443"
  done
  # W4
  chk "W4 p3 Secret has CLOUD_API_KEY, length >= 47 (value not read out)" "[ \"\$(kubectl -n $NS get secret family-ai-hermes-profiel-3 -o json | jq -r '.data.CLOUD_API_KEY // \"\" | @base64d | length')\" -ge 47 ]"
  chk "W4 p3 app env has CLOUD_API_KEY (name)" "envnames $P3 | grep -qx CLOUD_API_KEY"
  chk "W4 p3 init containers: no envFrom / secret env" "[ \"\$(kubectl -n $NS get pod $P3 -o json | jq '[.spec.initContainers[] | select(.envFrom or ([.env[]?.valueFrom.secretKeyRef] | map(select(.)) | length > 0))] | length')\" = 0 ]"
  chk "W4 p1/p2/OWUI Secrets + env without CLOUD_API_KEY" "for s in family-ai-hermes-profiel-1 family-ai-hermes-profiel-2; do kubectl -n $NS get secret \$s -o json | jq -e '.data | has(\"CLOUD_API_KEY\") | not' >/dev/null || exit 1; done; for p in $P1 $P2; do ! envnames \$p | grep -qx CLOUD_API_KEY || exit 1; done; ! kubectl -n $NS exec deploy/open-webui -c app -- sh -c 'env | cut -d= -f1' | grep -qx CLOUD_API_KEY"
  # W2b readback (numeric reads only)
  chk "W2b pod settings: input_token_ceiling = 65536 = context_tokens" "[ \"\$(xp $P3 cat /opt/data/plugins/model-providers/family-cloud/settings.json | jq -c '[.input_token_ceiling, .context_tokens]')\" = '[65536,65536]' ]"
  # W6
  chk "W6 spend PVC Bound + mounted on p3 only" "[ \"\$(kubectl -n $NS get pvc hermes-profiel-cloud-spend-3 -o jsonpath='{.status.phase}')\" = Bound ]"
  chk "W6 month.json numbers only" "xp $P3 cat /cloud-spend/month.json | python3 -I -c '
import json, sys, re
d = json.load(sys.stdin); k = {\"person_usd\",\"month\",\"usd\",\"input_tokens\",\"output_tokens\",\"cache_read_tokens\",\"cache_write_tokens\"}
ok = set(d) == k and re.fullmatch(r\"[0-9]{4}-[0-9]{2}\", d[\"month\"]) and all(isinstance(d[x], (int, float)) and not isinstance(d[x], bool) for x in k - {\"month\",\"person_usd\"}) \
     and set(d[\"person_usd\"]) == {\"profiel-1\",\"profiel-2\",\"profiel-3\"} and all(isinstance(v, (int, float)) for v in d[\"person_usd\"].values()) and d[\"usd\"] <= 200
sys.exit(0 if ok else 1)'"
}
post_checks first-start
chk "W6 first start: ledger guard created/kept month.json" "kubectl -n $NS logs $P3 -c cloud-spend-init | grep -q 'month.json created\|present, kept'"
chk "W2b ledger guard did not refuse; cloud price_confirmed still true in the pod" "! kubectl -n $NS logs $P3 -c cloud-spend-init | grep -q REFUSED && [ \"\$(xp $P3 cat /opt/data/plugins/model-providers/family-cloud/settings.json | jq -r .price_confirmed)\" = true ]"
chk "W2b marker numbers only" "xp $P3 cat /cloud-spend/.ledger-marker | jq -e 'keys == [\"inits\",\"month\"] and (.inits|type==\"number\") and (.month|test(\"^[0-9]{4}-[0-9]{2}$\"))' >/dev/null"
gate "post-deploy checks"
# W5/W6 after a restart: runtime_pinned stays true, the month total survives
MJ1=$(xp $P3 sha256sum /cloud-spend/month.json | cut -c1-64)
kubectl -n $NS rollout restart deploy/hermes-profiel-3 >/dev/null
chk "p3 restart rollout" "kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=10m"
post_checks after-restart
chk "W6/W2b restart: month.json byte-equal, guard kept it and never re-created it" "[ \"\$(xp \$(pod 3) sha256sum /cloud-spend/month.json | cut -c1-64)\" = '$MJ1' ] && kubectl -n $NS logs \$(pod 3) -c cloud-spend-init | grep -q 'present, kept' && ! kubectl -n $NS logs \$(pod 3) -c cloud-spend-init | grep -q 'created\|REFUSED'"
gate "restart checks"
P3=$(pod 3)

# ---------------------------------------------------------------- C4 + C5 (OWUI)
log "== C4 + C5"
OWUI_ADMIN_KEY="$OWUI_ADMIN_KEY" OWUI_SNAPSHOT="$OWUI_SNAPSHOT" "$HACK/ops/$CHG-owui-c4.sh" --apply | tee -a "$EV"
C4STATE=$(ls -t "$REPO/ops/evidence/$CHG/"k8s-owui-c4-*-before.json 2>/dev/null | head -1)
chk "C4 green" "tail -1 '$EV' | grep -q 'RESULT C4 GREEN'"
OW=$(kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
chk "C5 task model external = household-chat, never profiel-N; tags/follow-up/autocomplete/query off" "kubectl -n $NS exec -i $OW -c app -- python3 - <<'PY'
import sqlite3, json, sys
c = sqlite3.connect('file:/app/backend/data/webui.db?mode=ro', uri=True)
kv = {k: json.loads(v) for k, v in c.execute(\"select key, value from config where key like 'task.%'\")}
ext = kv.get('task.model.external', ''); dflt = kv.get('task.model.default', '')
off = all(kv.get(k) is False for k in ('task.tags.enable', 'task.follow_up.enable', 'task.autocomplete.enable', 'task.query.search.enable', 'task.query.retrieval.enable'))
sys.exit(0 if ext == 'household-chat' and 'profiel' not in str(dflt) and 'profiel' not in str(ext) and off else 1)
PY"
gate "C4/C5"

# ---------------------------------------------------------------- C6 + W7 + C7 synthetic canary
log "== C6/W7/C7 synthetic canary"
PORT=$((20000 + RANDOM % 20000)); kubectl -n $NS port-forward "pod/$OW" "$PORT:8080" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 30); do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 1; done
U="http://127.0.0.1:$PORT"
api() { t="$1"; m="$2"; u="$3"; b="${4:-}"; shift 3; [ $# -gt 0 ] && shift
  { printf 'header = "Authorization: Bearer %s"\n' "$t"; printf 'header = "Content-Type: application/json"\n'
    [ -n "$b" ] && printf 'data = "%s"\n' "$(printf '%s' "$b" | sed 's/\\/\\\\/g; s/"/\\"/g')"; } | curl -s -K - -X "$m" "$@" "$U$u"; }
PW="c010-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
cleanup() { [ -n "$CANARY_UID" ] && api "$OWUI_ADMIN_KEY" DELETE "/api/v1/users/$CANARY_UID" "" -o /dev/null; kill $PF 2>/dev/null || true; }
trap cleanup EXIT
CANARY_UID=$(api "$OWUI_ADMIN_KEY" POST /api/v1/auths/add '{"name":"c010-canary","email":"c010-canary@acceptatie.invalid","password":"'"$PW"'","role":"user"}' | jq -r '.id // empty')
GID=$(api "$OWUI_ADMIN_KEY" GET /api/v1/groups/ | jq -r '.[] | select(.name=="owui-profiel-3") | .id')
api "$OWUI_ADMIN_KEY" POST "/api/v1/groups/id/$GID/users/add" "{\"user_ids\":[\"$CANARY_UID\"]}" -o /dev/null
TOK=$(api - POST /api/v1/auths/signin '{"email":"c010-canary@acceptatie.invalid","password":"'"$PW"'"}' -H 'Authorization:' | jq -r '.token // empty')
chk "canary account in owui-profiel-3 sees hermes-agent-profiel-3" "[ -n '$CANARY_UID' ] && api '$TOK' GET /api/models | jq -e '[.data[].id] | index(\"hermes-agent-profiel-3\")' >/dev/null"
gate "canary account"
access() { xp "$(pod 3)" sh -c 'cat /opt/data/logs/agent.log | grep "aiohttp.access" | grep -c "POST /v1/chat/completions"'; }
fails() { { kubectl -n $NS logs "$(pod 3)" -c app --since=1h; xp "$(pod 3)" cat /opt/data/logs/agent.log; } 2>/dev/null | grep -c 'family-cloud: cloud call failed'; }
tokens() { xp "$(pod 3)" cat /cloud-spend/month.json | jq '.input_tokens'; }
spend() { xp "$(pod 3)" sha256sum /cloud-spend/month.json | cut -c1-64; }   # (c) per-turn state of the ledger
memhash() { xp "$(pod 3)" sh -c 'cd /opt/data/memories && find . -type f | LC_ALL=C sort | while read -r f; do printf "%s " "$f"; sha256sum < "$f"; done | sha256sum' | cut -c1-64; }
NODECIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$(kubectl -n $NS get pod "$(pod 3)" -o jsonpath='{.spec.nodeName}') -o jsonpath='{.items[0].metadata.name}')
syns() { kubectl -n kube-system exec "$NODECIL" -c cilium-agent -- hubble observe --since "$1" --from-pod "$NS/$(pod 3)" --to-fqdn api.anthropic.com --tcp-flags SYN -o jsonpb 2>/dev/null | grep -c '"flow"'; }
# turn <chat_id> <messages-json> : one user turn, response discarded unread; returns HTTP code
turn() { api "$TOK" POST /api/chat/completions "{\"model\":\"hermes-agent-profiel-3\",\"chat_id\":\"$1\",\"stream\":false,\"messages\":$2,\"background_tasks\":{\"title_generation\":true,\"tags_generation\":false,\"follow_up_generation\":false}}" -o /dev/null -w '%{http_code}' -m 240; }
newchat() { api "$TOK" POST /api/v1/chats/new '{"chat":{"title":"c010-canary","models":["hermes-agent-profiel-3"],"messages":[]}}' | jq -r '.id'; }
# C6: 3-turn public synthetic chat, 20 s apart (> httpx keep-alive), title generation on. Follow-ups carry the
# cloud's OWN synthetic answers (kept in memory, never logged): the router's stickiness sends any history with an
# assistant message the cloud did not produce to the Studio, so a hard-coded answer would test the wrong path.
ask() { api "$TOK" POST /api/chat/completions "{\"model\":\"hermes-agent-profiel-3\",\"chat_id\":\"$1\",\"stream\":false,\"messages\":$2,\"background_tasks\":{\"title_generation\":true,\"tags_generation\":false,\"follow_up_generation\":false}}" -m 240; }
A0=$(access); F0=$(fails); T0=$(tokens); S0=$(date -u +%Y-%m-%dT%H:%M:%SZ); CID=$(newchat); H=""
q1="Hoeveel poten heeft een spin? Antwoord kort."; q2="En een insect?"; q3="Noem een insect met vleugels."
m=$(jq -nc --arg q "$q1" '[{role:"user",content:$q}]')
C6E=$(date +%s); D6=""
for q in "$q2" "$q3" ""; do
  t0=$(tokens)
  r=$(ask "$CID" "$m"); a=$(printf '%s' "$r" | jq -c '.choices[0].message.content // empty' 2>/dev/null)
  D6="$D6 $(( $(tokens) - t0 ))"
  [ -n "$a" ] && H="$H 200" || H="$H err"; unset r
  [ -n "$q" ] && m=$(printf '%s' "$m" | jq -c --argjson a "${a:-\"\"}" --arg q "$q" '. + [{role:"assistant",content:$a},{role:"user",content:$q}]')
  sleep 20
done; unset a m
sleep 15; A1=$(access); F1=$(fails); T1=$(tokens); N=$(syns "$S0")
log "  C6 http:$H; p3 completions +$((A1-A0)); input_tokens per turn:$D6; failure lines +$((F1-F0)); hubble flows $N (corroboration only)"
chk "C6 3 turns HTTP 200" "[ \"$H\" = ' 200 200 200' ]"
chk "C6 hermes-profiel-3 got exactly one completion per user turn (title gen went elsewhere)" "[ $((A1-A0)) = 3 ]"
chk "C6/(c) month.json rose on each of the 3 cloud turns" "for d in $D6; do [ \$d -gt 0 ] || exit 1; done; [ \$(echo $D6 | wc -w) = 3 ]"
chk "W7 provider count > 0 (spend grew)" "[ $((T1-T0)) -gt 0 ]"
chk "W7 family-cloud failure lines = 0" "[ $((F1-F0)) = 0 ]"
chk "C6 sticky file holds HMACs/counts only" "xp \$(pod 3) cat /cloud-spend/sticky-profiel-3.json | python3 -I -c '
import json, sys, re
def ok(o):
    if isinstance(o, dict): return all(re.fullmatch(r\"[0-9a-f]{16,128}|profiel-[123]|[a-z_]{1,32}\", k) and ok(v) for k, v in o.items())
    if isinstance(o, list): return all(ok(x) for x in o)
    return isinstance(o, (int, float, bool)) or o is None or (isinstance(o, str) and re.fullmatch(r\"[0-9a-f]{16,128}|[0-9T:.Z+-]{4,40}|cloud|studio\", o) is not None)
sys.exit(0 if ok(json.load(sys.stdin)) else 1)'"
chk "(b) replay post: the canary session's own Hermes prompt -> cloud-SOUL + date only; wis -> Studio x2" "replay post $C6E"
gate "C6/W7"
# C7: private-context turns must stay on the Studio: provider connections must not grow
S1=$(date -u +%Y-%m-%dT%H:%M:%SZ); A0=$(access)
c7() { local cid s0 s1 s2; cid=$(newchat); s0=$(spend); H="$(turn "$cid" "$1")"; s1=$(spend); H="$H $(turn "$cid" "$2")"; s2=$(spend)
  log "  C7 $3 http: $H; ledger unchanged turn/next: $([ "$s0" = "$s1" ] && echo yes || echo NO)/$([ "$s1" = "$s2" ] && echo yes || echo NO)"
  [ "$H" = "200 200" ] && [ "$s0" = "$s1" ] && [ "$s1" = "$s2" ]; }
f1='[{"role":"user","content":"Wat is mijn huiswerk voor morgen?"}]'; f2='[{"role":"user","content":"Wat is mijn huiswerk voor morgen?"},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"En hoeveel is twee plus twee?"}]'
F7=$(fails)
chk "C7 huiswerk fetch + next turn answered" "c7 '$f1' '$f2' huiswerk"
l1='[{"role":"user","content":"Wat betekent fotosynthese bij biologie?"}]'; l2='[{"role":"user","content":"Wat betekent fotosynthese bij biologie?"},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Dank je."}]'
chk "C7 lesstof fetch + next turn answered" "c7 '$l1' '$l2' lesstof"
MK="c010-kanarie-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"   # unique synthetic marker, never in memory
MH0=$(memhash); MC0=$(xp "$(pod 3)" sh -c "grep -rlF '$MK' /opt/data/memories 2>/dev/null | wc -l")
v1='[{"role":"user","content":"Vergeet '$MK'."}]'; v2='[{"role":"user","content":"Vergeet '$MK'."},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Hoe laat is het?"}]'
chk "C7 gezin vergeet live (unique synthetic marker) + next turn on the Studio" "c7 '$v1' '$v2' vergeet"
sleep 30   # background memory writes, if any, land before the after-hash
chk "(a) vergeet: memory file set hash before == after, marker absent before and after (hash + presence only)" "[ \"\$(memhash)\" = '$MH0' ] && [ '$MC0' = 0 ] && [ \"\$(xp \$(pod 3) sh -c \"grep -rlF '$MK' /opt/data/memories 2>/dev/null | wc -l\")\" = 0 ]"
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
i1='[{"role":"user","content":[{"type":"text","text":"Wat zie je?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'$PNG'"}}]}]'
i2='[{"role":"user","content":[{"type":"text","text":"Wat zie je?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'$PNG'"}}]},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Welke kleur?"}]'
chk "C7 image + next turn answered" "c7 '$i1' '$i2' image"
FID=$(printf 'c010 synthetisch document: de kanarie is blauw.\n' | { printf 'header = "Authorization: Bearer %s"\n' "$TOK"; } | curl -s -K - -F "file=@-;filename=c010-canary.txt;type=text/plain" "$U/api/v1/files/" | jq -r '.id // empty')
d1='[{"role":"user","content":"Welke kleur heeft de kanarie in het document?"}]'
SD=$(spend)
chk "C7 document upload + next turn answered (RAG, C4 on)" "[ -n '$FID' ] && cid=\$(newchat) && [ \"\$(api '$TOK' POST /api/chat/completions '{\"model\":\"hermes-agent-profiel-3\",\"chat_id\":\"'\$cid'\",\"stream\":false,\"files\":[{\"type\":\"file\",\"id\":\"$FID\"}],\"messages\":$d1}' -o /dev/null -w '%{http_code}' -m 240)\" = 200 ] && [ \"\$(turn \$cid '[{\"role\":\"user\",\"content\":\"Welke kleur heeft de kanarie in het document?\"},{\"role\":\"assistant\",\"content\":\"(antwoord)\"},{\"role\":\"user\",\"content\":\"Dank je.\"}]')\" = 200 ]"
chk "C7 document turns left the ledger unchanged" "[ \"\$(spend)\" = '$SD' ]"
sleep 15; N7=$(syns "$S1"); A1=$(access)
log "  C7 hubble flows during private turns: $N7 (corroboration only); p3 completions +$((A1-A0)) (expect 10)"
chk "W7 no family-cloud failure line during C7" "[ \$(( \$(fails) - $F7 )) = 0 ]"
chk "C7 each turn was one p3 completion" "[ $((A1-A0)) = 10 ]"
gate "C7"

RES=$([ $RED = 0 ] && echo GREEN || echo RED)
log "RESULT go $RES (cloud ON for hermes-profiel-3 at $SHA)"
"$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$SHA" --arg ev "${EV#$REPO/}" --arg r "$RES" \
  '{step:"land 2 go-live profiel-3 (C2-C7, W3-W7)", deploy:$s, result:$r, evidence:$ev, c7_wis:"in-pod replay (Argus 16:58:12Z a)",
    authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
exit $RED
