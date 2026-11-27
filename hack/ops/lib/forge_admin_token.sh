# shellcheck shell=bash
# Short-lived Forgejo CLI token for ops shell scripts (chg-2026-11-20-001, tsk-2026-11-20-114).
# Bash twin of forge_admin_token.py; see there for the why. Source it, then:
#   fat_mint <purpose> <scopes> [username]   sets FAT_TOKEN (value, never printed) and FAT_NAME; traps EXIT
#   fat_api METHOD PATH [JSON-BODY] [SUDO]   in-pod curl with token auth, config on stdin -> FB (body), FC (code)
#   fat_cleanup                              deletes the token row by SQL on the primary, proves 401; idempotent
# Forgejo answers 401 to the token-delete API with token auth and the CLI has no delete, so the DB row is the route.
# The trap is set in the shell that calls fat_mint (a pipeline member is a subshell: call fat_mint inside it).

FAT_NS=${FAT_NS:-devtools}
FAT_TOKEN=""; FAT_NAME=""; FAT_USER=""
FB=""; FC=""

_fat_cq() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
_fat_sql_lit() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }

fat_pg_pod() {  # fat_pg_pod [primary|replica]; primary = CNPG status.currentPrimary (wq-115), fails closed
  local role=${1:-primary} out cur tgt
  if [ "$role" = primary ]; then
    out=$(kubectl -n "$FAT_NS" get cluster.postgresql.cnpg.io forge-pg \
      -o jsonpath='{.status.currentPrimary}|{.status.targetPrimary}') || return 1
    cur=${out%%|*}; tgt=${out#*|}
    [ -n "$cur" ] || { echo "fat_pg_pod: forge-pg currentPrimary is empty" >&2; return 1; }
    [ -z "$tgt" ] || [ "$tgt" = "$cur" ] || { echo "fat_pg_pod: switchover in flight ($cur -> $tgt)" >&2; return 1; }
    printf %s "$cur"; return 0
  fi
  out=$(kubectl -n "$FAT_NS" get pod -l "cnpg.io/cluster=forge-pg,cnpg.io/instanceRole=$role" \
    -o jsonpath='{.items[0].metadata.name}') || return 1
  [ -n "$out" ] || { echo "fat_pg_pod: no forge-pg $role pod" >&2; return 1; }
  printf %s "$out"
}

fat_sql() {  # fat_sql <statement> [rw] [primary|replica]; rw proves pg_is_in_recovery()=f first
  # Read-only: the SET is its own -c (R1, Argus wq-169); inside the statement's -c string it does not take effect.
  local pod pre=(-c "SET default_transaction_read_only=on")
  [ "${2:-}" = rw ] && pre=()
  pod=$(fat_pg_pod "${3:-primary}") || return 1
  if [ "${2:-}" = rw ]; then
    [ "$(kubectl -n "$FAT_NS" exec "$pod" -c postgres -- psql -U postgres -d forgejo -AtXq -c 'SELECT pg_is_in_recovery()')" = f ] \
      || { echo "fat_sql: refusing write, $pod is in recovery or unreachable" >&2; return 1; }
  fi
  kubectl -n "$FAT_NS" exec "$pod" -c postgres -- \
    psql -U postgres -d forgejo -v ON_ERROR_STOP=1 -AtXq "${pre[@]}" -c "$1"
}

fat_mint() {
  local purpose=$1 scopes=$2 user=${3:-admforgejo}
  [ -n "$scopes" ] && [ "$scopes" != all ] || { echo "fat_mint: ask for explicit minimal scopes" >&2; return 2; }
  [ -z "$FAT_NAME" ] || { echo "fat_mint: a token is already held ($FAT_NAME)" >&2; return 2; }
  FAT_USER=$user
  FAT_NAME="$purpose-tmp-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  trap fat_cleanup EXIT
  FAT_TOKEN=$(kubectl -n "$FAT_NS" exec deploy/forgejo -c forgejo -- forgejo admin user generate-access-token \
    --username "$user" --token-name "$FAT_NAME" --scopes "$scopes" --raw | tr -d '[:space:]') || FAT_TOKEN=""
  if [ "${#FAT_TOKEN}" -lt 20 ]; then echo "fat_mint: no usable token for $FAT_NAME (value not shown)" >&2; fat_cleanup; return 3; fi
  echo "minted $user token $FAT_NAME ($scopes), value not shown"
}

fat_api() {
  local m=$1 p=$2 body=${3:-} sudo=${4:-} cfg out
  [ -n "$FAT_TOKEN" ] || { FC=000; FB=""; echo "fat_api: no token held" >&2; return 0; }
  cfg="request = $(_fat_cq "$m")"$'\n'"url = $(_fat_cq "http://127.0.0.1:3000/api/v1$p")"$'\n'
  cfg+="header = $(_fat_cq "Authorization: token $FAT_TOKEN")"$'\n'
  cfg+='header = "Content-Type: application/json"'$'\n''header = "Accept: application/json"'$'\n'
  [ -n "$sudo" ] && cfg+="header = $(_fat_cq "Sudo: $sudo")"$'\n'
  [ -n "$body" ] && cfg+="data = $(_fat_cq "$body")"$'\n'
  out=$(printf '%s' "$cfg" | kubectl -n "$FAT_NS" exec -i deploy/forgejo -c forgejo -- curl -sS -w '\n%{http_code}' -K -) || out=$'\n000'
  cfg=""
  FC=${out##*$'\n'}; FB=${out%$'\n'*}
}

fat_cleanup() {
  [ -n "$FAT_NAME" ] || return 0
  local where left code
  where="name=$(_fat_sql_lit "$FAT_NAME") AND uid=(SELECT id FROM \"user\" WHERE lower_name=$(_fat_sql_lit "$(printf %s "$FAT_USER" | tr "[:upper:]" "[:lower:]")"))"
  fat_sql "DELETE FROM access_token_resource_repo WHERE token_id IN (SELECT id FROM access_token WHERE $where)" rw >/dev/null || true
  fat_sql "DELETE FROM access_token WHERE $where" rw >/dev/null || true
  left=$(fat_sql "SELECT count(*) FROM access_token WHERE $where" || echo "?")
  code=000
  if [ -n "$FAT_TOKEN" ]; then fat_api GET /user; code=$FC; fi
  FAT_TOKEN=""; FB=""
  echo "deleted tmp token $FAT_NAME by SQL: rows left $left; GET /user with it -> HTTP $code"
  [ "$left" = 0 ] || echo "FAIL: tmp token $FAT_NAME NOT gone, delete it by hand" >&2
  FAT_NAME=""
  trap - EXIT
}
