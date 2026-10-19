#!/usr/bin/env bash
# chg-2026-10-19-001 lesstof (land 1/3): derived delivery = what is LIVE on profiel-2/3 (8d8d27a-web7m6-huiswerk1,
# seeded bundles 6e3e959d / 58f51d91 on main e9c32ec8 / a528e0cd) + plugins/lesstof from family-ai
# deploy/lesstof/plugin-delta (commit 6c8743c) + ONE config.yaml line ('    - "lesstof"' after '    - "huiswerk"').
# NOT the rendered familie/2026-10-19 bundle: that carries land 2 (family-cloud provider) and land 3 (attachments).
#   hack/ops/chg-2026-10-19-001-derive-delivery.sh <huiswerk1-root> <plugin-delta-root> <out-root>
# Prints counts, sha256 prefixes and the diff -rq against the base only. Writes only <out-root> (must not exist).
set -euo pipefail
BASE="${1:?huiswerk1}"; DELTA="${2:?plugin-delta}"; OUT="${3:?out}"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
( cd "$BASE" && shasum -a 256 -c --strict SHA256SUMS >/dev/null )
( cd "$DELTA" && shasum -a 256 -c --strict SHA256SUMS >/dev/null )
# the delta must be exactly 3 files per boy, nothing else
want=$'profiel-2/plugins/lesstof/__init__.py\nprofiel-2/plugins/lesstof/instellingen.json\nprofiel-2/plugins/lesstof/plugin.yaml\nprofiel-3/plugins/lesstof/__init__.py\nprofiel-3/plugins/lesstof/instellingen.json\nprofiel-3/plugins/lesstof/plugin.yaml'
got=$(cd "$DELTA" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)
[ "$got" = "$want" ] || { echo "delta file set unexpected" >&2; exit 1; }
[ -z "$(cd "$DELTA" && find . -type l)" ] || { echo "symlink in delta" >&2; exit 1; }
mkdir -p "$OUT"
for n in 2 3; do
  cp -Rp "$BASE/profiel-$n" "$OUT/profiel-$n"
  [ ! -e "$OUT/profiel-$n/plugins/lesstof" ] || { echo "lesstof already in base" >&2; exit 1; }
  cp -Rp "$DELTA/profiel-$n/plugins/lesstof" "$OUT/profiel-$n/plugins/lesstof"
  python3 -I - "$OUT/profiel-$n/config.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
i = lines.index("plugins:")
assert lines[i + 1] == "  enabled:" and lines[i + 2] == '    - "gezin"' and lines[i + 3] == '    - "huiswerk"', "unexpected plugins block"
assert not lines[i + 4].startswith("    - "), "more plugins than expected"
lines.insert(i + 4, '    - "lesstof"')
open(p, "w").write("\n".join(lines))
PY
done
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived: $(grep -c . "$OUT/SHA256SUMS") files, SHA256SUMS sha256 $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
for n in 2 3; do
  echo "== diff -rq huiswerk1/profiel-$n derived/profiel-$n"
  diff -rq "$BASE/profiel-$n" "$OUT/profiel-$n" | sed "s#$BASE#huiswerk1#g; s#$OUT#derived#g" || true
  echo "== config.yaml diff profiel-$n"
  diff "$BASE/profiel-$n/config.yaml" "$OUT/profiel-$n/config.yaml" || true
  for f in __init__.py plugin.yaml instellingen.json; do
    echo "lesstof/$f sha256 $(shasum -a 256 "$OUT/profiel-$n/plugins/lesstof/$f" | cut -c1-12) git $(git hash-object "$OUT/profiel-$n/plugins/lesstof/$f" | cut -c1-8)"
  done
done
