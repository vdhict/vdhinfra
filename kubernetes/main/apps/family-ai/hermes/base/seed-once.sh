#!/bin/sh
# Write a Hermes profile's config bundle into /opt/data on EVERY start
# (chg-2026-09-26-001 v4, Mack addendum 1 §4: "our files are leading").
# Runs as UID 10000 (hermes) in an init container, with no capabilities.
# (File name kept for history; it is no longer copy-once.)
#
# Why every start: if config.yaml is ever missing, the image seeds its
# EXAMPLE config with ALL tools enabled (docker/stage2-hook.sh:443-456,
# v2026.9.24). Rewriting ours before every start closes that door, and a
# bundle update applies on the next restart instead of silently not at all.
#
#   /bundle/bundle.tar.gz          the profile bundle (Mack), from the SOPS
#   /bundle/bundle.tar.gz.sha256   Secret built by hack/family-ai/build-bundle.sh
#   inside the tarball: SHA256SUMS  per-file checksums
#
# FAIL-CLOSED, before anything is written:
#   * FAMILY_LLM_MODEL empty or still a __MACK_* placeholder (Themis B4);
#   * the bundle is still the PLACEHOLDER Secret;
#   * outer sha256 mismatch;
#   * any tar member that is not a regular file or directory (symlink 'l',
#     hardlink 'h', device ...) or not on the allow-list
#     config.yaml | SOUL.md | SHA256SUMS | plugins/** (Argus A8) - listed
#     with -tv BEFORE extraction; absolute paths and '..' refused;
#   * per-file SHA256SUMS mismatch after extraction into a temp dir.
# Then it writes EXACTLY: config.yaml, SOUL.md (overwrite) and plugins/
# (replaced as a whole, so a plugin removed from the bundle is removed from
# the profile). It NEVER touches memories/, state.db*, sessions/ or
# anything else in /opt/data.
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
    plugins|plugins/|plugins/*) ;;
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

# Write: files via temp + rename (never a half-written config), plugins/
# replaced as a whole.
for f in config.yaml SOUL.md; do
  [ -f "$T/$f" ] || fatal "bundle has no $f"
  cp "$T/$f" "$DATA/.$f.new" && mv -f "$DATA/.$f.new" "$DATA/$f"
done
rm -rf "$DATA/.plugins.new" "$DATA/.plugins.old"
if [ -d "$T/plugins" ]; then
  cp -R "$T/plugins" "$DATA/.plugins.new"
fi
if [ -e "$DATA/plugins" ]; then mv "$DATA/plugins" "$DATA/.plugins.old"; fi
if [ -d "$DATA/.plugins.new" ]; then mv "$DATA/.plugins.new" "$DATA/plugins"; fi
rm -rf "$DATA/.plugins.old"
rm -rf "$T" /tmp/seed-list /tmp/seed-types
printf '%s\n' "$got" > "$MARK.tmp" && mv "$MARK.tmp" "$MARK"   # informational: last bundle written
echo "seed-once: wrote config.yaml, SOUL.md, plugins/ from bundle $got"
