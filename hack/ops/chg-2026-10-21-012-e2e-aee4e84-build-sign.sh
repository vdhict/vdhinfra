#!/usr/bin/env bash
# chg-2026-10-21-012 (copy of chg-2026-10-20-001-e2e-3ccfbab-build-sign.sh sha256 f55d023a..95d7; changes: script name in usage +
# builder.id, NODE_VERSION_WANT check per child; gate, C1, C2, F3 and key retrieval unchanged). Node 24.22.1 rebuild from
# e2e/secreq-1.0-idtype aee4e84 (base node:24-trixie-slim index 1375326a).
# Original header: build the Passkey Point E2E harness image (`e2e`, ADR-026; e2e/Containerfile, context e2e/) as one
# manifest list linux/amd64 + linux/arm64 (as e2e-95610be: OCI index, both arches) from one commit of VDHICT/passkey-point,
# then (separate run, after review) push it to forge.bluejungle.net/palamedes/passkey-point-e2e, sign it by digest with the
# Passkey cosign key, attest an SLSA v1 provenance predicate and verify against the out-of-band public key.
# Minimal diff on hack/ops/chg-2026-10-20-001-dotnet-desk-0cc9bc7-build-sign.sh sha256 a761b6d2...e9e0 (Argus qa_passed
# 2026-10-19T22:59:51Z): c2-trap block, F3 cfg_check, C1 host check and key retrieval byte-identical; only the image /
# component, Containerfile / build context, repo parameters and the two-arch list handling differ. List checks reuse the
# repo's own scripts/release/verify-image-lists.ts (the e2e-95610be route), run from the archived source of the commit.
# Copied from chg-2026-10-15-007-preflight-build-sign.sh (Argus F1-F4); key retrieval unchanged. Added for the
# 2026-10-19T20:43:47Z ruling on chg-2026-10-06-008:
#   C1  runDetails.builder.id names the build host (hostname -s at run time) and the podman machine + VM type; the
#       verify-attestation output prints builder.id and the run fails unless it contains the host.
#   C2  after the key file is removed, a logged scan of $HOME/Code, the scratch dir and $TMPDIR for SIGSTORE/COSIGN
#       private-key PEM headers; any hit fails the run.
# Never prints the key, its password or the token.
#
#   PP_SCRATCH=<dir> hack/ops/chg-2026-10-21-012-e2e-aee4e84-build-sign.sh build <source-git-dir> <full-commit> <log> <evidence-dir>
#   PP_SCRATCH=<dir> hack/ops/chg-2026-10-21-012-e2e-aee4e84-build-sign.sh sign  <source-git-dir> <full-commit> <log> <evidence-dir>
#
# build: git archive -> podman build --platform linux/amd64,linux/arm64 --manifest (fresh list, refused if it exists; no
#        push, no key) -> verify-image-lists.ts (local) -> per child: image inspect, OCI archive, CycloneDX SBOM (syft),
#        grype gate (Critical, or High with a fix, fails, except the exact ar-015 four-field match; ci/run.sh step 10) -> a baseline C2 scan -> write-once
#        BUILD-e2e-<short>.txt record + sbom-e2e-<short>-{amd64,arm64}.cdx.json in <evidence-dir>.
# sign:  needs that record; refuses unless the local list localhost/passkey-point-e2e:e2e-<short> has exactly the recorded
#        child image ids and revision label; C2 scan (refuses on a hit) -> push --all -> remote children have the recorded
#        config digests -> verify-image-lists.ts --remote -> provenance (C1) -> key via Connect -> sign --recursive + attest
#        -> key removal -> C2 scan -> verify (index + each child) + verify-attestation (C1 check) -> DIGESTS-e2e-<short>.txt
#        + prov-e2e-<short>.json.
set -euo pipefail
MODE=${1:?mode build|sign}; SRC_GIT=${2:?source git dir}; COMMIT=${3:?commit}; LOG=${4:?log file}; EVD=${5:?evidence dir}
case "$MODE" in build|sign) ;; *) echo "mode must be build or sign" >&2; exit 64 ;; esac
[ ! -e "$LOG" ] || { echo "log $LOG exists; write-once, refusing" >&2; exit 64; }
[ -d "$EVD" ] || { echo "evidence dir $EVD missing" >&2; exit 64; }
S7=${COMMIT:0:7}
ARCHES=(amd64 arm64)
RECORD="$EVD/BUILD-e2e-$S7.txt"; SBOM_AMD="$EVD/sbom-e2e-$S7-amd64.cdx.json"; SBOM_ARM="$EVD/sbom-e2e-$S7-arm64.cdx.json"
DIGESTS="$EVD/DIGESTS-e2e-$S7.txt"; PROV_OUT="$EVD/prov-e2e-$S7.json"
if [ "$MODE" = build ]; then
  [ ! -e "$RECORD" ] && [ ! -e "$SBOM_AMD" ] && [ ! -e "$SBOM_ARM" ] || { echo "$RECORD or an SBOM exists; write-once, refusing" >&2; exit 64; }
