#!/bin/sh
# vdhwslin01 runner egress guard (chg-2026-10-05-031, Argus F3/C4).
# Installed as /usr/local/libexec/vdh-runner/nft-guard, runs as root.
#   nft-guard check   exit 0 only if table inet vdh_runner is loaded AND
#                     complete (ExecStartPre=+ of forgejo-runner-vm.service)
#   nft-guard guard   every minute (vdh-runner-nft-guard.timer): if the
#                     table is missing/incomplete, STOP forgejo-runner-vm
#                     (KillMode=control-group also kills the job VM).
set -eu
if [ "${VDH_GUARD_TEST:-0}" = 1 ]; then
  NFT="${VDH_GUARD_NFT:?}"; SYSTEMCTL="${VDH_GUARD_SYSTEMCTL:?}"
else
  NFT=nft; SYSTEMCTL=systemctl
fi

table_ok() {
  out="$("$NFT" list table inet vdh_runner 2>/dev/null)" || return 1
  # The rules that make the table worth anything; a half-flushed table fails.
  # nft prints the uid numerically when listing (meta skuid != 969 accept).
  uid="$(id -u runner 2>/dev/null || echo no-runner-user)"
  printf '%s\n' "$out" | grep -qE "meta skuid != (\"runner\"|${uid}) accept" || return 1
  # The output chain's final catch-all drop (policy is accept, so without it
  # everything not matched would pass).
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*counter packets [0-9]+ bytes [0-9]+ drop$' || return 1
  for want in \
    'ip daddr @nonpublic_v4' \
    'meta nfproto ipv6' \
    'tcp dport { 22, 2222 } ip saddr @ssh_allow_v4 accept' \
    'hook output priority' \
    'hook input priority'; do
    printf '%s\n' "$out" | grep -qF -- "$want" || return 1
  done
}

case "${1:-}" in
  check)
    if table_ok; then exit 0; fi
    echo "nft-guard: table inet vdh_runner missing or incomplete: refusing to start the runner"
    exit 1 ;;
  guard)
    if table_ok; then exit 0; fi
    if "$SYSTEMCTL" is-active --quiet forgejo-runner-vm.service; then
      "$SYSTEMCTL" stop forgejo-runner-vm.service
      echo "nft-guard: table inet vdh_runner missing or incomplete: STOPPED forgejo-runner-vm (no jobs until the firewall is back)"
    else
      echo "nft-guard: table inet vdh_runner missing or incomplete (runner already stopped)"
    fi ;;
  *) echo "usage: nft-guard check|guard" >&2; exit 2 ;;
esac
