#!/usr/bin/env bash
# Stage the runner bundle on vdhwslin01 through agent's standing sudo (chg-2026-10-05-031, after
# Sander's owner-session.sh). Replaces the 3 h sudo window (install-window.sh + 90-agent-provision),
# which is no longer needed: agent has standing, logged sudo (owner decision 2026-11-03).
#
#   team-stage.sh <commit on origin/main> [--dry-run]
#
# - takes provision.sh + vdh-provision-tonight EXACTLY as stored at <commit> (git show; never the
#   working tree), refuses unless <commit> is on origin/main;
# - copies them to ~agent/vdh-stage on the box, then `sudo install -o root -g root -m 0755` to
#   /usr/local/sbin/vdh-provision.sh and /usr/local/sbin/vdh-provision-tonight;
# - reads back both sha256 values on the box against the commit's, and that the wrapper pins the same
#   provision.sh. The wrapper's fixed arguments are unchanged; run it afterwards with
#   sudo-window/larry/provision-expect.exp dry|real|c4 (it calls `sudo -n /usr/local/sbin/vdh-provision-tonight <mode>`).
# - the stage copies in ~agent/vdh-stage are moved to ~agent/.trash-vdh-stage-<ts> (no deletion).
set -euo pipefail
commit="${1:?commit on origin/main}"; dry=0; [[ "${2:-}" == --dry-run ]] && dry=1
REPO="${REPO:-/Users/sheijden/Code/homelab-migration/vdhinfra}"
SSH="${SSH:-/usr/bin/ssh}"; HOST=vdhwslin01
P=hack/forgejo-runner/vdhwslin01
die() { echo "team-stage: $*" >&2; exit 2; }
sshb() { "$SSH" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

git -C "$REPO" fetch -q origin main
full="$(git -C "$REPO" rev-parse --verify "${commit}^{commit}")" || die "unknown commit"
git -C "$REPO" merge-base --is-ancestor "$full" origin/main || die "$full is not on origin/main; refusing"
ps="$(git -C "$REPO" show "$full:$P/provision.sh" | shasum -a 256 | cut -d' ' -f1)"
ws="$(git -C "$REPO" show "$full:$P/sudo-window/vdh-provision-tonight" | shasum -a 256 | cut -d' ' -f1)"
git -C "$REPO" show "$full:$P/sudo-window/vdh-provision-tonight" | grep -qx "PROV_SHA256=$ps" \
  || die "the wrapper at $full does not pin the provision.sh at $full"
echo "commit $full: provision.sh $ps, wrapper $ws"
sshb 'sudo -n true' || die "agent has no working sudo on the box (owner-session.sh not run?)"
if (( dry )); then echo "dry: would stage both files and sudo install them to /usr/local/sbin"; exit 0; fi

ts="$(date -u +%Y%m%dT%H%M%SZ)"
sshb "umask 022; mkdir -p ~/vdh-stage && test ! -L ~/vdh-stage"
git -C "$REPO" show "$full:$P/provision.sh" | sshb "cat > ~/vdh-stage/provision.sh"
git -C "$REPO" show "$full:$P/sudo-window/vdh-provision-tonight" | sshb "cat > ~/vdh-stage/vdh-provision-tonight"
[[ "$(sshb 'sha256sum ~/vdh-stage/provision.sh' | cut -d' ' -f1)" == "$ps" ]] || die "staged provision.sh differs"
[[ "$(sshb 'sha256sum ~/vdh-stage/vdh-provision-tonight' | cut -d' ' -f1)" == "$ws" ]] || die "staged wrapper differs"
sshb "sudo -n install -o root -g root -m 0755 ~/vdh-stage/provision.sh /usr/local/sbin/vdh-provision.sh \
   && sudo -n install -o root -g root -m 0755 ~/vdh-stage/vdh-provision-tonight /usr/local/sbin/vdh-provision-tonight"
[[ "$(sshb 'sha256sum /usr/local/sbin/vdh-provision.sh' | cut -d' ' -f1)" == "$ps" ]] || die "installed provision.sh differs"
[[ "$(sshb 'sha256sum /usr/local/sbin/vdh-provision-tonight' | cut -d' ' -f1)" == "$ws" ]] || die "installed wrapper differs"
sshb "stat -c '%U:%G %a %n' /usr/local/sbin/vdh-provision.sh /usr/local/sbin/vdh-provision-tonight"
sshb "mv ~/vdh-stage ~/.trash-vdh-stage-$ts"
echo "staged and installed from $full; next: expect sudo-window/larry/provision-expect.exp dry"
