#!/usr/bin/env bash
# Unit tests for src/idle-poweroff.sh: fixture root + stub loginctl/systemctl.
# Usage: tests/idle-poweroff.test.sh   (exit 0 = all pass)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# IDLE_SUT lets tests/idle-poweroff.mutation.sh run this suite against a mutated copy.
SUT="${IDLE_SUT:-${here}/../src/idle-poweroff.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/idle-test.XXXXXX")"
trap 'find "${T:?}" -delete' EXIT

NOW=2000000000
BOOT=0b5e1d2c-1111-2222-3333-444455556666
pass=0; fail=0

# Stub loginctl: answers from $T/<case>/logind/{sessions,session-<id>}.
make_stubs() {
  local d="$1"
  mkdir -p "$d/bin" "$d/logind"
  cat > "$d/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/../logind"
[[ -f "$dir/fail" ]] && exit 1
case "$1" in
  list-sessions) cat "$dir/sessions" ;;
  show-session)
    [[ " $* " == *" -p Seat "* ]] || exit 1
    cat "$dir/session-$2"
    ;;
esac
STUB
  # systemctl: records the call; exits with ../systemctl.rc if present (logind refusing).
  cat > "$d/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/.."
echo "$*" >> "$dir/systemctl.calls"
echo "systemctl $*" >> "$dir/order"
[[ -f "$dir/systemctl.rc" ]] && exit "$(cat "$dir/systemctl.rc")"
exit 0
STUB
  # systemd-inhibit: answers --list from ../inhibit/out; ../inhibit/fail makes it fail.
  cat > "$d/bin/systemd-inhibit" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/.."
echo "systemd-inhibit $*" >> "$dir/order"
[[ -f "$dir/inhibit/fail" ]] && exit 1
[[ " $* " == *" --list "* ]] || exit 2
cat "$dir/inhibit/out"
STUB
  chmod +x "$d/bin/loginctl" "$d/bin/systemctl" "$d/bin/systemd-inhibit"
}

# inhibit_table <dir> <row>...: systemd-inhibit --list output with header and footer.
inhibit_table() {
  local d="$1"; shift
  {
    echo 'WHO            UID  USER     PID  COMM            WHAT  WHY                                       MODE'
    printf '%s\n' "$@"
    echo
    echo "$# inhibitors listed."
  } > "$d/inhibit/out"
}

# new_case <name>: a fully idle team boot that SHOULD power off; tests break one thing.
new_case() {
  local d="$T/$1"
  mkdir -p "$d/run/forgejo-runner" "$d/run/vdh-input" "$d/proc/sys/kernel/random" "$d/inhibit"
  make_stubs "$d"
  echo "$BOOT" > "$d/proc/sys/kernel/random/boot_id"
  printf 'started_by=team\nboot_id=%s\nvia=initramfs-ssh-unlock\n' "$BOOT" > "$d/run/team-boot"
  echo "9000.12 1234.00" > "$d/proc/uptime"
  echo $(( NOW - 4000 )) > "$d/run/forgejo-runner/last-job-end"
  # Sander's account autologged in 35 s after boot and reports no idle hint: the real box.
  printf '2 1000 sheijden seat0 tty1\n7 1001 agent - -\n' > "$d/logind/sessions"
  printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\nTimestampMonotonic=35000000\n' > "$d/logind/session-2"
  printf 'Name=agent\nClass=user\nSeat=\nRemote=yes\nTimestampMonotonic=5000000000\n' > "$d/logind/session-7"
  # sampler state: running since uptime 60, last input at 5000, heartbeat fresh (uptime is 9000)
  printf 'boot_id=%s\nheartbeat=9000\nsince=60\nlast_input=5000\n' "$BOOT" > "$d/run/vdh-input/state"
  # logind inhibitors as listed on the box at 2026-11-27T01:12Z (evidence 101): delay locks only.
  inhibit_table "$d" \
    'NetworkManager 0    root     1493 NetworkManager  sleep NetworkManager needs to turn off networks delay' \
    'UPower         0    root     1791 upowerd         sleep Pause device polling                      delay' \
    'Omarchy        1000 sheijden 1916 systemd-inhibit sleep Lock screen before suspend                delay'
  echo "$d"
}

