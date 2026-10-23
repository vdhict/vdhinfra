#!/usr/bin/env bash
# chg-2026-10-23-003 disk guard for vdhmini01 (local) and vdhllmsrv01 (ssh studio-host). Larry tsk-2026-10-23-008.
# Runs from launchd on the Mini (net.vdhict.disk-guard, every 30 min).
#   < 15% free on /System/Volumes/Data: clean the team's OWN temporary data only:
#       brew cleanup, npm cache, uv cache, unused podman images (if podman exists),
#       and Claude session scratchpads under /private/tmp/claude-501 not touched for 7+ days.
#     Never touched: home directories, models (ollama), VMs, repos, backups, anything of Sander's.
#   < 10% free after that: one line to Larry in ~/mypka-handoff/<date>/ (once per host per day; silent, AGR-074).
# Every cleanup writes one change event on chg-2026-10-23-003. Prometheus keeps MacDiskSpaceLow/Critical as the alerts.
#   disk-guard.sh [--dry-run]
set -uo pipefail
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
CLEAN_BELOW=15; TELL_BELOW=10; DRY=${1:-}
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# The cleanup itself; runs on the target host (bash -s over ssh for the Studio). Prints "freed-from:<step>" lines.
CLEAN=$(cat <<'EOS'
export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/share/mise/shims:/usr/bin:/bin:/usr/sbin:/sbin
step() { echo "step:$1"; }
command -v brew >/dev/null && { brew cleanup -s --prune=7 >/dev/null 2>&1; step brew; }
command -v npm >/dev/null && { npm cache clean --force >/dev/null 2>&1; step npm; }
UV=$(command -v uv || ls -d "$HOME"/.local/share/mise/installs/*uv*/latest/*/uv 2>/dev/null | head -1)
[ -n "$UV" ] && { "$UV" cache clean >/dev/null 2>&1; step uv; }
PM=$(command -v podman || ls /opt/podman/bin/podman 2>/dev/null)
[ -n "$PM" ] && "$PM" machine inspect >/dev/null 2>&1 && { "$PM" image prune -af >/dev/null 2>&1; step podman; }
# Claude session scratchpads: /private/tmp/claude-501/<project>/<session>, untouched for 7+ days.
if [ -d /private/tmp/claude-501 ]; then
  n=0
  while IFS= read -r d; do
    [[ "$d" == /private/tmp/claude-501/*/* ]] || continue
    [ -n "$(find "$d" -mtime -7 -print -quit 2>/dev/null)" ] && continue   # anything recent inside: keep
    /bin/rm -rf -- "${d:?}" && n=$((n+1))
  done < <(find /private/tmp/claude-501 -mindepth 2 -maxdepth 2 -type d -mtime +7 2>/dev/null)
  step "scratch:$n"
fi
EOS
)

free_pct() { # <host>
  local line
  if [ "$1" = vdhmini01 ]; then line=$(df -k /System/Volumes/Data | tail -1); else line=$(ssh -o ConnectTimeout=10 -o BatchMode=yes studio-host 'df -k /System/Volumes/Data | tail -1') || return 1; fi
  echo "$line" | awk '{printf "%d", $4*100/($2)}'
}
run_clean() { if [ "$1" = vdhmini01 ]; then bash -s <<<"$CLEAN"; else ssh -o ConnectTimeout=10 -o BatchMode=yes studio-host 'bash -s' <<<"$CLEAN"; fi; }
log_event() { (cd "$REPO" && ./ops/ops change event chg-2026-10-23-003 executed --actor infra-ops --payload "$1" >/dev/null 2>&1) || true; }

for host in vdhmini01 vdhllmsrv01; do
  before=$(free_pct "$host") || { echo "$host: unreachable"; continue; }
  echo "$host: ${before}% free"
  [ "$before" -lt "$CLEAN_BELOW" ] || continue
  if [ "$DRY" = --dry-run ]; then echo "$host: would clean"; continue; fi
  steps=$(run_clean "$host" | sed -n 's/^step://p' | paste -sd, -)
  after=$(free_pct "$host" || echo "?")
  log_event "{\"step\":\"disk-guard $host\",\"summary\":\"free ${before}% < ${CLEAN_BELOW}%: cleaned own temp data (${steps}); now ${after}% free\"}"
  echo "$host: cleaned ($steps), now ${after}% free"
  if [ "$after" != "?" ] && [ "$after" -lt "$TELL_BELOW" ]; then
    d=$(date +%F); f="$HOME/mypka-handoff/$d/$d-atlas-to-larry-disk-$host.md"
    [ -e "$f" ] || { mkdir -p "$(dirname "$f")"; printf '# Atlas -> Larry: %s disk\n\n%s still has only %s%% free after cleaning own temp data (%s), %s. Rest needs a person: large non-team data. (chg-2026-10-23-003)\n— Atlas\n' "$host" "$host" "$after" "$steps" "$(date +%H:%M)" > "$f"; }
  fi
done
