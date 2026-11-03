#!/usr/bin/env bash
# chg-2026-10-05-031: create the HA webhook id for the vdhwslin01 waker on the Mini.
# Writes ~/.config/vdhwslin01/ha-webhook-id (0600, noclobber). Prints NOTHING of the value.
# Hestia puts the same value in HA secrets.yaml as vdhwslin01_wake_webhook_id by
# piping this file over stdin (never echo it, never put it on argv).
set -euo pipefail
umask 077
d="$HOME/.config/vdhwslin01"; f="$d/ha-webhook-id"
mkdir -p "$d"
[[ ! -e "$f" ]] || { echo "exists: $f (not overwritten)"; exit 0; }
set -o noclobber
/usr/bin/python3 -I -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(32))' > "$f"
echo "wrote $f ($(wc -c < "$f" | tr -d ' ') bytes, mode $(stat -f '%Lp' "$f"))"
