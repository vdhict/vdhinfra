#!/usr/bin/env bash
# chg-2026-10-20-010 automated cloud CUT-OFF for hermes-profiel-3 at the promotional-credit expiry
# (Argus 25-10 09:42:10Z pre-go item 3). Runs without any session: a launchd LaunchAgent on the Mini.
#
# Why launchd on the Mini and not an in-cluster Job: cloud-off is chg-2026-10-20-010-rollback.sh --execute, i.e.
# a git revert PUSHED to main + Flux reconcile + price_confirmed=false committed in the local family-ai repo. The
# plugin reads price_confirmed from the SOPS bundle (settings.json), not from a ConfigMap, so there is nothing a
# CronJob could patch; and a cluster Job has neither the push credential nor the family-ai repo. The Mini has both
# (GitHub App token minted per run; kubectl via the local relay), as the 13-10 launchd window job proved.
#
#   hack/ops/chg-2026-10-20-010-cutoff.sh arm <deploy-sha> --w2-event <ts>  # go-live step AND every re-arm: W2 gate
#                                       (golive.sh --gate-only GREEN) -> cut-off at that capture's promo_credit_expires_utc
#   hack/ops/chg-2026-10-20-010-cutoff.sh readback [<deploy-sha>]           # read-only; exit 0 iff armed (for that sha)
#   hack/ops/chg-2026-10-20-010-cutoff.sh launchd-selftest <deploy-sha>     # load a TEST label (cutoff 2099), wait for
#                                                                           # its launchd self-test, unload it again
#   hack/ops/chg-2026-10-20-010-cutoff.sh retire                            # only after the cut-off fired + cloud off
#   (fire --sha S --cutoff T --inst D --fai D --label L   is what launchd runs every 300 s)
#
# fire: integrity check of the pinned install (SHA256SUMS) -> self-test once per arm per UTC day (kubectl via relay,
# flux, git fetch, App-token push --dry-run, family-ai worktree on land2-cloud-on-live) -> before the cutoff: exit 0
# -> at/after the cutoff (now >= T): if done: exit 0; if the cloud CNP is already absent on origin/main: done, one
# event, no rollback; else rollback.sh --execute <sha> (at most 3 attempts, 5 min apart; then one FAILED event and
# stop). Exactly one change event per outcome (the rollback logs its own action line too). Never prints a token.
# Trigger time (Argus 25-10 09:56:03Z): never a constant; it is promo_credit_expires_utc of the evidence JSON that the
# W2 gate accepted for the given infra-ops event. Re-arm = new capture JSON + new infra-ops W2 event + arm (which
# runs --gate-only): the trigger moves to that grant's expiry (later or earlier); no re-arm -> the cut-off fires and
# cloud stays off (fail closed). One change-log line per (re-)arm. `retire` only after the cut-off has fired. No rm (AGR-121): replaced plists are
# moved to ~/Library/LaunchAgents/_retired/; installs are write-once dirs.
# Test-only overrides (offline tests, never in the real plist): C010_NOW C010_STATE_DIR C010_INST_BASE
# C010_AGENTS_DIR C010_LAUNCHCTL C010_OPS C010_MINT_CMD C010_REVOKE_CMD C010_FAI_WT C010_SKIP_ROLLBACK_DRYRUN
# C010_SELFTEST_WAIT C010_PATH_PREPEND C010_NOTIFY_LOG C010_ALERT_CONF.
# Alerts (Argus A3): FAILED, a real-label self-test RED and "not done 2 h after the trigger" each send ONE ntfy push to
# the team channel (pka-alert's self-hosted TEAM topic; priority 1 + "[night]" 23:00-07:00 Europe/Amsterdam, else 3;
# fallback: pka-alert) plus one `ops incident new` (the digest line). ops errors go to the fire log.
set -uo pipefail
CHG=chg-2026-10-20-010
LABEL_REAL="net.vdhict.$CHG-cutoff"
LABEL_TEST="net.vdhict.$CHG-cutoff-test"
TEST_CUTOFF=2099-01-01T00:00:00Z
FAI_BRANCH=land2-cloud-on-live
CNP_PATH=kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml
MAX_ATTEMPTS=3          # fast attempts (5 min apart); then FAILED alert + one retry per RETRY_S until done
RETRY_S=3600
LATE_S=7200            # not done this long after the trigger -> one alert, whatever the reason
INTERVAL=300
REPO="${VDH_REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
FAI_SRC="${FAMILY_AI_SRC:-/Users/sheijden/Code/pka-wires/family-ai-familie-2026-10-19}"
CACHE="$HOME/.cache/$CHG"
FAI_WT="${C010_FAI_WT:-$CACHE/fai-cutoff-wt}"
STATE="${C010_STATE_DIR:-$HOME/.local/state/$CHG-cutoff}"
INST_BASE="${C010_INST_BASE:-$HOME/.local/share/$CHG-cutoff}"
AGENTS="${C010_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHCTL="${C010_LAUNCHCTL:-/bin/launchctl}"
OPS="${C010_OPS:-$REPO/ops/ops}"
PY=/usr/bin/python3
DOMAIN="gui/$(id -u)"
AUTH="uitgevoerd onder programmagoedkeuring family-ai; AGR-109: tests are the gate"
mkdir -p "$STATE"
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date -j -u -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null; }
now_epoch() { if [ -n "${C010_NOW:-}" ]; then epoch "$C010_NOW"; else date -u +%s; fi; }
is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
is_ts() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && [ -n "$(epoch "$1")" ]; }
LOGF="$STATE/cutoff.log"   # fire() switches to a per-label log
line() { echo "$(utc) ${LABEL:-cutoff} $*" >> "$LOGF"; }
payload() { $PY -I -c '
import json, sys
d = dict(a.split("=", 1) for a in sys.argv[2:]); d["authority"] = sys.argv[1]; print(json.dumps(d, sort_keys=True))' "$AUTH" "$@"; }
# one change-log line; payload from key=value pairs (strings), built by python so quoting is never an issue
ev() { local o rc; o="$("$OPS" change event "$CHG" executed --actor k8s-engineer --payload-json "$(payload "$@")" 2>&1)"; rc=$?
  [ $rc = 0 ] || line "ops change event FAILED rc=$rc: $(printf '%s' "$o" | tr '\n' ' ' | cut -c1-200)"; return $rc; }
local_hour() { local h; h="$(TZ=Europe/Amsterdam date -r "$(now_epoch)" +%H)"; echo $((10#$h)); }
notify() { # $1 title  $2 body : one push to the team channel; never prints the topic or token
  local h prio title="$1"; h="$(local_hour)"; prio=3
  if [ "$h" -ge 23 ] || [ "$h" -lt 7 ]; then prio=1; title="[night] $1"; fi
  if [ -n "${C010_NOTIFY_LOG:-}" ]; then echo "prio=$prio title=$title" >> "$C010_NOTIFY_LOG"; line "notified (test) p$prio: $title"; return 0; fi
  local conf="${C010_ALERT_CONF:-$HOME/.config/pka-alert/alert.env}" srv top tf tok code
  kv() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | tail -1 | tr -d "\"'" | sed "s#\$HOME#$HOME#"; }
  srv="$(kv ALERT_SH_SERVER)"; top="$(kv ALERT_SH_TOPIC_TEAM)"; tf="$(kv ALERT_SH_TOKEN_FILE)"
  tok="$(sed -n 's/^NTFY_PKA_ALERT_TOKEN=//p' "$tf" 2>/dev/null | tail -1 | tr -d "\"' \r")"
  code=000
  case " alerts gezin gezin-test $(kv ALERT_SH_TOPIC_SANDER) " in *" $top "*) top=""; line "team topic is a phone topic: not used";; esac
  if [ -n "$srv" ] && [ -n "$top" ] && [ -n "$tok" ]; then
    local body; body="$($PY -I -c 'import json,sys; print(json.dumps({"topic":sys.argv[1],"title":sys.argv[2],"message":sys.argv[3],"priority":int(sys.argv[4]),"tags":["rotating_light"]}))' "$top" "$title" "$2" "$prio")"
    code="$(printf 'url = "%s/"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$srv" "$tok" \
      | /usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K - -X POST --data-binary "$body" 2>/dev/null)"
  fi
  tok=""
  if [ "$code" = 200 ]; then line "notified p$prio (team channel): $title"; return 0; fi
  line "team push http=$code: falling back to pka-alert"
  "$HOME/pka-alert/bin/pka-alert" c010-cutoff "$title" "$2" >/dev/null 2>&1 || true
}
alert() { # $1 key (once per key per deploy)  $2 title  $3 body : ntfy + digest line (ops incident)
  local m="$STATE/alert-$1-${SHA:-none}"; [ -e "$m" ] && return 0; : > "$m"
  notify "$2" "$3"
  local o rc; o="$("$OPS" incident new high --summary "$CHG cut-off: $2. $3" --actor k8s-engineer 2>&1)"; rc=$?
  [ $rc = 0 ] && line "digest line: ops incident new ($1)" || line "ops incident new FAILED rc=$rc: $(printf '%s' "$o" | tr '\n' ' ' | cut -c1-200)"
}
cnp_on_main() { git -C "$REPO" cat-file -e "origin/main:$CNP_PATH" 2>/dev/null; }
_TOK=""
mint() { # scoped token (contents:write on vdhinfra only), stdout only
  if [ -n "${C010_MINT_CMD:-}" ]; then "$C010_MINT_CMD"; return; fi
  "$PY" -I "$INST/$CHG-mint.py" mint 2>>"$LOGF"
}
auth_env() { # push credential for this process tree only (env, never argv, never printed)
  _TOK="$(mint)"; [ "${#_TOK}" -ge 20 ] || { _TOK=""; return 1; }
  export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$_TOK" | base64 | tr -d '\n')"; export GIT_CONFIG_VALUE_0
}
revoke_auth() { # revoke right after use (Argus L1)
  [ -n "$_TOK" ] || return 0
  if [ -n "${C010_REVOKE_CMD:-}" ]; then printf '%s' "$_TOK" | "$C010_REVOKE_CMD"
  else printf '%s' "$_TOK" | "$PY" -I "$INST/$CHG-mint.py" revoke 2>>"$LOGF"; fi || line "token revoke failed (expires within 1 h)"
  _TOK=""; unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}
