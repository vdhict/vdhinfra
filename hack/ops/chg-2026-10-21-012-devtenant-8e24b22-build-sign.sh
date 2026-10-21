#!/usr/bin/env bash
# chg-2026-10-21-012: devtenant image from VDHICT/passkey-point feat/v0.1-passkeys 8e24b22 (Node 24.22.1 security release,
# base node:24-alpine index 6a1c190e). Derived from hack/ops/chg-2026-10-20-001-devtenant-ac1358d-build-sign.sh
# (sha256 aaaa15cd..): the repo's own scripts/release/build-images.sh / sign-images.sh / tag-release.ts with
# PP_RELEASE_COMPONENT=devtenant, PP_COSIGN_SOURCE=connect and the out-of-band key, as for ac1358d. Added here:
#   G1  grype gate per child (pinned grype, CycloneDX SBOM by pinned syft from an OCI archive of the child): a Critical,
#       or a High with a fix, refuses. No exception list (ar-015 is for the e2e Debian base only).
#   G2  `node --version` in each child (network none, read-only) must print NODE_VERSION_WANT.
#   G3  push mode re-gates the recorded SBOMs with a fresh grype DB, checks the local list's children are the image ids
#       that passed G1/G2, pushes that list (no rebuild) to the staging tag *-unverified only, runs the repo's
#       verify-image-lists.ts --remote, and refuses to sign unless every registry child's config digest equals the
#       gated image id. Only then sign-images.sh + tag-release.ts, then an independent cosign
#       verify (index + each child + slsaprovenance1) against the out-of-band key.
#
#   devtenant-8e24b22-build-sign.sh build <worktree> <full-commit> <log-file> <evidence-dir>
#       build + verify the local list, G1, G2; write-once BUILD-devtenant-<short>.txt + SBOMs. No credential, no push.
#   devtenant-8e24b22-build-sign.sh push  <worktree> <full-commit> <log-file> <evidence-dir>
#       G3 as above; write-once DIGESTS-devtenant-<short>.txt.
# Push identity: palamedes (~/.config/pka/mack-dev-forge-package) and ONLY to forge.bluejungle.net/palamedes/passkey-point-*
# (chg-2026-10-10-001 option A; Atlas 2026-10-21). mypka-bot and admforgejo are never used. The token is read into a
# 0600 auth file in this session's scratchpad, reset to {"auths":{}} on exit; never printed.
set -euo pipefail
MODE=${1:?mode build|push}; WT=${2:?worktree}; COMMIT=${3:?commit}; LOG=${4:?log}; EVD=${5:?evidence dir}
case "$MODE" in build|push) ;; *) echo "mode build|push" >&2; exit 64 ;; esac
REPO=forge.bluejungle.net/palamedes/passkey-point-devtenant
PUSH_USER=palamedes; TOKFILE="$HOME/.config/pka/mack-dev-forge-package"
case "$REPO" in forge.bluejungle.net/palamedes/passkey-point-*) ;; *) echo "palamedes only for palamedes/passkey-point-*; refusing" >&2; exit 65 ;; esac
[ ! -e "$LOG" ] || { echo "log $LOG exists; write-once, refusing" >&2; exit 64; }
[ -d "$EVD" ] || { echo "evidence dir $EVD missing" >&2; exit 64; }
EVD=$(cd "$EVD" && pwd)  # absolute: rec() and the push steps run inside (cd "$WT"); push run 1 (15:13Z) failed on a relative path before signing
S7=${COMMIT:0:7}; SUFFIX="d$S7"
RECORD="$EVD/BUILD-devtenant-$S7.txt"; DIGESTS="$EVD/DIGESTS-devtenant-$S7.txt"
SBOM_AMD="$EVD/sbom-devtenant-$S7-amd64.cdx.json"; SBOM_ARM="$EVD/sbom-devtenant-$S7-arm64.cdx.json"
if [ "$MODE" = build ]; then
  [ ! -e "$RECORD" ] && [ ! -e "$SBOM_AMD" ] && [ ! -e "$SBOM_ARM" ] || { echo "$RECORD or an SBOM exists; write-once, refusing" >&2; exit 64; }
