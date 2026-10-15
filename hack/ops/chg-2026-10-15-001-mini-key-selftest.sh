#!/usr/bin/env bash
# chg-2026-10-15-001 C5 (Mini side): the export key must be REFUSED from the Mini itself (from= is node IPs only),
# and the direct export must produce a valid tar. Prints status codes, counts and sha256 prefixes only.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
F="$ROOT/kubernetes/main/apps/family-ai/huiswerk-refresh/app/huiswerk-mini-export.sops.yaml"
umask 077
TMP="$(mktemp -d)"
cleanup() { find "${TMP:?}" -mindepth 1 -delete; rmdir "${TMP:?}"; }
trap cleanup EXIT
sops -d --extract '["data"]["key"]' "$F" | base64 -d > "$TMP/key"
sops -d --extract '["data"]["known_hosts"]' "$F" | base64 -d > "$TMP/known_hosts"
for host in 172.16.2.201 127.0.0.1; do
  ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$TMP/known_hosts" -o HostKeyAlias=172.16.2.201 -i "$TMP/key" "sheijden@$host" huiswerk-export \
      > "$TMP/out" 2> "$TMP/err"
  echo "from-mini via $host: rc=$? stdout_bytes=$(wc -c < "$TMP/out" | tr -d ' ') denied=$(grep -c 'Permission denied' "$TMP/err")"
done
/usr/bin/python3 -I "$HOME/.local/libexec/huiswerk/export-package.py" > "$TMP/direct.tar"; rc=$?
echo "direct export: rc=$rc members=$(tar -tf "$TMP/direct.tar" | wc -l | tr -d ' ') sha256=$(shasum -a 256 "$TMP/direct.tar" | cut -c1-12)"
