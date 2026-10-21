#!/usr/bin/env bash
# chg-2026-10-21-012: copy of chg-2026-10-20-001-dotnet-desk-0cc9bc7-build-sign.sh (sha256 a761b6d2..e9e0) for the .NET desk
# rebuild from mypka-bot/passkey-point-dotnet main 7e090d0 (MSAL 4.91.1 and the 2026-10-21 dependency-currency bumps).
# Changes: script name in usage + builder.id, actor line, and the build-baseline hit count reads scan-*.real (the
# file key_header_scan writes; the copied line read a never-written .hits). Gate, C1, C2, F3, key retrieval unchanged.
# chg-2026-10-20-001 (logged under chg-2026-10-12-004, tsk-2026-10-13-049 criterion 3): build the .NET Passkey Point `desk`
# image for linux/amd64 from one commit of mypka-bot/passkey-point-dotnet, then (separate run, after review) push it to
# forge.bluejungle.net/palamedes/passkey-point-dotnet, sign it by digest with the Passkey cosign key, attest an SLSA v1
# provenance predicate and verify against the out-of-band public key. Copied from chg-2026-10-15-007-preflight-build-sign.sh
# (Argus F1-F4); key retrieval unchanged. Added for the 2026-10-19T20:43:47Z ruling on chg-2026-10-06-008:
#   C1  runDetails.builder.id names the build host (hostname -s at run time) and the podman machine + VM type; the
#       verify-attestation output prints builder.id and the run fails unless it contains the host.
#   C2  after the key file is removed, a logged scan of $HOME/Code, the scratch dir and $TMPDIR for SIGSTORE/COSIGN
#       private-key PEM headers; any hit fails the run.
# Never prints the key, its password or the token.
#
#   PP_SCRATCH=<dir> hack/ops/chg-2026-10-21-012-dotnet-desk-7e090d0-build-sign.sh build <source-git-dir> <full-commit> <log> <evidence-dir>
#   PP_SCRATCH=<dir> hack/ops/chg-2026-10-21-012-dotnet-desk-7e090d0-build-sign.sh sign  <source-git-dir> <full-commit> <log> <evidence-dir>
#
# build: git archive -> podman build --target desk (no push, no key) -> image inspect -> OCI-layout manifest digest ->
#        CycloneDX SBOM (syft) -> grype gate (Critical, or High with a fix, fails; ci/run.sh step 10) -> a baseline C2
#        scan -> write-once BUILD-desk-<short>.txt record + sbom-desk-<short>.cdx.json in <evidence-dir>.
# sign:  needs that record; refuses unless the local image localhost/passkey-point-dotnet:desk-<short> has the recorded
#        image id and revision label; C2 scan (refuses on a hit) -> push -> provenance (C1) -> key via Connect -> sign + attest -> key removal -> C2
#        scan -> verify + verify-attestation (C1 check) -> DIGESTS-desk-<short>.txt + prov-desk-<short>.json.
set -euo pipefail
MODE=${1:?mode build|sign}; SRC_GIT=${2:?source git dir}; COMMIT=${3:?commit}; LOG=${4:?log file}; EVD=${5:?evidence dir}
case "$MODE" in build|sign) ;; *) echo "mode must be build or sign" >&2; exit 64 ;; esac
[ ! -e "$LOG" ] || { echo "log $LOG exists; write-once, refusing" >&2; exit 64; }
[ -d "$EVD" ] || { echo "evidence dir $EVD missing" >&2; exit 64; }
S7=${COMMIT:0:7}
RECORD="$EVD/BUILD-desk-$S7.txt"; SBOM_OUT="$EVD/sbom-desk-$S7.cdx.json"
DIGESTS="$EVD/DIGESTS-desk-$S7.txt"; PROV_OUT="$EVD/prov-desk-$S7.json"
if [ "$MODE" = build ]; then
  [ ! -e "$RECORD" ] && [ ! -e "$SBOM_OUT" ] || { echo "$RECORD or $SBOM_OUT exists; write-once, refusing" >&2; exit 64; }
else
  [ -f "$RECORD" ] && [ -f "$SBOM_OUT" ] || { echo "sign needs $RECORD and $SBOM_OUT from a build run" >&2; exit 64; }
  [ ! -e "$DIGESTS" ] && [ ! -e "$PROV_OUT" ] || { echo "$DIGESTS or $PROV_OUT exists; write-once, refusing" >&2; exit 64; }
