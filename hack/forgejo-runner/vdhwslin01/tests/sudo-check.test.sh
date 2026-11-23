#!/usr/bin/env bash
# 2026-11-23: step_user's runner sudo check (runner_no_sudo). A deny-only rule
# ('ALL ALL=(ALL) !/usr/bin/asdcontrol', Omarchy's asdcontrol package) is no sudo right;
# any positive command, a positive probe, or unparsable output refuses (fail closed).
# Offline: sources provision.sh with a stubbed sudo, no root.
# shellcheck disable=SC1090,SC2317,SC2329,SC2034
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-${here}/../provision.sh}"
pass=0; fail=0
HDR='Matching Defaults entries for runner on vdhwslin01:
    secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/bin, passwd_tries=10

Runas and Command-specific defaults for runner:
    Defaults!/usr/bin/visudo env_keep+="SUDO_EDITOR EDITOR VISUAL"

User runner may run the following commands on vdhwslin01:'
case_body() { # <listing> <probe rc>: source the SUT, stub sudo, call runner_no_sudo
  LISTING="$1"; PROBE="$2"
  . "$SUT"
  sudo() {
    case "$*" in
      ("-l -U runner") printf '%s\n' "$LISTING"; return 0 ;;
      ("-n -l -U runner /usr/bin/true") return "$PROBE" ;;
      (*) echo "unexpected sudo $*" >&2; return 99 ;;
    esac
  }
  runner_no_sudo
}
try() { # try <name> <listing> <probe rc> <expect: pass|refuse>
  local rc
  set +e; (case_body "$2" "$3") >/dev/null 2>&1; rc=$?; set -e
  if { [[ "$4" == pass ]] && (( rc == 0 )); } || { [[ "$4" == refuse ]] && (( rc != 0 )); }; then
    pass=$((pass+1)); echo "ok   $1 -> $4"
  else fail=$((fail+1)); echo "FAIL $1: rc=$rc, want $4"; fi
}
try "deny-only rule (asdcontrol, measured 2026-11-23)" "$HDR
    (ALL) !/usr/bin/asdcontrol" 1 pass
try "deny-only, two negated commands" "$HDR
    (ALL) !/usr/bin/asdcontrol, !/usr/bin/su" 1 pass
try "not allowed to run sudo" "User runner is not allowed to run sudo on vdhwslin01." 1 pass
try "real ALL rule" "$HDR
    (ALL : ALL) ALL" 1 refuse
try "NOPASSWD positive rule" "$HDR
    (root) NOPASSWD: /usr/bin/systemctl" 1 refuse
try "NOPASSWD: ALL" "$HDR
    (ALL) NOPASSWD: ALL" 1 refuse
try "mixed rule (deny + allow, one line)" "$HDR
    (ALL) !/usr/bin/asdcontrol, /usr/bin/true" 1 refuse
try "mixed rules (deny line + allow line)" "$HDR
    (ALL) !/usr/bin/asdcontrol
    (root) /usr/bin/true" 1 refuse
try "deny-only listing but positive probe" "$HDR
    (ALL) !/usr/bin/asdcontrol" 0 refuse
try "unparsable: empty output" "" 1 refuse
try "unparsable: error text" "sudo: unknown user runner" 1 refuse
try "unparsable: may-run header, no entries" "$HDR" 1 refuse
try "unparsable: entry without runas" "$HDR
    /usr/bin/true" 1 refuse
try "unparsable: unindented line after block" "$HDR
    (ALL) !/usr/bin/asdcontrol
something else" 1 refuse
echo "RESULT: pass=$pass fail=$fail"
[[ "$fail" == 0 ]]
