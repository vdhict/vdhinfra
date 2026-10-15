#!/usr/bin/env bash
# chg-2026-10-15-001 M2+M3 (run on the Mini as the account that owns ~/family-ai-prive):
#   hack/ops/chg-2026-10-15-001-mini-export-install.sh <export-package.py> <expected-sha256> <pubkey-file>
# Installs the read-only export script and appends ONE forced-command key line to ~/.ssh/authorized_keys
# (backup first, idempotent). Rollback: cp ~/.ssh/authorized_keys.pre-chg-2026-10-15-001 ~/.ssh/authorized_keys
set -euo pipefail
SRC="${1:?export-package.py}"; WANT="${2:?sha256}"; PUB="${3:?pubkey file}"
TAG=huiswerk-export-chg-2026-10-15-001
DST="$HOME/.local/libexec/huiswerk/export-package.py"
AK="$HOME/.ssh/authorized_keys"
[ "$(shasum -a 256 "$SRC" | cut -d' ' -f1)" = "$WANT" ] || { echo "export-package.py sha mismatch" >&2; exit 1; }
read -r KT KB _ < "$PUB"
[ "$KT" = ssh-ed25519 ] || { echo "not an ed25519 public key" >&2; exit 1; }
mkdir -p "$(dirname "$DST")"
install -m 0555 "$SRC" "$DST"
[ -e "$AK.pre-chg-2026-10-15-001" ] || cp -p "$AK" "$AK.pre-chg-2026-10-15-001"
if grep -q "$TAG" "$AK"; then echo "key line already present"; else
  printf 'from="172.16.2.81,172.16.2.82,172.16.2.83",restrict,command="/usr/bin/python3 -I %s" %s %s %s\n' \
    "$DST" "$KT" "$KB" "$TAG" >> "$AK"
fi
echo "installed $(shasum -a 256 "$DST" | cut -c1-12) mode $(stat -f %Lp "$DST"); authorized_keys lines $(grep -c . "$AK"), tagged $(grep -c "$TAG" "$AK")"