fi
umask 022
exec > >(tee "$LOG") 2>&1

SCRATCH=${PP_SCRATCH:?scratch dir}
TMPD=${TMPDIR:?TMPDIR unset}
export PATH="$HOME/.local/opt/podman-6.1.3/bin:$HOME/.local/share/mise/installs/cosign/3.1.3:$(ls -d "$HOME"/.local/share/mise/installs/kubectl/1.36*/ | head -1):$PATH"
[ -f "${PP_CONTAINERS_CONF:-}" ] && export CONTAINERS_CONF="$PP_CONTAINERS_CONF"
export GODEBUG=netdns=go KUBECONFIG="$HOME/.kube/config"
MISE=/opt/homebrew/bin/mise; SYFT_VERSION=1.54.1; GRYPE_VERSION=0.120.0
TS_REPO="$HOME/Code/homelab-migration/passkey-point-passkeys"
CFG="$TS_REPO/scripts/release/signing-config.no-tlog.json"
CFG_SHA=6a7a661ba892f8ef2fad0929704287187b4dc302ae07176f524669d1d98e4912  # F3: pinned no-tlog signing config (Argus 2026-10-19T22:53:08Z)
cfg_check() {  # F3: refuse unless the no-tlog signing config is the pinned file and has no Rekor tlog URL
  [ "$(shasum -a 256 "$CFG" | cut -d' ' -f1)" = "$CFG_SHA" ] || { echo "F3: $CFG sha256 is not $CFG_SHA; refusing" >&2; exit 1; }
  jq -e '.rekorTlogUrls|length==0' "$CFG" >/dev/null || { echo "F3: $CFG has rekorTlogUrls; refusing" >&2; exit 1; }
  echo "F3: signing config $CFG sha256 $CFG_SHA (pinned), rekorTlogUrls empty"
}
OOB="$HOME/Code/homelab-migration/passkey-point-cosign.pub"
OOB_DER_SHA=6ad2a90a972cf633d34ac03640220cf0790d59e1e0e238294fa2760d31ad66e9
REPO=forge.bluejungle.net/palamedes/passkey-point-dotnet
REPO_URL=https://forge.bluejungle.net/mypka-bot/passkey-point-dotnet
LOCAL="localhost/passkey-point-dotnet:desk-$S7"
AUTHDIR="$SCRATCH/regauth-mackdev"; AUTH="$AUTHDIR/auth.json"
OP_ITEM=${PP_COSIGN_OP_ITEM:-op://home-infra/passkey-point-cosign}
unset COSIGN_PRIVATE_KEY COSIGN_PASSWORD PP_KEY PP_PW PP_TOK PP_ITEM
WORK=$(mktemp -d "$SCRATCH/pp-dotnet-desk-build.XXXXXX")
KWORK=""; KEYFILE=""
PF=""; KEY_FETCHED=0; SCAN_DONE=0
# >>> c2-trap (this block is also loaded by hack/ops/test-chg-2026-10-20-001-trap.sh)
# C2: a cosign/sigstore private-key PEM header (also the ENCRYPTED forms). The pattern text does not match itself, so
# this script and its log are no hits. SSH/TLS keys (OPENSSH/RSA/EC PRIVATE KEY) are not matched by design (Argus C2).
HDR_RE='-----BEGIN [A-Z ]*(SIGSTORE|COSIGN) PRIVATE KEY-----'
# C2 rule v2 (Argus qa_failed 2026-10-19T22:53:08Z, F2): classifier copied verbatim from Argus's tested c2cls.pl. It is a
# program of THIS script; each candidate file is only its stdin (data), never executed. Prints "<real> <synthetic>":
# total header matches minus whole blocks BEGIN S FAKEKEYBODY S END (S = space/tab/CR/LF or backslash-escaped n/r).
read -r -d '' C2CLS <<'PERL' || true
local $/; my $d = <STDIN> // '';
my $H = qr/-----BEGIN [A-Z ]*(?:SIGSTORE|COSIGN) PRIVATE KEY-----/;
my $E = qr/-----END [A-Z ]*(?:SIGSTORE|COSIGN) PRIVATE KEY-----/;
my $S = qr/(?:[ \t\r\n]|\\+[nr])*/;
my $t = () = $d =~ /$H/g;
my $f = () = $d =~ /$H${S}FAKEKEYBODY${S}$E/g;
print $t - $f, " ", $f, "\n";
PERL
key_header_scan() {  # $1 = label; returns 0 only when no file holds a real (non-synthetic) header
  local _e=0; case $- in *e*) _e=1 ;; esac; set +e
  local cand="$WORK/scan-$1.cand" errs="$WORK/scan-$1.err" real="$WORK/scan-$1.real" syn="$WORK/scan-$1.syn"
  local rc e f out r s nreal nsyn
  echo "-- C2 key-header scan ($1) $(date -u +%Y-%m-%dT%H:%M:%SZ): grep -rIlE -- '$HDR_RE' $HOME/Code $SCRATCH $TMPD, then rule v2 per file"
  grep -rIlE -- "$HDR_RE" "$HOME/Code" "$SCRATCH" "$TMPD" > "$cand" 2> "$errs"; rc=$?
  : > "$real"; : > "$syn"
  while IFS= read -r f; do
    if [ ! -e "$f" ]; then echo "   vanished before classification (not counted): $f"; continue; fi
    out=$(perl -e "$C2CLS" < "$f" 2>/dev/null)
    case "$out" in [0-9]*' '[0-9]*) r=${out%% *}; s=${out##* } ;; *) r=1; s=0; echo "   classifier failed, counted as real: $f" ;; esac
    [ "$r" -gt 0 ] && echo "$f real=$r synthetic=$s" >> "$real"
    [ "$s" -gt 0 ] && echo "$f synthetic=$s" >> "$syn"
  done < "$cand"
  nreal=$(wc -l < "$real" | tr -d ' '); nsyn=$(awk -F'synthetic=' '{n += $2} END {print n + 0}' "$syn"); e=$(wc -l < "$errs" | tr -d ' ')
  echo "   grep rc=$rc candidate files=$(wc -l < "$cand" | tr -d ' ') real-hit files=$nreal synthetic blocks=$nsyn unreadable/vanished-path messages=$e (paths only, never content)"
  sed -n '1,20s/^/   REAL: /p' "$real"; sed -n '1,30s/^/   synthetic (logged, not a fail): /p' "$syn"; sed -n '1,5s/^/   err: /p' "$errs"
  echo "   C2 scan ($1) done $(date -u +%Y-%m-%dT%H:%M:%SZ): real=$nreal synthetic=$nsyn, $([ "$nreal" = 0 ] && echo PASS || echo FAIL)"
  [ "$_e" = 1 ] && set -e
  [ "$nreal" = 0 ]
}
cleanup() {
  rc=$?
  set +e
  [ -z "$PF" ] || kill "$PF" 2>/dev/null || true
  if [ -n "$KWORK" ]; then
    rm -f "${KEYFILE:?}"
    if [ -d "$AUTHDIR" ]; then ( umask 077; printf '{"auths":{}}\n' > "$AUTH" ); echo "auth file reset: $(cat "$AUTH")"; fi
    if grep -rIl 'PRIVATE KEY-----' "${KWORK:?}" >/dev/null 2>&1; then echo "KEY MATERIAL LEFT in $KWORK" >&2; rc=99; fi
    find "${KWORK:?}" -mindepth 1 -delete; rmdir "${KWORK:?}"
    if [ "$KEY_FETCHED" = 1 ] && [ "$SCAN_DONE" = 0 ]; then key_header_scan trap || rc=99; fi
  fi
  find "${WORK:?}" -mindepth 1 -delete 2>/dev/null; rmdir "${WORK:?}" 2>/dev/null || true
  echo "EXIT $rc $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit "$rc"
}
# <<< c2-trap
trap cleanup EXIT

