#!/usr/bin/env bash
# chg-2026-10-30-001 (tsk-2026-10-30-005): read-only forge access for the Mini's pka-wires-sync.
# Argus go_scope = exactly 7 VDHICT repos (qa_failed 2026-10-30T07:28:25Z); hold_scope repos are NOT touched.
#
#   --dry-run (default)  read everything, print what WOULD change, change nothing (except the evidence file)
#   --yes                act: user, collaborators, key, ssh config block, per-repo remote URL
#
# Run on vdhmini01 as sheijden. Admin API: a short-lived admforgejo token minted by the forge CLI
# (hack/ops/lib/forge_admin_token.sh; chg-2026-11-20-001: the old Secret devtools/forgejo-admin-secret gets 401),
# read scopes in dry-run, write scopes with --yes, handed to curl inside the forgejo pod on STDIN (never argv, never
# printed, never written), deleted by SQL at the end and on exit. F11: refuses an empty token so no readback can be vacuous.
# The new user's password is random, sent once on STDIN, never stored or printed. No key, token or password is
# ever printed. Evidence: ops/evidence/chg-2026-10-30-001/run-<mode>-<UTC>.txt (write-once), gitleaks-checked.
#
# Design notes (for Argus):
#  - prohibit_login stays FALSE: Forgejo's ssh serv path rejects a user with prohibit_login ("account is
#    disabled"), so it would also kill ssh git. Web login is made unusable instead: random 48-byte password that
#    nobody holds + must_change_password. restricted=true, max_repo_creation=0, allow_create_organization=false,
#    allow_git_hook=false, allow_import_local=false, visibility private, not admin, no org membership.
#  - The key has no passphrase (launchd use) and is readable by every uid-501 process on the Mini, myPKA
#    included: it is effectively shared with myPKA and is registered as such in the evidence.
#  - Argus fix 1: a separate ssh alias `Host forge-read` (HostName/HostKeyAlias forge-ssh.bluejungle.net,
#    IdentitiesOnly, IdentityAgent none). No Host block for forge-ssh.bluejungle.net itself, so every other ssh
#    to the forge (vault-forge-push, chase, projection-golive, hold_scope copies) is unaffected.
#  - Argus fix 2: in the 7 copies only, every remote whose URL is VDHICT/<that repo> on the forge (https or
#    git@forge-ssh scp form) gets fetch URL git@forge-read:VDHICT/<repo>.git; the old URL is kept as that
#    remote's pushurl (push unchanged). Non-forge remotes (pka-approve's GitHub origin) are left alone. No global
#    insteadOf. Rollback per remote is printed.
#  - Argus fix 3: must_change_password is part of the flag readback.
# AGR-121: this script deletes nothing (no delete commands at all).
set -euo pipefail
umask 077

CHG=chg-2026-10-30-001
U=pka-mini-read
ORG=VDHICT
REPOS=(cluster-wires cycle gezin-dashboard invoicing pka-approve prikbord vdh-calendar)
WIRES="$HOME/Code/pka-wires"
KEY="$HOME/.ssh/forge-read_ed25519"
KEY_COMMENT="pka-mini-read@vdhmini01"
KEY_TITLE="pka-mini-read@vdhmini01"
SSH_HOST=forge-ssh.bluejungle.net
ALIAS=forge-read
SSHCFG="$HOME/.ssh/config"
MARK_B="# BEGIN forge read-only fetch ($CHG): user $U, 7 repos"
MARK_E="# END forge read-only fetch ($CHG)"
NS=devtools

MODE=dry-run
case "${1:-}" in
  ""|--dry-run) MODE=dry-run ;;
  --yes) MODE=yes ;;
  *) echo "usage: $0 [--dry-run|--yes]"; exit 2 ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=lib/forge_admin_token.sh
. "$REPO_ROOT/hack/ops/lib/forge_admin_token.sh"
EDIR="$REPO_ROOT/ops/evidence/$CHG"
TS=$(date -u +%Y%m%dT%H%M%SZ)
EF="$EDIR/run-$MODE-$TS.txt"

