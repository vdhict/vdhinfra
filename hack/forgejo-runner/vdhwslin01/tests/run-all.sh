#!/usr/bin/env bash
# All offline checks for hack/forgejo-runner/vdhwslin01. Exit 0 = green.
set -euo pipefail
cd "$(dirname "$0")/.."
SC="${SHELLCHECK:-shellcheck}"
echo "== shellcheck"
"$SC" -S style -s bash provision.in.sh provision.sh build.sh src/idle-poweroff.sh src/vm-dispatch.sh \
  src/vm-golden-build.sh src/initcpio-install-vdh-teamboot.sh tests/idle-poweroff.test.sh tests/run-all.sh tests/arch-container.sh
"$SC" -S style -s sh src/teamboot-shell.sh src/teamboot-record.sh
echo "== provision.sh in sync with sources"
./build.sh --check
echo "== bash -n on every shell file"
for f in provision.sh src/*.sh tests/*.sh build.sh; do bash -n "$f"; done
echo "== idle-poweroff unit tests"
bash tests/idle-poweroff.test.sh
echo "== waker controller unit tests"
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_controller.py 2>&1 | grep -v "^OPS_EVENT"
echo "== no secrets / client names in the bundle"
! grep -nEi 'BEGIN [A-Z ]*PRIVATE KEY|password=[^"$]|token=[A-Za-z0-9]{20,}' provision.sh src/* || { echo "secret-like string found" >&2; exit 1; }
echo "ALL GREEN"