FULL=$(git -C "$SRC_GIT" rev-parse --verify "$COMMIT^{commit}")
[ "$FULL" = "$COMMIT" ] || { echo "commit mismatch $FULL vs $COMMIT" >&2; exit 1; }
SHORT=${FULL:0:7}
HOST_S=$(hostname -s); [ -n "$HOST_S" ] || { echo "hostname -s is empty; refusing (C1)" >&2; exit 1; }
MACHINE=$(podman machine list --format '{{.Name}}|{{.VMType}}|{{.Default}}' | awk -F'|' '$3 == "true" {sub(/\*$/, "", $1); print $1 " " $2}')
[ "$(printf '%s\n' "$MACHINE" | grep -c .)" = 1 ] || { echo "not exactly one default podman machine; refusing (C1)" >&2; exit 1; }
PODMAN_V=$(podman version --format '{{.Client.Version}}')
BUILDER="podman $PODMAN_V on $HOST_S ($(uname -s | tr A-Z a-z)/$(uname -m)), podman machine $MACHINE, linux/amd64 (build stage native linux/arm64, cross-publish linux-x64)"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "== chg-2026-10-21-012 .NET desk $MODE, started $STARTED by k8s-engineer (Heph) for Atlas"
echo "source $REPO_URL commit $FULL (git archive, clean tree)"
echo "host $HOST_S; podman machine $MACHINE"
echo "tools: $(podman version --format 'podman client {{.Client.Version}} server {{.Server.Version}}'); $(cosign version 2>&1 | sed -n 's/^GitVersion: *//p' | sed 's/^/cosign /')"
echo "AGR-109: tests are the gate (Passkey dev tenant, AGR-087/098); no deploy, no git push"
echo "-- C2 pattern self-check (stdin only, no file): sigstore/cosign/encrypted forms must match, OPENSSH must not"
printf -- '-----BEGIN ENCRYPTED SIG%sSTORE PRIVATE KEY-----\n' '' | grep -qE -- "$HDR_RE"
printf -- '-----BEGIN SIG%sSTORE PRIVATE KEY-----\n' '' | grep -qE -- "$HDR_RE"
printf -- '-----BEGIN ENCRYPTED COS%sIGN PRIVATE KEY-----\n' '' | grep -qE -- "$HDR_RE"
if printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' | grep -qE -- "$HDR_RE"; then echo "C2 pattern matches an SSH key header; refusing" >&2; exit 1; fi
echo "   pattern self-check OK"

