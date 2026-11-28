#!/usr/bin/env bash
# shellcheck disable=SC2016  # file-wide: the sed programs match literal $vars in the script
# Mutation check for src/idle-poweroff.sh (wq-157): the unit suite must FAIL when
# the script's own block-inhibitor check is removed or weakened, or when the
# poweroff call goes back to --check-inhibitors=yes. chg-2026-11-28-101: also when
# the guard stops honouring the provisioning lock or loses its stale bound
# (idle-poweroff.test.sh), or provision.sh stops taking/releasing the lock
# (provision-lock.test.sh). Exit 0 = every mutant killed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SRC="${here}/../src/idle-poweroff.sh"
PROV="${here}/../provision.sh"
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
mutant no-prov-lock-section '/^# 2b\. provisioning lock/,/^# --- 3\. runner idle/{/^# --- 3\./!d;}'
mutant prov-lock-keep-disabled 's/|| keep "provisioning in progress/|| true "provisioning in progress/'
mutant prov-lock-no-stale-bound 's/^PROV_LOCK_MAX_S=7200$/PROV_LOCK_MAX_S=999999999/'
mutant prov-lock-owner-ignored 's/|| keep "provisioning lock not owned by root"/|| true/'
mutant prov-lock-dir-symlink-followed 's/\[\[ -d "\$prov_dir" \&\& ! -L "\$prov_dir" \]\] || keep/[[ -d "$prov_dir" ]] || keep/'
mutant prov-lock-no-boot-id-ignored 's/\[\[ -n "\$lock_boot" \]\] || keep/true || keep/'
mutant prov-lock-other-boot-honoured 's/if \[\[ "\$lock_boot" != "\$boot_id" \]\]; then/if false; then/'

# pmutant <name> <sed program>: mutate provision.sh; provision-lock.test.sh must fail.
pmutant() {
  local name="$1" prog="$2" m="$T/$1.provision.sh"
  sed -e "$prog" "$PROV" > "$m"
  if cmp -s "$PROV" "$m"; then echo "FAIL mutant $name did not change provision.sh"; survived=$((survived+1)); return; fi
  if PROV_SUT="$m" bash "${here}/provision-lock.test.sh" > "$T/$name.out" 2>&1; then
    survived=$((survived+1)); echo "FAIL mutant survived: $name"
  else
    killed=$((killed+1)); echo "ok   mutant killed: $name ($(tail -n1 "$T/$name.out"))"
  fi
}
pmutant prov-no-lock-take 's/\[\[ "\$s" == preflight \]\] || prov_lock_take/true/'
pmutant prov-lock-after-step 's/^    "step_\${s}"$/    "step_${s}"; [[ "$s" == preflight ]] || prov_lock_take/; s/^    \[\[ "\$s" == preflight \]\] || prov_lock_take$/    :/'
pmutant prov-dir-symlink-followed 's/\[\[ ! -L "\$dir" \]\] || die/true || die/'
pmutant prov-no-release '/^run_steps() {/,/^}/s/^  prov_lock_release$/  :/'
pmutant prov-release-on-failure 's/^run_steps() {$/run_steps() { trap prov_lock_release EXIT/'

echo "idle-poweroff mutation: ${killed} killed, ${survived} survived"
(( survived == 0 ))
