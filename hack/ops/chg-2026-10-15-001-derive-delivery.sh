#!/usr/bin/env bash
# chg-2026-10-15-001 option B: derived delivery = live web7m6 profiel-2/3 + plugins/huiswerk (verbatim from the
# huiswerk hermes-public bundle) + ONE config.yaml line ('    - "huiswerk"' after '    - "gezin"' in plugins.enabled).
#   hack/ops/chg-2026-10-15-001-derive-delivery.sh <web7m6-root> <hermes-public-root> <out-root>
# Prints counts, sha256 prefixes and the diff -rq against web7m6 only.
set -euo pipefail
BASE="${1:?web7m6}"; HP="${2:?hermes-public}"; OUT="${3:?out}"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
( cd "$BASE" && shasum -a 256 -c --strict SHA256SUMS >/dev/null )
( cd "$HP" && shasum -a 256 -c --strict SHA256SUMS >/dev/null )
mkdir -p "$OUT"
for n in 2 3; do
  cp -Rp "$BASE/profiel-$n" "$OUT/profiel-$n"
  [ ! -e "$OUT/profiel-$n/plugins/huiswerk" ] || { echo "huiswerk already in base" >&2; exit 1; }
  cp -Rp "$HP/profiel-$n/plugins/huiswerk" "$OUT/profiel-$n/plugins/huiswerk"
  python3 -I - "$OUT/profiel-$n/config.yaml" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
i = lines.index("plugins:")
assert lines[i + 1] == "  enabled:" and lines[i + 2] == '    - "gezin"', "unexpected plugins block"
assert not lines[i + 3].startswith("    - "), "more plugins than expected"
lines.insert(i + 3, '    - "huiswerk"')
open(p, "w").write("\n".join(lines))
PY
done
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derived: $(grep -c . "$OUT/SHA256SUMS") files, SHA256SUMS sha256 $(shasum -a 256 "$OUT/SHA256SUMS" | cut -c1-12)"
for n in 2 3; do
  echo "== diff -rq web7m6/profiel-$n derived/profiel-$n"
  diff -rq "$BASE/profiel-$n" "$OUT/profiel-$n" | sed "s#$BASE#web7m6#g; s#$OUT#derived#g" || true
  echo "== config.yaml diff profiel-$n"
  diff "$BASE/profiel-$n/config.yaml" "$OUT/profiel-$n/config.yaml" || true
  for f in __init__.py plugin.yaml instellingen.json; do
    echo "huiswerk/$f sha256 $(shasum -a 256 "$OUT/profiel-$n/plugins/huiswerk/$f" | cut -c1-12) git $(git hash-object "$OUT/profiel-$n/plugins/huiswerk/$f" | cut -c1-8) == hermes-public: $(cmp -s "$OUT/profiel-$n/plugins/huiswerk/$f" "$HP/profiel-$n/plugins/huiswerk/$f" && echo yes || echo NO)"
  done
done