else
  [ -f "$RECORD" ] && [ -f "$SBOM_AMD" ] && [ -f "$SBOM_ARM" ] || { echo "sign needs $RECORD and both SBOMs from a build run" >&2; exit 64; }
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
NODE_VERSION_WANT=v24.22.1  # chg-2026-10-21-012: Node.js 24.22.1 security release
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
REPO=forge.bluejungle.net/palamedes/passkey-point-e2e
REPO_URL=https://forge.bluejungle.net/VDHICT/passkey-point
LOCAL="localhost/passkey-point-e2e:e2e-$S7"
CRANE=$(ls -d "$HOME"/.local/share/mise/installs/aqua-google-go-containerregistry/*/ | head -1)crane
AUTHDIR="$SCRATCH/regauth-mackdev"; AUTH="$AUTHDIR/auth.json"
OP_ITEM=${PP_COSIGN_OP_ITEM:-op://home-infra/passkey-point-cosign}
unset COSIGN_PRIVATE_KEY COSIGN_PASSWORD PP_KEY PP_PW PP_TOK PP_ITEM
WORK=$(mktemp -d "$SCRATCH/pp-e2e-build.XXXXXX")
KWORK=""; KEYFILE=""
PF=""; KEY_FETCHED=0; SCAN_DONE=0
# >>> grype-gate (this block is also loaded by hack/ops/test-chg-2026-10-20-001-e2e-3ccfbab-gate.sh)
# Gate = ci/run.sh step 10: a Critical, or a High with a fix, refuses. ONE exception, ar-015 (Argus qa_passed
# 2026-10-21T06:54:05Z, C1): a hit is excepted only when ALL FOUR fields match exactly. No env knob, no prefix match.
GX_ID=CVE-2026-6653; GX_PKG=libxml2; GX_VER=2.12.7+dfsg+really2.9.14-2.1+deb13u3; GX_FIX=wont-fix
GATE_SEL='.matches[] | select(.vulnerability.severity == "Critical" or (.vulnerability.severity == "High" and .vulnerability.fix.state == "fixed"))'
GATE_EXC='(.vulnerability.id == $id and .artifact.name == $pkg and .artifact.version == $ver and .vulnerability.fix.state == $fix)'
GATE_JQ_COUNT="[$GATE_SEL | select($GATE_EXC | not)] | length"
GATE_JQ_EXCEPTED="[$GATE_SEL | select($GATE_EXC) | .vulnerability.id + \" \" + .artifact.name + \"@\" + .artifact.version] | unique | if length == 0 then \"none\" else join(\",\") end"
grype_gate() {  # $1 grype json, $2 label; lists every gate hit; returns 0 only when none is outside the exception
  local n
  echo "-- grype gate hits $2 (Critical, or High with a fix), all listed; exception ar-015 = $GX_ID $GX_PKG@$GX_VER $GX_FIX"
  jq -r "$GATE_SEL"' | "  GATE \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$1" | sort -u
  n=$(jq --arg id "$GX_ID" --arg pkg "$GX_PKG" --arg ver "$GX_VER" --arg fix "$GX_FIX" "$GATE_JQ_COUNT" "$1") || return 2
  echo "   gate hits outside ar-015: $n; excepted: $(jq -r --arg id "$GX_ID" --arg pkg "$GX_PKG" --arg ver "$GX_VER" --arg fix "$GX_FIX" "$GATE_JQ_EXCEPTED" "$1")"
  [ "$n" = 0 ] && echo "grype gate $2 PASS"
}
# <<< grype-gate
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
BUILDER="podman $PODMAN_V on $HOST_S ($(uname -s | tr A-Z a-z)/$(uname -m)), podman machine $MACHINE, linux/amd64 + linux/arm64 (one manifest list)"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "== chg-2026-10-21-012 e2e harness $MODE, started $STARTED by k8s-engineer (Heph) for Atlas"
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
# The local list's children as "<arch> <manifest digest> <image id>"; refuses unless exactly linux/amd64 + linux/arm64.
list_children() {
  podman manifest inspect "$LOCAL" > "$WORK/list.json"
  jq -e '[.manifests[] | .platform.os + "/" + .platform.architecture] | sort == ["linux/amd64", "linux/arm64"]' "$WORK/list.json" >/dev/null \
    || { echo "local list $LOCAL is not exactly linux/amd64 + linux/arm64" >&2; exit 1; }
  podman images -a --digests --format json > "$WORK/images.json"
  jq -r '.manifests[] | .platform.architecture + " " + .digest' "$WORK/list.json" | sort | while read -r a md; do
    id=$(jq -r --arg d "$md" '[.[] | select(.Digest == $d or ((.Digests // []) | index($d)))] | if length == 1 then .[0].Id else empty end' "$WORK/images.json")
    [ -n "$id" ] || { echo "no single local image for $a child $md" >&2; exit 1; }
    echo "$a $md $id"
  done
}
src_tree() { mkdir "$WORK/src"; git -C "$SRC_GIT" archive "$FULL" | tar -x -C "$WORK/src"; }

if [ "$MODE" = build ]; then
  cfg_check
  src_tree
  NODE_BASE=$(sed -n 's/^ARG NODE_IMAGE=//p' "$WORK/src/e2e/Containerfile" | head -1)
  echo "base (as committed): node $NODE_BASE"
  if podman manifest exists "$LOCAL"; then echo "local list $LOCAL exists; a build would add to it (2026-10-05), refusing" >&2; exit 1; fi
  echo "== build e2e (linux/amd64 + linux/arm64, one manifest list; e2e/Containerfile, context e2e/)"
  podman build --pull --no-cache --platform linux/amd64,linux/arm64 --manifest "$LOCAL" --label "org.opencontainers.image.revision=$FULL" \
    --label "org.opencontainers.image.source=$REPO_URL" -f "$WORK/src/e2e/Containerfile" "$WORK/src/e2e"
  FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "== verify local list (repo scripts/release/verify-image-lists.ts of $SHORT: own target, both arches, run, files = source)"
  node "$WORK/src/scripts/release/verify-image-lists.ts" --component e2e --revision "$FULL" --source "$WORK/src" "e2e=$LOCAL"
  CH=$(list_children); printf '%s\n' "$CH" > "$WORK/children.txt"
  for a in "${ARCHES[@]}"; do
    read -r _ MD ID < <(grep "^$a " "$WORK/children.txt")
    [ -n "${ID:-}" ] || { echo "no $a child in $LOCAL" >&2; exit 1; }
    echo "== inspect e2e $a child $MD"
    podman image inspect "$ID" --format \
      'id={{.Id}} arch={{.Architecture}} os={{.Os}} user={{.Config.User}} ports={{.Config.ExposedPorts}} entrypoint={{.Config.Entrypoint}} cmd={{.Config.Cmd}} workdir={{.Config.WorkingDir}}
env={{.Config.Env}}
labels={{.Config.Labels}}'
    [ "$(podman image inspect "$ID" --format '{{.Architecture}}/{{.Os}}')" = "$a/linux" ] || { echo "child is not linux/$a" >&2; exit 1; }
    [ "$(podman image inspect "$ID" --format '{{.Config.User}}')" = 10001:0 ] || { echo "image user is not 10001:0" >&2; exit 1; }
    NV=$(podman run --rm --network none --read-only --platform "linux/$a" --entrypoint node "$ID" --version)
    echo "node --version in $a child (network none, read-only): $NV"
    [ "$NV" = "$NODE_VERSION_WANT" ] || { echo "node in $a child is $NV, not $NODE_VERSION_WANT; refusing" >&2; exit 1; }
    printf '%s\n' "node_version_$a=$NV" >> "$WORK/record-arch.txt"
    echo "== OCI archive $a (local only, no registry): manifest digest; the registry digest is fixed at push in the sign run"
    podman save --format oci-archive -o "$WORK/e2e-$a-oci.tar" "$ID"
    OCI_DIGEST=$(tar -xOf "$WORK/e2e-$a-oci.tar" index.json | jq -r 'if (.manifests | length) == 1 then .manifests[0].digest else empty end')
    [ -n "$OCI_DIGEST" ] || { echo "oci archive index.json has not exactly one manifest" >&2; exit 1; }
    echo "oci-archive manifest digest $OCI_DIGEST"
    echo "== SBOM $a (syft $SYFT_VERSION, CycloneDX JSON, INF-SC-03)"
    "$MISE" x "aqua:anchore/syft@$SYFT_VERSION" -- syft scan "oci-archive:$WORK/e2e-$a-oci.tar" -q -o "cyclonedx-json=$WORK/sbom-$a.cdx.json"
    jq -e '.bomFormat == "CycloneDX" and ((.components // []) | length) > 0' "$WORK/sbom-$a.cdx.json" >/dev/null || { echo "SBOM empty or not CycloneDX" >&2; exit 1; }
    echo "sbom components=$(jq '.components | length' "$WORK/sbom-$a.cdx.json") specVersion=$(jq -r .specVersion "$WORK/sbom-$a.cdx.json")"
    echo "== grype $GRYPE_VERSION on the $a SBOM (fails on a Critical, or a High with a fix; ci/run.sh step 10)"
    "$MISE" x "aqua:anchore/grype@$GRYPE_VERSION" -- grype "sbom:$WORK/sbom-$a.cdx.json" -q -o json > "$WORK/grype-$a.json"
    jq -r '[.matches[] | .vulnerability.severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ") | "grype matches by severity: " + (if . == "" then "none" else . end)' "$WORK/grype-$a.json"
    jq -r '.matches[] | "  \(.vulnerability.severity) \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) fix=\(.vulnerability.fix.state)"' "$WORK/grype-$a.json" | sort | head -40
    grype_gate "$WORK/grype-$a.json" "$a" || { echo "grype gate $a: a Critical or fixable High outside ar-015; refusing" >&2; exit 1; }
    printf '%s\n' "grype_gate_excepted_$a=$(jq -r --arg id "$GX_ID" --arg pkg "$GX_PKG" --arg ver "$GX_VER" --arg fix "$GX_FIX" "$GATE_JQ_EXCEPTED" "$WORK/grype-$a.json")" >> "$WORK/record-arch.txt"
    printf '%s\n' "child_$a=$MD" "image_id_$a=$ID" "oci_manifest_digest_$a=$OCI_DIGEST" "grype_matches_$a=$(jq '.matches | length' "$WORK/grype-$a.json")" >> "$WORK/record-arch.txt"
  done
  # Informational here (no key in a build run): the sign run repeats this scan before the key fetch and refuses on a hit.
  if key_header_scan build-baseline; then BASE_HITS=0; else BASE_HITS=$(wc -l < "$WORK/scan-build-baseline.real" | tr -d ' ')
    echo "NOTE: $BASE_HITS pre-existing key-header hit(s) (paths above); a sign run refuses until they are gone"; fi
  cp "$WORK/sbom-amd64.cdx.json" "$SBOM_AMD"; cp "$WORK/sbom-arm64.cdx.json" "$SBOM_ARM"
  { echo "commit=$FULL"; echo "image_local=$LOCAL"; cat "$WORK/record-arch.txt"
    echo "node_index=$NODE_BASE"; echo "started=$STARTED"; echo "finished=$FINISHED"
    echo "builder=$BUILDER"; echo "sbom_sha256_amd64=$(shasum -a 256 "$SBOM_AMD" | cut -d' ' -f1)"; echo "sbom_sha256_arm64=$(shasum -a 256 "$SBOM_ARM" | cut -d' ' -f1)"
    echo "c2_build_baseline_hits=$BASE_HITS"; } > "$RECORD"
  echo "== RESULT (build, unsigned, not pushed)"; cat "$RECORD"
  echo "BUILD OK"
  exit 0
fi

# ---- sign ----
[ "$(rec commit)" = "$FULL" ] || { echo "record commit $(rec commit) is not $FULL" >&2; exit 1; }
NODE_BASE=$(rec node_index)
B_STARTED=$(rec started); B_FINISHED=$(rec finished); B_BUILDER=$(rec builder)
CH=$(list_children); printf '%s\n' "$CH" > "$WORK/children.txt"
for a in "${ARCHES[@]}"; do
  read -r _ MD ID < <(grep "^$a " "$WORK/children.txt")
  [ -n "${ID:-}" ] && [ "$ID" = "$(rec "image_id_$a")" ] && [ "$MD" = "$(rec "child_$a")" ] \
    || { echo "local $LOCAL $a child is not the recorded image $(rec "image_id_$a"); refusing" >&2; exit 1; }
  [ "$(podman image inspect "$ID" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$FULL" ] || { echo "revision label mismatch ($a)" >&2; exit 1; }
done
[ "$(shasum -a 256 "$SBOM_AMD" | cut -d' ' -f1)" = "$(rec sbom_sha256_amd64)" ] && [ "$(shasum -a 256 "$SBOM_ARM" | cut -d' ' -f1)" = "$(rec sbom_sha256_arm64)" ] \
  || { echo "an SBOM file changed since the build record" >&2; exit 1; }
for a in "${ARCHES[@]}"; do  # C1-C3 (ar-015): fresh grype on the recorded SBOM, same exact-match gate, before any push
  sb="$SBOM_AMD"; [ "$a" = arm64 ] && sb="$SBOM_ARM"
  echo "== grype $GRYPE_VERSION re-gate $a on recorded $(basename "$sb") (sign run, before key fetch and push)"
  "$MISE" x "aqua:anchore/grype@$GRYPE_VERSION" -- grype "sbom:$sb" -q -o json > "$WORK/grype-sign-$a.json"
  grype_gate "$WORK/grype-sign-$a.json" "sign-$a" || { echo "grype re-gate $a: a Critical or fixable High outside ar-015; refusing" >&2; exit 1; }
done
case "$B_BUILDER" in *" on $HOST_S ("*", podman machine $MACHINE,"*) ;; *) echo "build record host/machine is not this host $HOST_S / $MACHINE; refusing (C1)" >&2; exit 1 ;; esac
echo "local list $LOCAL children amd64 $(rec image_id_amd64) arm64 $(rec image_id_arm64) = build record $RECORD; built on this host/machine"
src_tree
key_header_scan before-key-fetch || { echo "C2: key-header hits before any key fetch; the after-removal scan could not show 0; refusing" >&2; exit 1; }

KWORK=$(mktemp -d "$SCRATCH/pp-e2e-sign.XXXXXX"); chmod 700 "$KWORK"
KEYFILE="$KWORK/cosign.key"
echo "== registry auth (palamedes, token from ~/.config/pka/mack-dev-forge-package, not printed)"
( umask 077; mkdir -p "$AUTHDIR"; tok=$(cat "$HOME/.config/pka/mack-dev-forge-package"); b64=$(printf 'palamedes:%s' "$tok" | base64 | tr -d '\n')
  printf '{"auths":{"forge.bluejungle.net":{"auth":"%s"}}}\n' "$b64" > "$AUTH" )
export REGISTRY_AUTH_FILE="$AUTH"
mkdir "$KWORK/docker"; ln -s "$AUTH" "$KWORK/docker/config.json"; export DOCKER_CONFIG="$KWORK/docker"

declare -a REFS=()
t=e2e
podman manifest push --all --digestfile "$WORK/digest-$t" "$LOCAL" "docker://$REPO:$t-$SHORT"
d=$(cat "$WORK/digest-$t"); echo "pushed $REPO:$t-$SHORT $d (list)"
REFS+=("$t=$REPO@$d")
echo "== registry children (by digest): config digest must be the recorded image id"
"$CRANE" manifest "$REPO@$d" > "$WORK/remote-list.json"
jq -e '[.manifests[] | .platform.os + "/" + .platform.architecture] | sort == ["linux/amd64", "linux/arm64"]' "$WORK/remote-list.json" >/dev/null \
  || { echo "registry list $d is not exactly linux/amd64 + linux/arm64" >&2; exit 1; }
for a in "${ARCHES[@]}"; do
  cd_=$(jq -r --arg a "$a" '.manifests[] | select(.platform.architecture == $a) | .digest' "$WORK/remote-list.json")
  cfg=$("$CRANE" manifest "$REPO@$cd_" | jq -r .config.digest)
  [ "$cfg" = "sha256:$(rec "image_id_$a")" ] || { echo "registry $a child $cd_ config $cfg is not the recorded image id; refusing" >&2; exit 1; }
  echo "$a child $cd_ config $cfg = recorded image id"
  printf '%s\n' "$a $cd_" >> "$WORK/remote-children.txt"
done
echo "== verify what the registry serves (repo verify-image-lists.ts --remote, pulled by digest)"
node "$WORK/src/scripts/release/verify-image-lists.ts" --component e2e --remote --revision "$FULL" --source "$WORK/src" "e2e=$REPO@$d"

echo "== provenance predicate (SLSA v1 shape of provenance.ts; built here with jq). C1: builder.id names host + machine"
for pair in "${REFS[@]}"; do
  t=${pair%%=*}
  jq -n --arg t "$t" --arg c "$FULL" --arg s "$SHORT" --arg u "$REPO_URL" --arg nb "$NODE_BASE" \
    --arg st "$B_STARTED" --arg fi "$B_FINISHED" --arg b "$B_BUILDER" \
    --arg sa "$(rec sbom_sha256_amd64)" --arg sr "$(rec sbom_sha256_arm64)" --arg san "$(basename "$SBOM_AMD")" --arg srn "$(basename "$SBOM_ARM")" '{
    buildDefinition: {
      buildType: "https://forge.bluejungle.net/VDHICT/passkey-point/e2e/Containerfile@v1",
      externalParameters: {target: $t, commit: $c, tagSuffix: $s, platforms: ["linux/amd64", "linux/arm64"]},
      internalParameters: {},
      resolvedDependencies: [
        {uri: ("git+" + $u + "@" + $c), digest: {gitCommit: $c}},
        {uri: "pkg:docker/docker.io/library/node", name: $nb, digest: {sha256: ($nb | split("@sha256:")[1])}}]},
    runDetails: {builder: {id: ("vdhinfra hack/ops/chg-2026-10-21-012-e2e-aee4e84-build-sign.sh (" + $b + ")")},
      metadata: {invocationId: (($c[0:7]) + "-" + $s + "-" + $t), startedOn: $st, finishedOn: $fi},
      byproducts: [{name: $san, mediaType: "application/vnd.cyclonedx+json", digest: {sha256: $sa}},
                   {name: $srn, mediaType: "application/vnd.cyclonedx+json", digest: {sha256: $sr}}]}}' > "$WORK/prov-$t.json"
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
  while read -r a cd_; do
    echo "-- cosign verify $REPO@$cd_ ($a child, signed by sign --recursive)"
    cosign verify --key "$OOB" --insecure-ignore-tlog "$REPO@$cd_" > "$WORK/verify-$t-$a.json"
    jq -c '.[] | {ref: .critical.identity["docker-reference"], digest: .critical.image["docker-manifest-digest"], type: .critical.type}' "$WORK/verify-$t-$a.json"
  done < "$WORK/remote-children.txt"
  echo "-- cosign verify-attestation --type slsaprovenance1 $r"
  cosign verify-attestation --key "$OOB" --insecure-ignore-tlog --type slsaprovenance1 "$r" > "$WORK/att-$t.json"
  jq -r '.payload' "$WORK/att-$t.json" | while read -r p; do printf '%s' "$p" | base64 -d | jq -c '{subject: .subject, commit: .predicate.buildDefinition.externalParameters.commit, target: .predicate.buildDefinition.externalParameters.target, builder_id: .predicate.runDetails.builder.id}'; done
  jq -r '.payload' "$WORK/att-$t.json" | while read -r p; do printf '%s' "$p" | base64 -d | jq -r '.predicate.runDetails.builder.id'; done > "$WORK/builder-ids-$t.txt"
  bad=$(grep -cvF " on $HOST_S (" "$WORK/builder-ids-$t.txt" || true)
  [ -s "$WORK/builder-ids-$t.txt" ] && [ "$bad" = 0 ] || { echo "C1: a verified attestation for $t lacks host $HOST_S in builder.id; refusing" >&2; exit 1; }
  echo "C1 OK: every verified slsaprovenance1 attestation for $t names host $HOST_S and machine $MACHINE"
done
echo "== RESULT"
for pair in "${REFS[@]}"; do echo "${pair%%=*} ${pair#*=}  (tag $REPO:${pair%%=*}-$SHORT)"; { printf '%s\n' "${pair#*=}"; sed "s|^\([a-z0-9]*\) |\1 $REPO@|" "$WORK/remote-children.txt"; } > "$DIGESTS"; cp "$WORK/prov-${pair%%=*}.json" "$PROV_OUT"; done
echo "DIGESTS -> $DIGESTS: $(cat "$DIGESTS")"; echo "provenance predicate -> $PROV_OUT sha256 $(shasum -a 256 "$PROV_OUT" | cut -d' ' -f1)"
echo "VERIFY OK"