plist_args() { /usr/bin/plutil -extract ProgramArguments json -o - "$1" 2>/dev/null; }
arg_of() { $PY -I -c 'import json,sys; a=json.loads(sys.argv[1]); print(a[a.index(sys.argv[2])+1] if sys.argv[2] in a else "")' "$1" "$2"; }

# =============================================================================================== fire (launchd)
fire() {
  local CUT="" INST_ARG="" FAI="" ; SHA=""; LABEL=""
  while [ $# -gt 0 ]; do case "$1" in --sha) SHA="$2";; --cutoff) CUT="$2";; --inst) INST_ARG="$2";; --fai) FAI="$2";;
    --label) LABEL="$2";; --w2-event) :;; *) echo "fire: unknown arg $1" >&2; exit 2;; esac; shift 2; done
  INST="$INST_ARG"
  is_sha "$SHA" && is_ts "$CUT" && [ -d "$INST" ] && [ -n "$FAI" ] && [ -n "$LABEL" ] || { echo "fire: bad args" >&2; exit 2; }
  LOGF="$STATE/fire-$LABEL.log"
  local ARMID NOW DAY; ARMID="$(basename "$INST")"; NOW="$(now_epoch)"; DAY="$(date -u -r "$NOW" +%Y%m%d)"
  local REAL=no; [ "$LABEL" = "$LABEL_REAL" ] && REAL=yes
  # 1 integrity of the pinned install
  if ! (cd "$INST" && shasum -a 256 -c --strict --quiet SHA256SUMS) >/dev/null 2>&1; then
    line "RED integrity: $INST does not match its SHA256SUMS"
    local m="$STATE/tamper-$LABEL-$ARMID-$DAY"
    [ -e "$m" ] || { : > "$m"; ev step="cutoff integrity RED (install changed after arm)" label="$LABEL" deploy="$SHA" result=RED needs_human=true
      [ $REAL = yes ] && alert "integrity-$DAY" "install changed after arm" "re-arm with cutoff.sh arm $SHA --w2-event <accepted event>; see $LOGF"; }
    exit 1
  fi
  eval "$(cd "$REPO" && mise env -s bash 2>/dev/null)"
  [ -z "${C010_PATH_PREPEND:-}" ] || export PATH="$C010_PATH_PREPEND:$PATH"
  # 2 self-test, once per arm per UTC day (the first run after load is the arm read-back proof). Argus A4: once the
  #   deploy is on main, the reviewed rollback.sh --dry-run <sha> origin/main must be GREEN too (proves the revert).
  local ST="$STATE/selftest-$LABEL-$ARMID-$DAY.json"
  if [ ! -e "$ST" ]; then
    local k=fail f=fail g=fail p=fail a=fail r=n/a
    [ "$(kubectl get ns family-ai -o name 2>/dev/null)" = namespace/family-ai ] && k=ok
    flux --version >/dev/null 2>&1 && f=ok
    git -C "$REPO" fetch -q origin 2>/dev/null && g=ok
    ( auth_env && git -C "$REPO" push --dry-run -q origin origin/main:refs/heads/main >/dev/null 2>&1; rc=$?; revoke_auth; exit $rc ) && p=ok
    [ "$(git -C "$FAI" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$FAI_BRANCH" ] \
      && [ -z "$(git -C "$FAI" status --porcelain -- content/cloudmodel.json 2>/dev/null)" ] && a=ok
    if [ $g = ok ] && git -C "$REPO" merge-base --is-ancestor "$SHA" origin/main 2>/dev/null; then
      FAMILY_AI_REPO="$FAI" VDH_REPO="$REPO" bash "$INST/$CHG-rollback.sh" --dry-run "$SHA" origin/main >> "$LOGF" 2>&1
      tail -1 "$LOGF" | grep -q 'RESULT dry-run GREEN' && r=ok || r=fail
    fi
    $PY -I -c 'import json,sys; k=["kubectl","flux","git_fetch","push_auth","family_ai_worktree","rollback_dry_run"]; v=sys.argv[6:12]