eval "$(mise env -s bash 2>/dev/null)" 2>/dev/null || true
command -v kubectl >/dev/null && command -v jq >/dev/null && command -v gitleaks >/dev/null || { echo "need kubectl jq gitleaks"; exit 2; }
[ "$(hostname -s)" = vdhmini01 ] || { echo "run on vdhmini01"; exit 2; }

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
act() { [ "$MODE" = yes ]; }

# --- forge admin API -------------------------------------------------------------------------------------------
load_admin() {
  local scopes=read:admin,read:repository,read:user,read:organization
  act && scopes=write:admin,write:repository,read:user,read:organization
  fat_mint "$CHG" "$scopes" || { echo "F11: no admin token, refusing"; exit 3; }
}
# forge METHOD PATH [JSON-BODY] [SUDO-USER] -> sets FB (body) and FC (http code). Body may hold no secrets
# except a create request, whose body is passed here on stdin only and never echoed.
forge() { fat_api "$@"; }
psql_ro() {
  local pod
  pod=$(kubectl -n "$NS" get pod -l cnpg.io/cluster=forge-pg,cnpg.io/instanceRole=primary -o name | head -1)
  kubectl -n "$NS" exec "$pod" -c postgres -- psql -d forgejo -tA -F ' ' -c "$1"
}
FLAGS_SQL="select is_admin, is_restricted, prohibit_login, max_repo_creation, allow_create_organization, allow_git_hook, allow_import_local, visibility, is_active, must_change_password from \"user\" where lower_name='$U'"
WANT_FLAGS="f t f 0 f f f 2 t t"   # visibility 2 = private
EDIT_BODY() { jq -nc --arg u "$U" --arg ln "$1" '{login_name:$ln, source_id:0, admin:false, restricted:true,
  prohibit_login:false, max_repo_creation:0, allow_create_organization:false, allow_git_hook:false,
  allow_import_local:false, visibility:"private", active:true, must_change_password:true}'; }

# --- steps -----------------------------------------------------------------------------------------------------
step_user() {
  echo "## 1 forge user $U"
  forge GET "/users/$U"
  if [ "$FC" = 404 ]; then
    if act; then
      local body
      body=$(head -c 48 /dev/urandom | base64 | tr -d '\n' | jq -Rsc --arg u "$U" \
        '{username:$u, login_name:$u, source_id:0, email:($u+"@noreply.bluejungle.net"), password:., must_change_password:true,
          send_notify:false, restricted:true, visibility:"private"}')
      forge POST /admin/users "$body"; body=""
      echo "create user HTTP $FC"; [ "$FC" = 201 ] || { fail "user create"; return; }
      forge PATCH "/admin/users/$U" "$(EDIT_BODY "$U")"; echo "set flags HTTP $FC"; [ "$FC" = 200 ] || fail "user flags"
    else
      echo "WOULD create user $U (random password, not stored), then set: restricted, prohibit_login=false (ssh), max_repo_creation 0, no org creation, no git hooks, no local import, private, not admin"
    fi
    return
  fi
  [ "$FC" = 200 ] || { fail "GET user HTTP $FC"; return; }
  local have ln
  have=$(psql_ro "$FLAGS_SQL" | head -1); ln=$(jq -r '.login_name // empty' <<<"$FB"); ln=${ln:-$U}
  echo "exists; flags is_admin,restricted,prohibit_login,max_repo_creation,create_org,git_hook,import_local,visibility,active,must_change_password = $have"
  if [ "$have" = "$WANT_FLAGS" ]; then echo "flags OK, nothing to correct"; return; fi
  if act; then forge PATCH "/admin/users/$U" "$(EDIT_BODY "$ln")"; echo "correct flags HTTP $FC"; [ "$FC" = 200 ] || fail "flag correction"
  else echo "WOULD correct flags to $WANT_FLAGS (only these flags)"; fi
  return 0
}