rec() { sed -n "s/^$1=//p" "$RECORD" | head -1; }

if [ "$MODE" = build ]; then
  cfg_check
  mkdir "$WORK/src"; git -C "$SRC_GIT" archive "$FULL" | tar -x -C "$WORK/src"
  SDK=$(sed -n 's/^ARG SDK_IMAGE=//p' "$WORK/src/Containerfile" | head -1)
  RT=$(sed -n 's/^ARG RUNTIME_IMAGE=//p' "$WORK/src/Containerfile" | head -1)
  echo "base (as committed): sdk $SDK runtime $RT"
  # Build-stage override (as chg-2026-10-12-004, 2026-10-14): dotnet under qemu amd64 emulation aborts (signal 6) on this
  # applehv VM (Rosetta off). PP_SDK_ARM64_CHILD pins the build stage to the linux/arm64 child of the SAME pinned SDK index,
  # so it runs natively and publishes for linux-x64 (TARGETARCH=amd64). The runtime stage stays the pinned aspnet index.
  BUILD_ARGS=(); SDK_USED=$SDK
  if [ -n "${PP_SDK_ARM64_CHILD:-}" ]; then
    CRANE=$(ls -d "$HOME"/.local/share/mise/installs/aqua-google-go-containerregistry/*/ | head -1)crane
    "$CRANE" manifest "$SDK" | jq -e --arg d "$PP_SDK_ARM64_CHILD" '[.manifests[] | select(.digest == $d and .platform.architecture == "arm64" and .platform.os == "linux")] | length == 1' >/dev/null \
      || { echo "PP_SDK_ARM64_CHILD $PP_SDK_ARM64_CHILD is not the linux/arm64 child of $SDK; refusing" >&2; exit 1; }
    SDK_USED="${SDK%%@*}@$PP_SDK_ARM64_CHILD"
    BUILD_ARGS+=(--build-arg "SDK_IMAGE=$SDK_USED")
    echo "build stage: SDK_IMAGE=$SDK_USED (verified linux/arm64 child of the pinned index; native, cross-publish linux-x64)"
  fi
  echo "== build desk (linux/amd64)"
  podman build --platform linux/amd64 --target desk ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --label "org.opencontainers.image.revision=$FULL" \
    --label "org.opencontainers.image.source=$REPO_URL" -t "$LOCAL" -f "$WORK/src/Containerfile" "$WORK/src"
  FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "== inspect desk"
  podman image inspect "$LOCAL" --format \
    'id={{.Id}} arch={{.Architecture}} os={{.Os}} user={{.Config.User}} ports={{.Config.ExposedPorts}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} workdir={{.Config.WorkingDir}}
env={{.Config.Env}}
labels={{.Config.Labels}}'
  IMAGE_ID=$(podman image inspect "$LOCAL" --format '{{.Id}}')
  [ "$(podman image inspect "$LOCAL" --format '{{.Architecture}}/{{.Os}}')" = amd64/linux ] || { echo "image is not linux/amd64" >&2; exit 1; }
  [ "$(podman image inspect "$LOCAL" --format '{{.Config.User}}')" = 1654 ] || { echo "image user is not 1654" >&2; exit 1; }
  echo "== OCI layout (local only, no registry): manifest digest; the registry digest is fixed at push in the sign run"
  # podman remote (machine) push supports only docker://, so save an OCI archive and read the manifest digest from index.json.
  podman save --format oci-archive -o "$WORK/desk-oci.tar" "$LOCAL"
  OCI_DIGEST=$(tar -xOf "$WORK/desk-oci.tar" index.json | jq -r 'if (.manifests | length) == 1 then .manifests[0].digest else empty end')
  [ -n "$OCI_DIGEST" ] || { echo "oci archive index.json has not exactly one manifest" >&2; exit 1; }
  echo "oci-archive manifest digest $OCI_DIGEST"
  echo "== SBOM (syft $SYFT_VERSION, CycloneDX JSON, INF-SC-03)"
  "$MISE" x "aqua:anchore/syft@$SYFT_VERSION" -- syft scan "oci-archive:$WORK/desk-oci.tar" -q -o "cyclonedx-json=$WORK/sbom.cdx.json"
  jq -e '.bomFormat == "CycloneDX" and ((.components // []) | length) > 0' "$WORK/sbom.cdx.json" >/dev/null || { echo "SBOM empty or not CycloneDX" >&2; exit 1; }
  echo "sbom components=$(jq '.components | length' "$WORK/sbom.cdx.json") specVersion=$(jq -r .specVersion "$WORK/sbom.cdx.json")"
  echo "== grype $GRYPE_VERSION on the SBOM (fails on a Critical, or a High with a fix; ci/run.sh step 10)"
  "$MISE" x "aqua:anchore/grype@$GRYPE_VERSION" -- grype "sbom:$WORK/sbom.cdx.json" -q -o json > "$WORK/grype.json"
  jq -r '[.matches[] | .vulnerability.severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ") | "grype matches by severity: " + (if . == "" then "none" else . end)' "$WORK/grype.json"
  jq -r '.matches[] | "  \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$WORK/grype.json" | sort | head -40
  GATE=$(jq '[.matches[] | select(.vulnerability.severity == "Critical" or (.vulnerability.severity == "High" and .vulnerability.fix.state == "fixed"))] | length' "$WORK/grype.json")
  [ "$GATE" = 0 ] || { echo "grype gate: $GATE Critical or fixable High; refusing" >&2; exit 1; }
  echo "grype gate PASS"
  # Informational here (no key in a build run): the sign run repeats this scan before the key fetch and refuses on a hit.
  if key_header_scan build-baseline; then BASE_HITS=0; else BASE_HITS=$(wc -l < "$WORK/scan-build-baseline.real" | tr -d ' ')
    echo "NOTE: $BASE_HITS pre-existing key-header hit(s) (paths above); a sign run refuses until they are gone"; fi
  cp "$WORK/sbom.cdx.json" "$SBOM_OUT"
  { echo "commit=$FULL"; echo "image_local=$LOCAL"; echo "image_id=$IMAGE_ID"; echo "oci_manifest_digest=$OCI_DIGEST"
    echo "sdk_index=$SDK"; echo "sdk_used=$SDK_USED"; echo "runtime_index=$RT"; echo "started=$STARTED"; echo "finished=$FINISHED"
    echo "builder=$BUILDER"; echo "sbom_sha256=$(shasum -a 256 "$SBOM_OUT" | cut -d' ' -f1)"
    echo "grype_matches=$(jq '.matches | length' "$WORK/grype.json")"; echo "c2_build_baseline_hits=$BASE_HITS"; } > "$RECORD"
  echo "== RESULT (build, unsigned, not pushed)"; cat "$RECORD"
  echo "BUILD OK"
  exit 0
fi

# ---- sign ----
[ "$(rec commit)" = "$FULL" ] || { echo "record commit $(rec commit) is not $FULL" >&2; exit 1; }
IMAGE_ID=$(rec image_id); SDK=$(rec sdk_index); SDK_USED=$(rec sdk_used); RT=$(rec runtime_index)
B_STARTED=$(rec started); B_FINISHED=$(rec finished); B_BUILDER=$(rec builder); SBOM_SHA=$(rec sbom_sha256)
[ "$(podman image inspect "$LOCAL" --format '{{.Id}}')" = "$IMAGE_ID" ] || { echo "local $LOCAL is not the recorded image $IMAGE_ID; refusing" >&2; exit 1; }
[ "$(podman image inspect "$LOCAL" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$FULL" ] || { echo "revision label mismatch" >&2; exit 1; }
[ "$(shasum -a 256 "$SBOM_OUT" | cut -d' ' -f1)" = "$SBOM_SHA" ] || { echo "SBOM file changed since the build record" >&2; exit 1; }
case "$B_BUILDER" in *" on $HOST_S ("*", podman machine $MACHINE,"*) ;; *) echo "build record host/machine is not this host $HOST_S / $MACHINE; refusing (C1)" >&2; exit 1 ;; esac
echo "local image $LOCAL id $IMAGE_ID = build record $RECORD; built on this host/machine"
key_header_scan before-key-fetch || { echo "C2: key-header hits before any key fetch; the after-removal scan could not show 0; refusing" >&2; exit 1; }

KWORK=$(mktemp -d "$SCRATCH/pp-dotnet-desk-sign.XXXXXX"); chmod 700 "$KWORK"
KEYFILE="$KWORK/cosign.key"
echo "== registry auth (palamedes, token from ~/.config/pka/mack-dev-forge-package, not printed)"
( umask 077; mkdir -p "$AUTHDIR"; tok=$(cat "$HOME/.config/pka/mack-dev-forge-package"); b64=$(printf 'palamedes:%s' "$tok" | base64 | tr -d '\n')
  printf '{"auths":{"forge.bluejungle.net":{"auth":"%s"}}}\n' "$b64" > "$AUTH" )
export REGISTRY_AUTH_FILE="$AUTH"
mkdir "$KWORK/docker"; ln -s "$AUTH" "$KWORK/docker/config.json"; export DOCKER_CONFIG="$KWORK/docker"

declare -a REFS=()
t=desk
podman push --digestfile "$WORK/digest-$t" "$LOCAL" "docker://$REPO:$t-$SHORT"
d=$(cat "$WORK/digest-$t"); echo "pushed $REPO:$t-$SHORT $d (build-run oci-archive digest $(rec oci_manifest_digest))"
REFS+=("$t=$REPO@$d")

echo "== provenance predicate (SLSA v1 shape of provenance.ts; built here with jq). C1: builder.id names host + machine"
for pair in "${REFS[@]}"; do
  t=${pair%%=*}
  jq -n --arg t "$t" --arg c "$FULL" --arg s "$SHORT" --arg u "$REPO_URL" --arg sdk "$SDK" --arg sdku "$SDK_USED" --arg rt "$RT" \
    --arg st "$B_STARTED" --arg fi "$B_FINISHED" --arg b "$B_BUILDER" --arg sb "$SBOM_SHA" --arg sbn "$(basename "$SBOM_OUT")" '{
    buildDefinition: {
      buildType: "https://forge.bluejungle.net/mypka-bot/passkey-point-dotnet/Containerfile@v1",
      externalParameters: {target: $t, commit: $c, tagSuffix: $s, platforms: ["linux/amd64"]},
      internalParameters: {buildArgs: {SDK_IMAGE: $sdku}},
      resolvedDependencies: [
        {uri: ("git+" + $u + "@" + $c), digest: {gitCommit: $c}},
        {uri: "pkg:docker/mcr.microsoft.com/dotnet/sdk", name: $sdk, digest: {sha256: ($sdk | split("@sha256:")[1])}},
        {uri: "pkg:docker/mcr.microsoft.com/dotnet/sdk?arch=arm64", name: $sdku, digest: {sha256: ($sdku | split("@sha256:")[1])}, annotations: {role: "build stage actually run (native arm64, cross-publish linux-x64)"}},
        {uri: "pkg:docker/mcr.microsoft.com/dotnet/aspnet", name: $rt, digest: {sha256: ($rt | split("@sha256:")[1])}}]},
    runDetails: {builder: {id: ("vdhinfra hack/ops/chg-2026-10-21-012-dotnet-desk-7e090d0-build-sign.sh (" + $b + ")")},
      metadata: {invocationId: (($c[0:7]) + "-" + $s + "-" + $t), startedOn: $st, finishedOn: $fi},
      byproducts: [{name: $sbn, mediaType: "application/vnd.cyclonedx+json", digest: {sha256: $sb}}]}}' > "$WORK/prov-$t.json"
  echo "prov-$t.json sha256 $(shasum -a 256 "$WORK/prov-$t.json" | cut -d' ' -f1) builder.id: $(jq -r .runDetails.builder.id "$WORK/prov-$t.json")"
done

cfg_check
echo "== cosign key via 1Password Connect (PP_COSIGN_SOURCE=connect path of sign-images.sh; values never printed)"
[ "$(openssl pkey -pubin -in "$OOB" -outform DER | shasum -a 256 | cut -d' ' -f1)" = "$OOB_DER_SHA" ] \
  || { echo "out-of-band public key DER hash mismatch; refusing" >&2; exit 1; }
ref=${OP_ITEM#op://}; VAULT=${ref%%/*}; ITEM=${ref#*/}
NS=security; SVC=onepassword-connect; SEC=onepassword-connect-secret
kubectl -n "$NS" port-forward --address 127.0.0.1 "svc/$SVC" :80 > "$KWORK/port-forward.log" 2>&1 &
PF=$!
PORT=""
for _ in $(seq 1 30); do
  PORT=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' "$KWORK/port-forward.log" | head -n 1)
  [ -n "$PORT" ] && break
  kill -0 "$PF" 2>/dev/null || break
  sleep 0.5
