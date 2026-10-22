#!/usr/bin/env bash
# chg-2026-10-22-006: runs INSIDE the pp-ci gate Job (docker.io/library/debian:13.4, privileged, rootful podman) on the
# dedicated, tainted worker (Argus C2).
# Installs the toolchain with every download checked against a pinned sha, waits for the inputs that the driver
# (chg-2026-10-22-006-pp-ci-gates.sh) copies in, runs `ci/run.sh` per target with PP_E2E_REF set, and waits for the
# driver to collect /work/out. No credential exists in this pod; nothing here pushes anywhere.
#
# Network proof first (Argus C3): /work/out/probes.txt, from the pod and from a podman container; the driver checks it
# and only then gives GO. Probe targets come from the driver in /work/in/probes.txt ("name host port expect").
# Inputs in /work/in (driver): targets.txt lines "<label> <bundle file> <full commit>", ref.bundle + ref.commit, GO.
# Output in /work/out/<label>: run.log, exit, and the repo's artifacts/ci (CI_OUT). /work/out/DONE when finished.
set -uo pipefail
export HOME=/work/home DEBIAN_FRONTEND=noninteractive DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
mkdir -p "$HOME" /work/out /work/tools/bin /work/src
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a /work/out/runner.log; }
die() { log "RUNNER FAILED: $*"; touch /work/out/DONE; wait_collect; exit 1; }
wait_collect() { for _ in $(seq 1 720); do [ -e /work/in/COLLECTED ] && return 0; sleep 10; done; }

NODE_V=24.22.1;  NODE_SHA=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
GRYPE_V=0.121.0; GRYPE_SHA=64e07133d3486115de647a66581461dccf5c732748a0a3119077395565f15519
SYFT_V=1.55.0;   SYFT_SHA=bb65249542db5fedeeb4d3f9b018b75e7264dbfbbb10486f044581a92f90490d
declare -A SDK_SHA512=(
  [10.0.113]=1f2746d3684ef782c4308e056e709e9361802e082e401aff3760868125009a8aee2803ff3eeb87587dc60c766e5dc4f9bfd6051c660a85602cc892c31f72256d
  [10.0.402]=1904a98dda2db34ba78ba3c4fb1b224455329af91c341d83547843c1839e112b04ae699ee92fa2449a8f62249196a938723078c0c60b9f65c88539d5687729c2
)
fetch() { curl -fsSL --retry 3 -o "$2" "$1" || die "download $1"; }

log "runner start on $(uname -m), $(. /etc/os-release; echo "$PRETTY_NAME")"
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends \
  podman crun netavark aardvark-dns passt slirp4netns uidmap fuse-overlayfs iptables \
  git curl ca-certificates xz-utils tar gzip python3 python3-yaml jq libicu76 >/dev/null 2>&1 || die "apt install"
log "apt: podman $(podman --version | awk '{print $3}'), git $(git --version | awk '{print $3}'), python $(python3 -V | awk '{print $2}')"

cd /work/tools
fetch "https://nodejs.org/dist/v$NODE_V/node-v$NODE_V-linux-x64.tar.xz" node.tar.xz
echo "$NODE_SHA  node.tar.xz" | sha256sum -c --quiet || die "node sha"
tar -xJf node.tar.xz && export PATH="/work/tools/node-v$NODE_V-linux-x64/bin:$PATH"
fetch "https://github.com/anchore/grype/releases/download/v$GRYPE_V/grype_${GRYPE_V}_linux_amd64.tar.gz" grype.tgz
echo "$GRYPE_SHA  grype.tgz" | sha256sum -c --quiet || die "grype sha"
fetch "https://github.com/anchore/syft/releases/download/v$SYFT_V/syft_${SYFT_V}_linux_amd64.tar.gz" syft.tgz
echo "$SYFT_SHA  syft.tgz" | sha256sum -c --quiet || die "syft sha"
tar -xzf grype.tgz -C bin grype && tar -xzf syft.tgz -C bin syft
mkdir -p dotnet
for v in "${!SDK_SHA512[@]}"; do
  fetch "https://builds.dotnet.microsoft.com/dotnet/Sdk/$v/dotnet-sdk-$v-linux-x64.tar.gz" "sdk-$v.tgz"
  echo "${SDK_SHA512[$v]}  sdk-$v.tgz" | sha512sum -c --quiet || die "dotnet sdk $v sha"
  tar -xzf "sdk-$v.tgz" -C dotnet