else
  [ -f "$RECORD" ] && [ -f "$SBOM_AMD" ] && [ -f "$SBOM_ARM" ] || { echo "push needs $RECORD and both SBOMs from a build run" >&2; exit 64; }
  [ ! -e "$DIGESTS" ] || { echo "$DIGESTS exists; write-once, refusing" >&2; exit 64; }
fi
umask 022
exec > >(tee "$LOG") 2>&1
SCRATCH=/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/afcadc58-4205-42d9-9959-d09214284b31/scratchpad
export PATH="$HOME/.local/share/mise/installs/node/24.22.1/bin:$HOME/.local/opt/podman-6.1.3/bin:$HOME/.local/share/mise/installs/cosign/3.1.3:$(ls -d "$HOME"/.local/share/mise/installs/kubectl/1.36*/ | head -1):$PATH"
export GODEBUG=netdns=go KUBECONFIG="$HOME/.kube/config" TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMPDIR"
MISE=/opt/homebrew/bin/mise; SYFT_VERSION=1.54.1; GRYPE_VERSION=0.120.0
NODE_VERSION_WANT=v24.22.1
CRANE=$(ls -d "$HOME"/.local/share/mise/installs/aqua-google-go-containerregistry/*/ | head -1)crane
OOB="$HOME/Code/homelab-migration/passkey-point-cosign.pub"
OOB_DER_SHA=6ad2a90a972cf633d34ac03640220cf0790d59e1e0e238294fa2760d31ad66e9
CFG_SHA=6a7a661ba892f8ef2fad0929704287187b4dc302ae07176f524669d1d98e4912
LOCAL="localhost/passkey-point-release-devtenant:$SUFFIX"
AUTHDIR="$SCRATCH/regauth-8e24b22"; AUTH="$AUTHDIR/auth.json"
WORK=$(mktemp -d "$SCRATCH/pp-devtenant-8e24b22.XXXXXX")
on_exit() {
  rc=$?
  if [ -d "$AUTHDIR" ]; then ( umask 077; printf '{"auths":{}}\n' > "$AUTH" ); echo "auth file reset: $(cat "$AUTH")"; fi
  echo "EXIT $rc $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
trap on_exit EXIT
FULL=$(git -C "$WT" rev-parse HEAD)
[ "$FULL" = "$COMMIT" ] || { echo "worktree HEAD $FULL is not $COMMIT" >&2; exit 1; }
[ -z "$(git -C "$WT" status --porcelain)" ] || { echo "worktree not clean" >&2; exit 1; }
echo "# chg-2026-10-21-012 devtenant image $MODE by k8s-engineer (Heph) for Atlas $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname -s) HEAD $FULL"
echo "AGR-109: tests are the gate (Passkey dev tenant, AGR-087/098)"
echo "tools: $(podman version --format 'podman client {{.Client.Version}} server {{.Server.Version}}'); $(cosign version 2>&1 | sed -n 's/^GitVersion: *//p' | sed 's/^/cosign /'); host node $(node --version)"
[ "$(shasum -a 256 "$WT/scripts/release/signing-config.no-tlog.json" | cut -d' ' -f1)" = "$CFG_SHA" ] \
  && jq -e '.rekorTlogUrls|length==0' "$WT/scripts/release/signing-config.no-tlog.json" >/dev/null \
  || { echo "F3: signing-config.no-tlog.json of $S7 is not the pinned $CFG_SHA or lists a tlog; refusing" >&2; exit 1; }
echo "F3: $S7 scripts/release/signing-config.no-tlog.json sha256 $CFG_SHA (pinned), rekorTlogUrls empty"
rec() { sed -n "s/^$1=//p" "$RECORD" | head -1; }
GATE_SEL='.matches[] | select(.vulnerability.severity == "Critical" or (.vulnerability.severity == "High" and .vulnerability.fix.state == "fixed"))'
grype_gate() {  # $1 grype json, $2 label
  local n
  echo "-- grype gate $2 (Critical, or High with a fix; no exceptions), all hits listed"
  jq -r "$GATE_SEL"' | "  GATE \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$1" | sort -u
  n=$(jq "[$GATE_SEL] | length" "$1")
  echo "   gate hits: $n"
  [ "$n" = 0 ] && echo "grype gate $2 PASS"
}
children() {  # "<arch> <child manifest digest> <image id>" of the local list; exactly linux/amd64 + linux/arm64
  podman manifest inspect "$LOCAL" > "$WORK/list.json"
  jq -e '[.manifests[] | .platform.os + "/" + .platform.architecture] | sort == ["linux/amd64", "linux/arm64"]' "$WORK/list.json" >/dev/null \
    || { echo "local list $LOCAL is not exactly linux/amd64 + linux/arm64" >&2; exit 1; }
  podman images -a --digests --format json > "$WORK/images.json"
  jq -r '.manifests[] | .platform.architecture + " " + .digest' "$WORK/list.json" | sort | while read -r a md; do
    # After a push podman keeps the registry child digest only in Names (<repo>@<digest>), not in Digest (run 3, 15:15Z).
    id=$(jq -r --arg d "$md" '[.[] | select(.Digest == $d or ((.Digests // []) | index($d)) or ((.Names // []) | any(endswith("@" + $d))))] | if length == 1 then .[0].Id else empty end' "$WORK/images.json")
    [ -n "$id" ] || { echo "no single local image for $a child $md" >&2; exit 1; }
    echo "$a $md $id"
  done
}

echo "== --pull: base images of $WT/Containerfile, both platforms"
imgs=$(sed -n 's/^ARG [A-Z_]*IMAGE=\(.*\)$/\1/p' "$WT/Containerfile" | sort -u)
[ -n "$imgs" ] || { echo "no base image ARG found in Containerfile" >&2; exit 1; }
for img in $imgs; do
  for p in linux/amd64 linux/arm64; do podman pull -q --platform "$p" "$img" >/dev/null; echo "pulled $img $p"; done
done
export PP_RELEASE_COMPONENT=devtenant PP_COSIGN_SOURCE=connect PP_COSIGN_PUB_OOB="$OOB"
export PP_REGISTRY_REPO="$REPO"

if [ "$MODE" = build ]; then
  STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ( cd "$WT" && scripts/release/build-images.sh "$FULL" "$SUFFIX" )
  FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  children > "$WORK/children.txt"; cat "$WORK/children.txt"
  : > "$WORK/record-arch.txt"
  for a in amd64 arm64; do
    read -r _ MD ID < <(grep "^$a " "$WORK/children.txt")
    [ "$(podman image inspect "$ID" --format '{{.Architecture}}/{{.Os}}')" = "$a/linux" ] || { echo "child is not linux/$a" >&2; exit 1; }
    [ "$(podman image inspect "$ID" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$FULL" ] || { echo "revision label mismatch ($a)" >&2; exit 1; }
    echo "== $a child $MD id $ID user $(podman image inspect "$ID" --format '{{.Config.User}}')"
    NV=$(podman run --rm --network none --read-only --platform "linux/$a" --entrypoint node "$ID" --version)
    echo "G2 node --version in $a child (network none, read-only): $NV"
    [ "$NV" = "$NODE_VERSION_WANT" ] || { echo "node in $a child is $NV, not $NODE_VERSION_WANT; refusing" >&2; exit 1; }
    podman save --format oci-archive -o "$WORK/dt-$a-oci.tar" "$ID"
    echo "== SBOM $a (syft $SYFT_VERSION, CycloneDX JSON)"
    "$MISE" x "aqua:anchore/syft@$SYFT_VERSION" -- syft scan "oci-archive:$WORK/dt-$a-oci.tar" -q -o "cyclonedx-json=$WORK/sbom-$a.cdx.json"
    jq -e '.bomFormat == "CycloneDX" and ((.components // []) | length) > 0' "$WORK/sbom-$a.cdx.json" >/dev/null || { echo "SBOM empty or not CycloneDX" >&2; exit 1; }
    echo "sbom components=$(jq '.components | length' "$WORK/sbom-$a.cdx.json")"
    echo "== grype $GRYPE_VERSION on the $a SBOM"
    "$MISE" x "aqua:anchore/grype@$GRYPE_VERSION" -- grype "sbom:$WORK/sbom-$a.cdx.json" -q -o json > "$WORK/grype-$a.json"
    jq -r '[.matches[] | .vulnerability.severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ") | "grype matches by severity: " + (if . == "" then "none" else . end)' "$WORK/grype-$a.json"
    jq -r '.matches[] | "  \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$WORK/grype-$a.json" | sort | head -40
    grype_gate "$WORK/grype-$a.json" "$a" || { echo "grype gate $a: a Critical or fixable High; refusing" >&2; exit 1; }
    printf '%s\n' "child_$a=$MD" "image_id_$a=$ID" "node_version_$a=$NV" "grype_matches_$a=$(jq '.matches | length' "$WORK/grype-$a.json")" >> "$WORK/record-arch.txt"
  done
  cp "$WORK/sbom-amd64.cdx.json" "$SBOM_AMD"; cp "$WORK/sbom-arm64.cdx.json" "$SBOM_ARM"
  { echo "commit=$FULL"; echo "image_local=$LOCAL"; cat "$WORK/record-arch.txt"
    echo "node_index=$(sed -n 's/^ARG NODE_IMAGE=//p' "$WT/Containerfile" | head -1)"; echo "started=$STARTED"; echo "finished=$FINISHED"
    echo "sbom_sha256_amd64=$(shasum -a 256 "$SBOM_AMD" | cut -d' ' -f1)"; echo "sbom_sha256_arm64=$(shasum -a 256 "$SBOM_ARM" | cut -d' ' -f1)"; } > "$RECORD"
  echo "== RESULT (build, unsigned, not pushed)"; cat "$RECORD"
  echo "BUILD OK"
  exit 0
fi

# ---- push ----
[ "$(rec commit)" = "$FULL" ] || { echo "record commit is not $FULL" >&2; exit 1; }
[ "$(shasum -a 256 "$SBOM_AMD" | cut -d' ' -f1)" = "$(rec sbom_sha256_amd64)" ] && [ "$(shasum -a 256 "$SBOM_ARM" | cut -d' ' -f1)" = "$(rec sbom_sha256_arm64)" ] \
  || { echo "an SBOM changed since the build record" >&2; exit 1; }
for a in amd64 arm64; do
  sb="$SBOM_AMD"; [ "$a" = arm64 ] && sb="$SBOM_ARM"
  echo "== grype $GRYPE_VERSION re-gate $a on recorded $(basename "$sb") (fresh DB, before push)"
  "$MISE" x "aqua:anchore/grype@$GRYPE_VERSION" -- grype "sbom:$sb" -q -o json > "$WORK/grype-push-$a.json"
  grype_gate "$WORK/grype-push-$a.json" "push-$a" || { echo "grype re-gate $a failed; refusing" >&2; exit 1; }
done
[ -s "$TOKFILE" ] || { echo "token file missing or empty" >&2; exit 64; }
( umask 077; mkdir -p "$AUTHDIR"; tok=$(cat "$TOKFILE"); b64=$(printf '%s:%s' "$PUSH_USER" "$tok" | base64 | tr -d '\n')
  printf '{"auths":{"forge.bluejungle.net":{"auth":"%s"}}}\n' "$b64" > "$AUTH" )
echo "push identity: $PUSH_USER to $REPO (token from $(basename "$TOKFILE"), not printed)"
export REGISTRY_AUTH_FILE="$AUTH"
mkdir -p "$SCRATCH/regauth-docker-8e24b22"; ln -sf "$AUTH" "$SCRATCH/regauth-docker-8e24b22/config.json"
export DOCKER_CONFIG="$SCRATCH/regauth-docker-8e24b22"
# Push run 2 (15:14Z): rebuilding through build-images.sh --push after run 1's push made its local-list verify refuse
# (podman local digest records changed; same image ids). So push mode no longer rebuilds: it pushes the gated local list
# itself, the way build-images.sh does (manifest push --all to the *-unverified staging tag), then runs the repo's
# verify-image-lists.ts --remote on what the registry serves.
echo "== G3 step 1a: local list $LOCAL children = the gated image ids of the build run"
children > "$WORK/children.txt"; cat "$WORK/children.txt"
for a in amd64 arm64; do
  read -r _ _ ID < <(grep "^$a " "$WORK/children.txt")
  [ "$ID" = "$(rec "image_id_$a")" ] || { echo "local $a child $ID is not the gated image id $(rec "image_id_$a"); refusing" >&2; exit 1; }
  [ "$(podman image inspect "$ID" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$FULL" ] || { echo "revision label mismatch ($a)" >&2; exit 1; }
done
echo "== G3 step 1b: push the gated list to the staging tag devtenant-$SUFFIX-unverified (no release tag, unsigned)"
podman manifest push --all --digestfile "$WORK/digest" "$LOCAL" "docker://$REPO:devtenant-$SUFFIX-unverified"
D=$(cat "$WORK/digest"); [[ "$D" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no pushed digest" >&2; exit 1; }
echo "staging push $REPO@$D"
mkdir "$WORK/src"; git -C "$WT" archive "$FULL" | tar -x -C "$WORK/src"
echo "== G3 step 1c: verify what the registry serves (repo verify-image-lists.ts --remote, pulled by digest)"
( cd "$WT" && node scripts/release/verify-image-lists.ts --component devtenant --remote --revision "$FULL" --source "$WORK/src" "devtenant=$REPO@$D" )
echo "== G3 step 2: registry children = the gated image ids of the build run"
"$CRANE" manifest "$REPO@$D" > "$WORK/remote-list.json"
jq -e '[.manifests[] | .platform.os + "/" + .platform.architecture] | sort == ["linux/amd64", "linux/arm64"]' "$WORK/remote-list.json" >/dev/null \
  || { echo "registry list $D is not exactly linux/amd64 + linux/arm64" >&2; exit 1; }
: > "$WORK/remote-children.txt"
for a in amd64 arm64; do
  cd_=$(jq -r --arg a "$a" '.manifests[] | select(.platform.architecture == $a) | .digest' "$WORK/remote-list.json")
  cfg=$("$CRANE" manifest "$REPO@$cd_" | jq -r .config.digest)
  [ "$cfg" = "sha256:$(rec "image_id_$a")" ] || { echo "registry $a child $cd_ config $cfg is not the gated image id $(rec "image_id_$a"); NOT signing" >&2; exit 1; }
  echo "$a child $cd_ config $cfg = gated image id (G1 grype, G2 $(rec "node_version_$a"))"
  echo "$a $cd_" >> "$WORK/remote-children.txt"
done
echo "== G3 step 3: sign + attest (repo sign-images.sh, PP_COSIGN_SOURCE=connect, out-of-band key check)"
[ "$(openssl pkey -pubin -in "$OOB" -outform DER | shasum -a 256 | cut -d' ' -f1)" = "$OOB_DER_SHA" ] || { echo "OOB public key hash mismatch; refusing" >&2; exit 1; }
( cd "$WT" && scripts/release/sign-images.sh "$FULL" "$SUFFIX" "$(rec started)" "$(rec finished)" "devtenant=$REPO@$D" )
echo "== release tag, on the verified digest only"
( cd "$WT" && node scripts/release/tag-release.ts "$REPO@$D" "devtenant-$SUFFIX" )
echo "== independent verify against the out-of-band key $OOB (sha256 DER $OOB_DER_SHA)"
cosign verify --key "$OOB" --insecure-ignore-tlog "$REPO@$D" | jq -c '.[] | {ref: .critical.identity["docker-reference"], digest: .critical.image["docker-manifest-digest"]}'
while read -r a cd_; do
  echo "-- $a child"; cosign verify --key "$OOB" --insecure-ignore-tlog "$REPO@$cd_" | jq -c '.[] | {digest: .critical.image["docker-manifest-digest"]}'
done < "$WORK/remote-children.txt"
cosign verify-attestation --key "$OOB" --insecure-ignore-tlog --type slsaprovenance1 "$REPO@$D" | jq -r '.payload' | while read -r p; do
  printf '%s' "$p" | base64 -d | jq -c '{subject: [.subject[].digest.sha256], commit: .predicate.buildDefinition.externalParameters.commit, target: .predicate.buildDefinition.externalParameters.target}'; done
{ echo "$REPO@$D"; sed "s|^\([a-z0-9]*\) |\1 $REPO@|" "$WORK/remote-children.txt"; } > "$DIGESTS"
echo "DIGESTS -> $DIGESTS:"; cat "$DIGESTS"
echo "VERIFY OK"