json.dump({"utc":sys.argv[1],"label":sys.argv[2],"deploy":sys.argv[3],"cutoff_utc":sys.argv[4],"launchd":sys.argv[5]!="",
           "checks":dict(zip(k,v)),"ok":all(x in ("ok","n/a") for x in v)}, open(sys.argv[12],"x"), sort_keys=True)' \
      "$(utc)" "$LABEL" "$SHA" "$CUT" "${XPC_SERVICE_NAME:-}" $k $f $g $p $a $r "$ST" 2>/dev/null
    local sum="kubectl=$k flux=$f git_fetch=$g push_auth=$p family_ai_worktree=$a rollback_dry_run=$r"
    line "selftest $sum"
    if [ $REAL = yes ] && { [ "$k$f$g$p$a" != okokokokok ] || [ $r = fail ]; }; then
      ev step="cutoff self-test RED (cut-off may not work)" label="$LABEL" deploy="$SHA" cutoff_utc="$CUT" checks="$sum" result=RED needs_human=true
      alert "selftest-$DAY" "self-test RED, the cut-off at $CUT may not work" "$sum; see $LOGF"
    fi
  fi
  # 3 time guard
  [ "$NOW" -ge "$(epoch "$CUT")" ] || exit 0
  [ $REAL = yes ] || { line "test label past its cutoff: no action"; exit 0; }
  [ -e "$STATE/done-$SHA" ] && exit 0
  if [ "$NOW" -ge $(( $(epoch "$CUT") + LATE_S )) ]; then
    alert late "cloud cut-off NOT done $((LATE_S / 3600)) h after $CUT" "profiel-3 cloud may still be on; see $LOGF; by hand: hack/ops/$CHG-rollback.sh --execute $SHA"
  fi
  local ATT="$STATE/attempts-$SHA" LAST="$STATE/last-$SHA" n RETRY=no
  n=$( [ -e "$ATT" ] && wc -l < "$ATT" | tr -d ' ' || echo 0)
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then
    if [ ! -e "$STATE/failed-$SHA" ]; then
      : > "$STATE/failed-$SHA"; line "FAILED after $n attempts: retrying every $((RETRY_S / 60)) min until done"
      ev step="cutoff FAILED after $n attempts: cloud may still be ON for profiel-3; retrying hourly" deploy="$SHA" cutoff_utc="$CUT" \
         result=RED needs_human=true action="run hack/ops/$CHG-rollback.sh --execute $SHA by hand; see $LOGF"
      alert failed "cloud cut-off FAILED after $n attempts" "profiel-3 cloud may still be on; retrying hourly; see $LOGF"
    fi
    [ $(( NOW - $(cat "$LAST" 2>/dev/null || echo 0) )) -ge "$RETRY_S" ] || exit 1
    RETRY=yes
  fi
  # fetch and token-mint failures are logged but never count as attempts (Argus A3)
  git -C "$REPO" fetch -q origin || { line "git fetch failed (not counted as an attempt)"; exit 1; }
  if ! cnp_on_main; then
    : > "$STATE/done-$SHA"; line "cloud already off on origin/main: no rollback needed"
    ev step="cutoff at promo expiry: cloud already off on main (no-op)" deploy="$SHA" cutoff_utc="$CUT" previous_attempts="$n" result=GREEN
    [ -e "$STATE/failed-$SHA" ] && notify "cloud cut-off done after FAILED" "cloud off on main (no-op); see $LOGF"
    exit 0
  fi
  if ! git -C "$REPO" merge-base --is-ancestor "$SHA" origin/main; then
    [ $RETRY = yes ] || echo "$(utc) armed sha not on main" >> "$ATT"; echo "$NOW" > "$LAST"
    line "RED: cloud CNP on main but armed $SHA is not in main"
    [ $RETRY = yes ] || ev step="cutoff RED: cloud CNP on main but the armed deploy is not in main (re-deployed? re-arm)" deploy="$SHA" \
       cutoff_utc="$CUT" attempt="$((n + 1))" result=RED needs_human=true
    exit 1
  fi
  auth_env || { line "GitHub App token mint failed (not counted as an attempt)"; exit 1; }
  [ $RETRY = yes ] || echo "$(utc) rollback --execute" >> "$ATT"; echo "$NOW" > "$LAST"
  line "cutoff $CUT reached: rollback.sh --execute $SHA ($([ $RETRY = yes ] && echo hourly retry || echo "attempt $((n + 1))"))"
  FAMILY_AI_REPO="$FAI" VDH_REPO="$REPO" bash "$INST/$CHG-rollback.sh" --execute "$SHA" \
    "promo credit expiry cut-off $CUT (Argus 25-10 item 3, launchd $LABEL)" >> "$LOGF" 2>&1; local rc=$?
  revoke_auth
  local rev; rev="$(ls -t "$REPO/ops/evidence/$CHG/"k8s-rollback-*-execute.txt 2>/dev/null | head -1)"
  git -C "$REPO" fetch -q origin
  if ! cnp_on_main; then
    : > "$STATE/done-$SHA"; line "cloud OFF on origin/main (rollback rc=$rc)"
    ev step="cutoff at promo expiry: cloud off for profiel-3 (rollback.sh --execute)" deploy="$SHA" cutoff_utc="$CUT" \
       attempt="$([ $RETRY = yes ] && echo hourly-retry || echo $((n + 1)))" rollback_rc="$rc" rollback_evidence="${rev#$REPO/}" \
       result="$([ $rc = 0 ] && echo GREEN || echo 'GREEN on main, rollback readback RED: check evidence')"
    [ -e "$STATE/failed-$SHA" ] && notify "cloud cut-off done after FAILED" "cloud off on main (rollback rc=$rc); see $LOGF"
    exit 0
  fi
  line "RED: rollback rc=$rc and the cloud CNP is still on origin/main"
  [ $RETRY = yes ] || ev step="cutoff attempt RED: cloud CNP still on main" deploy="$SHA" attempt="$((n + 1))" rollback_rc="$rc" \
     rollback_evidence="${rev#$REPO/}" result=RED
  exit 1
}

