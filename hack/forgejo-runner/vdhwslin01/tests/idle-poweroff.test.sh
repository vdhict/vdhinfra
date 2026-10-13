#!/usr/bin/env bash
# Unit tests for src/idle-poweroff.sh: fixture root + stub loginctl/systemctl.
# Usage: tests/idle-poweroff.test.sh   (exit 0 = all pass)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SUT="${here}/../src/idle-poweroff.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/idle-test.XXXXXX")"
trap 'find "${T:?}" -delete' EXIT

NOW=2000000000
BOOT=0b5e1d2c-1111-2222-3333-444455556666
pass=0; fail=0

# Stub loginctl: answers from $T/<case>/logind/{seat0,sessions,session-<id>}.
make_stubs() {
  local d="$1"
  mkdir -p "$d/bin" "$d/logind"
  cat > "$d/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/../logind"
[[ -f "$dir/fail" ]] && exit 1
case "$1" in
  show-seat)     cat "$dir/seat0" ;;
  list-sessions) cat "$dir/sessions" ;;
  show-session)  cat "$dir/session-$2" ;;
esac
STUB
  cat > "$d/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../systemctl.calls"
STUB
  chmod +x "$d/bin/loginctl" "$d/bin/systemctl"
}

# new_case <name>: a fully idle team boot that SHOULD power off; tests break one thing.
new_case() {
  local d="$T/$1"
  mkdir -p "$d/run/forgejo-runner" "$d/proc/sys/kernel/random"
  make_stubs "$d"
  echo "$BOOT" > "$d/proc/sys/kernel/random/boot_id"
  printf 'started_by=team\nboot_id=%s\nvia=initramfs-ssh-unlock\n' "$BOOT" > "$d/run/team-boot"
  echo "9000.12 1234.00" > "$d/proc/uptime"
  echo $(( NOW - 4000 )) > "$d/run/forgejo-runner/last-job-end"
  printf 'IdleHint=yes\nIdleSinceHint=%s\n' "$(( (NOW - 4000) * 1000000 ))" > "$d/logind/seat0"
  printf '2 1000 sheijden seat0 tty1\n7 1001 agent - -\n' > "$d/logind/sessions"
  printf 'Name=sheijden\nClass=user\nIdleHint=yes\nIdleSinceHint=%s\n' "$(( (NOW - 4000) * 1000000 ))" > "$d/logind/session-2"
  printf 'Name=agent\nClass=user\nIdleHint=no\nIdleSinceHint=0\n' > "$d/logind/session-7"
  echo "$d"
}

run_case() { # run_case <dir> -> stdout of SUT
  local d="$1"
  VDH_IDLE_TEST=1 VDH_IDLE_ROOT="$d" VDH_IDLE_LOGINCTL="$d/bin/loginctl" \
    VDH_IDLE_SYSTEMCTL="$d/bin/systemctl" VDH_IDLE_NOW="$NOW" bash "$SUT"
}

expect() { # expect <name> <dir> <KEEP|POWEROFF> <substring>
  local name="$1" d="$2" want="$3" sub="$4" out
  out="$(run_case "$d" 2>&1)" || true
  local called=no; [[ -s "$d/systemctl.calls" ]] && called=yes
  if [[ "$out" == *"$want"* && "$out" == *"$sub"* ]] \
     && { [[ "$want" == POWEROFF && "$called" == yes ]] || [[ "$want" == KEEP && "$called" == no ]]; }; then
    pass=$((pass+1)); echo "ok   $name"
  else
    fail=$((fail+1)); echo "FAIL $name: got [$out] systemctl_called=$called"
  fi
}

d="$(new_case all-idle)"
expect "all conditions hold -> poweroff" "$d" POWEROFF "boot_id=$BOOT"
if grep -qx 'poweroff --check-inhibitors=yes' "$d/systemctl.calls"; then
  pass=$((pass+1)); echo "ok   poweroff respects inhibitors"
else fail=$((fail+1)); echo "FAIL poweroff call: $(cat "$d/systemctl.calls")"; fi