done
[ -n "$PORT" ] || { echo "kubectl port-forward to $NS/$SVC did not start" >&2; exit 1; }
PP_TOK=$(kubectl -n "$NS" get secret "$SEC" -o jsonpath='{.data.token}' | base64 -d)
[ -n "$PP_TOK" ] || { echo "no Connect token in $NS/$SEC" >&2; exit 1; }
cget() { printf 'Authorization: Bearer %s\n' "$PP_TOK" | curl -fsS --max-time 20 -H @- "http://127.0.0.1:$PORT$1"; }
VID=$(cget "/v1/vaults?filter=name%20eq%20%22$VAULT%22" | jq -r --arg v "$VAULT" '[.[] | select(.name == $v)] | if length == 1 then .[0].id else empty end')
[ -n "$VID" ] || { echo "vault $VAULT: not exactly one through Connect" >&2; exit 1; }
IID=$(cget "/v1/vaults/$VID/items?filter=title%20eq%20%22$ITEM%22" | jq -r --arg t "$ITEM" '[.[] | select(.title == $t)] | if length == 1 then .[0].id else empty end')
[ -n "$IID" ] || { echo "item $VAULT/$ITEM: not exactly one through Connect" >&2; exit 1; }
KEY_FETCHED=1
PP_ITEM=$(cget "/v1/vaults/$VID/items/$IID")
unset PP_TOK
kill "$PF" 2>/dev/null || true; wait "$PF" 2>/dev/null || true; PF=""
( umask 077; printf '%s' "$PP_ITEM" | jq -r '[.fields[] | select(.label == "private-key")] | if length == 1 then .[0].value else empty end' > "$KEYFILE" )
PP_PW=$(printf '%s' "$PP_ITEM" | jq -r '[.fields[] | select(.label == "password")] | if length == 1 then .[0].value else empty end')
unset PP_ITEM
grep -q 'PRIVATE KEY-----' "$KEYFILE" && [ -n "$PP_PW" ] || { echo "item $VAULT/$ITEM: no single private-key and password field" >&2; exit 1; }
[ "$(stat -f '%Lp' "$KEYFILE")" = 600 ] || { echo "key file is not 0600; refusing" >&2; exit 1; }
signer() { COSIGN_PASSWORD="$PP_PW" cosign "$@"; }
signer public-key --key "$KEYFILE" > "$KWORK/derived.pub"
cmp -s <(grep -v '^-----' "$KWORK/derived.pub") <(grep -v '^-----' "$OOB") \
  || { echo "the 1Password key does not match the out-of-band key $OOB; refusing to sign" >&2; exit 1; }
