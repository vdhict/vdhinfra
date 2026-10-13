#!/usr/bin/env bash
# chg-2026-10-05-031: revert the partial Studio runner build of 2026-10-13 (stopped after Argus qa_failed 08:33Z, B1-B3).
# Run ON the Mac Studio (vdhllmsrv01) as the login user, e.g. `ssh studio-host 'bash -s' < this-file`.
# Removes only what k8s-engineer added 10:31-10:35 local: brew formulas tart + softnet, the cirruslabs/cli tap and its
# softnet trust entry, and the tart image cache ~/.tart (one pulled OCI image). No VM was created; no network change.
# Leaves untouched: node_exporter, ghostty, household-ai, everything else.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1

TART_HOME="${HOME:?}/.tart"

if pgrep -x tart >/dev/null || pgrep -x softnet >/dev/null; then
  echo "ABORT: tart/softnet process running" >&2; exit 1
fi

if command -v tart >/dev/null; then
  tart list --quiet 2>/dev/null | while read -r vm; do
    # a tag and its digest alias are one image; deleting the first removes the second
    [ -n "$vm" ] && { tart delete "$vm" 2>/dev/null || true; }
  done
fi

brew list --formula tart >/dev/null 2>&1 && brew uninstall --formula tart
brew list --formula softnet >/dev/null 2>&1 && brew uninstall --formula softnet
brew untrust --formula cirruslabs/cli/softnet 2>/dev/null || true
brew tap | grep -qx cirruslabs/cli && brew untap cirruslabs/cli

if [ -d "$TART_HOME" ]; then
  find "$TART_HOME" -mindepth 1 -delete
  rmdir "$TART_HOME"
fi

# brew download cache of the two formulas (only the tart/softnet tarballs; other cache untouched)
DL="${HOME:?}/Library/Caches/Homebrew/downloads"
[ -d "$DL" ] && find "$DL" -maxdepth 1 -type f \( -name '*--tart.tar.gz' -o -name '*--softnet.tar.gz' \) -delete

echo "--- readback"
ls "$DL" 2>/dev/null | grep -E -- '--(tart|softnet)\.tar\.gz$' || echo "brew cache tart/softnet: absent"
brew list --formula --versions
brew tap
command -v tart || echo "tart: absent"
[ -e "$TART_HOME" ] && echo "~/.tart: PRESENT" || echo "~/.tart: absent"