step_collab() {
  echo "## 2 read collaborator on exactly ${#REPOS[@]} repos"
  local r
  for r in "${REPOS[@]}"; do
    forge GET "/repos/$ORG/$r"; [ "$FC" = 200 ] || { fail "$ORG/$r not found (HTTP $FC)"; continue; }
    forge GET "/repos/$ORG/$r/collaborators/$U"
    if [ "$FC" = 204 ]; then
      forge GET "/repos/$ORG/$r/collaborators/$U/permission"; local perm; perm=$(jq -r '.permission // "?"' <<<"$FB")
      if [ "$perm" = read ]; then echo "$r: already read"; continue; fi
      echo "$r: collaborator with '$perm'"
    else echo "$r: not a collaborator"; fi
    if act; then forge PUT "/repos/$ORG/$r/collaborators/$U" '{"permission":"read"}'; echo "$r: add read HTTP $FC"; [ "$FC" = 204 ] || fail "$r collaborator"
    else echo "$r: WOULD set read collaborator"; fi
  done
  return 0
}

step_key() {
  echo "## 3 ssh key $KEY (user key, not a deploy key)"
  if [ -e "$KEY" ]; then
    local m c; m=$(stat -f '%Lp' "$KEY"); c=$(awk '{print $3}' "$KEY.pub")
    echo "key exists, mode $m, comment $c, fp $(ssh-keygen -l -f "$KEY.pub" | awk '{print $2}')"
    [ "$m" = 600 ] || { if act; then chmod 600 "$KEY"; echo "mode set 600"; else echo "WOULD chmod 600"; fi; }
    [ "$c" = "$KEY_COMMENT" ] || fail "key comment is '$c', want $KEY_COMMENT (not touching an existing key)"
  elif act; then
    ssh-keygen -q -t ed25519 -N "" -C "$KEY_COMMENT" -f "$KEY"; chmod 600 "$KEY"
    echo "generated, fp $(ssh-keygen -l -f "$KEY.pub" | awk '{print $2}')"
  else echo "WOULD generate ed25519 key, no passphrase, 0600, comment $KEY_COMMENT"; fi
  forge GET "/users/$U/keys?limit=50"
  if [ "$FC" = 404 ]; then echo "WOULD add public key to $U after the user exists (title $KEY_TITLE)"; return; fi
  [ "$FC" = 200 ] || { fail "GET keys HTTP $FC"; return; }
  echo "user keys on forge: $(jq length <<<"$FB")"
  if [ ! -e "$KEY.pub" ]; then echo "WOULD add public key (title $KEY_TITLE)"; return; fi
  local pub; pub=$(awk '{print $1" "$2}' "$KEY.pub")
  if jq -e --arg k "$pub" 'any(.[]; (.key|split(" ")[0:2]|join(" "))==$k)' <<<"$FB" >/dev/null; then echo "public key already on $U"; return; fi
  jq -e --arg t "$KEY_TITLE" 'any(.[]; .title==$t)' <<<"$FB" >/dev/null && { fail "a different key titled $KEY_TITLE exists; not replacing"; return; }
  if act; then forge POST "/admin/users/$U/keys" "$(jq -nc --arg t "$KEY_TITLE" --arg k "$pub" '{title:$t, key:$k}')"; echo "add key HTTP $FC"; [ "$FC" = 201 ] || fail "key add"
  else echo "WOULD add public key (title $KEY_TITLE)"; fi
  return 0
}

block() { printf '%s\n' "$MARK_B" "Host $ALIAS" "  HostName $SSH_HOST" "  HostKeyAlias $SSH_HOST" "  User git" "  Port 22" \
  "  IdentityFile ~/.ssh/forge-read_ed25519" "  IdentitiesOnly yes" "  IdentityAgent none" "  StrictHostKeyChecking yes" "$MARK_E"; }
