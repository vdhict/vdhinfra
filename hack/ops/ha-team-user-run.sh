#!/bin/sh
# Runs hack/ops/ha-team-user.py through a port-forward to 127.0.0.1 (macOS local-network privacy blocks python from
# the LAN) and writes the token into Secret mypka/ha-team-token ONLY if a token came out (no empty Secret).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HOME/Code/pka-wires/_toolchains/open-webui-0.11.4-test/.venv/bin/python3"
kubectl -n mypka get secret ha-team-token >/dev/null 2>&1 && { echo "REFUSED: mypka/ha-team-token exists" >&2; exit 1; }
PORT=$((20000 + $$ % 10000))
kubectl -n home-automation port-forward svc/home-assistant "$PORT:8123" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 1; done
HA_BASE="http://127.0.0.1:$PORT" HA_ADMIN_TOKEN="$(cat "$HOME/Code/homelab-migration/config/hasskey")" "$PY" -I "$HERE/ha-team-user.py" \
| /usr/bin/python3 -I -c '
import subprocess, sys
t = sys.stdin.read()
if len(t) < 100:
    sys.exit("no token produced; nothing written")
r = subprocess.run(["kubectl", "-n", "mypka", "create", "secret", "generic", "ha-team-token", "--from-file=token=/dev/stdin"], input=t.encode(), capture_output=True)
print(r.stdout.decode().strip() or r.stderr.decode().strip()[:200])'
kubectl -n mypka label secret ha-team-token app.kubernetes.io/part-of=mypka owner-decision=agr-126 >/dev/null
kubectl -n mypka get secret ha-team-token -o json | jq -r '"keys=\(.data|keys) len=\(.data.token|@base64d|length)"'
