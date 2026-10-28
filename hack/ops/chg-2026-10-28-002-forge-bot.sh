#!/usr/bin/env bash
# chg-2026-10-28-002: create the forge bot cursus-publisher (owner of ONLY the cursus-gast package), the way
# wires-publisher was made (chg-2026-10-07-007): server CLI via kubectl exec, no admin login, non-admin, restricted,
# no orgs; visibility set to private through the bot's own web session (the API has no visibility field).
# Ends DORMANT: the password is replaced in-pod by a random one nobody holds; the push step later resets it via the
# admin CLI and mints a write:package token then. No token is minted here.
#
#   hack/ops/chg-2026-10-28-002-forge-bot.sh
#
# Secret handling (inc lesson from wires-publisher: the CLI printed a random password once):
#   * never --random-password; the password is generated locally into a 0600 file, sent to the pod over STDIN only
#     (not on the kubectl argv), read into a shell variable inside the pod;
#   * every CLI output goes to a 0600 file that is never shown; only a fixed success line is grepped and the number
#     of occurrences of the password in it is counted (must be 0);
#   * curl reads credentials from 0600 config/data files, never argv; all are emptied in the EXIT trap.
# Prints HTTP codes, ids and booleans only. No rm (AGR-121): files are emptied, not deleted.
set -euo pipefail
umask 077
BOT=cursus-publisher
EMAIL=$BOT@noreply.forge.bluejungle.net
B=https://forge.bluejungle.net
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRATCH=${SCRATCH:-/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/afcadc58-4205-42d9-9959-d09214284b31/scratchpad}
RUN=$(date -u +%Y%m%dT%H%M%SZ)
A=$(mktemp -d "$SCRATCH/forge-bot-$RUN.XXXXXX")
PW=$A/bot.pass; CC=$A/bot.curlcfg; J=$A/web.jar; R=$A/pw.raw; O=$A/cli.out; H=$A/web.html
for f in "$PW" "$CC" "$J" "$R" "$O" "$H"; do : > "$f"; done
EV=$A/evidence.txt; : > "$EV"
ev() { printf '%s\n' "$*" | tee -a "$EV"; }
eval "$(mise env -s bash 2>/dev/null)" 2>/dev/null || true
K="kubectl -n devtools exec -i deploy/forgejo -c forgejo --"
EVDIR=$REPO_ROOT/ops/evidence/chg-2026-10-28-002

