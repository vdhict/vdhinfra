#!/usr/bin/env bash
# chg-2026-10-20-010 land 2 (cloud on profiel-3 only): derived delivery = what is LIVE on profiel-3 (bundle from
# origin/main, outer sha256 fe64b2a1, delivery 8d8d27a-web7m6-huiswerk1-lesstof4-f4 = chg-2026-10-25-002 F4, Argus D1-D6)
# with config.yaml replaced and the
# 4 family-cloud files added, all 5 taken from the family-ai render of land2-cloud-v0225-routelog 03614a1 (= 2634ce0
# + route line 5a9a361 + route record d50234d + v0.22.5 API-door admission 03614a1; __init__.py 650bd56f -> bd0ffb6c, other 4 pins unchanged) (family-cloud ported
# to Hermes v0.22.5, on Mack's lesstof-v5-f4 480456c; plugin.yaml/settings.json/cloud-SOUL.md unchanged since 1e8f887)
# and checked against full sha256 pins.
# Nothing else may differ: the other live files must be byte-equal in live and in the render (no exceptions: F4 is
# in the render's base since 2634ce0).
#
#   hack/ops/chg-2026-10-20-010-derive-p3.sh <render-root> <out-root>
#
# Writes only <out-root> (must not exist). Prints counts and sha256 prefixes, never file content.
# Then: hack/family-ai/build-bundle.sh 3 <out-root>/delivery
set -euo pipefail
RENDER="${1:?render root}"; OUT="${2:?out root}"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel)"
LIVE_OUTER=fe64b2a128258e45d23c70b1cb642ceae1750ce901891f59b667cc3e860274f2
# bash 3.2 (macOS): no associative arrays; one "sha256 path" per line
PINS='0437f3f6b58ecbc993bb00b1d7d7ab7c980ffb2da4fab715d884dd92c4e1b29f config.yaml
bd0ffb6c43b0eb5979148b2e3490c086d4338dbc1f43e71406d859772edaec22 plugins/model-providers/family-cloud/__init__.py
ba0794c5647d780f2edfddc806ba58f7519e80cc9975c86be7f0c7e950af4046 plugins/model-providers/family-cloud/plugin.yaml
d3ea565e3280419b44567f57b87050d644cb25e26b015091eadb71ea99b7c542 plugins/model-providers/family-cloud/settings.json
b67506a71c1f29cbbacee91e487ad74c5a8736a32047cf6575ac61c70b356fd0 plugins/model-providers/family-cloud/cloud-SOUL.md'
pin_of() { echo "$PINS" | awk -v f="$1" '$2==f{print $1}'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
R="$RENDER/profiel-3"; [ -d "$R" ] || { echo "no profiel-3 in render" >&2; exit 1; }
[ -z "$(cd "$R" && find . -type l)" ] || { echo "symlink in render" >&2; exit 1; }

mkdir -p "$OUT/live" "$OUT/delivery/profiel-3"
# 1. live bundle exactly as on origin/main
git -C "$ROOT" show origin/main:kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml > "$OUT/bundle.sops.yaml"
sops -d --extract '["data"]["bundle.tar.gz"]' "$OUT/bundle.sops.yaml" | base64 -d > "$OUT/live.tar.gz"
[ "$(sha "$OUT/live.tar.gz")" = "$LIVE_OUTER" ] || { echo "live outer sha256 is not $LIVE_OUTER" >&2; exit 1; }
tar -xzf "$OUT/live.tar.gz" -C "$OUT/live"
( cd "$OUT/live" && shasum -a 256 -c --strict --quiet SHA256SUMS ) || { echo "live SHA256SUMS failed" >&2; exit 1; }
live_files=$(cd "$OUT/live" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)
render_files=$(cd "$R" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

# 2. file sets: render = live + the 4 family-cloud files; live has config.yaml and no family-cloud
added=$(LC_ALL=C comm -13 <(echo "$live_files") <(echo "$render_files"))
removed=$(LC_ALL=C comm -23 <(echo "$live_files") <(echo "$render_files"))
want_added=$(echo "$PINS" | awk '{print $2}' | grep family-cloud | LC_ALL=C sort)
[ "$added" = "$want_added" ] || { echo "render adds an unexpected file set" >&2; exit 1; }
[ -z "$removed" ] || { echo "render drops live files" >&2; exit 1; }

# 3. copy live, then the 5 pinned files from the render; every pin checked in full
( cd "$OUT/live" && COPYFILE_DISABLE=1 tar -cf - $live_files ) | ( cd "$OUT/delivery/profiel-3" && tar -xf - )
for f in $(echo "$PINS" | awk '{print $2}'); do
  [ "$(sha "$R/$f")" = "$(pin_of "$f")" ] || { echo "render pin mismatch: $f" >&2; exit 1; }
  mkdir -p "$OUT/delivery/profiel-3/$(dirname "$f")"
  cp "$R/$f" "$OUT/delivery/profiel-3/$f"
  [ "$(sha "$OUT/delivery/profiel-3/$f")" = "$(pin_of "$f")" ] || { echo "copy pin mismatch: $f" >&2; exit 1; }
done

# 4. every non-pinned file: delivery == live == render (byte-equal)
same=0
while IFS= read -r f; do
  [ -n "$(pin_of "$f")" ] && continue
  a=$(sha "$OUT/live/$f"); b=$(sha "$OUT/delivery/profiel-3/$f"); c=$(sha "$R/$f")
  [ "$a" = "$b" ] && [ "$a" = "$c" ] || { echo "non-pinned file differs: $f" >&2; exit 1; }
  same=$((same + 1))
done <<<"$live_files"
[ "$(sha "$OUT/live/config.yaml")" != "$(pin_of config.yaml)" ] || { echo "config.yaml unchanged vs live?" >&2; exit 1; }

( cd "$OUT/delivery" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
total=$(grep -c . "$OUT/delivery/SHA256SUMS")
echo "derive-p3: live outer $LIVE_OUTER OK; live files $(echo "$live_files" | wc -l | tr -d ' '); same=$same; changed=1 (config.yaml); added=4 (family-cloud); delivery files $total"
echo "$PINS" | awk '{print "pin " substr($1,1,12) " " $2}'
