#!/usr/bin/env bash
# shellcheck disable=SC2016  # file-wide: the sed programs match literal $vars in the script
# Mutation check for src/idle-poweroff.sh (wq-157): the unit suite must FAIL when
# the script's own block-inhibitor check is removed or weakened, or when the
# poweroff call goes back to --check-inhibitors=yes. Exit 0 = every mutant killed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SRC="${here}/../src/idle-poweroff.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/idle-mut.XXXXXX")"
trap 'find "${T:?}" -delete' EXIT
killed=0; survived=0

# mutant <name> <sed program>: the mutant must differ from the source and fail the suite.
mutant() {
  local name="$1" prog="$2" m="$T/$1.sh"
  sed -e "$prog" "$SRC" > "$m"
  if cmp -s "$SRC" "$m"; then echo "FAIL mutant $name did not change the script"; survived=$((survived+1)); return; fi
  if IDLE_SUT="$m" bash "${here}/idle-poweroff.test.sh" > "$T/$name.out" 2>&1; then
    survived=$((survived+1)); echo "FAIL mutant survived: $name"
  else
    killed=$((killed+1)); echo "ok   mutant killed: $name ($(tail -n1 "$T/$name.out"))"
  fi
}

mutant no-inhibitor-section '/^# --- 5\. no block inhibitor/,/^# --- 6\. power off/{/^# --- 6\./!d;}'
mutant no-shutdown-keep 's/|| keep "${mode} inhibitor on shutdown held by ${f\[0\]}"/|| true/'
mutant block-weak-ignored 's/block|block-weak) ;;/block) ;; block-weak) continue ;;/'
mutant inhibit-failure-ignored 's/|| keep "cannot list logind inhibitors"/|| true/'
mutant check-inhibitors-yes 's/poweroff --check-inhibitors=no/poweroff --check-inhibitors=yes/'
mutant refusal-not-caught 's/^if ! "\$SYSTEMCTL" poweroff --check-inhibitors=no; then/if "$SYSTEMCTL" poweroff --check-inhibitors=no; then/'

echo "idle-poweroff mutation: ${killed} killed, ${survived} survived"
(( survived == 0 ))
