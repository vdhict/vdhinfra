#!/usr/bin/env bash
# chg-2026-11-24-003 / tsk-2026-11-17-110: v13c gate prep. BUILD + SCAN ONLY of the .NET Passkey Point `desk` image from
# mypka-bot/passkey-point-dotnet 557e3a6 (v13c/v13c-repin: Red Hat Hardened .NET 10.0.15, SDK 10.0.115). No push, no key,
# no token, no signing, nothing leaves the host. Deletes nothing (work dir stays in the scratchpad).
# Route = hack/ops/chg-2026-10-22-006-dotnet-desk-10d8340-build-sign.sh build mode, plus an arm64 child and a local list:
#   amd64: --platform linux/amd64, build stage SDK_IMAGE = the linux/arm64 child of the SAME pinned SDK index (dotnet under
#          qemu amd64 aborts on this applehv VM, 2026-10-14), so restore/publish run natively and publish linux-x64
#          (TARGETARCH=amd64). Runtime stage = the pinned aspnet-runtime index (resolves to its amd64 child).
#   arm64: --platform linux/arm64, Containerfile defaults unchanged (both indexes resolve to their arm64 child).
#   list : podman manifest create + add of the two local images (local only).
# Per arch: inspect (arch, user 65532), runtime readback, OCI archive digest, syft CycloneDX SBOM, grype on the SBOM,
# gate = ci/run.sh step 10 / ci/image-gate.py (Critical, or High with a fix, fails; the desk gate has NO exception;
# ar-015 is the e2e libxml2 exception and is reported only). The repo's own ci/image-gate.py runs as a cross-check.
# SDK actually used: `dotnet --version` + `--list-sdks` inside the build-stage image (--target build, cached layers) at /src,
# where the repo's global.json sits. disk-guard (30 min) prunes images below 15% free unless a container runs: a holder
# container (--rm, network none) runs for the whole build and is stopped in the trap.
#
#   PP_SCRATCH=<dir> hack/ops/chg-2026-11-24-003-desk-557e3a6-build.sh <source-worktree> <full-commit> <ts> <evidence-dir>
set -euo pipefail
SRC_GIT=${1:?source worktree}; COMMIT=${2:?full commit}; TS=${3:?utc ts}; EVD=${4:?evidence dir}
S7=${COMMIT:0:7}
LOG="$EVD/90-desk-$S7-$TS-build.log"; RECORD="$EVD/91-BUILD-desk-$S7-$TS.txt"
SBOM_AMD="$EVD/92-sbom-desk-$S7-$TS-amd64.cdx.json"; SBOM_ARM="$EVD/92-sbom-desk-$S7-$TS-arm64.cdx.json"
GRYPE_AMD="$EVD/93-grype-desk-$S7-$TS-amd64.json"; GRYPE_ARM="$EVD/93-grype-desk-$S7-$TS-arm64.json"
for f in "$LOG" "$RECORD" "$SBOM_AMD" "$SBOM_ARM" "$GRYPE_AMD" "$GRYPE_ARM"; do [ ! -e "$f" ] || { echo "$f exists; write-once, refusing" >&2; exit 64; }; done
[ -d "$EVD" ] || { echo "evidence dir $EVD missing" >&2; exit 64; }
umask 022
exec > >(tee "$LOG") 2>&1

