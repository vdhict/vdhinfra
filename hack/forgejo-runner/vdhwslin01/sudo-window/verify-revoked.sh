#!/usr/bin/env bash
# Argus C4 read-back after `vdh-provision-tonight revoke` (chg-2026-10-05-031).
# Run AS agent on vdhwslin01. Writes a write-once evidence file in the
# current directory and prints PASS/FAIL. (agent cannot list /etc/sudoers.d:
# the root-side proof that the file is gone is the revoke mode's own output.)
set -uo pipefail
out="vdhwslin01-sudo-revoked-$(date -u +%Y%m%dT%H%M%SZ).txt"
[[ ! -e "$out" ]] || { echo "$out exists"; exit 1; }
check() {
  local rc=0 l s g
  echo "# chg-2026-10-05-031 sudo-window revoke read-back, host $(hostname), user $(id -un), $(date -u +%FT%TZ)"
  l="$(sudo -n -l 2>&1)"; s=$?
  echo "sudo -n -l exit=$s"; while IFS= read -r x; do echo "  | $x"; done <<<"$l"
  if [[ $s -ne 0 ]] && ! grep -qi 'may run' <<<"$l"; then echo "ok   sudo -n -l fails, no may-run lines"; else echo "FAIL sudo rights remain"; rc=1; fi
  if sudo -n /usr/local/sbin/vdh-provision-tonight dry </dev/null >/dev/null 2>&1; then echo "FAIL wrapper still runnable via sudo"; rc=1; else echo "ok   wrapper no longer runnable via sudo"; fi
  g=" $(id -nG agent) "
  if [[ "$g" != *" wheel "* && "$g" != *" sudo "* ]]; then echo "ok   agent groups:$g(no wheel/sudo)"; else echo "FAIL agent in wheel/sudo:$g"; rc=1; fi
  if systemctl is-active --quiet vdh-agent-provision-revoke.timer 2>/dev/null; then echo "info backstop timer still pending (harmless: rm -f of an absent file)"; else echo "ok   backstop timer not pending"; fi
  echo "RESULT: $([ $rc = 0 ] && echo PASS || echo FAIL)"
}
check >"$out" 2>&1
chmod 0444 "$out"
cat "$out"
grep -qx 'RESULT: PASS' "$out"
