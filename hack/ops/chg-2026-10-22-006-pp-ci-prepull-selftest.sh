#!/usr/bin/env bash
# chg-2026-10-22-006: self-test of the runner's pre-pull block (Mack 25-10). Offline: no cluster, no registry.
# Sources the block between "# >>> prepull" and "# <<< prepull" from chg-2026-10-22-006-pp-ci-runner.sh with a fake
# podman + timeout on PATH and sleep stubbed, then checks: retry/backoff, 3x fail, digest mismatch, unpinned ref,
# and that the runner calls the pre-pull (failing the gate) before the first ci/run.sh.
#   chg-2026-10-22-006-pp-ci-prepull-selftest.sh <scratch-dir>     (scratch dir must not exist yet; write-once)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); RS="$HERE/chg-2026-10-22-006-pp-ci-runner.sh"
T=${1:?scratch dir}; [ ! -e "$T" ] || { echo "$T exists; write-once, refusing" >&2; exit 64; }
mkdir -p "$T/bin"
cat > "$T/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
# FAKE_FAILS = pull failures before the first success; FAKE_DIGEST = what inspect reports.
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
c=$(cat "$FAKE_STATE/count" 2>/dev/null || echo 0)
case "$1 $2" in
  "pull -q")
    c=$((c + 1)); echo "$c" > "$FAKE_STATE/count"
    if [ "$c" -le "$FAKE_FAILS" ]; then
      echo "Trying to pull $3..." >&2
      echo "Error: copying system image from manifest list: reading blob sha256:b5546b43: fetching blob: received unexpected HTTP status: 503 Service Unavailable" >&2
      exit 125
    fi
    echo 0123456789ab; exit 0 ;;
  "image inspect")
    case "$4" in
      *Digest\}\}) echo "$FAKE_DIGEST" ;;
      *) echo "${5%%@*}@$FAKE_DIGEST " ;;
    esac ;;
  *) echo "fake podman: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod 0755 "$T/bin/timeout" "$T/bin/podman"
BLOCK="$T/prepull-block.sh"
sed -n '/^# >>> prepull/,/^# <<< prepull/p' "$RS" > "$BLOCK"
[ -s "$BLOCK" ] || { echo "FAIL: no prepull block in $RS"; exit 1; }

PASS=0; FAIL=0
ok() { echo "PASS $*"; PASS=$((PASS + 1)); }
no() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }

# run_case <name> <fails> <inspect digest> <ref|-> <want rc> <want tries> <want waits>
run_case() {
  local name=$1 fails=$2 dig=$3 ref=$4 wrc=$5 wtries=$6 wwaits=$7 d="$T/$1" rc tries waits
  mkdir -p "$d"
  rc=$(
    export PATH="$T/bin:$PATH" FAKE_STATE="$d" FAKE_FAILS="$fails" FAKE_DIGEST="$dig"
    sleep() { echo "$1" >> "$FAKE_STATE/waits"; }
    . "$BLOCK"
    PREPULL_LOG="$d/prepull.txt"
    [ "$ref" = - ] && ref=$PREPULL_REF
    prepull "$ref"; echo $?
  )
  tries=$(cat "$d/count" 2>/dev/null || echo 0)
  waits=$(paste -sd, - 2>/dev/null < "$d/waits"); waits=${waits:-none}
  [ "$rc" = "$wrc" ] && [ "$tries" = "$wtries" ] && [ "$waits" = "$wwaits" ] \
    && ok "$name: rc=$rc tries=$tries waits=$waits" \
    || no "$name: rc=$rc (want $wrc) tries=$tries (want $wtries) waits=$waits (want $wwaits)"
  sed 's/^/    /' "$d/prepull.txt"
}
PIN=sha256:0465844ba1d9f5689ac64626537e275f59b65569703e90edc46b33f93f872d8b
OTHER=sha256:1111111111111111111111111111111111111111111111111111111111111111
run_case ok-first-try        0 "$PIN"   - 0 1 none
run_case fail-2x-then-ok     2 "$PIN"   - 0 3 10,30
run_case fail-3x-gate-fails  3 "$PIN"   - 1 3 10,30
run_case fail-5x-stops-at-3  5 "$PIN"   - 1 3 10,30
run_case digest-mismatch     0 "$OTHER" - 2 1 none
run_case unpinned-tag-refused 0 "$PIN" registry.access.redhat.com/hi/dotnet-sdk:10.0 3 0 none

# Static checks on the runner itself.
grep -qx 'PREPULL_REF=registry.access.redhat.com/hi/dotnet-sdk@sha256:0465844ba1d9f5689ac64626537e275f59b65569703e90edc46b33f93f872d8b' "$RS" \
  && ok "pinned ref is the step 9 digest" || no "pinned ref"
call=$(grep -n '^prepull "\$PREPULL_REF"' "$RS" | head -1 | cut -d: -f1)
first_ci=$(grep -n 'bash ci/run.sh' "$RS" | head -1 | cut -d: -f1)
[ -n "$call" ] && [ -n "$first_ci" ] && [ "$call" -lt "$first_ci" ] \
  && ok "runner calls prepull (line $call) before the first ci/run.sh (line $first_ci)" || no "prepull call order"
grep -A4 '^prepull "\$PREPULL_REF"' "$RS" | grep -q '\*) .*die "pre-pull failed' \
  && grep -A4 '^prepull "\$PREPULL_REF"' "$RS" | grep -q '2) .*die "pre-pull failed' \
  && ok "non-zero prepull -> die (exit 1, 'pre-pull failed' line)" || no "prepull failure path"
bash -n "$RS" && ok "runner parses (bash -n)" || no "runner syntax"
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
