#!/usr/bin/env bash
# All offline checks for hack/forgejo-runner/vdhwslin01. Exit 0 = green.
set -euo pipefail
cd "$(dirname "$0")/.."
SC="${SHELLCHECK:-shellcheck}"
echo "== shellcheck"
"$SC" -S style -s bash provision.in.sh provision.sh build.sh src/idle-poweroff.sh src/vm-dispatch.sh \
  src/vm-golden-build.sh src/initcpio-install-vdh-teamboot.sh tests/idle-poweroff.test.sh tests/run-all.sh tests/arch-container.sh tests/nft-guard.test.sh tests/nft-kernel.sh tests/sudo-window-container.sh tests/remote-unlock.test.sh tests/user-groups.test.sh \
  sudo-window/vdh-provision-tonight sudo-window/install-window.sh sudo-window/verify-revoked.sh sudo-window/pin.sh sudo-window/larry/sweep-count.sh mini/make-webhook-id.sh mini/install-waker.sh mini/ha-cap-readback.sh tests/run-in-pod.sh post-run-checks.sh
"$SC" -S style -s sh src/teamboot-shell.sh src/teamboot-record.sh src/nft-guard.sh
echo "== provision.sh in sync with sources"
./build.sh --check
echo "== bash -n on every shell file"
for f in provision.sh src/*.sh tests/*.sh build.sh; do bash -n "$f"; done
echo "== idle-poweroff unit tests"
bash tests/idle-poweroff.test.sh
echo "== sudo-window: install-window.sh pins in sync"
sudo-window/pin.sh --check
visudo_line="$(grep -v '^#' sudo-window/90-agent-provision)"
[[ "$visudo_line" != *"*"* && "$visudo_line" != *SETENV* && "$visudo_line" != *"NOPASSWD: ALL"* ]] || { echo "drop-in too broad" >&2; exit 1; }
echo "== remote-unlock hook fixture tests"
bash tests/remote-unlock.test.sh
echo "== D6 runner group refusal"
bash tests/user-groups.test.sh
echo "== nft-guard unit tests"
bash tests/nft-guard.test.sh
echo "== Mini waker unit tests (macOS /usr/bin/python3 3.9 = what launchd runs, and python3)"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 tests/test_waker_mini.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_waker_mini.py
echo "== revive invariants (2026-11-03, Argus D4/D5)"
img="$(sed -n 's/^JOB_IMAGE="\(.*\)"$/\1/p' provision.in.sh)"
[[ "$img" == *@sha256:* ]] || { echo "JOB_IMAGE not digest-pinned" >&2; exit 1; }
grep -qF "\"$img\"" src/vm-golden-build.sh || { echo "golden pre-pull differs from JOB_IMAGE" >&2; exit 1; }
! grep -nE '^SSH_ALLOW[A-Z_]*=\(.*172\.16\.2\.8[1-3]' provision.in.sh || { echo "cluster workers still on the ssh allow list" >&2; exit 1; }
grep -q "^RUNNER_SCOPE=vdhict$" provision.in.sh || { echo "scope marker missing" >&2; exit 1; }
pub="${MINI_UNLOCK_PUB:-$HOME/.ssh/vdhwslin01_unlock_mini.pub}"
if [[ -r "$pub" ]]; then
  grep -qF "$(awk '{print $2}' "$pub")" sudo-window/vdh-provision-tonight || { echo "wrapper pubkey is not the Mini unlock key" >&2; exit 1; }
else echo "(wrapper pubkey not compared: Mini unlock pub not on this machine)"; fi
! grep -n -- '--steps [a-z,]*keyslot' sudo-window/vdh-provision-tonight || { echo "wrapper runs keyslot" >&2; exit 1; }
echo "ok   job image pinned + golden matches, no .81-.83, scope vdhict, wrapper without keyslot"
echo "== no secrets / client names in the bundle"
! grep -nEi 'BEGIN [A-Z ]*PRIVATE KEY|password=[^"$]|token=[A-Za-z0-9]{20,}' provision.sh src/* mini/* || { echo "secret-like string found" >&2; exit 1; }
echo "ALL GREEN"