SCRATCH=${PP_SCRATCH:?scratch dir}
export PATH="$HOME/.local/opt/podman-6.1.3/bin:$PATH"
export CONTAINERS_HELPER_BINARY_DIR="$HOME/.local/opt/podman-6.1.3/bin"
MISE=/opt/homebrew/bin/mise; SYFT_VERSION=1.54.1; GRYPE_VERSION=0.120.0
CRANE=$HOME/.local/share/mise/installs/aqua-google-go-containerregistry/0.22.1/crane
SDK_WANT=registry.access.redhat.com/hi/dotnet-sdk@sha256:1932ed7182997745254f4e99c08fb8f707ba06c9b61cc4578310456e2450ad92
RT_WANT=registry.access.redhat.com/hi/aspnet-runtime@sha256:7efd2bb3433d68d6fde5b26ee7a4975a7967e253bc94da07a520e76a63312de4
REPO_URL=https://forge.bluejungle.net/mypka-bot/passkey-point-dotnet
LIST="localhost/passkey-point-dotnet:desk-$S7"
HOLD="desk-$S7-diskguard-hold"
WORK=$(mktemp -d "$SCRATCH/pp-desk-$S7-build.XXXXXX")
GX_ID=CVE-2026-6653; GX_PKG=libxml2; GX_VER=2.12.7+dfsg+really2.9.14-2.1+deb13u3; GX_FIX=wont-fix
GATE_SEL='.matches[] | select(.vulnerability.severity == "Critical" or (.vulnerability.severity == "High" and .vulnerability.fix.state == "fixed"))'
GATE_EXC='(.vulnerability.id == $id and .artifact.name == $pkg and .artifact.version == $ver and .vulnerability.fix.state == $fix)'
free() { echo "disk $(date -u +%Y-%m-%dT%H:%M:%SZ) $1: $(df -h /System/Volumes/Data | awk 'NR==2 {print $4 " free of " $2 " (" 100-$5 "% free)"}')"; }
cleanup() {
  rc=$?; set +e
  podman stop -t 2 "$HOLD" >/dev/null 2>&1 && echo "holder container $HOLD stopped (--rm)"
  free end
  echo "work dir kept (scratchpad, nothing deleted): $WORK"
  echo "EXIT $rc $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit "$rc"
}
trap cleanup EXIT

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "== chg-2026-11-24-003 .NET desk $S7 BUILD + SCAN ONLY (tsk-2026-11-17-110, v13c gate prep), started $STARTED by k8s-engineer (Heph) for Atlas"
echo "AGR-109: tests are the gate; no push, no key, no token, no signing; nothing leaves $(hostname -s)"
free start
FULL=$(git -C "$SRC_GIT" rev-parse --verify HEAD)
[ "$FULL" = "$COMMIT" ] || { echo "worktree HEAD $FULL is not $COMMIT; refusing" >&2; exit 1; }
[ -z "$(git -C "$SRC_GIT" status --porcelain)" ] || { echo "worktree not clean; refusing" >&2; exit 1; }
echo "source $REPO_URL commit $FULL (worktree HEAD, clean; built from git archive)"
echo "commit subject: $(git -C "$SRC_GIT" log -1 --format=%s "$FULL")"
mkdir "$WORK/src"; git -C "$SRC_GIT" archive "$FULL" | tar -x -C "$WORK/src"
SDK=$(sed -n 's/^ARG SDK_IMAGE=//p' "$WORK/src/Containerfile" | head -1)
RT=$(sed -n 's/^ARG RUNTIME_IMAGE=//p' "$WORK/src/Containerfile" | head -1)
echo "base (as committed): sdk $SDK runtime $RT"
[ "$SDK" = "$SDK_WANT" ] && [ "$RT" = "$RT_WANT" ] || { echo "Containerfile bases are not the expected pins; refusing" >&2; exit 1; }
echo "global.json: $(jq -c .sdk "$WORK/src/global.json")"
podman version --format 'podman client {{.Client.Version}} server {{.Server.Version}}'
MACHINE=$(podman machine list --format '{{.Name}}|{{.VMType}}|{{.Default}}' | awk -F'|' '$3 == "true" {sub(/\*$/, "", $1); print $1 " " $2}')
echo "podman machine: $MACHINE"
for r in "$SDK" "$RT"; do "$CRANE" manifest "$r" > "$WORK/idx-$(basename "${r%%@*}").json"; done
child() { jq -r --arg a "$2" '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)] | if length == 1 then .[0].digest else empty end' "$WORK/idx-$1.json"; }
SDK_ARM=$(child dotnet-sdk arm64); SDK_AMD=$(child dotnet-sdk amd64); RT_AMD=$(child aspnet-runtime amd64); RT_ARM=$(child aspnet-runtime arm64)
[ -n "$SDK_ARM" ] && [ -n "$SDK_AMD" ] && [ -n "$RT_AMD" ] && [ -n "$RT_ARM" ] || { echo "an index lacks a single linux child" >&2; exit 1; }
echo "sdk index children: arm64 $SDK_ARM amd64 $SDK_AMD"
echo "runtime index children: arm64 $RT_ARM amd64 $RT_AMD"
SDK_ARM_REF="${SDK%%@*}@$SDK_ARM"

