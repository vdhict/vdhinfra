#!/usr/bin/env bash
# chg-2026-10-20-001: devtenant image from VDHICT/passkey-point feat/v0.1-passkeys ac1358d (carries f131aad
# lab.extraOrigins and 6074c56 tapsim displayName), modelled on ops/evidence/chg-2026-10-12-005/09-devtenant-build-sign.sh:
# the repo's own scripts/release/build-images.sh with PP_RELEASE_COMPONENT=devtenant (linux/amd64 + linux/arm64 list,
# local list verify; with push: staging tag, remote verify, sign + SLSA attest via PP_COSIGN_SOURCE=connect, verify
# against the out-of-band key, release tag). Builder host vdhmini01, podman machine.
# --pull: build-images.sh has no --pull, so the Containerfile's FROM images are pulled fresh for both platforms first.
#
#   devtenant-ac1358d-build-sign.sh build <worktree> <full-commit> <log-file>
#       build + verify the local list only; no registry credential, no push, no signing.
#   devtenant-ac1358d-build-sign.sh push  <worktree> <full-commit> <log-file> <user> <token-file>
#       as build, then --push. The token file is read into a 0600 auth file in this session's scratchpad, reset to
#       {"auths":{}} on exit. Never prints a token, the key or its password.
# Push identity (Atlas 2026-10-21, correcting the brief): Passkey Point images go to
# forge.bluejungle.net/palamedes/passkey-point-* as user palamedes (~/.config/pka/mack-dev-forge-package), as decided
# in chg-2026-10-10-001 option A and used for the 7bd83cf and dcd2404 devtenant builds. The palamedes ban applies to
# the cluster-wires push (chg-2026-10-07-007) only. So: palamedes is allowed ONLY when the target repo is
# palamedes/passkey-point-devtenant; mypka-bot and admforgejo are always refused.
set -euo pipefail
MODE=${1:?mode build|push}; WT=${2:?worktree}; COMMIT=${3:?commit}; LOG=${4:?log}
case "$MODE" in build) ;; push) PUSH_USER=${5:?user}; TOKFILE=${6:?token file} ;; *) echo "mode build|push" >&2; exit 64 ;; esac
REPO=${PP_REGISTRY_REPO:-forge.bluejungle.net/palamedes/passkey-point-devtenant}
[ ! -e "$LOG" ] || { echo "log $LOG exists; write-once, refusing" >&2; exit 64; }
umask 022
exec > >(tee "$LOG") 2>&1
SCRATCH=/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/afcadc58-4205-42d9-9959-d09214284b31/scratchpad
export PATH="$HOME/.local/opt/podman-6.1.3/bin:$HOME/.local/share/mise/installs/cosign/3.1.3:$(ls -d "$HOME"/.local/share/mise/installs/kubectl/1.36*/ | head -1):$PATH"
export GODEBUG=netdns=go KUBECONFIG="$HOME/.kube/config" TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"
AUTHDIR="$SCRATCH/regauth-ac1358d"; AUTH="$AUTHDIR/auth.json"
on_exit() { rc=$?; if [ -d "$AUTHDIR" ]; then ( umask 077; printf '{"auths":{}}\n' > "$AUTH" ); echo "auth file reset: $(cat "$AUTH")"; fi; echo "EXIT $rc $(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
trap on_exit EXIT
FULL=$(git -C "$WT" rev-parse HEAD)
[ "$FULL" = "$COMMIT" ] || { echo "worktree HEAD $FULL is not $COMMIT" >&2; exit 1; }
[ -z "$(git -C "$WT" status --porcelain)" ] || { echo "worktree not clean" >&2; exit 1; }
echo "# devtenant image $MODE by k8s-engineer for Atlas $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname -s) HEAD $FULL"
echo "AGR-109: tests are the gate (npm test on this worktree before the build)"
echo "tools: $(podman version --format 'podman client {{.Client.Version}} server {{.Server.Version}}'); $(cosign version 2>&1 | sed -n 's/^GitVersion: *//p' | sed 's/^/cosign /')"

echo "== --pull: base images of $WT/Containerfile, both platforms"
# FROM uses ARG defaults (digest-pinned, e.g. NODE_IMAGE=docker.io/library/node@sha256:...); stages and scratch skipped.
imgs=$(sed -n 's/^ARG [A-Z_]*IMAGE=\(.*\)$/\1/p' "$WT/Containerfile" | sort -u)
[ -n "$imgs" ] || { echo "no base image ARG found in Containerfile" >&2; exit 1; }
for img in $imgs; do
  for p in linux/amd64 linux/arm64; do podman pull -q --platform "$p" "$img" >/dev/null; echo "pulled $img $p"; done
done

if [ "$MODE" = push ]; then
  case "$PUSH_USER" in
    mypka-bot|admforgejo) echo "push identity $PUSH_USER is never allowed; refusing" >&2; exit 65 ;;
    palamedes) [ "$REPO" = forge.bluejungle.net/palamedes/passkey-point-devtenant ] \
                 || { echo "palamedes allowed only for palamedes/passkey-point-devtenant, not $REPO (chg-2026-10-10-001)" >&2; exit 65; } ;;
  esac
  [ -s "$TOKFILE" ] || { echo "token file missing or empty" >&2; exit 64; }
  ( umask 077; mkdir -p "$AUTHDIR"; tok=$(cat "$TOKFILE"); b64=$(printf '%s:%s' "$PUSH_USER" "$tok" | base64 | tr -d '\n')
    printf '{"auths":{"forge.bluejungle.net":{"auth":"%s"}}}\n' "$b64" > "$AUTH" )
  echo "push identity: $PUSH_USER to $REPO (token from $(basename "$TOKFILE"), not printed; Atlas 2026-10-21 per chg-2026-10-10-001)"
  export REGISTRY_AUTH_FILE="$AUTH"
  mkdir -p "$SCRATCH/regauth-docker-ac1358d"; ln -sf "$AUTH" "$SCRATCH/regauth-docker-ac1358d/config.json"
  export DOCKER_CONFIG="$SCRATCH/regauth-docker-ac1358d"
fi
export PP_RELEASE_COMPONENT=devtenant PP_COSIGN_SOURCE=connect PP_COSIGN_PUB_OOB="$HOME/Code/homelab-migration/passkey-point-cosign.pub"
cd "$WT"
if [ "$MODE" = push ]; then
  scripts/release/build-images.sh "$FULL" "d${FULL:0:7}" --push
else
  scripts/release/build-images.sh "$FULL" "d${FULL:0:7}"
  echo "== local list"
  podman manifest inspect "localhost/passkey-point-release-devtenant:d${FULL:0:7}" \
    | jq -c '.manifests[] | {platform: (.platform.os + "/" + .platform.architecture), digest}'
fi
