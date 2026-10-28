#!/usr/bin/env bash
# chg-2026-10-28-002: tokens of the forge bot cursus-publisher (owner of ONLY the cursus-gast package).
#
#   hack/ops/chg-2026-10-28-002-forge-bot-token.sh push-auth <authfile>
#       reset the bot's password in-pod (random, never leaves the pod), mint a write:package token
#       cursus-push-<UTC> via the admin CLI (--raw, stdout to a 0600 file), write a 0600 podman auth file
#       {"auths":{"forge.bluejungle.net":...}} at <authfile> (refused if it exists non-empty), scope-test the token.
#       Then: CURSUS_PUSH_AUTHFILE=<authfile> hack/ops/chg-2026-10-28-002-build-sign.sh <commit> --push
#   hack/ops/chg-2026-10-28-002-forge-bot-token.sh revoke [<authfile>]
#       wake the bot with a temporary local password (stdin only), delete EVERY token named cursus-push-*,
#       prove none is left (and, with <authfile>, that its token is dead, then empty the file), make the bot dormant.
#   hack/ops/chg-2026-10-28-002-forge-bot-token.sh pull-item
#       needs Secret security/onepassword-cursus-gast-token (exit 3 until the owner has created the Connect token
#       item). Preflight Connect (vault cursus-gast, exactly one), refuse if a cursus-pull token already exists,
#       mint read:package token cursus-pull, scope-test it, write it into vault cursus-gast item forge-pull
#       (fields username, credential) via 1Password Connect, read back by hash. On any failure after the mint the
#       new token is deleted again. Bot ends dormant.
#
# Never prints a password, token or Connect token: values live in 0600 files or shell variables and go to the pod
# over stdin; curl reads credentials from 0600 config/header files; CLI output is never shown. Evidence (write-once):
# ops/evidence/chg-2026-10-28-002/<NN>-forge-bot-token-<mode>-<UTC>.txt. No rm (AGR-121): files are emptied.
# Exit codes: 0 ok, 1 an assertion failed, 2 usage/precondition, 3 Connect secret/vault not there yet, 4 refused.
set -euo pipefail
umask 077
MODE=${1:-}; ARG=${2:-}
case "$MODE" in
  push-auth) [ -n "$ARG" ] || { echo "usage: $0 push-auth <authfile>" >&2; exit 2; };;
  revoke|pull-item) ;;
  *) echo "usage: $0 push-auth <authfile> | revoke [<authfile>] | pull-item" >&2; exit 2;;
esac
BOT=cursus-publisher
B=https://forge.bluejungle.net
HOST=forge.bluejungle.net
REPO=$BOT/cursus-gast
VAULT=cursus-gast; ITEM=forge-pull
CS_NS=security; CS_SECRET=onepassword-cursus-gast-token; CS_SVC=onepassword-connect
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRATCH=${SCRATCH:-/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/afcadc58-4205-42d9-9959-d09214284b31/scratchpad}
RUN=$(date -u +%Y%m%dT%H%M%SZ)
A=$(mktemp -d "$SCRATCH/forge-bot-token-$MODE-$RUN.XXXXXX")
PW=$A/bot.pass; CC=$A/bot.curlcfg; TK=$A/token; TH=$A/tok.hdr; O=$A/cli.out; CH=$A/connect.hdr; BODY=$A/item.json
SECRETS=("$PW" "$CC" "$TK" "$TH" "$O" "$CH" "$BODY")
for f in "${SECRETS[@]}"; do : > "$f"; done
EV=$A/evidence.txt; : > "$EV"
ev() { printf '%s\n' "$*" | tee -a "$EV"; }
eval "$(mise env -s bash 2>/dev/null)" 2>/dev/null || true
K="kubectl -n devtools exec -i deploy/forgejo -c forgejo --"
EVDIR=$REPO_ROOT/ops/evidence/chg-2026-10-28-002
WOKEN=0; PF=""; MINTED_NAME=""; FAIL=0