# =============================================================================================== install + load
install_and_load() { # $1 sha  $2 cutoff  $3 label  $4 w2 event ts ; uses SRC
  local SHA="$1" CUT="$2" LABEL="$3" W2="$4" TS INST PL REND
  TS="$(date -u +%Y%m%dT%H%M%SZ)"; INST="$INST_BASE/$TS-${SHA:0:8}-${LABEL##*-}"
  mkdir -p "$INST_BASE"; mkdir "$INST" || { echo "install dir $INST exists (write-once): retry" >&2; return 1; }
  # the reviewed bytes of the deploy commit, never the working tree
  git -C "$SRC" show "$SHA:hack/ops/$CHG-cutoff.sh" > "$INST/$CHG-cutoff.sh" &&
  git -C "$SRC" show "$SHA:hack/ops/$CHG-rollback.sh" > "$INST/$CHG-rollback.sh" &&
  git -C "$SRC" show "$SHA:hack/ops/$CHG-mint.py" > "$INST/$CHG-mint.py" &&
  git -C "$SRC" show "$SHA:hack/ops/net.vdhict.$CHG-cutoff.plist" > "$INST/template.plist" || { echo "deploy commit lacks the cut-off files" >&2; return 1; }
  (cd "$INST" && shasum -a 256 "$CHG-cutoff.sh" "$CHG-rollback.sh" "$CHG-mint.py" > SHA256SUMS)
  local APPID="${GITHUB_APP_ID:-${GH_APP_ID:-}}" INSTID="${GITHUB_APP_INSTALLATION_ID:-${GH_APP_INSTALLATION_ID:-}}" KEYP="${GITHUB_APP_KEY_PATH:-${GH_APP_PRIVATE_KEY_FILE:-}}"
  [ -n "$APPID" ] && [ -n "$INSTID" ] && [ -n "$KEYP" ] || { echo "GitHub App env (GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_PRIVATE_KEY_FILE) missing" >&2; return 1; }
  REND="$INST/$LABEL.plist"
  $PY -I - "$INST/template.plist" "$REND" "$LABEL" "$INST" "$SHA" "$CUT" "$FAI_WT" "$HOME" "$APPID" "$INSTID" "$KEYP" "$REPO" "$INTERVAL" "$W2" <<'PY' || return 1
import sys, html
src, dst, label, inst, sha, cut, fai, home, appid, instid, keyp, repo, interval, w2 = sys.argv[1:15]
t = open(src).read()
for k, v in {"LABEL": label, "INST": inst, "SHA": sha, "CUTOFF": cut, "FAI": fai, "HOME": home,
             "APP_ID": appid, "APP_INSTALLATION_ID": instid, "APP_KEY_PATH": keyp, "REPO": repo, "INTERVAL": interval, "W2EVENT": w2}.items():
    t = t.replace("@@%s@@" % k, html.escape(v))
assert "@@" not in t, "unrendered placeholder"
open(dst, "x").write(t)
PY
  /usr/bin/plutil -lint -s "$REND" || return 1
  PL="$AGENTS/$LABEL.plist"; mkdir -p "$AGENTS/_retired"
  if [ -e "$PL" ]; then
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    mv "$PL" "$AGENTS/_retired/$LABEL.$TS.plist"
  fi
  cp "$REND" "$PL"
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PL" >&2 || { echo "launchctl bootstrap failed" >&2; return 1; }
  # wait for the launchd self-test of this install (RunAtLoad)
  local ST="$STATE/selftest-$LABEL-$(basename "$INST")-$(date -u -r "$(now_epoch)" +%Y%m%d).json" i
  for i in $(seq 1 "${C010_SELFTEST_WAIT:-180}"); do [ -e "$ST" ] && break; sleep 1; done
  [ -e "$ST" ] || { echo "no launchd self-test result after ${C010_SELFTEST_WAIT:-180}s ($ST)" >&2; return 1; }
  echo "$INST"
}