echo "derived public key matches out-of-band key (DER sha256 $OOB_DER_SHA)"

for pair in "${REFS[@]}"; do
  t=${pair%%=*}; r=${pair#*=}
  echo "== sign + attest $t $r"
  signer sign --yes --recursive --key "$KEYFILE" --signing-config "$CFG" "$r" 2>&1 | tee "$KWORK/sign-$t.log"
  signer attest --yes --key "$KEYFILE" --signing-config "$CFG" --type slsaprovenance1 \
    --predicate "$WORK/prov-$t.json" "$r" 2>&1 | tee -a "$KWORK/sign-$t.log"
  if grep -qi 'tlog entry created' "$KWORK/sign-$t.log"; then echo "cosign reports a transparency-log upload for $t; refusing" >&2; exit 1; fi
done
unset PP_PW
rm -f "${KEYFILE:?}"
[ ! -e "$KEYFILE" ] || { echo "the key file could not be removed: $KEYFILE" >&2; exit 1; }
if grep -rIl 'PRIVATE KEY-----' "$KWORK" >/dev/null 2>&1; then echo "key material left in $KWORK" >&2; exit 1; fi
echo "== key file removed; no key material left in the run's temp directory"
SCAN_DONE=1
key_header_scan after-key-removal || { echo "C2: key-header hits after the key file was removed; refusing" >&2; exit 99; }

echo "== verify against the out-of-band key $OOB"
for pair in "${REFS[@]}"; do
  t=${pair%%=*}; r=${pair#*=}
  echo "-- cosign verify $r"
  cosign verify --key "$OOB" --insecure-ignore-tlog "$r" > "$WORK/verify-$t.json"
  jq -c '.[] | {ref: .critical.identity["docker-reference"], digest: .critical.image["docker-manifest-digest"], type: .critical.type}' "$WORK/verify-$t.json"
  echo "-- cosign verify-attestation --type slsaprovenance1 $r"
  cosign verify-attestation --key "$OOB" --insecure-ignore-tlog --type slsaprovenance1 "$r" > "$WORK/att-$t.json"
  jq -r '.payload' "$WORK/att-$t.json" | while read -r p; do printf '%s' "$p" | base64 -d | jq -c '{subject: .subject, commit: .predicate.buildDefinition.externalParameters.commit, target: .predicate.buildDefinition.externalParameters.target, builder_id: .predicate.runDetails.builder.id}'; done
  jq -r '.payload' "$WORK/att-$t.json" | while read -r p; do printf '%s' "$p" | base64 -d | jq -r '.predicate.runDetails.builder.id'; done > "$WORK/builder-ids-$t.txt"
  bad=$(grep -cvF " on $HOST_S (" "$WORK/builder-ids-$t.txt" || true)
  [ -s "$WORK/builder-ids-$t.txt" ] && [ "$bad" = 0 ] || { echo "C1: a verified attestation for $t lacks host $HOST_S in builder.id; refusing" >&2; exit 1; }
  echo "C1 OK: every verified slsaprovenance1 attestation for $t names host $HOST_S and machine $MACHINE"
done
echo "== RESULT"
for pair in "${REFS[@]}"; do echo "${pair%%=*} ${pair#*=}  (tag $REPO:${pair%%=*}-$SHORT)"; printf '%s\n' "${pair#*=}" > "$DIGESTS"; cp "$WORK/prov-${pair%%=*}.json" "$PROV_OUT"; done
echo "DIGESTS -> $DIGESTS: $(cat "$DIGESTS")"; echo "provenance predicate -> $PROV_OUT sha256 $(shasum -a 256 "$PROV_OUT" | cut -d' ' -f1)"
echo "VERIFY OK"
