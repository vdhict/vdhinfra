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
#              restart + W5/W6 again, C4 (owui-c4.sh --apply), C5, C6+W7 synthetic canary (2 cloud turns), C7 private
#              turns gated on F6/F1/F2 only (attempt 10, owner 27-10; see # >>> c010-f6), lesstof dropped (AGR-073).
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
# the automatic rollback needs a land2-cloud-v0225 checkout (the branch of record; the deployed render is 03614a1 = 2634ce0 + route line + route record + API-door admission); the
# main family-ai checkout may be on another branch
export FAMILY_AI_REPO="${FAMILY_AI_REPO:-$HOME/.cache/$CHG/fai-cutoff-wt-v0225}"
PIN_IMAGE="docker.io/nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d"   # = main hermes/base (f2c88fa3)
TS=$(date -u +%Y%m%dT%H%M%SZ); CACHE="$HOME/.cache/$CHG/golive-$TS"; mkdir -p "$CACHE"
RUN_ID="golive-$TS"; : > "$CACHE/run-start"   # fix 3: identifies files written by THIS run (run id + mtime)
EV="$REPO/ops/evidence/$CHG/k8s-golive-$TS-${MODE#--}.txt"; [ ! -e "$EV" ] || { echo "evidence $EV exists (write-once): retry in a second" >&2; exit 1; }
eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
log() { echo "$*" | tee -a "$EV"; }
# >>> c010-rev (Flux lastAppliedRevision check; identical in golive.sh and rollback.sh; tested by test-rev.sh)
rev_is() { # $1 = ks .status.lastAppliedRevision, $2 = full 40-hex sha: exactly main@sha1:<sha> or refs/heads/main@sha1:<sha>
  [[ "$2" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ "$1" = "main@sha1:$2" ] || [ "$1" = "refs/heads/main@sha1:$2" ]
}
# <<< c010-rev
RED=0; PUSHED=""; C4STATE=""; CANARY_UID=""
# >>> c010-c4state (fix 3, 25-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-owui-c4.sh)
# rollback() may only restore a C4 before-state written during THIS run: newer than the run's start marker AND
# carrying this run's id; never "the newest file in the evidence dir" (an older run's state would roll OWUI back
# to a stale value).
c4_state_ok() { # $1 state file  $2 run-start marker  $3 run id
  [ -f "$1" ] && [ "$1" -nt "$2" ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("run_id") == sys.argv[2] else 1)' "$1" "$3" 2>/dev/null; }
c4_state_of_this_run() { # $1 evidence dir  $2 run-start marker  $3 run id : prints the one matching state file, else nothing
  local f n=0 hit=""
  for f in "$1"/k8s-owui-c4-*-before.json; do c4_state_ok "$f" "$2" "$3" && { n=$((n + 1)); hit="$f"; }; done
  [ "$n" = 1 ] && printf '%s\n' "$hit"; return 0; }
# <<< c010-c4state
# >>> c010-c4c5 (attempt-4 fixes, 26-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-owui-c4.sh)
# C4: judged on owui-c4's OWN stdout of this run (captured to a run-scoped file), never on "the last line of the
# evidence": exactly one line with the fixed prefix "RESULT C4 ", and that line is "RESULT C4 GREEN". Line order
# and any info lines golive adds around it do not matter. owui-c4 --apply prints no RESULT line at all on failure.
c4_result_green() { # $1 file holding owui-c4 --apply stdout of this run
  [ -f "$1" ] || { echo "C4 RED: no owui-c4 output captured"; return 1; }
  local n; n=$(grep -c '^RESULT C4 ' "$1")
  [ "$n" = 1 ] || { echo "C4 RED: $n owui-c4 RESULT lines (need exactly 1)"; return 1; }
  grep -Eq '^RESULT C4 GREEN( |$)' "$1" || { echo "C4 RED: owui-c4 RESULT is not GREEN"; return 1; }
  echo "C4 GREEN: one owui-c4 RESULT line, GREEN"; }
# C5: Open WebUI's config table is (key TEXT, value JSON). A JSON-declared column has NUMERIC affinity in SQLite, so
# numeric JSON text is stored as INTEGER (task.autocomplete.input_max_length) and sqlite3 hands back an int; the
# attempt-3 and attempt-4 C5 called json.loads on it and died with TypeError before comparing anything. Every stored
# type is decoded explicitly; anything else, or text that is not JSON, is RED with a named reason (key + type, never
# a value). Reads the DB read-only. argv[1] = DB path (tests); default = the OWUI pod's DB.
read -r -d '' C5_PY <<'PY' || true
import json, sqlite3, sys
class Bad(Exception): pass
def decode(key, v):
    if v is None: return None                                   # SQL NULL
    if isinstance(v, bool): return v                            # bool before int (bool is an int subclass)
    if isinstance(v, (int, float)): return v                    # numeric JSON stored with NUMERIC affinity
    if isinstance(v, str):
        try: return json.loads(v)                               # JSON text
        except ValueError: raise Bad(f"{key}: stored text is not JSON") from None
    raise Bad(f"{key}: unsupported stored type {type(v).__name__}")
def check(rows):
    kv = {k: decode(k, v) for k, v in rows}
    ext = kv.get("task.model.external")
    if not isinstance(ext, str): raise Bad(f"task.model.external: expected a string, got {type(ext).__name__}")
    if ext != "household-chat": raise Bad("task.model.external: not household-chat")
    dflt = kv.get("task.model.default")
    if dflt is not None and not isinstance(dflt, str): raise Bad(f"task.model.default: expected a string, got {type(dflt).__name__}")
    if dflt and "profiel" in dflt: raise Bad("task.model.default: names a profiel-N model")
    for k in ("task.tags.enable", "task.follow_up.enable", "task.autocomplete.enable",
              "task.query.search.enable", "task.query.retrieval.enable"):
        if k not in kv: raise Bad(f"{k}: missing")
        if kv[k] is not False: raise Bad(f"{k}: expected JSON false, got {type(kv[k]).__name__} {'true' if kv[k] is True else 'value'}")
    return len(kv)
# --- main
db = sys.argv[1] if len(sys.argv) > 1 else "/app/backend/data/webui.db"
try:
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    n = check(c.execute("select key, value from config where key like 'task.%'").fetchall())
except Bad as e:
    print(f"C5 RED: {e}"); sys.exit(1)
except sqlite3.Error as e:
    print(f"C5 RED: sqlite read failed ({type(e).__name__})"); sys.exit(1)
print(f"C5 GREEN: {n} task.% keys decoded; external = household-chat; tags/follow-up/autocomplete/query off"); sys.exit(0)
PY
# <<< c010-c4c5
# >>> c010-chk (attempt-5 fix, 27-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-exit.sh)
# The check body runs in a SUBSHELL: attempt 5 died because the C6/(c) body `for d in $D6; do ... || exit 1; done`
# was eval'd in golive's own shell, so its `exit 1` ended golive (rc 1) before `gate "C6/W7"` could roll back.
# Bodies only test; none of them sets a variable the run needs later.
chk() { if ( eval "$2" ) >>"$CACHE/chk.log" 2>&1; then log "  ok   $1"; else log "  RED  $1"; RED=1; fi; }
# <<< c010-chk
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
  rollback_core "$1"
  log "RESULT go RED -> rolled back"; exit 1
}
rollback_core() { # the rollback itself; also run by the exit guard (c010-exitguard) on any other exit after the push
  ROLLED_BACK=1; log "ROLLBACK: $1"
  [ -n "$C4STATE" ] && c4_state_ok "$C4STATE" "$CACHE/run-start" "$RUN_ID" && OWUI_ADMIN_KEY="$OWUI_ADMIN_KEY" "$HACK/ops/$CHG-owui-c4.sh" --rollback "$C4STATE" | tee -a "$EV"
  fresh_token "rollback push" || log "  RED  rollback continues with the caller's credential (if any)"
  "$HACK/ops/$CHG-rollback.sh" --execute "$SHA" "golive red: $1" | tee -a "$EV"
  revoke_token "rollback push"
}
# <<< c010-auth
# >>> c010-a8 (attempt-7 fix, 27-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-a8.sh)
# Attempt 7 failed at the cloud with HTTP 400: the org-scoped key needs anthropic-workspace-id (Atlas 16:22:30Z). Two
# free checks (POST /v1/messages/count_tokens, synthetic text, nothing billed), status number only:
#  A8a before the push, from the Mini's egress: the bundle's settings (workspace_id, model) + the 1Password key
#      (op read; no session -> RED, nothing pushed). The key goes to curl on stdin only, never argv/output/files.
#  A8b after the push, before C4: in the p3 pod, the deployed plugin's own count_tokens_status() = the production
#      client (pinned TLS), headers and settings, through the deployed CNP (unchanged).
C010_CLOUD_KEY_REF="${C010_CLOUD_KEY_REF:-op://home-infra/hermes-antrophic-api-key/credential}"
a8_mini() { # $1 = the bundle's settings.json ; prints one "A8a ..." line ; rc 0 iff HTTP 200
  local s="$1" ws model key code body url
  ws=$(python3 -I -c 'import json,re,sys; d=json.load(open(sys.argv[1])); w=d.get("workspace_id"); print(w if isinstance(w,str) and re.fullmatch(r"wrkspc_[A-Za-z0-9]+", w) else "")' "$s" 2>/dev/null)
  [ -n "$ws" ] || { echo "A8a no valid workspace_id in the bundle settings (placeholder?): no call"; return 1; }
  model=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$s" 2>/dev/null)
  [[ "$model" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || { echo "A8a bundle model unreadable: no call"; return 1; }
  url="https://api.anthropic.com/v1/messages/count_tokens"
  if [ -n "${C010_A8_URL:-}" ]; then   # test only: a loopback fake, never another host
    [[ "$C010_A8_URL" =~ ^http://127\.0\.0\.1:[0-9]{2,5}/ ]] || { echo "A8a refused test URL override"; return 1; }; url="$C010_A8_URL"; fi
  if [ -n "${C010_CLOUD_KEY_CMD:-}" ]; then key="$("$C010_CLOUD_KEY_CMD" 2>/dev/null)"; else key="$(op read "$C010_CLOUD_KEY_REF" 2>/dev/null)"; fi
  [[ "$key" =~ ^sk-ant-[A-Za-z0-9_-]{40,}$ ]] || { key=""; echo "A8a cloud key not readable (1Password session?): no call"; return 1; }
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "messages": [{"role": "user", "content": "synthetic token count"}]}))' "$model")
  code=$({ printf 'header = "x-api-key: %s"\n' "$key"; printf 'header = "anthropic-version: 2023-06-01"\n'
           printf 'header = "anthropic-workspace-id: %s"\n' "$ws"; printf 'header = "content-type: application/json"\n'; } \
         | curl -s -K - -o /dev/null -w '%{http_code}' --max-time 30 -X POST --data-binary "$body" "$url")
  key=""
  echo "A8a count_tokens status ${code:-none} (Mini egress; free, synthetic)"; [ "$code" = 200 ]; }
A8B_PY='import importlib.util, json, os, sys
root, plugin = "/opt/hermes", "/opt/data/plugins/model-providers/family-cloud/__init__.py"
os.chdir(root); sys.path.insert(0, root)
try:
    spec = importlib.util.spec_from_file_location("c010_a8_plugin", plugin)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    settings = json.load(open(os.path.join(os.path.dirname(plugin), "settings.json")))
    print("A8b count_tokens status %s (in-pod, production client + headers; free, synthetic)" % mod.count_tokens_status(settings))
except Exception as e:
    print("A8b error %s" % type(e).__name__)'
a8_pod() { xp "$1" env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c "$A8B_PY" 2>/dev/null | grep '^A8b ' | tail -1; }
# <<< c010-a8
# >>> c010-exitguard (attempt-5 fix, 27-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-exit.sh)
# Once the deploy is pushed, golive may end in exactly two ways: GREEN (GO_FINISHED=1 after gate "C7") or after
# rollback(). ANY other end (a check body or helper that exits, set -u on an unbound variable, a crash, INT/TERM/HUP)
# runs rollback_core from this EXIT trap, then the registered cleanup (canary account), and keeps a non-zero rc.
# The trap is installed once, before the push; nothing later may replace it (C6 registers CLEANUP_HOOK instead).
GO_FINISHED=""; ROLLED_BACK=""; CLEANUP_HOOK=""
on_exit() {
  local rc=$?; trap '' HUP INT TERM   # R2 (Argus 27-10): a 2nd signal can no longer cut the rollback short ($? first)
  trap - EXIT; set +u
  if [ -n "$PUSHED" ] && [ -z "$GO_FINISHED" ] && [ -z "$ROLLED_BACK" ]; then
    log "  RED  golive ended (rc=$rc) after the push without GREEN and without a rollback -> exit guard rolls back"
    rollback_core "exit guard: golive ended rc=$rc after the push"
    log "RESULT go RED -> rolled back (exit guard)"
    [ "$rc" = 0 ] && rc=1
  fi
  [ -n "$CLEANUP_HOOK" ] && "$CLEANUP_HOOK"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
# <<< c010-exitguard
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
chk "rollback prerequisite: FAMILY_AI_REPO is a clean land2-cloud-v0225 checkout" \
  "[ \"\$(git -C '$FAMILY_AI_REPO' rev-parse --abbrev-ref HEAD)\" = land2-cloud-v0225 ] && [ -z \"\$(git -C '$FAMILY_AI_REPO' status --porcelain -- content/cloudmodel.json)\" ]"
chk "push auth: a fresh scoped App token can push (git push --dry-run, no ref changes), then revoked" \
  "fresh_token preflight && GIT_TERMINAL_PROMPT=0 git -C '$REPO' push --dry-run -q origin origin/main:refs/heads/main; r=\$?; revoke_token preflight; [ \$r = 0 ]"
if [ "$MODE" = --go ]; then
  W2EXP=$(printf '%s\n' "$W2OUT" | sed -n 's/.*promo_credit_expires_utc=\([0-9TZ:-]*\).*/\1/p')
  chk "cut-off armed for $SHA at the accepted grant expiry ${W2EXP:-(no grant in this w2a)} and read back (launchd, Argus item 3)" \
    "'$SRC/hack/ops/$CHG-cutoff.sh' readback '$SHA' | tee -a '$EV' | grep \"trigger_utc=${W2EXP:-[0-9]}\" >/dev/null"
else
  log "  info cut-off: $("$SRC/hack/ops/$CHG-cutoff.sh" readback "$SHA" 2>&1 | head -1) (--go refuses unless armed for $SHA)"
fi
fc_init_pin() { # the family-cloud __init__.py pin from hack/ops/chg-2026-10-20-010-pin-fc-init.txt (64 hex or nothing)
  awk '!/^#/ && NF {if ($2 == "plugins/model-providers/family-cloud/__init__.py" && $1 ~ /^[0-9a-f]+$/ && length($1) == 64) print $1; exit}' "$1"; }
FC_INIT_PIN=$(fc_init_pin "$HACK/ops/$CHG-pin-fc-init.txt")
chk "family-cloud __init__.py pin readable (hack/ops/$CHG-pin-fc-init.txt): ${FC_INIT_PIN:0:12}" "[ \${#FC_INIT_PIN} = 64 ]"
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
  '0437f3f6b58ecbc993bb00b1d7d7ab7c980ffb2da4fab715d884dd92c4e1b29f  config.yaml' \
  '$FC_INIT_PIN  plugins/model-providers/family-cloud/__init__.py' \
  'ba0794c5647d780f2edfddc806ba58f7519e80cc9975c86be7f0c7e950af4046  plugins/model-providers/family-cloud/plugin.yaml' \
  'd7f0c4aa4832de7d4acd3b53a677b740bb69952f114081d7cedbd73969d30dbc  plugins/model-providers/family-cloud/settings.json' \
  'b67506a71c1f29cbbacee91e487ad74c5a8736a32047cf6575ac61c70b356fd0  plugins/model-providers/family-cloud/cloud-SOUL.md' | shasum -a 256 -c --strict --quiet"
# Attempt 7 (c): the admission must hold against the REAL v0.22.5 gateway, not only synthetic frames. Run the required
# family-ai test on the record checkout ($FAMILY_AI_REPO), after proving its plugin bytes are exactly the bundle's.
chk "A8a free count_tokens from the Mini with the bundle's workspace_id + model and the 1Password key = 200" \
  "a8_mini '$CACHE/new/plugins/model-providers/family-cloud/settings.json' | tee -a '$EV' | grep -q '^A8a count_tokens status 200 '"
chk "A7 admission vs the real v0.22.5 gateway: record checkout plugin == bundle plugin, test_cloudmodel_realgateway 7/7 (required)" \
  "[ \"\$(shasum -a 256 '$FAMILY_AI_REPO/plugin/model-providers/family-cloud/__init__.py' | cut -d' ' -f1)\" = \"\$(shasum -a 256 '$CACHE/new/plugins/model-providers/family-cloud/__init__.py' | cut -d' ' -f1)\" ] && (cd '$FAMILY_AI_REPO' && FAMILY_AI_REQUIRE_REAL_GATEWAY=1 python3 -m unittest tests.test_cloudmodel_realgateway 2>&1 | tail -1 | grep -qx OK)"
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
c2_config() { # $1 = p3 pod: fetch the deployed config.yaml (env-var NAMES only, no secrets); posthash AND keys
  kubectl -n $NS exec "$1" -c app -- cat /opt/data/config.yaml > "$CACHE/pod-config-$1.yaml" || return 1
  python3 -I "$HACK/ops/$CHG-c2-config.py" gate "$CACHE/new/config.yaml" "$CACHE/pod-config-$1.yaml" \
    "$HACK/ops/$CHG-c2-allow.txt" "$HACK/ops/$CHG-c2-posthash.txt" | tee -a "$EV"
}
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
chk "C2 posthash reference: derive(this bundle's config.yaml) == committed c2-posthash.txt" "[ \"\$(python3 -I '$HACK/ops/$CHG-c2-config.py' derive '$CACHE/new/config.yaml')\" = \"\$(awk '!/^#/ && NF {print \$1; exit}' '$HACK/ops/$CHG-c2-posthash.txt')\" ]"
chk "C2 pod image DEFAULT_CONFIG['_config_version'] == 51 (the stamp the posthash assumes)" "[ \"\$(xp $P3 env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c 'import sys; sys.path.insert(0, \"/opt/hermes\"); from hermes_cli.config_defaults import DEFAULT_CONFIG; print(DEFAULT_CONFIG[\"_config_version\"])')\" = 51 ]"
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
# F2 starts here (pod clock, 5 s margin): older attempts' cloud_ok records in the route file stay out of the window
PUSH_E=$(xp "$(pod 3)" date +%s 2>/dev/null); [[ "$PUSH_E" =~ ^[0-9]{10}$ ]] || PUSH_E=$(date +%s); PUSH_E=$((PUSH_E - 5))
deploy_push || { log "RED push refused or no token (main moved?): rebase + re-run preflight; nothing pushed"; exit 1; }
PUSHED="$SHA"; log "  pushed $SHA to main"
flux reconcile source git flux-system -n flux-system >>"$CACHE/chk.log" 2>&1
for ks in family-ai-network-policies family-ai-hermes; do
  flux reconcile ks $ks -n flux-system --timeout=10m >>"$CACHE/chk.log" 2>&1
  chk "ks $ks Ready at $SHA" "rev_is \"\$(kubectl -n flux-system get ks $ks -o jsonpath='{.status.lastAppliedRevision}')\" '$(git -C "$SRC" rev-parse "$SHA")' && kubectl -n flux-system wait ks/$ks --for=condition=Ready --timeout=5m"
done
chk "p3 rollout complete" "kubectl -n $NS rollout status deploy/hermes-profiel-3 --timeout=10m"
gate "reconcile"
P3=$(pod 3)

# ---------------------------------------------------------------- C2 C3 W3 W4 W5 W6
post_checks() {
  local tag="$1"; P3=$(pod 3)
  log "== checks ($tag) on $P3"
  chk "C2 p3 seeded bundle = new outer" "[ \"\$(xp $P3 cat /opt/data/.family-ai-seeded)\" = '$NEW_OUTER' ]"
  # bytes for every bundle file except config.yaml (Hermes v0.22.5 appends _config_version); stdin needs exec -i
  chk "C2 p3 deployed files == bundle SHA256SUMS except config.yaml (17)" "grep -v '  config.yaml\$' '$CACHE/new/SHA256SUMS' | kubectl -n $NS exec -i $P3 -c app -- sh -c 'cd /opt/data && sha256sum -c --strict --quiet -' && [ \"\$(xp $P3 sh -c 'cd /opt/data && { ls config.yaml SOUL.md; find plugins -type f ! -path \"*/__pycache__/*\"; } | LC_ALL=C sort')\" = \"\$(awk '{print \$2}' '$CACHE/new/SHA256SUMS' | LC_ALL=C sort)\" ]"
  chk "C2 p3 config.yaml: posthash AND keys (Argus 11:58:52Z ruling_c2)" "c2_config $P3"
  chk "C2 p1/p2 untouched (pod uid + seeded bundle)" "[ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-1 -o jsonpath='{.items[0].metadata.uid}')\" = '$U1' ] && [ \"\$(kubectl -n $NS get pod -l app.kubernetes.io/instance=hermes-profiel-2 -o jsonpath='{.items[0].metadata.uid}')\" = '$U2' ] && [ \"\$(xp $P1 cat /opt/data/.family-ai-seeded)\" = '$M1' ] && [ \"\$(xp $P2 cat /opt/data/.family-ai-seeded)\" = '$M2' ]"
  chk "C3/W5 env HERMES_IMAGE == pod image == PINNED_IMAGE" "[ \"\$(xp $P3 printenv HERMES_IMAGE)\" = \"\$(kubectl -n $NS get pod $P3 -o jsonpath='{.spec.containers[?(@.name==\"app\")].image}')\" ] && [ \"\$(xp $P3 printenv HERMES_IMAGE)\" = '$PIN_IMAGE' ]"
  chk "C3/W5 pinned runtime in the pod (pin-probe: imports exactly the plugin's PINNED_MODULES)" "xp $P3 env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python -c \"\$(cat '$HACK/ops/$CHG-pin-probe.py')\" | tee -a '$EV' | grep '\"ok\": true' >/dev/null"
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
A8B=$(a8_pod "$(pod 3)"); log "  info ${A8B:-A8b no output}"
chk "A8b in-pod count_tokens on the deployed plugin + settings + CNP = 200 (free, synthetic)" \
  "[ \"$A8B\" = 'A8b count_tokens status 200 (in-pod, production client + headers; free, synthetic)' ]"
gate "A8 count_tokens"
P3=$(pod 3)

# ---------------------------------------------------------------- C4 + C5 (OWUI)
log "== C4 + C5"
OWUI_ADMIN_KEY="$OWUI_ADMIN_KEY" OWUI_SNAPSHOT="$OWUI_SNAPSHOT" C010_RUN_ID="$RUN_ID" "$HACK/ops/$CHG-owui-c4.sh" --apply | tee -a "$EV" "$CACHE/c4-apply.out"
C4STATE=$(c4_state_of_this_run "$REPO/ops/evidence/$CHG" "$CACHE/run-start" "$RUN_ID")
C4REL=${C4STATE#"$REPO"/}; log "  info C4 state of this run: ${C4REL:-none}"   # was printed twice (rel + abs) in attempt 4
log "  info $(c4_result_green "$CACHE/c4-apply.out")"
chk "C4 green (exactly one owui-c4 RESULT line of this run, GREEN)" "c4_result_green '$CACHE/c4-apply.out'"
OW=$(kubectl -n $NS get pod -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
C5OUT=$(kubectl -n $NS exec -i "$OW" -c app -- python3 - <<< "$C5_PY" 2>>"$CACHE/chk.log"); C5RC=$?
log "  info ${C5OUT:-C5 RED: no output from the in-pod check (exit $C5RC)}"
chk "C5 task model external = household-chat, never profiel-N; tags/follow-up/autocomplete/query off" \
  "[ $C5RC = 0 ] && [ \"\$(grep -c '^C5 ' <<< \"\$C5OUT\")\" = 1 ] && grep -q '^C5 GREEN: ' <<< \"\$C5OUT\""
gate "C4/C5"

# ---------------------------------------------------------------- C6 + W7 + C7 synthetic canary
log "== C6/W7/C7 synthetic canary"
# >>> c010-c6turn (attempt-6 item b, 27-10; sourced as-is by hack/ops/chg-2026-10-20-010-test-golive-c6.sh)
# Attempt 5: golive's port-forward to OWUI died after C6 turn 1; turns 2/3 and the cleanup DELETE never reached OWUI,
# and golive recorded neither curl codes nor sizes. Now: liveness before/after every canary call, re-open + log on loss
# (as go-session pf_up); per-turn metadata with the answer unread; and C6 judged on the ROUTE p3 itself took.
# NB the id OWUI returns is minted by Hermes' API server (api_server_openai_routes.py: chatcmpl-<uuid>) on EVERY turn,
# so the client id class is logged as metadata only. The route and the PROVIDER id class come from the family-cloud
# plugin's own route record file /opt/data/family-cloud-route.jsonl (family-ai d50234d: one JSON line per routed
# turn, exactly ts/route/rule/id_class; msg_ = Anthropic, chatcmpl- = Studio). Argus 27-10 15:21:18Z: C6 never opens
# agent.log (its lines carry user text that can forge a route line); exactly ONE record per turn window, any other
# count is RED "inconclusive" and only the count is logged.
PF="${PF:-}"; PORT="${PORT:-}"; PF_REOPEN=0
pf_alive() { [ -n "$PF" ] && kill -0 "$PF" 2>/dev/null && nc -z 127.0.0.1 "$PORT" 2>/dev/null; }
pf_up() { # (re)open the port-forward to the OWUI pod; sets PORT, PF, U
  [ -n "$PF" ] && kill "$PF" 2>/dev/null; PORT=$((20000 + RANDOM % 20000))
  kubectl -n $NS port-forward "pod/$OW" "$PORT:8080" >/dev/null 2>>"$CACHE/pf.err" & PF=$!   # stderr kept: why it dropped
  echo "$PF" >> "$CACHE/pf.pids"   # a re-open inside a chk subshell (c7) outlives it: cleanup kills every pid listed
  for _ in $(seq 1 30); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 1; done
  U="http://127.0.0.1:$PORT"; nc -z 127.0.0.1 "$PORT" 2>/dev/null; }
pf_kill_all() { local x; [ -f "$CACHE/pf.pids" ] && while read -r x; do kill "$x" 2>/dev/null; done < "$CACHE/pf.pids"; return 0; }
pf_ensure() { # $1 = where; returns non-zero only if a lost port-forward cannot be re-opened
  pf_alive && return 0
  PF_REOPEN=$((PF_REOPEN + 1)); log "  info port-forward to OWUI lost ($1): re-opening (#$PF_REOPEN)"
  if pf_up; then log "  info port-forward re-opened ($1)"; else log "  RED  port-forward could not be re-opened ($1)"; return 1; fi; }
# stdin: one response body. Prints metadata only: bytes, json, top-level key NAMES, error key, content present,
# client id class. Never a value or any text of the answer.
RESP_META_PY='import sys, json
raw = sys.stdin.buffer.read(); out = {"bytes": len(raw), "json": "no", "keys": "-", "error_key": "no", "content": "no", "client_id_class": "none"}
try:
    d = json.loads(raw)
except Exception:
    d = None
if isinstance(d, dict):
    out["json"] = "yes"; out["keys"] = ",".join(sorted(k for k in d if isinstance(k, str) and k.isidentifier())[:12]) or "-"
    out["error_key"] = "yes" if ("error" in d or "detail" in d) else "no"
    try: c = d["choices"][0]["message"]["content"]
    except Exception: c = None
    out["content"] = "yes" if isinstance(c, str) and c.strip() else "no"
    i = d.get("id")
    out["client_id_class"] = "none" if not isinstance(i, str) else ("chatcmpl-" if i.startswith("chatcmpl-") else ("msg_" if i.startswith("msg_") else "other"))
elif d is not None:
    out["json"] = "yes"
print(" ".join("%s=%s" % kv for kv in out.items()))'
resp_meta() { /usr/bin/python3 -I -c "$RESP_META_PY"; }
# In p3 (argv: [--all] start end [files]): the route records with ts in [start, end] (epoch seconds, pod clock).
# Reads ONLY the plugin's route record file (+ its .1); never agent.log. A record must be one JSON object with exactly
# ts/route/rule/id_class and allowed values; a line that is not is counted as malformed (last 500 lines per file).
# Prints JSON: count + malformed, and the record fields only when count == 1. --all (attempt 10, F6/F2) adds
# "records": [[ts, route, rule, id_class], ...] for every in-window record (the same four validated fields only).
C6LOG_PY='import sys, re, json
args = sys.argv[1:]; full = bool(args) and args[0] == "--all"; args = args[1:] if full else args
start, end = float(args[0]), float(args[1])
files = args[2:] or ["/opt/data/family-cloud-route.jsonl.1", "/opt/data/family-cloud-route.jsonl"]
RULE = re.compile(r"[A-Za-z_]{1,48}")
hits, bad = [], 0
for f in files:
    try: fh = open(f, "rb")
    except OSError: continue
    with fh: lines = fh.read().splitlines()[-500:]
    for raw in lines:
        try:
            d = json.loads(raw)
            ok = (isinstance(d, dict) and set(d) == {"ts", "route", "rule", "id_class"} and type(d["ts"]) in (int, float)
                  and d["route"] in ("cloud", "studio") and isinstance(d["rule"], str) and RULE.fullmatch(d["rule"])
                  and d["id_class"] in ("msg_", "chatcmpl-", "none"))
        except Exception:
            ok = False
        if not ok: bad += 1; continue
        if start - 1 <= d["ts"] <= end + 1: hits.append(d)
out = {"count": len(hits), "malformed": bad}
if len(hits) == 1 and bad == 0:
    out.update(route=hits[0]["route"], rule=hits[0]["rule"], id_class=hits[0]["id_class"])
if full: out["records"] = sorted([d["ts"], d["route"], d["rule"], d["id_class"]] for d in hits)
print(json.dumps(out))'
p3_turnlog() { xp "$(pod 3)" /opt/hermes/.venv/bin/python -I -c "$C6LOG_PY" "$1" "$2"; }
# stdin: p3_turnlog JSON. exit 0 iff exactly one well-formed record in the window and it is route=cloud rule=cloud_ok
# id_class=msg_. count != 1 (or malformed > 0): RED "inconclusive", only the counts are printed.
C6VERDICT_PY='import sys, json
try: d = json.load(sys.stdin)
except Exception: print("p3 route record unreadable -> inconclusive"); sys.exit(1)
n, bad = d.get("count"), d.get("malformed")
if n != 1 or bad != 0:
    print("p3 route records in window=%s malformed=%s -> inconclusive" % (n, bad)); sys.exit(1)
ok = (d.get("route"), d.get("rule"), d.get("id_class")) == ("cloud", "cloud_ok", "msg_")
print("p3 route=%s rule=%s id_class=%s -> %s" % (d.get("route"), d.get("rule"), d.get("id_class"), "cloud" if ok else "NOT cloud"))
sys.exit(0 if ok else 1)'
c6_turn_verdict() { /usr/bin/python3 -I -c "$C6VERDICT_PY"; }
# <<< c010-c6turn
# >>> c010-f6 (attempt 10, 27-10; owner: gate C7 on F1, F2, F6 only; Argus 22:27:11Z amended; sourced as-is by
# hack/ops/chg-2026-10-20-010-test-golive-f6.sh and by go-session.sh for F2)
# Attempt 9: the OWUI port-forward dropped mid-turn (curl 000) while Hermes still answered, and the abandoned huiswerk
# turn answered 3 s into the next turn's clock window. Now every canary turn runs STRICTLY after the previous one has
# settled server-side, and is judged on server-side records, never on the HTTP code:
#   F6  per turn: exactly one Hermes session changed; it has a new user message from this turn (state.db timestamp >=
#       send - 2 s) and ended on an assistant message; route records in [send - 1 s, that assistant message + 2 s] ==
#       the session's api_call_count increase (>= 1); route=cloud / rule cloud_* records == 0. Independent of the ledger.
#   F1  the next turn in the SAME chat after a private turn: F6 holds and every rule is a non-cloud Studio rule (any
#       name: the new latch rule is logged as found).
#   F2  no rule cloud_ok record from the push to the end outside the C6 (golive) and E3 (go session) windows.
# state.db is read in the pod read-only, METADATA ONLY: sessions.id (hashed, 12 hex), source class, api_call_count,
# messages.session_id, role, timestamp, finish_reason (enum-checked). Never content, tool_calls or prompts.
# Validated read-only on attempt 9's real rows (27-10 ~23Z): per session, route records == api_call_count increase
# (C6 3/3, huiswerk 1/1, vergeet 2/2 incl. a tool call, image 2/2); a new OWUI chat with the same first message is
# appended to the EXISTING Hermes session (C6's held 14 calls), hence deltas; a first turn ends with a session_meta row.
# The route file only via C6LOG_PY (four validated fields). agent.log is never opened here.
# 000 handling (Atlas 22:27:11Z): after a non-200 the turn is NOT resent while state.db or the route file shows
# anything of it; we wait for the abandoned Hermes turn to finish (assistant message + stable api_call_count) or
# C010_F6_WAIT s, then judge it. A resend happens at most once, only after C010_F6_SETTLE s (> curl -m 240 + Studio
# time) with no session change and no route record, i.e. the request provably never reached Hermes. Cloud turns
# (C6) are never resent. A turn that does not settle in time is RED-inconclusive and the remaining C7 turns are
# skipped (no overlap, ever).
F6_WAIT="${C010_F6_WAIT:-360}"; F6_SETTLE="${C010_F6_SETTLE:-300}"; F6_POLL="${C010_F6_POLL:-5}"; F6_ABORT=""
SDB_PY='import sqlite3, json, sys, time, hashlib, re
since = float(sys.argv[1]); db = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/state.db"
c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
h = lambda s: hashlib.sha256(str(s).encode()).hexdigest()[:12]
enum = lambda v, ok: v if isinstance(v, str) and re.fullmatch(ok, v) else ("none" if v is None else "other")
out = {}
for sid, src, acc in c.execute("select id, source, coalesce(api_call_count, 0) from sessions"):
    out[h(sid)] = {"src": "api_server" if src == "api_server" else "other", "acc": acc,
                   "last_role": None, "last_ts": None, "last_finish": "none", "users_since": 0, "first_user_ts": None}
for sid, role, ts, fin in c.execute("select m.session_id, m.role, m.timestamp, m.finish_reason from messages m join "
                                    "(select session_id, max(id) mid from messages where role != ? group by session_id) x on m.id = x.mid",
                                    ("session_meta",)):   # Hermes adds a session_meta row after a first turn
    if h(sid) in out:
        out[h(sid)].update(last_role=enum(role, r"user|assistant|tool|system"), last_ts=ts, last_finish=enum(fin, r"[a-z_]{1,24}"))
for sid, n, t0 in c.execute("select session_id, count(*), min(timestamp) from messages where role = ? and timestamp >= ? "
                            "group by session_id", ("user", since)):
    if h(sid) in out:
        out[h(sid)].update(users_since=n, first_user_ts=t0)
print(json.dumps({"now": time.time(), "sessions": out}))'
# local judge. argv: e0 s0.json s1.json routes.json. Prints one JSON object; never anything but hashes, counts, rules.
F6JUDGE_PY='import json, sys
e0 = float(sys.argv[1]); s0, s1, rt = (json.load(open(p)) for p in sys.argv[2:5])
a, b = s0["sessions"], s1["sessions"]
sig = lambda x: (x.get("acc"), x.get("last_ts"), x.get("users_since"))
changed = [k for k, v in b.items() if k not in a or sig(v) != sig(a[k]) or v.get("users_since", 0) > 0]
recs = rt.get("records") or []
out = {"state": "", "sid": None, "changed": len(changed), "records_total": len(recs), "malformed": rt.get("malformed", -1)}
if not changed:
    out["state"] = "none" if not recs else "orphan"
elif len(changed) > 1:
    out["state"] = "multi"
else:
    k = changed[0]; v = b[k]; d = v["acc"] - (a[k]["acc"] if k in a else 0)
    final = v["last_role"] == "assistant" and v["last_finish"] not in ("tool_calls", "other") and v["last_ts"] is not None
    paired = v["users_since"] > 0 and v["first_user_ts"] is not None and (not final or v["first_user_ts"] <= v["last_ts"])
    hi = (v["last_ts"] + 2) if final else float("inf")
    win = [r for r in recs if e0 - 1 <= r[0] <= hi]
    rules = {}
    for r in win: rules[r[2]] = rules.get(r[2], 0) + 1
    out.update(sid=k, api_calls=d, final=final, paired=paired, n=len(win), after=len(recs) - len(win),
               cloud=sum(1 for r in win if r[1] == "cloud" or r[2].startswith("cloud")), rules=rules,
               cloud_ok=sum(1 for r in win if r[2] == "cloud_ok"),
               studio_only=bool(win) and all(r[1] == "studio" and not r[2].startswith("cloud") for r in win),
               sig="%s:%s:%s" % (k, v["acc"], v["last_ts"]))
    out["state"] = "done" if final and paired and d >= 1 else "pending"
print(json.dumps(out, sort_keys=True))'
# F2: argv: routes.json "a:b,c:d,..." (windows, pod epoch). Counts rule cloud_ok records inside/outside.
F2_PY='import json, sys
rt = json.load(open(sys.argv[1])); wins = [tuple(map(float, w.split(":"))) for w in sys.argv[2].split(",") if w]
ok = [r for r in (rt.get("records") or []) if r[2] == "cloud_ok"]
inside = sum(1 for r in ok if any(lo <= r[0] <= hi for lo, hi in wins))
print(json.dumps({"cloud_ok": len(ok), "inside": inside, "outside": len(ok) - inside, "malformed": rt.get("malformed", -1), "windows": len(wins)}))
sys.exit(0 if len(ok) == inside and rt.get("malformed", 0) == 0 else 1)'
pod_now() { xp "$(pod 3)" date +%s; }
sdb() { xp "$(pod 3)" /opt/hermes/.venv/bin/python -I -c "$SDB_PY" "$1"; }                      # $1 since (pod epoch)
routes_all() { xp "$(pod 3)" /opt/hermes/.venv/bin/python -I -c "$C6LOG_PY" --all "$1" "$2"; }   # $1 $2 window
f6_judge() { /usr/bin/python3 -I -c "$F6JUDGE_PY" "$@"; }
jf() { # JSON field of stdin: dict/list/bool as JSON (true/false), None as empty, else the plain value
  /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(json.dumps(v) if isinstance(v,(dict,list,bool)) else ("" if v is None else v))' "$1"; }
f2_check() { # $1 from (pod epoch) $2 windows "a:b,..." : one "F2 ..." line; rc 0 iff no cloud_ok outside the windows
  local f="$CACHE/f2-routes-$RANDOM.json" o rc
  routes_all "$1" "$(( $(pod_now) + 5 ))" > "$f" || { echo "F2 RED: route file unreadable"; return 1; }
  o=$(/usr/bin/python3 -I -c "$F2_PY" "$f" "$2"); rc=$?
  echo "F2 cloud_ok records since push $o -> $([ $rc = 0 ] && echo ok || echo RED)"; return $rc; }
pf_fresh() { # $1 where: a NEW port-forward before every canary turn + HTTP readiness (GET /health = 200)
  local i c
  for i in 1 2 3; do
    pf_up && { c=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$U/health"); [ "$c" = 200 ] && return 0; }
    log "  info port-forward not ready ($1, try $i, health=${c:-none})"; sleep 2
  done
  log "  RED  no ready port-forward to OWUI ($1)"; return 1; }
send_turn() { # $1 chat id $2 messages json [$3 files json] : HTTP code only, response discarded unread
  local body; body=$(jq -nc --arg c "$1" --argjson m "$2" --argjson f "${3:-null}" \
    '{model:"hermes-agent-profiel-3", chat_id:$c, stream:false, messages:$m,
      background_tasks:{title_generation:true, tags_generation:false, follow_up_generation:false}} + (if $f then {files:$f} else {} end)')
  api "$TOK" POST /api/chat/completions "$body" -o /dev/null -w '%{http_code}' -m 240; }
f6_settle() { # $1 e0 $2 s0 file $3 "http code" $4 tag -> writes $CACHE/f6-$4.json (last judge), prints the final state
  local e0="$1" s0="$2" code="$3" tag="$4" t=0 prev="" st j lim="$F6_WAIT" s1="$CACHE/f6-$4-s1.json" rf="$CACHE/f6-$4-rt.json"
  [ "$code" = 200 ] || lim=$(( F6_WAIT > F6_SETTLE ? F6_WAIT : F6_SETTLE ))
  while :; do
    sdb "$((e0 - 2))" > "$s1" 2>/dev/null; routes_all "$((e0 - 1))" "$(( $(pod_now) + 5 ))" > "$rf" 2>/dev/null
    j=$(f6_judge "$e0" "$s0" "$s1" "$rf" 2>/dev/null) || j='{"state":"unreadable"}'
    printf '%s\n' "$j" > "$CACHE/f6-$tag.json"; st=$(printf '%s' "$j" | jf state)
    case "$st" in
      done) [ "$prev" = "$(printf '%s' "$j" | jf sig)" ] && { echo done; return 0; }; prev=$(printf '%s' "$j" | jf sig);;
      none) [ "$code" != 200 ] && [ "$t" -ge "$F6_SETTLE" ] && { echo none; return 0; };;
      multi|orphan|unreadable) [ "$t" -ge 30 ] && { echo "$st"; return 0; };;
    esac
    [ "$t" -ge "$lim" ] && { echo "timeout-$st"; return 0; }
    sleep "$F6_POLL"; t=$((t + F6_POLL))
  done; }
pturn() { # $1 label $2 kind (private|next) $3 chat id $4 messages json [$5 files json] -> f6.tsv row; rc 0 iff F6 (+F1)
  local label="$1" kind="$2" cid="$3" ms="$4" files="${5:-}" try=1 e0="" code="" st="" j="{}" ok why l0="" l1=""
  [ -n "$F6_ABORT" ] && { log "  RED  F6 $label: skipped (an earlier turn did not settle: no overlapping turns)"; printf '%s\t%s\tred\tskipped\t-\n' "$label" "$kind" >> "$CACHE/f6.tsv"; return 1; }
  while :; do
    code=""; st=""; j='{}'
    if ! pf_fresh "F6 $label"; then   # nothing was sent: no settle needed, and a resend cannot duplicate anything
      code=pf; st=none
    else
      e0=$(pod_now); sdb "$((e0 - 2))" > "$CACHE/f6-$label-$try-s0.json" 2>/dev/null; l0=$(spend)
      code=$(send_turn "$cid" "$ms" "$files")
      st=$(f6_settle "$e0" "$CACHE/f6-$label-$try-s0.json" "$code" "$label-$try"); j=$(cat "$CACHE/f6-$label-$try.json"); l1=$(spend)
    fi
    if [ "$st" = none ] && [ "$try" = 1 ] && [ "$code" != 200 ]; then
      if [ "$code" = pf ]; then log "  info F6 $label: no ready port-forward, nothing was sent -> one more try"
      else log "  info F6 $label: http=$code and after ${F6_SETTLE}s no session change and no route record: never reached Hermes -> resent once"; fi
      try=2; continue
    fi
    break
  done
  ok=1; why=""
  [ "$st" = done ] || { ok=0; why="inconclusive: $st"; case "$st" in timeout-*) F6_ABORT=1;; esac; }
  if [ "$ok" = 1 ]; then
    [ "$(printf '%s' "$j" | jf n)" = "$(printf '%s' "$j" | jf api_calls)" ] || { ok=0; why="route records != api_call_count increase"; }
    [ "$(printf '%s' "$j" | jf cloud)" = 0 ] || { ok=0; why="${why:+$why; }cloud record(s) on a private turn"; }
    [ "$(printf '%s' "$j" | jf malformed)" = 0 ] || { ok=0; why="${why:+$why; }malformed route lines"; }
    [ "$(printf '%s' "$j" | jf after)" = 0 ] || { ok=0; why="${why:+$why; }route records after the turn's assistant message"; }
    [ "$kind" = next ] && [ "$(printf '%s' "$j" | jf studio_only)" != true ] && { ok=0; why="${why:+$why; }F1: next turn not Studio-only"; }
  fi
  log "  F6 $label ($kind): http=$code tries=$try session=$(printf '%s' "$j" | jf sid) api_calls=+$(printf '%s' "$j" | jf api_calls) route_records=$(printf '%s' "$j" | jf n) cloud=$(printf '%s' "$j" | jf cloud) rules=$(printf '%s' "$j" | jf rules | tr -d ' ') sessions_changed=$(printf '%s' "$j" | jf changed); ledger unchanged (corroboration): $([ "$l0" = "$l1" ] && echo yes || echo NO) -> $([ $ok = 1 ] && echo ok || echo "RED ($why)")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$kind" "$([ $ok = 1 ] && echo ok || echo red)" "$(printf '%s' "$j" | jf rules | tr -d ' \t')" "$(printf '%s' "$j" | jf sid)" >> "$CACHE/f6.tsv"
  [ $ok = 1 ]; }
c6_settle() { # $1 e0 $2 s0 file $3 http $4 tag : C6 turns are never resent; only wait until the server turn settled
  local st; st=$(f6_settle "$1" "$2" "$3" "$4"); log "  info C6 $4 server turn: $st (session $(jf sid < "$CACHE/f6-$4.json"), api_calls +$(jf api_calls < "$CACHE/f6-$4.json"))"
  [ "$st" = done ]; }
# <<< c010-f6
pf_up || { log "  RED  no port-forward to OWUI for the canary"; RED=1; }
# >>> c010-canary-api (sourced as-is by hack/ops/chg-2026-10-20-010-test-owui-c4.sh)
# Same bug class as the attempt-3 C4 exit: a trailing `[ -n "$b" ] && printf` made the config group exit 1 on every
# body-less call, so under pipefail `api ... | jq -e ...` read RED even when the answer was right (C6 would have failed).
api() { t="$1"; m="$2"; u="$3"; b="${4:-}"; shift 3; [ $# -gt 0 ] && shift
  { printf 'header = "Authorization: Bearer %s"\n' "$t"; printf 'header = "Content-Type: application/json"\n'
    if [ -n "$b" ]; then printf 'data = "%s"\n' "$(printf '%s' "$b" | sed 's/\\/\\\\/g; s/"/\\"/g')"; fi; } | curl -s -K - -X "$m" "$@" "$U$u"; }
# <<< c010-canary-api
PW="c010-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
cleanup() { # canary account delete; re-opens a lost port-forward first (attempt 5: the DELETE never reached OWUI)
  if [ -n "$CANARY_UID" ]; then pf_ensure cleanup; c=$(api "$OWUI_ADMIN_KEY" DELETE "/api/v1/users/$CANARY_UID" "" -o /dev/null -w '%{http_code}'); log "  info cleanup: canary account DELETE http=$c"; fi
  pf_kill_all; }
CLEANUP_HOOK=cleanup   # run by on_exit (c010-exitguard); never `trap ... EXIT` here, that would drop the exit guard
CANARY_UID=$(api "$OWUI_ADMIN_KEY" POST /api/v1/auths/add '{"name":"c010-canary","email":"c010-canary@acceptatie.invalid","password":"'"$PW"'","role":"user"}' | jq -r '.id // empty')
GID=$(api "$OWUI_ADMIN_KEY" GET /api/v1/groups/ | jq -r '.[] | select(.name=="owui-profiel-3") | .id')
api "$OWUI_ADMIN_KEY" POST "/api/v1/groups/id/$GID/users/add" "{\"user_ids\":[\"$CANARY_UID\"]}" -o /dev/null
TOK=$(api - POST /api/v1/auths/signin '{"email":"c010-canary@acceptatie.invalid","password":"'"$PW"'"}' -H 'Authorization:' | jq -r '.token // empty')
chk "canary account in owui-profiel-3 sees hermes-agent-profiel-3" "[ -n '$CANARY_UID' ] && api '$TOK' GET /api/models | jq -e '[.data[].id] | index(\"hermes-agent-profiel-3\")' >/dev/null"
gate "canary account"
access() { xp "$(pod 3)" sh -c 'cat /opt/data/logs/agent.log | grep "aiohttp.access" | grep -c "POST /v1/chat/completions"'; }
# counted INSIDE the pod (Argus 15:21:18Z): only the number leaves the pod; never copy agent.log or pod logs to the Mini.
# agent.log* (current + rotated) so a rotation during the run cannot lower the count.
fails() { xp "$(pod 3)" sh -c 'cat /opt/data/logs/agent.log* 2>/dev/null | grep -c "family-cloud: cloud call failed" || true'; }
tokens() { xp "$(pod 3)" cat /cloud-spend/month.json | jq '.input_tokens'; }
spend() { xp "$(pod 3)" sha256sum /cloud-spend/month.json | cut -c1-64; }   # (c) per-turn state of the ledger
memhash() { xp "$(pod 3)" sh -c 'cd /opt/data/memories && find . -type f | LC_ALL=C sort | while read -r f; do printf "%s " "$f"; sha256sum < "$f"; done | sha256sum' | cut -c1-64; }
NODECIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$(kubectl -n $NS get pod "$(pod 3)" -o jsonpath='{.spec.nodeName}') -o jsonpath='{.items[0].metadata.name}')
syns() { kubectl -n kube-system exec "$NODECIL" -c cilium-agent -- hubble observe --since "$1" --from-pod "$NS/$(pod 3)" --to-fqdn api.anthropic.com --tcp-flags SYN -o jsonpb 2>/dev/null | grep -c '"flow"'; }
newchat() { api "$TOK" POST /api/v1/chats/new '{"chat":{"title":"c010-canary","models":["hermes-agent-profiel-3"],"messages":[]}}' | jq -r '.id'; }
# C6: 2-turn public synthetic chat, 20 s apart (> httpx keep-alive), title generation on. Follow-ups carry the
# cloud's OWN synthetic answers (kept in memory, never logged): the router's stickiness sends any history with an
# assistant message the cloud did not produce to the Studio, so a hard-coded answer would test the wrong path.
# Attempt 10 cloud budget (owner: ~3 real cloud turns per go): C6 3 -> 2 turns (turn 2 still covers the follow-up +
# the idle keep-alive), the C7 lesstof turn dropped, E3 (go session) stays 1: 5 -> 3. Turns are never resent; each
# waits for its server-side turn to settle (c6_settle) so nothing overlaps; its window feeds F2.
ask() { local c="$1" ms="$2"; shift 2   # extra curl args (e.g. -w) pass through
  api "$TOK" POST /api/chat/completions "{\"model\":\"hermes-agent-profiel-3\",\"chat_id\":\"$c\",\"stream\":false,\"messages\":$ms,\"background_tasks\":{\"title_generation\":true,\"tags_generation\":false,\"follow_up_generation\":false}}" -m 240 "$@"; }
A0=$(access); F0=$(fails); T0=$(tokens); S0=$(date -u +%Y-%m-%dT%H:%M:%SZ); CID=$(newchat); H=""
q1="Hoeveel poten heeft een spin? Antwoord kort."; q2="En een insect?"
m=$(jq -nc --arg q "$q1" '[{role:"user",content:$q}]')
C6E=$(date +%s); D6=""; C6NOTCLOUD=""; n6=0; F2WIN=""
for q in "$q2" ""; do
  n6=$((n6 + 1)); pf_ensure "before C6 turn $n6"
  t0=$(tokens); e0=$(xp "$(pod 3)" date +%s); sdb "$((e0 - 2))" > "$CACHE/c6-$n6-s0.json" 2>/dev/null
  r=$(ask "$CID" "$m" -w '\n%{http_code}'); crc=$?; code="${r##*$'\n'}"; r="${r%$'\n'*}"
  meta=$(printf '%s' "$r" | resp_meta); a=$(printf '%s' "$r" | jq -c '.choices[0].message.content // empty' 2>/dev/null); unset r
  sleep 3; c6_settle "$e0" "$CACHE/c6-$n6-s0.json" "$code" "c6turn$n6" || C6NOTCLOUD="$C6NOTCLOUD settle$n6"
  e1=$(xp "$(pod 3)" date +%s); tl=$(p3_turnlog "$e0" "$e1"); F2WIN="$F2WIN${F2WIN:+,}$((e0 - 1)):$((e1 + 1))"
  D6="$D6 $(( $(tokens) - t0 ))"
  v=$(printf '%s' "$tl" | c6_turn_verdict) || C6NOTCLOUD="$C6NOTCLOUD $n6"
  pf_alive && pfa=up || pfa=LOST
  log "  C6 turn $n6: curl_rc=$crc http=$code $meta pf_after=$pfa; $v"
  [ "$crc" = 0 ] && [ "$code" = 200 ] && [ -n "$a" ] && H="$H 200" || H="$H err"
  [ -n "$q" ] && m=$(printf '%s' "$m" | jq -c --argjson a "${a:-\"\"}" --arg q "$q" '. + [{role:"assistant",content:$a},{role:"user",content:$q}]')
  sleep 20
done; unset a m
sleep 15; A1=$(access); F1=$(fails); T1=$(tokens); N=$(syns "$S0")
log "  C6 http:$H; p3 completions +$((A1-A0)); input_tokens per turn:$D6; failure lines +$((F1-F0)); hubble flows $N (corroboration only); port-forward re-opens $PF_REOPEN"
chk "C6 2 turns HTTP 200" "[ \"$H\" = ' 200 200' ]"
chk "C6 every turn answered by the cloud (exactly one p3 route record per turn: cloud/cloud_ok/msg_; Studio or inconclusive is RED)" "[ -z '$C6NOTCLOUD' ]"
chk "C6 hermes-profiel-3 got exactly one completion per user turn (title gen went elsewhere)" "[ $((A1-A0)) = 2 ]"
chk "C6/(c) month.json rose on each of the 2 cloud turns" "for d in $D6; do [ \$d -gt 0 ] || exit 1; done; [ \$(echo $D6 | wc -w) = 2 ]"
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
# C7 (attempt 10, owner 27-10): private-context turns, gated ONLY on F6 (each private turn and its next turn), F1 (that
# next turn, same chat, neutral question, Studio-only, rule name logged) and F2 (no cloud_ok outside the C6 windows).
# The vergeet memory hash (a) stays a gate: it guards against deleting real memory, not a routing criterion.
# Lesstof dropped (AGR-073: school books may go to the cloud): no F-check needs it and it saves a cloud turn.
# Ledger (month.json hash) unchanged over C7: a GATE (Argus 23:03:54Z condition 1: a billed cloud call that the plugin
# logs as studio/refusal or studio/guard_* has no cloud record, so F6 alone misses it). Completion count, Hubble flows
# and family-cloud failure lines: info only (corroboration).
# Turns run strictly one after another (pturn waits for the server-side turn); the chat id is made on a fresh
# port-forward. Each pturn writes one row to $CACHE/f6.tsv; the chks read that file (pturn runs outside chk).
: > "$CACHE/f6.tsv"
pf_ensure "before C7" || { RED=1; gate "C7 port-forward"; }
S1=$(date -u +%Y-%m-%dT%H:%M:%SZ); A0=$(access); F7=$(fails); SL7=$(spend)
c7() { # $1 turn msgs $2 next msgs $3 label [$4 files json for the first turn]
  local cid; pf_fresh "C7 $3 new chat" && cid=$(newchat)
  [ -n "${cid:-}" ] && [ "$cid" != null ] || { log "  RED  C7 $3: no chat id"; printf '%s\tprivate\tred\tno_chat\t-\n%s next\tnext\tred\tno_chat\t-\n' "$3" "$3" >> "$CACHE/f6.tsv"; return 1; }
  pturn "$3" private "$cid" "$1" "${4:-}"; pturn "$3 next" next "$cid" "$2"; }
f1='[{"role":"user","content":"Wat is mijn huiswerk voor morgen?"}]'; f2='[{"role":"user","content":"Wat is mijn huiswerk voor morgen?"},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"En hoeveel is twee plus twee?"}]'
c7 "$f1" "$f2" huiswerk
MK="c010-kanarie-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"   # unique synthetic marker, never in memory
MH0=$(memhash); MC0=$(xp "$(pod 3)" sh -c "grep -rlF '$MK' /opt/data/memories 2>/dev/null | wc -l")
v1='[{"role":"user","content":"Vergeet '$MK'."}]'; v2='[{"role":"user","content":"Vergeet '$MK'."},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Hoe laat is het?"}]'
c7 "$v1" "$v2" vergeet
sleep 30   # background memory writes, if any, land before the after-hash
chk "(a) vergeet: memory file set hash before == after, marker absent before and after (hash + presence only)" "[ \"\$(memhash)\" = '$MH0' ] && [ '$MC0' = 0 ] && [ \"\$(xp \$(pod 3) sh -c \"grep -rlF '$MK' /opt/data/memories 2>/dev/null | wc -l\")\" = 0 ]"
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
i1='[{"role":"user","content":[{"type":"text","text":"Wat zie je?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'$PNG'"}}]}]'
i2='[{"role":"user","content":[{"type":"text","text":"Wat zie je?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'$PNG'"}}]},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Welke kleur?"}]'
c7 "$i1" "$i2" image
# the synthetic document goes from a file in the run's 0700 cache dir; stdin carries only the curl config (token).
# (Attempts 9 and 10 sent an empty upload: the text was piped into a block that ignored it and file=@- shared stdin with -K -.)
printf 'c010 synthetisch document: de kanarie is blauw.\n' > "$CACHE/c010-canary.txt"
FID=""; pf_fresh "C7 document upload" && FID=$(printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -s -K - -F "file=@$CACHE/c010-canary.txt;filename=c010-canary.txt;type=text/plain" "$U/api/v1/files/" | jq -r '.id // empty')
d1='[{"role":"user","content":"Welke kleur heeft de kanarie in het document?"}]'
d2='[{"role":"user","content":"Welke kleur heeft de kanarie in het document?"},{"role":"assistant","content":"(antwoord)"},{"role":"user","content":"Dank je."}]'
if [ -n "$FID" ]; then c7 "$d1" "$d2" document "[{\"type\":\"file\",\"id\":\"$FID\"}]"
else log "  RED  C7 document: upload gave no file id"; printf 'document\tprivate\tred\tno_upload\t-\ndocument next\tnext\tred\tno_upload\t-\n' >> "$CACHE/f6.tsv"; fi
sleep 15; N7=$(syns "$S1"); A1=$(access)
log "  C7 info (corroboration only): hubble flows $N7; p3 completions +$((A1-A0)); family-cloud failure lines +$(( $(fails) - F7 ))"
chk "C7 ledger (month.json) unchanged over all C7 turns (a billed cloud call logged as refusal/guard_* has no cloud record)" "[ \"\$(spend)\" = '$SL7' ]"
chk "F6 every private C7 turn + its next turn: route records == api_call_count increase, 0 cloud records (8 rows, all ok)" \
  "[ \$(awk -F'\t' '\$3==\"ok\"' '$CACHE/f6.tsv' | wc -l) = 8 ] && [ \$(wc -l < '$CACHE/f6.tsv') = 8 ]"
chk "F1 each next turn in the same chat after a private turn: Studio-only (rules: $(awk -F'\t' '$2=="next"{printf "%s=%s ", $1, $4}' "$CACHE/f6.tsv"))" \
  "[ \$(awk -F'\t' '\$2==\"next\" && \$3==\"ok\"' '$CACHE/f6.tsv' | wc -l) = 4 ]"
log "  info F1 same Hermes session as the private turn: $(awk -F'\t' '{s[$1]=$5} END {for (k in s) if (k ~ / next$/) {p=substr(k,1,length(k)-5); printf "%s=%s ", p, (s[k]==s[p] ? "yes" : "no")}}' "$CACHE/f6.tsv")"
F2OUT=$(f2_check "$PUSH_E" "$F2WIN"); F2RC=$?; log "  $F2OUT (windows C6 $F2WIN)"
log "F2 windows from=$PUSH_E c6=$F2WIN"   # read by go-session.sh for its own F2 over E3
chk "F2 no cloud_ok route record outside the C6 windows since the push" "[ $F2RC = 0 ]"
gate "C7"
GO_FINISHED=1   # the only point after the push where golive may end without a rollback (RED is 0 here)

RES=$([ $RED = 0 ] && echo GREEN || echo RED)
log "RESULT go $RES (cloud ON for hermes-profiel-3 at $SHA)"
"$REPO/ops/ops" change event $CHG executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$SHA" --arg ev "${EV#$REPO/}" --arg r "$RES" \
  '{step:"land 2 go-live profiel-3 (C2-C7, W3-W7; attempt 10: C6 2 cloud turns, C7 gated on F6/F1/F2, lesstof dropped)", deploy:$s, result:$r, evidence:$ev, c7_wis:"in-pod replay (Argus 16:58:12Z a)",
    authority:"uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"}')" >/dev/null
exit $RED
