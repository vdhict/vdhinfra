#!/bin/sh
# Copy-ONCE of a Hermes profile's config bundle into /opt/data
# (chg-2026-09-26-001). Runs as UID 10000 (hermes) in an init container,
# with no capabilities.
#
#   /bundle/bundle.tar.gz          the profile bundle (Mack), from the SOPS
#   /bundle/bundle.tar.gz.sha256   Secret built by hack/family-ai/build-bundle.sh
#   inside the tarball: SHA256SUMS  per-file checksums
#
# FAIL-CLOSED on every start (before anything else):
#   * FAMILY_LLM_MODEL empty or still a __MACK_* placeholder (Themis B4):
#     Hermes would otherwise start, pass its TCP probes and fail every chat.
#   * the bundle is still the PLACEHOLDER Secret.
# Then, only on the FIRST start:
#   * both checksums verified BEFORE extraction;
#   * tar members listed with -tv BEFORE extraction: only regular files and
#     directories (no symlinks 'l', no hardlinks 'h', no devices), and only
#     paths on the allow-list config.yaml | SOUL.md | SHA256SUMS |
#     plugins/** | skills/** (Argus A8). No absolute paths, no '..';
#   * never overwrite anything already in /opt/data (cp -n) - memories/,
#     state.db and sessions/ are the child's own state and are never on the
#     allow-list anyway;
#   * /opt/data/.family-ai-seeded (bundle sha256) is written last. Re-seeding
#     is a deliberate, recorded act: delete the marker.
set -eu
DATA="${SEED_DATA:-/opt/data}"   # overridable for the offline test only
B="${SEED_BUNDLE:-/bundle}"
MARK="$DATA/.family-ai-seeded"
fatal() { echo "seed-once: FATAL: $*" >&2; exit 1; }

case "${FAMILY_LLM_MODEL:-}" in
  "") fatal "FAMILY_LLM_MODEL is empty (ConfigMap family-ai-runtime)" ;;
  __MACK_*) fatal "FAMILY_LLM_MODEL is still the placeholder - set the real model id in family-ai-runtime" ;;
esac
if [ -e "$B/PLACEHOLDER" ]; then
  fatal "the config bundle for this profile is still the placeholder - build it with hack/family-ai/build-bundle.sh"
fi
[ -r "$B/bundle.tar.gz" ] || fatal "bundle.tar.gz missing"
[ -r "$B/bundle.tar.gz.sha256" ] || fatal "bundle.tar.gz.sha256 missing"
want=$(cut -d' ' -f1 "$B/bundle.tar.gz.sha256")
got=$(sha256sum "$B/bundle.tar.gz" | cut -d' ' -f1)
[ "$want" = "$got" ] || fatal "bundle sha256 mismatch (want $want, got $got)"
echo "seed-once: model set, bundle sha256 $got verified"

if [ -e "$MARK" ]; then
  had=$(cat "$MARK")
  if [ "$had" = "$got" ]; then
    echo "seed-once: already seeded with this bundle - nothing to do"
  else
    echo "seed-once: NOTE already seeded with $had; the mounted bundle ($got) is NOT applied (copy-once). Delete $MARK to re-seed."
  fi
  exit 0
fi

# Member types and names, BEFORE extraction. GNU tar -tv: first column is
# the mode string; its first character is the type ('-' file, 'd' dir,
# 'l' symlink, 'h' hardlink, 'c'/'b' device, 'p' fifo).
tar -tvzf "$B/bundle.tar.gz" > /tmp/seed-types || fatal "cannot list tarball"
while IFS= read -r line; do
  case "$line" in
    -*|d*) ;;
    *) fatal "bundle member is not a regular file or directory: ${line%% *}" ;;
  esac
done < /tmp/seed-types
tar -tzf "$B/bundle.tar.gz" > /tmp/seed-list || fatal "cannot list tarball"
while IFS= read -r p; do
  case "$p" in
    /*) fatal "absolute path in bundle" ;;
    ..|../*|*/..|*/../*) fatal "'..' in bundle path" ;;
  esac
  q=${p#./}
  case "$q" in
    config.yaml|SOUL.md|SHA256SUMS) ;;
    plugins|plugins/|plugins/*|skills|skills/|skills/*) ;;
    *) fatal "bundle member not on the allow-list: $q" ;;
  esac
  case "/$q/" in
    */.env/*|*/auth.json/*) fatal "bundle member refused: $q" ;;
  esac
done < /tmp/seed-list

T=$(mktemp -d /tmp/seed.XXXXXX)
tar -xzf "$B/bundle.tar.gz" -C "$T" --no-same-owner --no-same-permissions
[ -r "$T/SHA256SUMS" ] || fatal "bundle has no SHA256SUMS"
( cd "$T" && sha256sum -c --strict --quiet SHA256SUMS ) || fatal "per-file SHA256SUMS check failed"
echo "seed-once: per-file SHA256SUMS verified ($(wc -l < "$T/SHA256SUMS") files)"
rm -f "$T/SHA256SUMS"

cp -Rn "$T"/. "$DATA"/
rm -rf "$T" /tmp/seed-list /tmp/seed-types
printf '%s\n' "$got" > "$MARK.tmp" && mv "$MARK.tmp" "$MARK"
echo "seed-once: seeded /opt/data from bundle $got"