finish() {
  rc=$?
  set +e
  for f in "$PW" "$CC" "$J" "$R" "$O" "$H"; do : > "$f"; done
  ev "local secret files emptied: $(stat -f '%z' "$PW" "$CC" "$J" "$R" "$O" "$H" | tr '\n' ' ')bytes"
  ev "result rc=$rc finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$EVDIR"
  n=$(find "$EVDIR" -maxdepth 1 -name '[0-9][0-9]-*' | sed 's|.*/||' | cut -c1-2 | sort -n | tail -1)
  out=$EVDIR/$(printf '%02d' $(( 10#${n:-0} + 1 )))-forge-bot-$RUN.txt
  if ( set -o noclobber; cat "$EV" > "$out" ) 2>/dev/null; then chmod 644 "$out"; echo "evidence: ${out#$REPO_ROOT/}"
  else echo "evidence NOT written" >&2; rc=98; fi
  echo "EXIT $rc"; exit "$rc"
}
trap finish EXIT
newpass() { openssl rand -base64 60 | tr -d '\n/+=' | cut -c1-48 > "$PW"; printf '\n' >> "$PW"; }
leaks() { grep -cF -f <(head -1 "$PW") "$O" || true; }  # pattern from a file descriptor, not argv
asbot() { # asbot METHOD PATH -> body, last line "HTTP nnn"
  printf 'user = "%s:%s"\n' "$BOT" "$(head -1 "$PW" | tr -d '\n')" > "$CC"
  curl -sS -K "$CC" -X "$1" -H 'Accept: application/json' -w '\nHTTP %{http_code}\n' "$B$2"
  : > "$CC"
}

ev "== chg-2026-10-28-002 forge bot $BOT, run $RUN, actor k8s-engineer (Heph), decision Atlas"
ev "AGR-109: tests are the gate"
ev "forgejo pod: $(kubectl -n devtools get pod -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name} {.items[0].status.phase}' 2>/dev/null)"

# 0 pre-state: the user must not exist yet
$K forgejo admin user list > "$O" 2>/dev/null
if awk -v u="$BOT" '$2==u' "$O" | grep -q .; then ev "STOP: $BOT already exists"; exit 2; fi
ev "pre-state: $BOT absent; users listed $(($(wc -l < "$O") - 1))"

# 1 create (password over stdin, never --random-password)
newpass
$K sh -c 'IFS= read -r P; forgejo admin user create --username "$1" --email "$2" --password "$P" --must-change-password=false --restricted; rc=$?; P=""; exit $rc' \
  sh "$BOT" "$EMAIL" < "$PW" > "$O" 2>&1 || { ev "STOP: create failed (output withheld; leak count $(leaks))"; : > "$O"; exit 3; }
ev "create: success line $(grep -c 'successfully created' "$O" || true), password occurrences in CLI output $(leaks)"
[ "$(leaks)" = 0 ] || { ev "STOP: CLI output contains the password; rotating now"; : > "$O"; exit 4; }
: > "$O"

# 2 read-back as the bot
asbot GET /api/v1/user > "$A/u.json"
ev "GET /api/v1/user as bot -> $(tail -1 "$A/u.json")"
sed '$d' "$A/u.json" | jq -c '{login, id, is_admin, restricted, visibility}' | tee -a "$EV"

# 3 visibility private via the bot's own web session (narrowing only)
: > "$J"; head -1 "$PW" | tr -d '\n' > "$R"
ev "$(curl -sS -c "$J" -b "$J" -o "$H" -w 'GET /user/login -> %{http_code}' "$B/user/login")"
ev "$(curl -sS -c "$J" -b "$J" -o /dev/null -w 'POST /user/login -> %{http_code}' \
  --data-urlencode "user_name=$BOT" --data-urlencode "password@$R" "$B/user/login")"
: > "$R"
ev "$(curl -sS -c "$J" -b "$J" -o "$H" -w 'GET /user/settings -> %{http_code}' "$B/user/settings")"
grep -q 'name="visibility"' "$H" || { ev "STOP: settings form not served (not logged in?)"; exit 5; }
ev "$(curl -sS -c "$J" -b "$J" -o /dev/null -w 'POST /user/settings -> %{http_code}' \
  --data-urlencode "name=$BOT" --data-urlencode "full_name=" --data-urlencode "website=" --data-urlencode "location=" \
  --data-urlencode "description=" --data-urlencode "pronouns=" --data-urlencode "visibility=2" \
  --data-urlencode "keep_email_private=on" "$B/user/settings")"
curl -sS -c "$J" -b "$J" -o /dev/null "$B/user/logout" || true
: > "$J"; : > "$H"

# 4 read-back: the brief's assertions
asbot GET /api/v1/user > "$A/u2.json"
ev "GET /api/v1/user as bot -> $(tail -1 "$A/u2.json")"
U=$(sed '$d' "$A/u2.json" | jq -c '{login, id, is_admin, restricted, visibility}'); ev "$U"
asbot GET /api/v1/user/orgs > "$A/o.json"
ev "GET /api/v1/user/orgs as bot -> $(tail -1 "$A/o.json") count $(sed '$d' "$A/o.json" | jq 'length')"
asbot GET "/api/v1/packages/$BOT" > "$A/p.json"
ev "GET /api/v1/packages/$BOT as bot -> $(tail -1 "$A/p.json") count $(sed '$d' "$A/p.json" | jq 'length' 2>/dev/null)"
ANON=$(curl -sS -o /dev/null -w '%{http_code}' "$B/v2/")
ev "anonymous GET /v2/ -> $ANON"
FAIL=0
printf '%s' "$U" | jq -e --arg u "$BOT" '.login == $u and .is_admin == false and .restricted == true and .visibility == "private"' >/dev/null \
  && ev "assert login/is_admin false/restricted true/visibility private: PASS" || { ev "assert user fields: FAIL"; FAIL=1; }
[ "$(sed '$d' "$A/o.json" | jq 'length')" = 0 ] && ev "assert no orgs: PASS" || { ev "assert no orgs: FAIL"; FAIL=1; }
[ "$ANON" = 401 ] && ev "assert anonymous /v2/ 401: PASS" || { ev "assert anonymous /v2/ 401: FAIL"; FAIL=1; }
asbot GET "/api/v1/users/$BOT/tokens" > "$A/t.json"
TN=$(sed '$d' "$A/t.json" | jq 'length')
ev "GET /api/v1/users/$BOT/tokens as bot -> $(tail -1 "$A/t.json") count $TN (push step mints write:package later)"
[ "$TN" = 0 ] && ev "assert no tokens: PASS" || { ev "assert no tokens: FAIL"; FAIL=1; }
for f in "$A/u.json" "$A/u2.json" "$A/o.json" "$A/p.json" "$A/t.json"; do : > "$f"; done

# 5 dormant: in-pod random password nobody holds; prove the local one is dead
$K sh -c 'P=$(head -c 48 /dev/urandom | base64 | tr -d "\n"); forgejo admin user change-password -u "$1" -p "$P" --must-change-password=false; rc=$?; P=""; exit $rc' \
  sh "$BOT" > "$O" 2>&1 || { ev "STOP: dormant change-password failed"; : > "$O"; exit 6; }
ev "dormant change-password (in-pod random, never left the pod): success line $(grep -c 'successfully updated' "$O" || true)"
: > "$O"
C=$(asbot GET /api/v1/user | tail -1)
ev "previous password GET /api/v1/user -> $C"
[ "$C" = "HTTP 401" ] && ev "assert previous password dead: PASS" || { ev "assert previous password dead: FAIL"; FAIL=1; }
$K forgejo admin user list 2>/dev/null | awk -v u="$BOT" '$2==u{print "cli list: id "$1" user "$2" active "$(NF-2)" admin "$(NF-1)" 2fa "$NF}' | tee -a "$EV"
[ "$FAIL" = 0 ] || exit 1