step_sshcfg() {
  echo "## 4 ssh config: separate alias Host $ALIAS (no block for $SSH_HOST itself)"
  echo "remotes of the 7 copies use: $(for r in "${REPOS[@]}"; do git -C "$WIRES/$r" remote -v 2>/dev/null | awk '/[(]fetch[)]$/{print $2}'; done \
    | sed -E 's#^(https?://)([^/@]*@)?([^/:]+).*#\1\3#; s#^([^@/]+)@([^:]+):.*#ssh \1@\2 (scp form, port 22)#' | sort | uniq -c | tr '\n' ';')"
  ssh-keygen -F "$SSH_HOST" -f "$HOME/.ssh/known_hosts" >/dev/null || fail "$SSH_HOST not in known_hosts (StrictHostKeyChecking yes would block)"
  if grep -qF "$MARK_B" "$SSHCFG"; then
    if [ "$(awk -v b="$MARK_B" -v e="$MARK_E" '$0==b{f=1} f{print} $0==e{f=0}' "$SSHCFG")" = "$(block)" ]; then
      echo "block present and matches"; else fail "marked block present but differs; not editing"; fi
    return
  fi
  if grep -Eiq "^[[:space:]]*(Host|Match)[[:space:]].*($ALIAS|\*)" "$SSHCFG"; then fail "another Host/Match line could cover $ALIAS; not editing"; return; fi
  if act; then
    cp -n "$SSHCFG" "$SSHCFG.pre-$CHG"; { printf '\n'; block; } >> "$SSHCFG"; chmod 600 "$SSHCFG"
    echo "appended block (backup $SSHCFG.pre-$CHG); other Host blocks untouched"
  else echo "WOULD append (other Host blocks untouched, backup ~/.ssh/config.pre-$CHG):"; block | sed 's/^/    /'; fi
  return 0
}