finish() {
  rc=$?
  set +e
  if [ -n "$MINTED_NAME" ]; then  # pull-item failed after the mint: delete the new token again
    ev "cleanup: deleting freshly minted $MINTED_NAME after failure"
    [ "$WOKEN" = 1 ] || wake
    del_named "^$MINTED_NAME\$"
  fi
  [ "$WOKEN" = 1 ] && dormant
  [ -n "$PF" ] && kill "$PF" 2>/dev/null
  for f in "${SECRETS[@]}"; do : > "$f"; done
  ev "local secret files emptied: $(stat -f '%z' "${SECRETS[@]}" | tr '\n' ' ')bytes"
  ev "result mode=$MODE rc=$rc failures=$FAIL finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$EVDIR"
  n=$(find "$EVDIR" -maxdepth 1 -name '[0-9][0-9]-*' | sed 's|.*/||' | cut -c1-2 | sort -n | tail -1)
  out=$EVDIR/$(printf '%02d' $(( 10#${n:-0} + 1 )))-forge-bot-token-$MODE-$RUN.txt
  if ( set -o noclobber; cat "$EV" > "$out" ) 2>/dev/null; then chmod 644 "$out"; echo "evidence: ${out#$REPO_ROOT/}"
  else echo "evidence NOT written" >&2; rc=98; fi
  echo "EXIT $rc"; exit "$rc"
}
trap finish EXIT

# ---- helpers ---------------------------------------------------------------------------------------------------------
asbot() { # asbot METHOD PATH -> body + last line "HTTP nnn" (basic auth with the temporary password)
  printf 'user = "%s:%s"\n' "$BOT" "$(head -1 "$PW" | tr -d '\n')" > "$CC"
  curl -sS -K "$CC" -X "$1" -H 'Accept: application/json' -w '\nHTTP %{http_code}\n' "$B$2"
  : > "$CC"
}
astoken() { # astoken PATH -> HTTP code only (token from $TK)
  printf 'header = "Authorization: token %s"\n' "$(head -1 "$TK" | tr -d '\n')" > "$TH"
  curl -sS -o /dev/null -K "$TH" -w '%{http_code}' -H 'Accept: application/json' "$B$1" || echo 000
  : > "$TH"
}
regtoken() { # regtoken SCOPE -> HTTP code of the registry token endpoint with basic bot:token
  printf 'user = "%s:%s"\n' "$BOT" "$(head -1 "$TK" | tr -d '\n')" > "$TH"
  curl -sS -o /dev/null -K "$TH" -w '%{http_code}' "$B/v2/token?service=container_registry&scope=repository:$REPO:$1" || echo 000
  : > "$TH"
}
wake() { # temporary local password, sent over stdin; the user must exist and be non-admin
  $K forgejo admin user list 2>/dev/null | awk -v u="$BOT" '$2==u{print $(NF-1)}' > "$O"
  [ "$(cat "$O")" = false ] || { ev "STOP: $BOT missing or admin"; : > "$O"; exit 2; }
  openssl rand -base64 60 | tr -d '\n/+=' | cut -c1-48 > "$PW"; printf '\n' >> "$PW"
  $K sh -c 'IFS= read -r P; forgejo admin user change-password -u "$1" -p "$P" --must-change-password=false; rc=$?; P=""; exit $rc' \
    sh "$BOT" < "$PW" > "$O" 2>&1 || { ev "STOP: wake change-password failed"; : > "$O"; exit 2; }
  : > "$O"; WOKEN=1
  C=$(asbot GET /api/v1/user | tail -1); ev "wake: temporary password set over stdin; GET /api/v1/user as bot -> $C"
  [ "$C" = "HTTP 200" ] || { ev "STOP: wake read-back not 200"; exit 2; }
}
dormant() { # in-pod random password nobody holds; prove the temporary one is dead
  $K sh -c 'P=$(head -c 48 /dev/urandom | base64 | tr -d "\n"); forgejo admin user change-password -u "$1" -p "$P" --must-change-password=false; rc=$?; P=""; exit $rc' \
    sh "$BOT" > "$O" 2>&1 || { ev "dormant change-password FAILED"; FAIL=1; }
  : > "$O"
  if [ -s "$PW" ]; then
    C=$(asbot GET /api/v1/user | tail -1); ev "dormant: in-pod random password; previous temporary password -> $C"
    [ "$C" = "HTTP 401" ] || { ev "assert previous password dead: FAIL"; FAIL=1; }
  else ev "dormant: in-pod random password (no local password was held)"; fi
  : > "$PW"; WOKEN=0
}
reset_in_pod() { # admin-CLI password reset to an in-pod random value (no wake, nothing local)
  $K sh -c 'P=$(head -c 48 /dev/urandom | base64 | tr -d "\n"); forgejo admin user change-password -u "$1" -p "$P" --must-change-password=false; rc=$?; P=""; exit $rc' \
    sh "$BOT" > "$O" 2>&1 || { ev "STOP: password reset failed"; : > "$O"; exit 2; }
  ev "password reset via admin CLI (in-pod random): success line $(grep -c 'successfully updated' "$O" || true)"; : > "$O"
}
tokens() { asbot GET "/api/v1/users/$BOT/tokens" > "$O"; [ "$(tail -1 "$O")" = "HTTP 200" ] || { ev "STOP: token list $(tail -1 "$O")"; : > "$O"; exit 2; }
           sed '$d' "$O" | jq -c '[.[] | {id, name, scopes}]'; : > "$O"; }
del_named() { # del_named <jq regex> : delete every token whose name matches; prints the count
  local L ids
  L=$(tokens); ids=$(printf '%s' "$L" | jq -r --arg re "$1" '.[] | select(.name | test($re)) | .id')
  for id in $ids; do ev "DELETE token $id ($(printf '%s' "$L" | jq -r --argjson i "$id" '.[] | select(.id == $i) | .name')) -> $(asbot DELETE "/api/v1/users/$BOT/tokens/$id" | tail -1)"; done
  L=$(tokens); left=$(printf '%s' "$L" | jq --arg re "$1" '[.[] | select(.name | test($re))] | length')
  ev "tokens matching $1 left: $left (all tokens now: $(printf '%s' "$L" | jq -c '[.[] | .name]'))"
  [ "$left" = 0 ] || { ev "assert none left: FAIL"; FAIL=1; }
  [ "$1" = "^$MINTED_NAME\$" ] && [ "$left" = 0 ] && MINTED_NAME=""
  return 0
}
mint() { # mint <name> <scope> -> token in $TK (admin CLI, --raw; stdout to the 0600 file, never shown)
  $K forgejo admin user generate-access-token --username "$BOT" --token-name "$1" --scopes "$2" --raw > "$TK" 2> "$O" \
    || { ev "STOP: mint $1 failed ($(grep -ciE 'exist|duplicate' "$O" || true) exists-lines)"; : > "$O"; : > "$TK"; exit 2; }
  : > "$O"
  tr -d '\n' < "$TK" | grep -qE '^[0-9a-f]{40}$' || { ev "STOP: minted output is not a single 40-hex token"; : > "$TK"; exit 2; }
  ev "minted $1 scope $2 via admin CLI (--raw to a 0600 file; value not shown)"
}
scope_tests() { # scope_tests <push|pull>
  ev "token GET /api/v1/packages/$BOT -> $(astoken "/api/v1/packages/$BOT")"
  for p in /api/v1/user /api/v1/user/repos /api/v1/admin/users "/api/v1/packages/wires-publisher" "/api/v1/packages/palamedes"; do
    c=$(astoken "$p"); ev "token GET $p -> $c"; [ "$c" = 403 ] || { ev "assert 403: FAIL"; FAIL=1; }
  done
  c=$(regtoken "$1"); ev "registry /v2/token scope $REPO:$1 -> $c"; [ "$c" = 200 ] || { ev "assert registry $1 200: FAIL"; FAIL=1; }
}

ev "== chg-2026-10-28-002 forge bot token, mode $MODE, run $RUN, actor k8s-engineer (Heph)"
ev "AGR-109: tests are the gate"

# ---- push-auth -------------------------------------------------------------------------------------------------------
if [ "$MODE" = push-auth ]; then
  AUTH=$ARG
  [ ! -s "$AUTH" ] || { ev "REFUSED: $AUTH exists and is not empty"; exit 4; }
  [ -d "$(dirname "$AUTH")" ] || { ev "REFUSED: directory of the authfile does not exist"; exit 2; }
  reset_in_pod
  NAME=cursus-push-$RUN
  mint "$NAME" write:package
  scope_tests push
  ( umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$HOST" \
      "$(printf '%s:%s' "$BOT" "$(head -1 "$TK" | tr -d '\n')" | base64 | tr -d '\n')" > "$AUTH" )
  chmod 600 "$AUTH"
  ev "authfile written: mode $(stat -f %Lp "$AUTH"), hosts $(jq -c '.auths | keys' "$AUTH")"
  : > "$TK"
  ev "next: CURSUS_PUSH_AUTHFILE=<authfile> hack/ops/chg-2026-10-28-002-build-sign.sh <commit> --push; then: $0 revoke <authfile>"
  [ "$FAIL" = 0 ] || { ev "a scope test failed: run revoke now"; exit 1; }
  exit 0
fi

# ---- revoke ----------------------------------------------------------------------------------------------------------
if [ "$MODE" = revoke ]; then
  if [ -n "$ARG" ] && [ -s "$ARG" ]; then
    jq -r --arg h "$HOST" '.auths[$h].auth // empty' "$ARG" | base64 -d | cut -d: -f2- > "$TK" 2>/dev/null || true
  fi
  wake
  del_named '^cursus-push-'
  if [ -s "$TK" ]; then
    c=$(astoken /api/v1/packages/$BOT); r=$(regtoken pull)
    ev "authfile token after revoke: API -> $c, /v2/token -> $r"
    [ "$c" = 401 ] && [ "$r" = 401 ] && ev "assert authfile token dead: PASS" || { ev "assert authfile token dead: FAIL"; FAIL=1; }
    : > "$TK"; : > "$ARG"; ev "authfile emptied ($(stat -f %z "$ARG") bytes)"
  fi
  dormant
  [ "$FAIL" = 0 ] || exit 1
  exit 0
fi

# ---- pull-item -------------------------------------------------------------------------------------------------------
if ! kubectl -n "$CS_NS" get secret "$CS_SECRET" >/dev/null 2>&1; then
  ev "STOP: Secret $CS_NS/$CS_SECRET does not exist yet. The owner must first create the Connect token item"
  ev "      op-connect-token-cursus-gast in home-infra (field credential; a Connect token with read+write on vault"
  ev "      $VAULT only). ESO then syncs it. Nothing minted, nothing written."
  exit 3
fi
kubectl -n "$CS_NS" port-forward --address 127.0.0.1 "svc/$CS_SVC" :80 > "$A/pf.log" 2>&1 &
PF=$!; PORT=""
for _ in $(seq 1 30); do
  PORT=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' "$A/pf.log" | head -1)
  [ -n "$PORT" ] && break; kill -0 "$PF" 2>/dev/null || break; sleep 0.5
done
[ -n "$PORT" ] || { ev "STOP: port-forward to $CS_NS/$CS_SVC did not start"; exit 3; }
( printf 'Authorization: Bearer '; kubectl -n "$CS_NS" get secret "$CS_SECRET" -o jsonpath='{.data.token}' | base64 -d; printf '\n' ) > "$CH"
[ "$(wc -c < "$CH")" -gt 30 ] || { ev "STOP: Secret $CS_NS/$CS_SECRET has no token key"; exit 3; }
cget() { curl -sS --max-time 20 -H @"$CH" -w '\nHTTP %{http_code}\n' "http://127.0.0.1:$PORT$1"; }
R=$(cget "/v1/vaults?filter=name%20eq%20%22$VAULT%22"); ev "Connect GET vaults (name $VAULT) -> $(printf '%s' "$R" | tail -1)"
VID=$(printf '%s' "$R" | sed '$d' | jq -r --arg v "$VAULT" '[.[] | select(.name == $v)] | if length == 1 then .[0].id else empty end' 2>/dev/null)
[ -n "$VID" ] || { ev "STOP: vault $VAULT not exactly one through the cursus-gast Connect token"; exit 3; }
R=$(cget "/v1/vaults/$VID/items?filter=title%20eq%20%22$ITEM%22")
IID=$(printf '%s' "$R" | sed '$d' | jq -r --arg t "$ITEM" '[.[] | select(.title == $t)] | if length == 1 then .[0].id elif length == 0 then "" else "MANY" end')
[ "$IID" != MANY ] || { ev "STOP: more than one item $ITEM in $VAULT"; exit 4; }
ev "item $ITEM in $VAULT: $( [ -n "$IID" ] && echo 'exists (will be updated)' || echo 'absent (will be created)')"

wake
L=$(tokens)
[ "$(printf '%s' "$L" | jq '[.[] | select(.name == "cursus-pull")] | length')" = 0 ] \
  || { ev "REFUSED: a cursus-pull token already exists (rotation = delete it in a reviewed step first)"; exit 4; }
MINTED_NAME=cursus-pull
mint cursus-pull read:package
scope_tests pull
c=$(regtoken push); ev "registry /v2/token scope $REPO:push with read token -> $c (informational)"
[ "$FAIL" = 0 ] || { ev "STOP: scope tests failed"; exit 1; }

if [ -n "$IID" ]; then
  cget "/v1/vaults/$VID/items/$IID" | sed '$d' > "$BODY"
  jq --rawfile t "$TK" --arg u "$BOT" '
    .fields = ([.fields[]? | select(.label != "username" and .label != "credential")]
      + [{id: "username", label: "username", type: "STRING", value: $u},
         {id: "credential", label: "credential", type: "CONCEALED", value: ($t | rtrimstr("\n"))}])' "$BODY" > "$BODY.new"
  mv "$BODY.new" "$BODY"
  C=$(curl -sS --max-time 20 -H @"$CH" -H 'Content-Type: application/json' -X PUT --data @"$BODY" -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:$PORT/v1/vaults/$VID/items/$IID")
  ev "Connect PUT item $ITEM -> $C"
else
  jq -n --rawfile t "$TK" --arg u "$BOT" --arg vid "$VID" --arg title "$ITEM" '{
    vault: {id: $vid}, title: $title, category: "API_CREDENTIAL",
    tags: ["chg-2026-10-28-002"],
    fields: [{id: "username", label: "username", type: "STRING", value: $u},
             {id: "credential", label: "credential", type: "CONCEALED", value: ($t | rtrimstr("\n"))}]}' > "$BODY"
  curl -sS --max-time 20 -H @"$CH" -H 'Content-Type: application/json' -X POST --data @"$BODY" -o "$A/post.out" -w '%{http_code}' \
      "http://127.0.0.1:$PORT/v1/vaults/$VID/items" > "$A/post.code" || echo 000 > "$A/post.code"
  C=$(cat "$A/post.code"); IID=$(jq -r '.id // empty' "$A/post.out" 2>/dev/null); : > "$A/post.out"
  ev "Connect POST item $ITEM -> $C"
fi
: > "$BODY"
case "$C" in 200|201) ;; *) ev "STOP: Connect write refused ($C): the cursus-gast Connect token needs write on $VAULT"; exit 1;; esac
# read back by hash: the stored credential must equal the minted token
cget "/v1/vaults/$VID/items/$IID" | sed '$d' > "$BODY"
WANT=$(tr -d '\n' < "$TK" | shasum -a 256 | cut -c1-64)
GOT=$(jq -r '[.fields[] | select(.label == "credential")] | if length == 1 then .[0].value else "" end' "$BODY" | tr -d '\n' | shasum -a 256 | cut -c1-64)
USR=$(jq -r '[.fields[] | select(.label == "username")] | .[0].value // ""' "$BODY")
: > "$BODY"
[ "$GOT" = "$WANT" ] && [ "$USR" = "$BOT" ] && ev "read-back item $ITEM: username = $BOT, credential sha256 matches the minted token: PASS" \
  || { ev "read-back item $ITEM: FAIL (username or credential hash differ)"; exit 1; }
MINTED_NAME=""   # stored: keep the token
: > "$TK"
ev "pull token cursus-pull kept (read:package), stored only in $VAULT/$ITEM; rotate-by 90 days (add to the token register)"
dormant
[ "$FAIL" = 0 ] || exit 1
exit 0
