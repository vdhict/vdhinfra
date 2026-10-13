#!/usr/bin/env bash
# Argus C7: arm the vdhwslin01 waker by pinning the box's PUBLIC host keys
# through Git + Flux only (never a hand edit in the cluster).
#
#   pin-known-hosts.sh <file-with-lines> [--push]
#
# <file> holds the "controller known_hosts lines" from provision.sh's
# SEND THIS BACK block (dropbear on 2222) and, optionally, sshd lines on 22
# (e.g. from `ssh-keyscan -p 22 172.16.3.205`). Only lines of the form
#   [172.16.3.205]:2222|22 <ssh-ed25519|ecdsa-sha2-nistp*|ssh-rsa> <base64>
# are accepted; anything else aborts. Without --push it only shows the diff.
set -euo pipefail
src="${1:?file with known_hosts lines}"; push="${2:-}"
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
KH=kubernetes/main/apps/devtools/vdhwslin01-waker/app/known_hosts
re='^\[172\.16\.3\.205\]:(2222|22) (ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,2}$'
lines="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$src" | grep -v '^$' | sort -u)"
[[ -n "$lines" ]] || { echo "no lines"; exit 1; }
while IFS= read -r l; do [[ "$l" =~ $re ]] || { echo "REJECTED line: $l"; exit 1; }; done <<<"$lines"
grep -q '^\[172\.16\.3\.205\]:2222 ' <<<"$lines" || { echo "no dropbear (2222) line: the waker would stay fail-closed"; exit 1; }
for l in $(awk '{print $1"|"$2}' <<<"$lines" | sort | uniq -d); do echo "duplicate key type for $l"; exit 1; done

wt="${HOME}/.cache/chg-2026-10-05-031-pin-$(date -u +%Y%m%dT%H%M%SZ)"
git -C "$REPO" fetch -q origin main
git -C "$REPO" worktree add -q --detach "$wt" origin/main
{ echo "# vdhwslin01 PUBLIC host keys (chg-2026-10-05-031, Argus C7), pinned $(date -u +%FT%TZ)"
  echo "# from provision.sh SEND THIS BACK (2222) and ssh-keyscan (22)"
  echo "$lines"; } >"$wt/$KH"
git -C "$wt" --no-pager diff -- "$KH"
for l in $(awk '{print $3}' <<<"$lines"); do echo "$l" | base64 -d >/dev/null 2>&1 || { echo "bad base64"; exit 1; }; done
while IFS= read -r l; do printf '%s\n' "${l#* }" | ssh-keygen -lf - 2>/dev/null | sed "s/^/fingerprint ${l%% *}: /"; done <<<"$lines"
[[ "$push" == --push ]] || { echo "(not pushed; re-run with --push)"; exit 0; }
git -C "$wt" add "$KH"
git -C "$wt" commit -q -m "feat(vdhwslin01-waker): pin vdhwslin01 host keys, arms the waker (chg-2026-10-05-031, Argus C7)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" \
  -m "Claude-Session: https://claude.ai/code/session_01Qp4a2txbDr22wt8Dn4D9NM"
git -C "$wt" push -q origin HEAD:main
echo "pushed $(git -C "$wt" rev-parse --short HEAD)"
eval "$(mise env -s bash -C "$REPO" 2>/dev/null)"
flux reconcile source git flux-system -n flux-system >/dev/null
flux reconcile ks vdhwslin01-waker -n flux-system
cm="$(kubectl -n devtools get cronjob vdhwslin01-waker -o jsonpath='{.spec.jobTemplate.spec.template.spec.volumes[?(@.name=="known-hosts")].configMap.name}')"
echo "live ConfigMap ${cm}:"; kubectl -n devtools get cm "$cm" -o jsonpath='{.data.known_hosts}' | grep -v '^#'