step_remotes() {
  echo "## 5 per-repo remotes (no global insteadOf)"
  local r n url pu new
  for r in "${REPOS[@]}"; do
    [ -d "$WIRES/$r/.git" ] || { fail "$r: no git working copy at ~/Code/pka-wires/$r"; continue; }
    for n in $(git -C "$WIRES/$r" remote); do
      url=$(git -C "$WIRES/$r" config --get "remote.$n.url"); pu=$(git -C "$WIRES/$r" config --get "remote.$n.pushurl" || true)
      new="git@$ALIAS:$ORG/$r.git"
      if [ "$url" = "$new" ]; then echo "$r/$n: already $ALIAS, pushurl ${pu:+set}${pu:-none}"
      elif [[ "$url" =~ ^(https://forge\.bluejungle\.net/|git@forge-ssh\.bluejungle\.net:)$ORG/$r(\.git)?/?$ ]]; then
        if act; then
          [ -n "$pu" ] || git -C "$WIRES/$r" config "remote.$n.pushurl" "$url"
          git -C "$WIRES/$r" config "remote.$n.url" "$new"
          echo "$r/$n: fetch -> $ALIAS, push kept on old url (rollback: git -C ~/Code/pka-wires/$r config remote.$n.url $url; git -C ~/Code/pka-wires/$r config --unset remote.$n.pushurl)"
        else echo "$r/$n: WOULD set fetch url -> git@$ALIAS:$ORG/$r.git (from $(sed -E 's#^(https?://[^/]+).*#\1#; s#^([^@/]+@[^:]+):.*#ssh \1#' <<<"$url")), pushurl ${pu:+stays as is}${pu:-= old url (push unchanged)}"; fi
      elif [[ "$url" == https://*@* ]]; then echo "$r/$n: https url with embedded credential, not touched (not printed)"
      else echo "$r/$n: $(sed -E 's#^(https?://)([^/]+).*#\1\2#; s#^([^@/]+@[^:]+):.*#ssh \1#' <<<"$url") unchanged"; fi
    done
  done
  return 0
}

step_readback() {
  echo "## 6 readback"
  forge GET "/users/$U"
  if [ "$FC" != 200 ]; then echo "user $U: HTTP $FC (absent)"; act && fail "user absent after --yes"
  else
    local f; f=$(psql_ro "$FLAGS_SQL" | head -1)
    echo "flags is_admin,restricted,prohibit_login,max_repo_creation,create_org,git_hook,import_local,visibility,active,must_change_password = $f (want $WANT_FLAGS)"
    [ "$f" = "$WANT_FLAGS" ] || fail "flags"
    local r ok=0
    for r in "${REPOS[@]}"; do
      forge GET "/repos/$ORG/$r/collaborators?limit=50"
      local cl; cl=$(jq -r '[.[].login]|join(",")' <<<"$FB" 2>/dev/null || echo "?")
      forge GET "/repos/$ORG/$r/collaborators/$U/permission"; local perm; perm=$(jq -r '.permission // "none"' <<<"$FB" 2>/dev/null || echo "?")
      echo "$r: collaborators [$cl]; $U permission $perm"
      [ "$perm" = read ] && ok=$((ok+1))
    done
    forge GET "/user/repos?limit=50" "" "$U"; local vis; vis=$(jq -r '[.[].full_name]|sort|join(",")' <<<"$FB" 2>/dev/null || echo "?")
    echo "repos visible to $U (sudo /user/repos, HTTP $FC): $(jq length <<<"$FB" 2>/dev/null || echo ?) [$vis]"
    local want; want=$(printf "$ORG/%s\n" "${REPOS[@]}" | sort | paste -sd, -)
    forge GET "/users/$U/repos?limit=50"; local own; own=$(jq '[.[]|select(.owner.login=="'"$U"'")]|length' <<<"$FB" 2>/dev/null || echo "?")
    forge GET "/users/$U/orgs?limit=50"; local orgs; orgs=$(jq length <<<"$FB" 2>/dev/null || echo "?")
    echo "read on $ok/7; own repos $own; orgs $orgs"
    if act; then [ "$ok" = 7 ] && [ "$vis" = "$want" ] && [ "$own" = 0 ] && [ "$orgs" = 0 ] || fail "access scope is not exactly the 7 repos read-only"; fi
  fi
  echo "fetch --dry-run per forge remote (exit codes only; BatchMode, no prompt):"
  local n url rc
  for r in "${REPOS[@]}"; do
    for n in $(git -C "$WIRES/$r" remote 2>/dev/null); do
      url=$(git -C "$WIRES/$r" config --get "remote.$n.url")
      [[ "$url" == git@$ALIAS:* || "$url" == git@$SSH_HOST:* || "$url" == https://forge.bluejungle.net/* ]] || continue
      rc=0; GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15' \
        git -C "$WIRES/$r" fetch --dry-run -q "$n" >/dev/null 2>&1 || rc=$?
      echo "$r/$n: exit $rc"; act && [ "$rc" != 0 ] && fail "$r/$n fetch"
    done
  done
  return 0
}

main() {
  echo "$CHG forge-mini-read mode=$MODE start=$TS host=$(hostname -s)"
  echo "scope: ${REPOS[*]} (Argus go_scope; hold_scope untouched)"
  echo "registered: the private key is readable by all uid-501 processes on the Mini, so it is shared with myPKA"
  load_admin
  step_user; step_collab; step_key; step_sshcfg; step_remotes; step_readback
  fat_cleanup
  echo "## 7 summary: mode=$MODE failures=$FAILS end=$(date -u +%Y%m%dT%H%M%SZ)"
  [ "$FAILS" = 0 ]
}

mkdir -p "$EDIR"
[ -e "$EF" ] && { echo "evidence $EF exists (write-once)"; exit 4; }
set -o noclobber
rc=0; main 2>&1 | tee "$EF" || rc=$?
set +o noclobber
if gitleaks dir --no-banner --redact "$EF" >/dev/null 2>&1; then echo "gitleaks: clean ($(basename "$EF"))"
else echo "gitleaks: FINDING in $EF, do not commit it"; rc=5; fi
exit "$rc"
