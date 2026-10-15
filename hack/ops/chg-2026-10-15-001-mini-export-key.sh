#!/usr/bin/env bash
# chg-2026-10-15-001 M1: generate the read-only huiswerk export key and write it straight into a SOPS Secret.
#   hack/ops/chg-2026-10-15-001-mini-export-key.sh <pubkey-out-file>
# The private key exists only in a 0700 temp dir and is deleted at the end; it is never printed.
# Output: kubernetes/main/apps/family-ai/huiswerk-refresh/app/huiswerk-mini-export.sops.yaml (encrypted),
#         <pubkey-out-file> (public key line), fingerprints on stdout.
set -euo pipefail
. "$(dirname "$0")/../family-ai/lib.sh"
PUB_OUT="${1:?usage: $0 <pubkey-out-file>}"
ROOT="$(git rev-parse --show-toplevel)"
OUT="$ROOT/kubernetes/main/apps/family-ai/huiswerk-refresh/app/huiswerk-mini-export.sops.yaml"
[ ! -e "$OUT" ] || die "$OUT exists - refusing to overwrite"
HOSTKEY=/etc/ssh/ssh_host_ed25519_key.pub
[ -r "$HOSTKEY" ] || die "no $HOSTKEY"
umask 077
TMP="$(mktemp -d)"
cleanup() { find "${TMP:?}" -mindepth 1 -delete; rmdir "${TMP:?}"; }
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -C huiswerk-export-chg-2026-10-15-001 -f "$TMP/key"
printf '172.16.2.201 %s\n' "$(awk '{print $1" "$2}' "$HOSTKEY")" > "$TMP/known_hosts"
python3 -I - "$TMP" <<'PY'
import base64, sys, pathlib
t = pathlib.Path(sys.argv[1])
b = lambda n: base64.b64encode((t / n).read_bytes()).decode()
(t / "secret.yaml").write_text(
    "---\n# chg-2026-10-15-001: read-only export key for the Mini forced command + pinned Mini host key.\n"
    "apiVersion: v1\nkind: Secret\nmetadata:\n  name: huiswerk-mini-export\n  annotations:\n"
    "    kustomize.toolkit.fluxcd.io/substitute: disabled\ntype: Opaque\ndata:\n"
    f"  key: {b('key')}\n  known_hosts: {b('known_hosts')}\n")
PY
mkdir -p "$(dirname "$OUT")"
sops_write "$TMP/secret.yaml" "$OUT"
cp "$TMP/key.pub" "$PUB_OUT"
echo "export key: $(ssh-keygen -lf "$TMP/key.pub" | awk '{print $1, $2}')"
echo "pinned host: $(ssh-keygen -lf "$TMP/known_hosts" | awk '{print $1, $2}')"
echo "secret: $OUT (encrypted)"
