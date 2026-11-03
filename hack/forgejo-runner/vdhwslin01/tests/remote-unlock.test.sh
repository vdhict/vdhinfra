#!/usr/bin/env bash
# Fixture tests for the `remote-unlock` initramfs ssh hook support in provision.sh
# (detect_initramfs + step_initramfs). Runs on macOS or Linux, no root, no box:
# it sources provision.sh (which does not run main when sourced) and stubs
# effective_hooks, dropbearkey, stat -c and install -o/-g.
# Usage: tests/remote-unlock.test.sh [path-to-provision.sh]   (exit 0 = all pass)
# SC2034/SC2317/SC2329: globals read by the sourced script, stubs called indirectly.
# shellcheck disable=SC2034,SC2317,SC2329,SC1090,SC1091,SC2012
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-${here}/../provision.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/ru-test.XXXXXX")"
trap '[[ -n "${KEEP_T:-}" ]] || find "${T:?}" -delete' EXIT
pass=0; fail=0
# the sourced copy only differs by the root check (uninstall) so the test can run unprivileged
sed 's/(( EUID == 0 ))/true/' "$SUT" > "$T/sut.sh"
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# The unit under test runs in a subshell per case: ( case_body ) with fresh state.
# shellcheck source=/dev/null
run_case() { # run_case <name> <hooks> <with_hostkey 0|1> <keyfile-content|NONE> [mode]
  local name="$1" hooks="$2" hk="$3" content="$4" mode="${5:-600}"
  local d="$T/$name"; mkdir -p "$d/ru" "$d/bak"
  [[ "$content" != NONE ]] && { printf '%b' "$content" > "$d/ru/authorized_keys"; chmod "$mode" "$d/ru/authorized_keys"; }
  (( hk )) && echo hostkey-material > "$d/ru/dropbear_ed25519_host_key"
  echo 00:11:22 > "$d/ru/mac"
  printf '%s' "$hooks" > "$d/hooks"
  echo "$d"
}
exec_case() { # exec_case <dir> <cmd...>   -> runs in subshell, output to <dir>/out, rc to <dir>/rc
  local d="$1"; shift
  (
    export REMOTE_UNLOCK_DIR="$d/ru" REMOTE_UNLOCK_BACKUP_DIR="$d/bak"
    # shellcheck disable=SC1090
    . "$T/sut.sh"
    effective_hooks() { cat "$d/hooks"; }
    mkinitcpio() { :; }
    dropbearkey() { echo "Public key portion is:"; echo "ssh-ed25519 AAAAFAKEHOSTKEYBLOB root@box"; echo "Fingerprint: x"; }
    stat() { # GNU-style -c on any platform
      if [[ "$1" == -c ]]; then
        if stat_gnu=$(command stat -c "$2" "$3" 2>/dev/null); then echo "$stat_gnu"; return; fi
        case "$2" in '%a') command stat -f '%Lp' "$3" ;; '%U:%G') command stat -f '%Su:%Sg' "$3" ;; esac
      else command stat "$@"; fi
    }
    install() { local a=() skip=0 x; for x in "$@"; do if (( skip )); then skip=0; continue; fi
      case "$x" in -o|-g) skip=1 ;; *) a+=("$x") ;; esac; done; command install "${a[@]}"; }
    chown() { :; }
    # anything outside the fixture dirs (initcpio/mkinitcpio config) is swallowed, never written
    write_file_real="$(declare -f write_file)"; eval "${write_file_real/write_file/write_file_real}"
    write_file() { case "$1" in "$d"/*) write_file_real "$@" ;; *) cat >/dev/null; echo "    (stub: not writing $1)" ;; esac; }
    initramfs_rebuild() { echo REBUILD-CALLED; }
    payload_initcpio_install_vdh_teamboot() { echo "# stub"; }
    write_file_orig="$(declare -f write_file)"
    DRY=0; CTRL_PUBKEY="ssh-ed25519 AAAACTRLBLOB test-controller"
    "$@"
  ) > "$d/out" 2>&1 && echo 0 > "$d/rc" || echo $? > "$d/rc"
}
rc()  { cat "$1/rc"; }
out() { cat "$1/out"; }

HOOKS_RU=' base udev block remote-unlock encryptssh filesystems vdh-teamboot '
SANDER='ssh-ed25519 AAAASANDERKEY sander-unlock\n'
SANDER2='command="/bin/x" ssh-ed25519 AAAASECONDKEY second-key\n'

echo "== 1 remote-unlock accepted"
d="$(run_case t1 "$HOOKS_RU" 1 "$SANDER")"; exec_case "$d" detect_initramfs
check "1 exit 0" test "$(rc "$d")" = 0
check "1 detects remote-unlock + key path" grep -q "initramfs ssh: remote-unlock, authorized keys: $d/ru/authorized_keys" "$d/out"

echo "== 2 neither hook -> refuse (encryptssh only)"
d="$(run_case t2 ' base udev block encryptssh filesystems ' 1 "$SANDER")"; exec_case "$d" detect_initramfs
check "2 refuses" test "$(rc "$d")" != 0
check "2 says no dropbear/tinyssh/remote-unlock hook" grep -q 'no dropbear/tinyssh/remote-unlock hook' "$d/out"

echo "== 3 refusals around remote-unlock"
d="$(run_case t3a "$HOOKS_RU" 0 "$SANDER")"; exec_case "$d" detect_initramfs
check "3a host key missing -> refuse" test "$(rc "$d")" != 0
d="$(run_case t3b "$HOOKS_RU" 1 NONE)"; exec_case "$d" detect_initramfs
check "3b authorized_keys missing -> refuse" test "$(rc "$d")" != 0
d="$(run_case t3c "$HOOKS_RU" 1 '')"; exec_case "$d" detect_initramfs
check "3c authorized_keys empty -> refuse" test "$(rc "$d")" != 0
d="$(run_case t3d ' base remote-unlock dropbear encryptssh ' 1 "$SANDER")"; exec_case "$d" detect_initramfs
check "3d two ssh hooks (ambiguous) -> refuse" test "$(rc "$d")" != 0

echo "== 4 key appended, idempotent, existing keys preserved, mode kept"
d="$(run_case t4 "$HOOKS_RU" 1 "${SANDER}${SANDER2}" 640)"
before="$(cat "$d/ru/authorized_keys")"
exec_case "$d" bash -c ':' >/dev/null  # warm-up no-op
run_both() { detect_initramfs; step_initramfs; step_initramfs; }
exec_case "$d" run_both
f="$d/ru/authorized_keys"
check "4 exit 0" test "$(rc "$d")" = 0
check "4 controller key present exactly once" test "$(grep -c vdhwslin01-waker "$f")" = 1
check "4 restricted options on controller line" grep -q '^no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAACTRLBLOB vdhwslin01-waker$' "$f"
check "4 existing keys preserved byte-identical (first 2 lines)" test "$(head -n2 "$f")" = "$before"
check "4 file mode preserved 640" test "$(command stat -f '%Lp' "$f" 2>/dev/null || command stat -c '%a' "$f")" = 640
check "4 backup of the original taken, equals original" test "$(cat "$d/bak/remote-unlock-authorized_keys.vdh-orig")" = "$before"
check "4 no extra file in the hook input dir" test "$(ls "$d/ru" | tr '\n' ' ')" = "authorized_keys dropbear_ed25519_host_key mac "
check "4 initramfs rebuilt via the script's own function" grep -q REBUILD-CALLED "$d/out"
check "4 host key line derived (known_hosts format)" grep -q '\[172.16.3.205\]:2222 ssh-ed25519 AAAAFAKEHOSTKEYBLOB' "$d/out"
check "4 hook input files untouched" test "$(cat "$d/ru/dropbear_ed25519_host_key")" = hostkey-material

echo "== 5 no trailing newline in existing file: keys not glued together"
d="$(run_case t5 "$HOOKS_RU" 1 'ssh-ed25519 AAAASANDERKEY sander-unlock')"
exec_case "$d" run_both
check "5 exit 0" test "$(rc "$d")" = 0
check "5 sander line intact on its own line" grep -qx 'ssh-ed25519 AAAASANDERKEY sander-unlock' "$d/ru/authorized_keys"
check "5 two lines" test "$(wc -l < "$d/ru/authorized_keys" | tr -d ' ')" = 2

echo "== 6 post-check restores on key loss"
d="$(run_case t6 "$HOOKS_RU" 1 "$SANDER")"
lossy() { detect_initramfs; write_file() { : > "$1"; }; step_initramfs; }
exec_case "$d" lossy
check "6 refuses" test "$(rc "$d")" != 0
check "6 original key restored" grep -qx 'ssh-ed25519 AAAASANDERKEY sander-unlock' "$d/ru/authorized_keys"

echo "== 7 uninstall removes only our line"
d="$(run_case t7 "$HOOKS_RU" 1 "${SANDER}${SANDER2}" 600)"; exec_case "$d" run_both
un() { run() { echo "(run) $*"; }; uninstall; }
exec_case "$d" un
check "7 controller line gone" test "$(grep -c vdhwslin01-waker "$d/ru/authorized_keys")" = 0
check "7 both original keys remain" test "$(grep -c 'AAAASANDERKEY\|AAAASECONDKEY' "$d/ru/authorized_keys")" = 2

echo "== 8 the box as measured 2026-11-03 + the Mini unlock key already present (owner, 27-10)"
# Effective HOOKS read on vdhwslin01 as agent (Omarchy 4.5.0rc2, conf.d incl. zz-remote-unlock.conf).
HOOKS_BOX=' base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block remote-unlock encryptssh filesystems fsck btrfs-overlayfs resume '
MINI='ssh-ed25519 AAAACTRLBLOB vdhwslin01_unlock_mini@vdhmini01-20261027\n'
d="$(run_case t8 "$HOOKS_BOX" 1 "${SANDER}${MINI}" 600)"
before="$(cat "$d/ru/authorized_keys")"
# detect on the real line; then the effective line as mkinitcpio sees it after our zz-vdh-teamboot.conf
run_both8() { detect_initramfs; printf '%s' "${HOOKS_BOX}vdh-teamboot " > "$d/hooks"; step_initramfs; step_initramfs; }
exec_case "$d" run_both8
check "8 exit 0" test "$(rc "$d")" = 0
# shellcheck disable=SC2016  # $1 expands in the child bash
check "8 order check passes on the real line + appended vdh-teamboot (after encryptssh, after resume)" \
  bash -c '! grep -q "vdh-teamboot is not after encryptssh" "$1" && grep -q REBUILD-CALLED "$1"' _ "$d/out"
check "8 detects remote-unlock on the real HOOKS line" grep -q "initramfs ssh: remote-unlock" "$d/out"
check "8 key already present -> said so" grep -q "controller key already in" "$d/out"
check "8 authorized_keys byte-identical (nothing appended)" test "$(cat "$d/ru/authorized_keys")" = "$before"
check "8 no backup needed, none taken" test ! -e "$d/bak/remote-unlock-authorized_keys.vdh-orig"
un8() { run() { echo "(run) $*"; }; uninstall; }
exec_case "$d" un8
check "8 uninstall leaves the owner-added Mini key alone" test "$(cat "$d/ru/authorized_keys")" = "$before"

echo "RESULT: pass=$pass fail=$fail"
[[ "$fail" == 0 ]]