run_case() { # run_case <dir> -> stdout of SUT
  local d="$1"
  VDH_IDLE_TEST=1 VDH_IDLE_ROOT="$d" VDH_IDLE_LOGINCTL="$d/bin/loginctl" \
    VDH_IDLE_SYSTEMCTL="$d/bin/systemctl" VDH_IDLE_INHIBIT="$d/bin/systemd-inhibit" \
    VDH_IDLE_NOW="$NOW" bash "$SUT"
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
# wq-157: systemctl's own check (=yes) refuses on any logged-in user, so the script checks
# block inhibitors itself, FIRST, and then calls poweroff with --check-inhibitors=no, once.
if [[ "$(cat "$d/order")" == "systemd-inhibit --list --mode=block --no-pager"$'\n'"systemctl poweroff --check-inhibitors=no" ]]; then
  pass=$((pass+1)); echo "ok   inhibitors listed first, then poweroff --check-inhibitors=no (once)"
else fail=$((fail+1)); echo "FAIL call order/flags: $(cat "$d/order")"; fi

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

d="$(new_case autologin-only)"
expect "only the autologin (35 s after boot, never idle) -> poweroff" "$d" POWEROFF "input_quiet=4000s"

d="$(new_case autologin-edge)"
printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\nTimestampMonotonic=180000000\n' > "$d/logind/session-2"
expect "session at exactly 180 s is still the autologin -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case later-login)"
printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\nTimestampMonotonic=180000001\n' > "$d/logind/session-2"
expect "session 180.000001 s after boot is a login -> keep" "$d" KEEP "a login, not the autologin"

d="$(new_case later-login-second)"
printf '2 1000 sheijden seat0 tty1\n9 1000 sheijden seat0 tty2\n' > "$d/logind/sessions"
printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\nTimestampMonotonic=3000000000\n' > "$d/logind/session-9"
expect "autologin plus a later local login -> keep" "$d" KEEP "session 9 (sheijden) began 3000 s after boot"

for class in user-incomplete user-light; do
  d="$(new_case "$class")"
  printf 'Name=sheijden\nClass=%s\nSeat=seat0\nRemote=no\nTimestampMonotonic=3000000000\n' "$class" > "$d/logind/session-2"
  expect "$class session counts -> keep" "$d" KEEP "began 3000 s after boot"
done

d="$(new_case two-early)"
printf '9 1000 sheijden seat0 tty2\n' >> "$d/logind/sessions"
printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\nTimestampMonotonic=40000000\n' > "$d/logind/session-9"
expect "two early seat0 sessions -> keep" "$d" KEEP "additional early seat0 session 9"

for seat in '' seat1; do
  d="$(new_case "early-seat-${seat:-empty}")"
  printf 'Name=sheijden\nClass=user\nSeat=%s\nRemote=no\nTimestampMonotonic=35000000\n' "$seat" > "$d/logind/session-2"
  expect "early session with seat ${seat:-empty} -> keep" "$d" KEEP "is not on seat0"
done

d="$(new_case remote-sander)"
printf '2 1000 sheijden seat0 tty1\n9 1000 sheijden - pts/0\n' > "$d/logind/sessions"
printf 'Name=sheijden\nClass=user\nSeat=\nRemote=yes\nTimestampMonotonic=20000000\n' > "$d/logind/session-9"
expect "remote session (even early) -> keep" "$d" KEEP "remote session 9 (sheijden)"

d="$(new_case no-start-time)"; printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\n' > "$d/logind/session-2"
expect "session without start time -> keep" "$d" KEEP "no readable start time"

d="$(new_case no-remote-prop)"; printf 'Name=sheijden\nClass=user\nSeat=seat0\nTimestampMonotonic=35000000\n' > "$d/logind/session-2"
expect "session without Remote property -> keep" "$d" KEEP "Remote unreadable"

for running in 'state: RUNNING' RUNNING; do
  d="$(new_case "audio-${running%%:*}")"
  mkdir -p "$d/proc/asound/card0/pcm0p/sub0" "$d/proc/asound/card1/pcm0p/sub1"
  printf 'closed\n' > "$d/proc/asound/card0/pcm0p/sub0/status"
  printf '%s\nowner_pid: 123\n' "$running" > "$d/proc/asound/card1/pcm0p/sub1/status"
  expect "audio status '$running' -> keep" "$d" KEEP "audio is playing"
done

d="$(new_case audio-idle)"
mkdir -p "$d/proc/asound/card0/pcm0p/sub0"
printf 'state: PREPARED\n' > "$d/proc/asound/card0/pcm0p/sub0/status"
expect "PCM stream prepared -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case audio-unreadable)"
mkdir -p "$d/proc/asound/card0/pcm0p/sub0"
ln -s missing "$d/proc/asound/card0/pcm0p/sub0/status"
expect "unreadable PCM status -> keep" "$d" KEEP "cannot read audio status"

d="$(new_case state-missing-key)"; printf 'boot_id=%s\nheartbeat=9000\nsince=60\n' "$BOOT" > "$d/run/vdh-input/state"
expect "state without last_input key -> keep" "$d" KEEP "state lacks last_input"

d="$(new_case input-recent)"; printf 'boot_id=%s\nheartbeat=9000\nsince=60\nlast_input=8400\n' "$BOOT" > "$d/run/vdh-input/state"
expect "input 10 min ago -> keep" "$d" KEEP "local input 600s ago"

d="$(new_case input-below-edge)"; printf 'boot_id=%s\nheartbeat=9000\nsince=60\nlast_input=5401\n' "$BOOT" > "$d/run/vdh-input/state"
expect "input 3599 s ago -> keep" "$d" KEEP "local input 3599s ago < 3600s"

d="$(new_case input-edge)"; printf 'boot_id=%s\nheartbeat=9000\nsince=60\nlast_input=5400\n' "$BOOT" > "$d/run/vdh-input/state"
expect "input exactly 60 min ago -> poweroff" "$d" POWEROFF "input_quiet=3600s"

d="$(new_case input-never)"; printf 'boot_id=%s\nheartbeat=9000\nsince=60\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
expect "no input ever seen, sampler up since boot -> poweroff" "$d" POWEROFF "input_quiet=8940s"

d="$(new_case sampler-young)"; printf 'boot_id=%s\nheartbeat=9000\nsince=8500\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
expect "sampler only watched 8 min -> keep" "$d" KEEP "local input 500s ago"

d="$(new_case no-sampler-state)"; find "$d/run/vdh-input/state" -delete
expect "no sampler state -> keep" "$d" KEEP "input activity unknown (no /run/vdh-input/state)"

d="$(new_case stale-heartbeat)"; printf 'boot_id=%s\nheartbeat=8900\nsince=60\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
expect "sampler heartbeat 100 s old -> keep" "$d" KEEP "heartbeat 100s old"

d="$(new_case foreign-state)"; printf 'boot_id=deadbeef\nheartbeat=9000\nsince=60\nlast_input=\n' > "$d/run/vdh-input/state"
expect "state from another boot -> keep" "$d" KEEP "another boot"

d="$(new_case garbage-state)"; printf 'boot_id=%s\nheartbeat=soon\nsince=60\nlast_input=\n' "$BOOT" > "$d/run/vdh-input/state"
expect "unreadable state -> keep" "$d" KEEP "state unreadable"

d="$(new_case symlink-state)"
mv "$d/run/vdh-input/state" "$d/valid-snapshot"
ln -s "$d/valid-snapshot" "$d/run/vdh-input/state"
expect "state is a symlink -> keep" "$d" KEEP "input activity unknown"

d="$(new_case runner-session)"
printf '2 1000 sheijden seat0 tty1\n8 1002 runner - -\n' > "$d/logind/sessions"
printf 'Name=runner\nClass=user\nSeat=\nRemote=no\nTimestampMonotonic=9000000000\n' > "$d/logind/session-8"
expect "runner user session never blocks -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case greeter)"
printf '2 1000 sheijden seat0 tty1\n3 975 gdm seat0 tty7\n' > "$d/logind/sessions"
printf 'Name=gdm\nClass=greeter\nSeat=seat0\nRemote=no\nTimestampMonotonic=900000000000\n' > "$d/logind/session-3"
expect "greeter session ignored -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case logind-down)"; touch "$d/logind/fail"
expect "logind unreadable -> keep" "$d" KEEP "cannot list logind sessions"

d="$(new_case garbage-uptime)"; echo "x" > "$d/proc/uptime"
expect "unreadable uptime -> keep" "$d" KEEP "cannot read uptime"

d="$(new_case bad-last-end)"; echo "soon" > "$d/run/forgejo-runner/last-job-end"
expect "unreadable last-job-end -> keep" "$d" KEEP "unreadable last-job-end"

d="$(new_case symlink-job)"; ln -s /etc/shadow "$d/run/forgejo-runner/job-active"
expect "symlink in runner-owned /run/forgejo-runner -> keep" "$d" KEEP "symlink in /run/forgejo-runner"

# --- wq-157: logind refusal, inhibitors, agent sessions -----------------------
d="$(new_case logind-refuses)"; echo 1 > "$d/systemctl.rc"
out="$(run_case "$d" 2>&1)" || true
if [[ "$out" == *"POWEROFF: started_by=team"* && "$out" == *"KEEP: systemctl poweroff refused"* ]] \
   && [[ "$(cat "$d/systemctl.calls")" == "poweroff --check-inhibitors=no" ]]; then
  pass=$((pass+1)); echo "ok   logind refuses poweroff -> KEEP line (old behaviour), exit 0"
else fail=$((fail+1)); echo "FAIL logind refusal: [$out]"; fi

d="$(new_case evidence-101-sessions)"
# The sessions logind listed when it refused on 2026-11-27: tty1 autologin, two user managers,
# two agent sshd sessions (one a long-running journal follow, 1 h+ old).
printf ' 1 1000 sheijden seat0 tty1\n17 1001 agent - -\n 2 1000 sheijden - -\n30 1001 agent - -\n39 1001 agent - -\n' > "$d/logind/sessions"
printf 'Name=sheijden\nClass=user\nSeat=seat0\nRemote=no\nTimestampMonotonic=29711462\n' > "$d/logind/session-1"
printf 'Name=agent\nClass=manager\nSeat=\nRemote=no\nTimestampMonotonic=45128900000\n' > "$d/logind/session-17"
printf 'Name=sheijden\nClass=manager\nSeat=\nRemote=no\nTimestampMonotonic=29800000\n' > "$d/logind/session-2"
printf 'Name=agent\nClass=user\nSeat=\nRemote=yes\nTimestampMonotonic=45140000000\n' > "$d/logind/session-30"
printf 'Name=agent\nClass=user\nSeat=\nRemote=yes\nTimestampMonotonic=48900000000\n' > "$d/logind/session-39"
expect "evidence-101 sessions (autologin + agent sshd, 1 h+ old) -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case block-shutdown)"
inhibit_table "$d" 'Unattended Upgrades 0 root 777 python3 shutdown Stop shutdown while upgrading block'
expect "block inhibitor on shutdown -> keep" "$d" KEEP "block inhibitor on shutdown held by Unattended"

d="$(new_case block-multi-what)"
inhibit_table "$d" \
  'NetworkManager 0 root 1493 NetworkManager sleep NetworkManager needs to turn off networks delay' \
  'backup 0 root 4242 kopia shutdown:sleep:idle Backup running, do not stop block'
expect "block inhibitor shutdown:sleep:idle -> keep" "$d" KEEP "block inhibitor on shutdown held by backup"

d="$(new_case block-weak-shutdown)"
inhibit_table "$d" 'gnome 1000 sheijden 999 gsd shutdown Unsaved work block-weak'
expect "block-weak inhibitor on shutdown -> keep" "$d" KEEP "block-weak inhibitor on shutdown"

d="$(new_case block-sleep-only)"
inhibit_table "$d" 'steam 1000 sheijden 999 steam sleep:idle Download in progress block'
expect "block inhibitor on sleep only does not stop poweroff -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case delay-shutdown)"
inhibit_table "$d" 'ModemManager 0 root 1500 ModemManager shutdown:sleep Clean up modems delay'
expect "delay inhibitor on shutdown (logind honours it) -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case unknown-mode)"
inhibit_table "$d" 'odd 0 root 1 odd shutdown Something new strong'
expect "inhibitor with an unknown mode -> keep" "$d" KEEP "unknown mode strong"

d="$(new_case inhibit-fails)"; touch "$d/inhibit/fail"
expect "systemd-inhibit fails -> keep" "$d" KEEP "cannot list logind inhibitors"

d="$(new_case inhibit-no-header)"; printf 'something else entirely\n' > "$d/inhibit/out"
expect "inhibitor list in an unknown layout -> keep" "$d" KEEP "layout unknown"

d="$(new_case inhibit-empty)"; : > "$d/inhibit/out"
expect "empty inhibitor list output -> keep" "$d" KEEP "inhibitor list empty"

d="$(new_case inhibit-none)"; printf 'No inhibitors.\n' > "$d/inhibit/out"
expect "systemd says 'No inhibitors.' -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case inhibit-filtered)"; inhibit_table "$d"
expect "header + '0 inhibitors listed.' -> poweroff" "$d" POWEROFF "POWEROFF"

d="$(new_case inhibit-why-says-shutdown)"
inhibit_table "$d" 'tool 0 root 1 tool sleep Before a shutdown we wait block'
expect "block lock whose WHY says 'shutdown' (fail safe) -> keep" "$d" KEEP "inhibitor on shutdown"

# The test seam must be inert unless VDH_IDLE_TEST=1: with the variables set but the
# switch off, the script must read the real (absent on macOS) /run/team-boot -> KEEP.
d="$(new_case seam-off)"
out="$(VDH_IDLE_ROOT="$d" VDH_IDLE_LOGINCTL="$d/bin/loginctl" VDH_IDLE_SYSTEMCTL="$d/bin/systemctl" \
  VDH_IDLE_INHIBIT="$d/bin/systemd-inhibit" VDH_IDLE_NOW="$NOW" bash "$SUT" 2>&1 || true)"
if [[ "$out" == *"KEEP"* && ! -s "$d/systemctl.calls" ]]; then pass=$((pass+1)); echo "ok   test seam inert without VDH_IDLE_TEST=1"
else fail=$((fail+1)); echo "FAIL seam: $out"; fi

echo "idle-poweroff tests: ${pass} passed, ${fail} failed"
(( fail == 0 ))
