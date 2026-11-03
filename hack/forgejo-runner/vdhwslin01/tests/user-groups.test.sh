#!/usr/bin/env bash
# D6 (2026-11-03): step_user refuses any runner group set other than exactly
# "runner kvm" (docker = root on the host since Sander's dockerd runs; libvirt,
# wheel, sudo likewise). Offline: sources provision.sh with stubs, no root.
# shellcheck disable=SC1090,SC2317,SC2329,SC2034
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-${here}/../provision.sh}"
pass=0; fail=0
case_body() { # runs in a subshell: source the SUT, stub, call step_user
  G="$1"
  . "$SUT"
  id() { case "$*" in (runner) return 0 ;; ("-nG runner") echo "$G" ;; (*) command id "$@" ;; esac; }
  run() { :; }; sudo() { return 1; }; runner_dir() { :; }
  stat() { echo runner; }
  DRY=0
  step_user 2>&1
}
try() { # try <name> <groups> <expect: refuse|accept>
  local out rc
  set +e
  out="$(case_body "$2")"; rc=$?
  set -e
  if [[ "$3" == refuse ]]; then
    if (( rc != 0 )) && grep -q 'refusing' <<<"$out"; then pass=$((pass+1)); echo "ok   $1 refused"; else fail=$((fail+1)); echo "FAIL $1 not refused: $out"; fi
  else
    if grep -q 'exactly runner+kvm' <<<"$out"; then pass=$((pass+1)); echo "ok   $1 accepted"; else fail=$((fail+1)); echo "FAIL $1 not accepted: $out"; fi
  fi
}
try "runner kvm"            "runner kvm"        accept
try "kvm runner (order)"    "kvm runner"        accept
try "docker"                "runner kvm docker" refuse
try "libvirt"               "runner kvm libvirt" refuse
try "wheel"                 "runner kvm wheel"  refuse
try "extra group (video)"   "runner kvm video"  refuse
try "missing kvm"           "runner"            refuse
echo "RESULT: pass=$pass fail=$fail"
[[ "$fail" == 0 ]]