if podman image exists "$LIST" || podman manifest exists "$LIST"; then echo "$LIST exists locally; refusing (fresh list only)" >&2; exit 1; fi
for a in amd64 arm64; do podman image exists "$LIST-$a" && { echo "$LIST-$a exists locally; refusing" >&2; exit 1; }; done

echo "== disk-guard holder: $SDK_ARM_REF sleep (network none, --rm)"
podman pull -q "$SDK_ARM_REF"
podman run -d --rm --name "$HOLD" --network none --entrypoint sleep "$SDK_ARM_REF" 21600
[ -n "$(podman ps -q --filter "name=^$HOLD\$")" ] || { echo "holder container not running; refusing (disk-guard would prune)" >&2; exit 1; }
echo "SDK image $SDK_ARM_REF: dotnet --version (no global.json) $(podman run --rm --network none --entrypoint dotnet "$SDK_ARM_REF" --version)"

build() {  # $1 arch, rest extra args
  local a=$1; shift
  echo "== build desk linux/$a $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  podman build --no-cache --platform "linux/$a" --target desk "$@" --label "org.opencontainers.image.revision=$FULL" \
    --label "org.opencontainers.image.source=$REPO_URL" -t "$LIST-$a" -f "$WORK/src/Containerfile" "$WORK/src"
  echo "== build-stage SDK readback linux/$a (--target build, cached layers; dotnet at /src with the repo global.json)"
  podman build --platform "linux/$a" --target build "$@" -t "localhost/passkey-point-dotnet:buildstage-$S7-$a" -f "$WORK/src/Containerfile" "$WORK/src" 2>&1 | tail -3
  echo "build stage $a: dotnet --version = $(podman run --rm --network none -w /src --entrypoint dotnet "localhost/passkey-point-dotnet:buildstage-$S7-$a" --version)"
  echo "build stage $a: dotnet --list-sdks = $(podman run --rm --network none -w /src --entrypoint dotnet "localhost/passkey-point-dotnet:buildstage-$S7-$a" --list-sdks | tr '\n' ' ')"
  echo "build stage $a: uname -m = $(podman run --rm --network none --entrypoint uname "localhost/passkey-point-dotnet:buildstage-$S7-$a" -m); /out/desk RID check: $(podman run --rm --network none --entrypoint sh "localhost/passkey-point-dotnet:buildstage-$S7-$a" -c 'jq -r ".runtimeTarget.name" /out/desk/PasskeyPoint.Web.deps.json 2>/dev/null || grep -o "\"name\": *\"[^\"]*\"" /out/desk/PasskeyPoint.Web.deps.json | head -1')"
  free "after build $a"
}
build amd64 --build-arg "SDK_IMAGE=$SDK_ARM_REF"
build arm64
FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "== local manifest list $LIST (local only)"
podman manifest create "$LIST"
for a in amd64 arm64; do podman manifest add "$LIST" "containers-storage:$LIST-$a"; done
podman manifest inspect "$LIST" > "$WORK/list.json"
jq -e '[.manifests[] | .platform.os + "/" + .platform.architecture] | sort == ["linux/amd64", "linux/arm64"]' "$WORK/list.json" >/dev/null || { echo "list is not exactly linux/amd64 + linux/arm64" >&2; exit 1; }
jq -r '.mediaType, (.manifests[] | "  \(.platform.os)/\(.platform.architecture) \(.digest) \(.mediaType)")' "$WORK/list.json"
LIST_DIGEST="sha256:$(podman manifest inspect "$LIST" | shasum -a 256 | cut -d' ' -f1)"
echo "list: local manifest JSON sha256 $LIST_DIGEST (podman re-serialises; the registry list digest is fixed only at push)"