done
export DOTNET_ROOT=/work/tools/dotnet PATH="/work/tools/dotnet:/work/tools/bin:$HOME/.dotnet/tools:$PATH"
log "tools: node $(node -v), dotnet sdks $(dotnet --list-sdks | awk '{print $1}' | paste -sd, -), $(grype version 2>/dev/null | awk '/^Version/{print "grype "$2}'), $(syft version 2>/dev/null | awk '/^Version/{print "syft "$2}')"

# Rootful podman: overlay on the emptyDir (vfs fallback), cgroups disabled (no delegated cgroup in the pod), chroot
# isolation for builds, file events (no systemd/journald here).
mkdir -p /etc/containers
conf_storage() { printf '[storage]\ndriver = "%s"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' "$1" > /etc/containers/storage.conf; }
printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n[containers]\nnetns = "bridge"\ncgroups = "disabled"\n' > /etc/containers/containers.conf
export BUILDAH_ISOLATION=chroot
PROBE_IMG=docker.io/library/debian:13.4@sha256:e2d08da6f42ef4b09b165d55528a12727aeed8240dc9edf888e3ec07e10ef9da
conf_storage overlay
if ! podman run --rm "$PROBE_IMG" true >>/work/out/runner.log 2>&1; then
  log "overlay storage refused in the user namespace; switching to vfs"
  podman system reset -f >/dev/null 2>&1; conf_storage vfs
  podman run --rm "$PROBE_IMG" true >>/work/out/runner.log 2>&1 || die "podman cannot run a container here"
fi
log "podman: $(podman info --format '{{.Host.Arch}} storage={{.Store.GraphDriverName}} cgroups={{.Host.CgroupsVersion}} rootless={{.Host.Security.Rootless}}' 2>&1)"
touch /work/out/TOOLS
for _ in $(seq 1 60); do [ -e /work/in/probes.txt ] && break; sleep 5; done
[ -e /work/in/probes.txt ] || die "no probe list"
probe() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo open || echo closed; }
: > /work/out/probes.txt
while read -r name host port expect; do
  [ -n "$name" ] || continue
  a=$(probe "$host" "$port")
  b=$(podman run --rm "$PROBE_IMG" bash -c "timeout 6 bash -c 'exec 3<>/dev/tcp/$host/$port' 2>/dev/null && echo open || echo closed" 2>/dev/null)
  echo "$name pod=$a container=${b:-error} expect=$expect" >> /work/out/probes.txt
done < /work/in/probes.txt
log "probes written"
touch /work/out/READY
log "ready; waiting for the driver (probe check, then inputs)"
for _ in $(seq 1 360); do [ -e /work/in/GO ] && break; [ -e /work/in/ABORT ] && die "driver aborted (probe check failed)"; sleep 10; done
[ -e /work/in/GO ] || die "no inputs within 60 min"

REF_COMMIT=$(cat /work/in/ref.commit)
git clone -q /work/in/ref.bundle /work/ref && git -C /work/ref checkout -q --detach "$REF_COMMIT" || die "reference checkout $REF_COMMIT"
log "reference $(git -C /work/ref rev-parse HEAD)"
( cd /work/ref/e2e && npm ci --ignore-scripts --no-audit --no-fund >/work/out/ref-npm.log 2>&1 \
  && node node_modules/playwright-core/cli.js install --with-deps chromium-headless-shell >>/work/out/ref-npm.log 2>&1 ) || die "reference e2e install (see ref-npm.log)"
log "reference e2e installed"

while read -r label bundle commit; do
  [ -n "$label" ] || continue
  src="/work/src/$label"; out="/work/out/$label"; mkdir -p "$out"
  git clone -q "/work/in/$bundle" "$src" && git -C "$src" checkout -q --detach "$commit" || { echo 90 > "$out/exit"; log "$label: checkout $commit failed"; continue; }
  [ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] || { echo 91 > "$out/exit"; log "$label: HEAD mismatch"; continue; }
  log "$label: ci/run.sh at $commit"
  ( cd "$src" && CI_OUT="$out/ci" PP_E2E_REF=/work/ref bash ci/run.sh ) > "$out/run.log" 2>&1
  rc=$?; echo "$rc" > "$out/exit"; log "$label: exit $rc"
  podman images --digests --format '{{.Repository}}@{{.Digest}}' | sort -u > "$out/images-pulled.txt"
  podman container prune -f >/dev/null 2>&1; podman pod prune -f >/dev/null 2>&1
done < /work/in/targets.txt
touch /work/out/DONE
log "all targets done; waiting for collection"
wait_collect
log "collected; exit"
