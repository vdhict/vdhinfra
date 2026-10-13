#!/usr/bin/env bash
# Argus C7 count-only sweep for the registration token (chg-2026-10-05-031).
# Prints only COUNTS, never a match. Expected total 0.
#   sweep-count.sh <0600 token file> <path>...
# Larry's MacBook: the Larry session jsonl dir, ~/.zsh_history / ~/.bash_history,
# the expect output you captured. On the box (as Sander or via the next sudo
# window), run with: journalctl -b > a 0600 file, /var/log/vdh-runner-initramfs-*.log,
# /var/log/vdh-provision-*.log.
set -uo pipefail
tf="${1:?token file}"; shift
[[ "$(stat -f '%Lp' "$tf" 2>/dev/null || stat -c '%a' "$tf")" == 600 ]] || { echo "token file must be 0600"; exit 2; }
total=0
for p in "$@"; do
  n="$(grep -rcF -f "$tf" -- "$p" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
  echo "count $n  $p"; total=$((total + n))
done
echo "TOTAL $total (expected 0)"
(( total == 0 ))