: > "$WORK/record-arch.txt"
for a in amd64 arm64; do
  IMG="$LIST-$a"; ID=$(podman image inspect "$IMG" --format '{{.Id}}')
  MD=$(jq -r --arg a "$a" '.manifests[] | select(.platform.architecture == $a) | .digest' "$WORK/list.json")
  echo "== inspect desk $a (image id $ID, list child $MD)"
  podman image inspect "$IMG" --format 'arch={{.Architecture}} os={{.Os}} user={{.Config.User}} ports={{.Config.ExposedPorts}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} workdir={{.Config.WorkingDir}}
env={{.Config.Env}}
labels={{.Config.Labels}}'
  [ "$(podman image inspect "$IMG" --format '{{.Architecture}}/{{.Os}}')" = "$a/linux" ] || { echo "image is not linux/$a" >&2; exit 1; }
  [ "$(podman image inspect "$IMG" --format '{{.Config.User}}')" = 65532 ] || { echo "image user is not 65532 (ci/image.sh)" >&2; exit 1; }
  [ "$(podman image inspect "$IMG" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$FULL" ] || { echo "revision label mismatch" >&2; exit 1; }
  if RTS=$(podman run --rm --network none --read-only --platform "linux/$a" --entrypoint dotnet "$IMG" --list-runtimes 2>&1); then
    echo "runtime readback $a (network none, read-only): $(printf '%s' "$RTS" | tr '\n' ';')"
  else echo "runtime readback $a FAILED (informational; amd64 runs under qemu on this arm64 VM): $(printf '%s' "$RTS" | tail -2 | tr '\n' ';')"; fi
  podman save --format oci-archive -o "$WORK/desk-$a-oci.tar" "$IMG"
  OCI_DIGEST=$(tar -xOf "$WORK/desk-$a-oci.tar" index.json | jq -r 'if (.manifests | length) == 1 then .manifests[0].digest else empty end')
  [ -n "$OCI_DIGEST" ] || { echo "oci archive index.json has not exactly one manifest" >&2; exit 1; }
  echo "oci-archive manifest digest $a $OCI_DIGEST"
  echo "== SBOM $a (syft $SYFT_VERSION, CycloneDX JSON)"
  "$MISE" x "aqua:anchore/syft@$SYFT_VERSION" -- syft scan "oci-archive:$WORK/desk-$a-oci.tar" -q -o "cyclonedx-json=$WORK/sbom-$a.cdx.json"
  jq -e '.bomFormat == "CycloneDX" and ((.components // []) | length) > 0' "$WORK/sbom-$a.cdx.json" >/dev/null || { echo "SBOM empty or not CycloneDX" >&2; exit 1; }
  echo "sbom components=$(jq '.components | length' "$WORK/sbom-$a.cdx.json") specVersion=$(jq -r .specVersion "$WORK/sbom-$a.cdx.json")"
  echo "sbom dotnet runtime components: $(jq -r '[.components[] | select(.name | test("^(Microsoft\\.NETCore\\.App|Microsoft\\.AspNetCore\\.App|dotnet|aspnetcore-runtime|dotnet-runtime)"; "i")) | .name + "@" + (.version // "?")] | unique | join(", ")' "$WORK/sbom-$a.cdx.json")"
  echo "== grype $GRYPE_VERSION on the $a SBOM"
  "$MISE" x "aqua:anchore/grype@$GRYPE_VERSION" -- grype "sbom:$WORK/sbom-$a.cdx.json" -q -o json > "$WORK/grype-$a.json"
  echo "grype db: $(jq -r '.descriptor.db | "\(.built // .status.built // "?") schema \(.schemaVersion // .status.schemaVersion // "?")"' "$WORK/grype-$a.json" 2>/dev/null)"
  jq -r '[.matches[] | .vulnerability.severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ") | "grype matches by severity: " + (if . == "" then "none" else . end)' "$WORK/grype-$a.json"
  jq -r '.matches[] | "  \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$WORK/grype-$a.json" | sort -u | head -60
  echo "-- gate hits $a (Critical, or High with a fix), all listed"
  jq -r "$GATE_SEL"' | "  GATE \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$WORK/grype-$a.json" | sort -u
  HITS=$(jq "[$GATE_SEL] | length" "$WORK/grype-$a.json")
  OUT015=$(jq --arg id "$GX_ID" --arg pkg "$GX_PKG" --arg ver "$GX_VER" --arg fix "$GX_FIX" "[$GATE_SEL | select($GATE_EXC | not)] | length" "$WORK/grype-$a.json")
  echo "gate hits $a: $HITS; outside ar-015: $OUT015 (desk gate has no exception)"
  echo "-- repo cross-check: python3 -I ci/image-gate.py (of $S7)"
  if python3 -I "$WORK/src/ci/image-gate.py" "$WORK/grype-$a.json"; then REPOGATE=pass; else REPOGATE=FAIL; fi
  echo "repo image-gate $a: $REPOGATE"
  printf '%s\n' "image_id_$a=$ID" "list_child_$a=$MD" "oci_manifest_digest_$a=$OCI_DIGEST" "grype_matches_$a=$(jq '.matches | length' "$WORK/grype-$a.json")" \
    "gate_hits_$a=$HITS" "gate_outside_ar015_$a=$OUT015" "repo_image_gate_$a=$REPOGATE" >> "$WORK/record-arch.txt"
  free "after scan $a"
done
cp "$WORK/sbom-amd64.cdx.json" "$SBOM_AMD"; cp "$WORK/sbom-arm64.cdx.json" "$SBOM_ARM"
cp "$WORK/grype-amd64.json" "$GRYPE_AMD"; cp "$WORK/grype-arm64.json" "$GRYPE_ARM"
{ echo "commit=$FULL"; echo "list_local=$LIST"; echo "list_local_json_sha256=$LIST_DIGEST"; cat "$WORK/record-arch.txt"
  echo "sdk_index=$SDK"; echo "sdk_used_amd64=$SDK_ARM_REF (arm64 child, native, cross-publish linux-x64)"; echo "sdk_used_arm64=$SDK (resolves to $SDK_ARM)"
  echo "runtime_index=$RT"; echo "runtime_child_amd64=$RT_AMD"; echo "runtime_child_arm64=$RT_ARM"
  echo "started=$STARTED"; echo "finished_build=$FINISHED"; echo "builder=podman $(podman version --format '{{.Client.Version}}') on $(hostname -s), machine $MACHINE"
  echo "syft=$SYFT_VERSION grype=$GRYPE_VERSION"
  for f in "$SBOM_AMD" "$SBOM_ARM" "$GRYPE_AMD" "$GRYPE_ARM"; do echo "$(basename "$f") sha256 $(shasum -a 256 "$f" | cut -d' ' -f1)"; done; } > "$RECORD"
echo "== RESULT (build + scan only, unsigned, not pushed)"; cat "$RECORD"
G=$(grep -c '^gate_outside_ar015_.*=0$' "$RECORD")
[ "$G" = 2 ] && echo "BUILD+SCAN OK (gate PASS both arches)" || { echo "BUILD done, GATE FAIL (see gate hits above)"; exit 1; }