ensure_fai_wt() {
  if [ -d "$FAI_WT" ] && [ "$(git -C "$FAI_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$FAI_BRANCH" ]; then return 0; fi
  [ -e "$FAI_WT" ] && { echo "$FAI_WT exists but is not a $FAI_BRANCH worktree" >&2; return 1; }
  # the branch may still be registered by a dead scratch worktree: force only if every other registration is prunable
  local live
  live=$(git -C "$FAI_SRC" worktree list --porcelain | awk -v b="refs/heads/$FAI_BRANCH" '
    /^worktree /{w=$2; br=""; pr=0} /^branch /{br=$2} /^prunable/{pr=1} /^$/{if (br==b && !pr) print w} END{if (br==b && !pr) print w}')
  [ -z "$live" ] || { echo "$FAI_BRANCH is checked out in a live worktree: $live" >&2; return 1; }
  mkdir -p "$(dirname "$FAI_WT")"
  git -C "$FAI_SRC" worktree add -q -f "$FAI_WT" "$FAI_BRANCH"
}

readback() { # [sha] [label] ; prints the armed state, exit 0 iff loaded + args sane (+ sha match) + selftest ok
  local WANT="${1:-}" LABEL="${2:-$LABEL_REAL}" PL A SHA CUT INST ST LP
  PL="$AGENTS/$LABEL.plist"
  [ -e "$PL" ] || { echo "readback: $LABEL not installed"; return 1; }
  A="$(plist_args "$PL")"; SHA="$(arg_of "$A" --sha)"; CUT="$(arg_of "$A" --cutoff)"; INST="$(arg_of "$A" --inst)"
  local W2; W2="$(arg_of "$A" --w2-event)"
  LP="$("$LAUNCHCTL" print "$DOMAIN/$LABEL" 2>/dev/null)"
  local loaded=no; [ -n "$LP" ] && loaded=yes
  local lexit; lexit="$(printf '%s\n' "$LP" | awk -F'= ' '/last exit code/{print $2; exit}')"
  local interval; interval="$(/usr/bin/plutil -extract StartInterval raw -o - "$PL" 2>/dev/null)"
  ST="$(ls -t "$STATE/selftest-$LABEL-$(basename "$INST")-"*.json 2>/dev/null | head -1)"
  local integ=fail; (cd "$INST" 2>/dev/null && shasum -a 256 -c --strict --quiet SHA256SUMS) >/dev/null 2>&1 && integ=ok
  echo "readback $LABEL: loaded=$loaded trigger_utc=$CUT deploy=$SHA interval=${interval}s last_exit=${lexit:-n/a} integrity=$integ"
  echo "  from w2 event $W2 (promo_credit_expires_utc of the accepted capture); install $INST"
  [ -n "$ST" ] && echo "  selftest $(basename "$ST"): $($PY -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("ok" if d["ok"] else "RED", "launchd" if d["launchd"] else "NOT-launchd", d["utc"], " ".join("%s=%s"%kv for kv in sorted(d["checks"].items())))' "$ST")"
  for m in done failed; do [ -e "$STATE/$m-$SHA" ] && echo "  state: $m"; done
  [ "$loaded" = yes ] && is_ts "$CUT" && is_sha "$SHA" && [ "$integ" = ok ] && [ -n "$ST" ] || return 1
  [ -z "$WANT" ] || [ "$WANT" = "$SHA" ] || { echo "  armed for $SHA, not for $WANT"; return 1; }
  $PY -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["ok"] and d["launchd"] else 1)' "$ST"
}

need_src_sha() { # $1 sha: run from the worktree holding the deploy commit, which must add the cloud CNP
  is_sha "$1" || { echo "deploy sha must be 40 hex" >&2; exit 2; }
  SRC="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "run from the deploy worktree" >&2; exit 2; }
  git -C "$SRC" cat-file -e "$1^{commit}" || { echo "unknown commit $1" >&2; exit 2; }
  git -C "$SRC" diff-tree --no-commit-id --name-status -r "$1" | grep -qxF "A"$'\t'"$CNP_PATH" \
    || { echo "REFUSED: $1 is not the commit that adds $CNP_PATH (rollback.sh reverts exactly that commit)" >&2; exit 2; }
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$1" ] || { echo "REFUSED: run from the worktree whose HEAD is $1 (the gate reads its bundle)" >&2; exit 2; }
}

arm_with() { # $1 sha $2 cutoff $3 w2 event ts $4 evidence file $5 armed|re-armed
  local SHA="$1" CUT="$2" W2="$3" EVF="$4" KIND="$5" INST
  [ "$(now_epoch)" -lt "$(epoch "$CUT")" ] || { echo "REFUSED: cutoff $CUT is not in the future" >&2; exit 2; }
  ensure_fai_wt || exit 1
  if [ -z "${C010_SKIP_ROLLBACK_DRYRUN:-}" ]; then
    FAMILY_AI_REPO="$FAI_WT" VDH_REPO="$REPO" bash "$SRC/hack/ops/$CHG-rollback.sh" --dry-run "$SHA" "$SHA" \
      | tail -1 | grep -q 'RESULT dry-run GREEN' || { echo "REFUSED: rollback.sh --dry-run $SHA not GREEN" >&2; exit 1; }
  fi
  INST="$(install_and_load "$SHA" "$CUT" "$LABEL_REAL" "$W2")" || exit 1
  readback "$SHA" "$LABEL_REAL"; local rb=$?
  ev step="cutoff $KIND (launchd $LABEL_REAL)" deploy="$SHA" trigger_utc="$CUT" trigger_source="promo_credit_expires_utc of $EVF" \
     w2_event="$W2" interval_s="$INTERVAL" \
     install="$INST" sums_sha256="$(shasum -a 256 "$INST/SHA256SUMS" | cut -c1-16)" readback="$([ $rb = 0 ] && echo GREEN || echo RED)"
  exit $rb
}

# =============================================================================================== dispatch
MODE="${1:-}"; shift || true
case "$MODE" in
  fire) fire "$@";;
  readback) readback "${1:-}" "${2:-$LABEL_REAL}";;
  arm)
    need_src_sha "${1:-}"; SHA="$1"; shift
    [ "${1:-}" = --w2-event ] && [ -n "${2:-}" ] || { echo "arm needs --w2-event <ts of the infra-ops W2 event>" >&2; exit 2; }
    W2="$2"
    OUT="$(bash "$SRC/hack/ops/$CHG-golive.sh" --gate-only "$SHA" --w2-event "$W2" 2>&1)"; rc=$?
    [ $rc = 0 ] || { echo "REFUSED: W2 gate: $(printf '%s\n' "$OUT" | grep REFUSED | tail -1)" >&2; exit 2; }
    CUT="$(printf '%s\n' "$OUT" | sed -n 's/.*promo_credit_expires_utc=\([0-9TZ:-]*\).*/\1/p' | tail -1)"
    EVF="$(printf '%s\n' "$OUT" | sed -n 's/.*: evidence \([^ ]*\) (.*/\1/p' | tail -1)"
    is_ts "$CUT" || { echo "REFUSED: the gate passed without a promo_credit_expires_utc (prepaid w2a needed for a cut-off)" >&2; exit 2; }
    echo "W2 gate GREEN: cut-off time from $EVF promo_credit_expires_utc = $CUT"
    PL="$AGENTS/$LABEL_REAL.plist"; KIND=armed
    if [ -e "$PL" ]; then
      A="$(plist_args "$PL")"
      if [ "$(arg_of "$A" --sha)" = "$SHA" ] && [ "$(arg_of "$A" --cutoff)" = "$CUT" ] && [ "$(arg_of "$A" --w2-event)" = "$W2" ] \
         && readback "$SHA" >/dev/null 2>&1; then echo "already armed for $SHA at $CUT from w2 event $W2 (no change)"; readback "$SHA"; exit 0; fi
      KIND=re-armed; echo "re-arm: $(arg_of "$A" --cutoff) -> $CUT"
    fi
    arm_with "$SHA" "$CUT" "$W2" "$EVF" "$KIND";;
  launchd-selftest)
    need_src_sha "${1:-}"; SHA="$1"
    ensure_fai_wt || exit 1
    INST="$(install_and_load "$SHA" "$TEST_CUTOFF" "$LABEL_TEST" none)"; ok=$?
    [ $ok = 0 ] && readback "$SHA" "$LABEL_TEST"; rb=$?
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL_TEST" >/dev/null 2>&1
    mkdir -p "$AGENTS/_retired"; [ -e "$AGENTS/$LABEL_TEST.plist" ] && mv "$AGENTS/$LABEL_TEST.plist" "$AGENTS/_retired/$LABEL_TEST.$(date -u +%Y%m%dT%H%M%SZ).plist"
    echo "launchd-selftest $([ $ok = 0 ] && [ $rb = 0 ] && echo GREEN || echo RED) (test label unloaded and moved to _retired)"
    [ $ok = 0 ] && [ $rb = 0 ];;
  retire)
    PL="$AGENTS/$LABEL_REAL.plist"; [ -e "$PL" ] || { echo "nothing armed"; exit 0; }
    SHA="$(arg_of "$(plist_args "$PL")" --sha)"
    git -C "$REPO" fetch -q origin
    [ -e "$STATE/done-$SHA" ] && ! cnp_on_main || { echo "REFUSED: retire only after the cut-off fired and cloud is off on main" >&2; exit 2; }
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL_REAL" >/dev/null 2>&1; mkdir -p "$AGENTS/_retired"
    mv "$PL" "$AGENTS/_retired/$LABEL_REAL.$(date -u +%Y%m%dT%H%M%SZ).plist"
    ev step="cutoff retired after firing" deploy="$SHA" result=GREEN; echo "retired";;
  *) sed -n '2,30p' "$0"; exit 2;;
esac