d="$(new_case no-marker)"; find "$d/run/team-boot" -delete
expect "Sander boot (no marker) -> keep" "$d" KEEP "no /run/team-boot"

d="$(new_case stale-marker)"; printf 'started_by=team\nboot_id=deadbeef\n' > "$d/run/team-boot"
expect "marker from another boot -> keep" "$d" KEEP "boot_id does not match"

d="$(new_case sander-marker)"; printf 'started_by=sander\nboot_id=%s\n' "$BOOT" > "$d/run/team-boot"
expect "marker not team -> keep" "$d" KEEP "started_by=team"

d="$(new_case young)"; echo "7199.99 1.00" > "$d/proc/uptime"
expect "uptime < 2h -> keep" "$d" KEEP "uptime 7199s"

d="$(new_case job)"; date +%s > "$d/run/forgejo-runner/job-active"
expect "job running -> keep" "$d" KEEP "runner has a job"

d="$(new_case recent-job)"; echo $(( NOW - 1800 )) > "$d/run/forgejo-runner/last-job-end"
expect "last job 30 min ago -> keep" "$d" KEEP "last job ended 1800s"

d="$(new_case no-job-this-boot)"; find "$d/run/forgejo-runner/last-job-end" -delete
expect "no job this boot, all idle -> poweroff" "$d" POWEROFF "runner_idle=none-this-boot"

d="$(new_case seat-busy)"; printf 'IdleHint=no\nIdleSinceHint=0\n' > "$d/logind/seat0"
expect "seat0 IdleHint=no -> keep" "$d" KEEP "seat0 IdleHint=no"

d="$(new_case seat-recent)"; printf 'IdleHint=yes\nIdleSinceHint=%s\n' "$(( (NOW - 1800) * 1000000 ))" > "$d/logind/seat0"
expect "seat0 idle 30 min -> keep" "$d" KEEP "seat0 idle 1800s"

d="$(new_case remote-sander)"
printf '2 1000 sheijden seat0 tty1\n9 1000 sheijden - pts/0\n' > "$d/logind/sessions"
printf 'Name=sheijden\nClass=user\nIdleHint=no\nIdleSinceHint=0\n' > "$d/logind/session-9"
expect "Sander ssh session active -> keep" "$d" KEEP "session 9 (sheijden) is active"

d="$(new_case greeter)"
printf '2 1000 sheijden seat0 tty1\n3 975 gdm seat0 tty7\n' > "$d/logind/sessions"
printf 'Name=gdm\nClass=greeter\nIdleHint=no\nIdleSinceHint=0\n' > "$d/logind/session-3"
expect "greeter session ignored -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case logind-down)"; touch "$d/logind/fail"
expect "logind unreadable -> keep" "$d" KEEP "cannot read seat0"

d="$(new_case garbage-uptime)"; echo "x" > "$d/proc/uptime"
expect "unreadable uptime -> keep" "$d" KEEP "cannot read uptime"

d="$(new_case bad-last-end)"; echo "soon" > "$d/run/forgejo-runner/last-job-end"
expect "unreadable last-job-end -> keep" "$d" KEEP "unreadable last-job-end"

# The test seam must be inert unless VDH_IDLE_TEST=1: with the variables set but the
# switch off, the script must read the real (absent on macOS) /run/team-boot -> KEEP.
d="$(new_case seam-off)"
out="$(VDH_IDLE_ROOT="$d" VDH_IDLE_LOGINCTL="$d/bin/loginctl" VDH_IDLE_SYSTEMCTL="$d/bin/systemctl" \
  VDH_IDLE_NOW="$NOW" bash "$SUT" 2>&1 || true)"
if [[ "$out" == *"KEEP"* && ! -s "$d/systemctl.calls" ]]; then pass=$((pass+1)); echo "ok   test seam inert without VDH_IDLE_TEST=1"
else fail=$((fail+1)); echo "FAIL seam: $out"; fi

echo "idle-poweroff tests: ${pass} passed, ${fail} failed"
(( fail == 0 ))
