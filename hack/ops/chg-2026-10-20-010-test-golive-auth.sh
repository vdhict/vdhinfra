#!/usr/bin/env bash
# chg-2026-10-20-010 offline test (Argus G-b): golive.sh mints a FRESH App token right before the deploy push and
# again inside rollback(), passes it via env only, and revokes it after each push.
#
#   bash hack/ops/chg-2026-10-20-010-test-golive-auth.sh [<scratch-dir>]
#
# Sources the marked `# >>> c010-auth` block of the real golive.sh unchanged. Stubs: minter (a new fake token per
# call), revoker, a git wrapper that records which token each push carried, and rollback.sh. Scratch bare origin,
# no network, no real token. Deletes nothing (AGR-121). Exit 0 iff all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; GOLIVE="$HERE/chg-2026-10-20-010-golive.sh"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-golive-auth-XXXXXX")}"; mkdir -p "$B/bin" "$B/hack/ops" "$B/cache"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
CHG=chg-2026-10-20-010
# token of a push = base64-decoded GIT_CONFIG_VALUE_0 (what git would send)
cat > "$B/bin/tokof" <<'EOF'
#!/bin/bash
v="${GIT_CONFIG_VALUE_0:-}"; [ -n "$v" ] || { echo none; exit 0; }; printf '%s' "${v#Authorization: Basic }" | base64 -d | cut -d: -f2
EOF
cat > "$B/bin/mint" <<EOF
#!/bin/bash
[ -e "$B/mint-fail" ] && exit 1
n=\$(( \$(cat "$B/mint-count" 2>/dev/null || echo 0) + 1 )); echo \$n > "$B/mint-count"; printf 'fake-test-token-%02d-not-a-secret-xyz' \$n
EOF
cat > "$B/bin/revoke" <<EOF
#!/bin/bash
echo "revoked \$(cat)" >> "$B/revoked.log"
EOF
cat > "$B/bin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) echo "push \$("$B/bin/tokof")" >> "$B/push.log";; esac
exec /usr/bin/git "\$@"
EOF
cat > "$B/hack/ops/$CHG-rollback.sh" <<EOF
#!/bin/bash
echo "rollback \$1 \$2 token=\$("$B/bin/tokof")" >> "$B/push.log"
EOF
chmod +x "$B/bin/"* "$B/hack/ops/$CHG-rollback.sh"
/usr/bin/git init -q --bare "$B/origin.git"; /usr/bin/git clone -q "$B/origin.git" "$B/src" 2>/dev/null
/usr/bin/git -C "$B/src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
/usr/bin/git -C "$B/src" push -q origin HEAD:refs/heads/main   # origin main exists, as on GitHub
/usr/bin/git -C "$B/src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m deploy
SHAX=$(/usr/bin/git -C "$B/src" rev-parse HEAD)
BLOCK="$B/c010-auth.sh"; sed -n '/^# >>> c010-auth/,/^# <<< c010-auth/p' "$GOLIVE" > "$BLOCK"
t "the marked auth block exists in golive.sh and defines fresh_token, revoke_token, deploy_push, rollback" \
  bash -c "grep -q '^fresh_token()' '$BLOCK' && grep -q '^revoke_token()' '$BLOCK' && grep -q '^deploy_push()' '$BLOCK' && grep -q '^rollback()' '$BLOCK'"
t "golive.sh pushes only through deploy_push (no other 'push origin' to main)" \
  bash -c "[ \$(grep -c 'push -q origin \"\$SHA:main\"' '$GOLIVE') = 1 ] && grep -q '^deploy_push ||' '$GOLIVE'"

run() { # $1 = shell snippet run with the block sourced; prints nothing of the tokens
  PATH="$B/bin:/usr/bin:/bin" C010_MINT_CMD="$B/bin/mint" C010_REVOKE_CMD="$B/bin/revoke" \
    SRC="$B/src" SHA="$SHAX" HACK="$B/hack" CHG=$CHG CACHE="$B/cache" EV="$B/ev.txt" C4STATE="" \
    bash -c "log() { echo \"\$*\" >> '$B/ev.txt'; }; . '$BLOCK'; $1"
}
# a token already in the caller's env must never be what the push uses
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:stale-caller-token-not-a-secret-000' | base64)"
run 'deploy_push; echo "rc=$? after=${GIT_CONFIG_VALUE_0:-unset}" > "'"$B"'/after-push"'
t "G1 deploy push carried a freshly minted token (#01), not the caller's stale one" bash -c "grep -qx 'push fake-test-token-01-not-a-secret-xyz' '$B/push.log'"
t "G1 push succeeded and the token was revoked after it; env cleared" bash -c "grep -q '^rc=0 after=unset' '$B/after-push' && grep -qx 'revoked fake-test-token-01-not-a-secret-xyz' '$B/revoked.log'"
t "G1 origin main = the deploy sha" bash -c "[ \"\$(/usr/bin/git -C '$B/origin.git' rev-parse main)\" = '$SHAX' ]"
( run 'rollback "test red"' ) >/dev/null 2>&1; rrc=$?
t "G2 rollback() minted ANOTHER fresh token (#02) and rollback.sh ran with it" bash -c "grep -qx 'rollback --execute $SHAX token=fake-test-token-02-not-a-secret-xyz' '$B/push.log'"
t "G2 rollback() revoked token #02 afterwards and exits 1 (RED)" bash -c "[ $rrc = 1 ] && grep -qx 'revoked fake-test-token-02-not-a-secret-xyz' '$B/revoked.log'"
t "G2 two mints in total, one per push" bash -c "[ \"\$(cat '$B/mint-count')\" = 2 ]"
: > "$B/mint-fail"; /usr/bin/git -C "$B/src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m deploy2
SHA2=$(/usr/bin/git -C "$B/src" rev-parse HEAD); np=$(grep -c '^push ' "$B/push.log")
PATH="$B/bin:/usr/bin:/bin" C010_MINT_CMD="$B/bin/mint" C010_REVOKE_CMD="$B/bin/revoke" SRC="$B/src" SHA="$SHA2" HACK="$B/hack" \
  CHG=$CHG CACHE="$B/cache" EV="$B/ev.txt" bash -c "log() { echo \"\$*\" >> '$B/ev.txt'; }; . '$BLOCK'; deploy_push"; frc=$?
t "G3 mint fails -> deploy_push returns non-zero and NO push is attempted" bash -c "[ $frc != 0 ] && [ \$(grep -c '^push ' '$B/push.log') = $np ] && [ \"\$(/usr/bin/git -C '$B/origin.git' rev-parse main)\" = '$SHAX' ]"
( run 'rollback "test red, mint down"' ) >/dev/null 2>&1
t "G4 mint fails in rollback() -> rollback.sh still runs (fail towards cloud off), RED line logged" bash -c "[ \$(grep -c '^rollback --execute' '$B/push.log') = 2 ] && grep -q 'rollback continues with the caller' '$B/ev.txt'"
t "G5 no token value in the go-live log" bash -c "! grep -q 'fake-test-token\|stale-caller' '$B/ev.txt'"
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
