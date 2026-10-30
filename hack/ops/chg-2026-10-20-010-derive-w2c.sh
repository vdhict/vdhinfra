#!/usr/bin/env bash
# chg-2026-10-20-010 W2c: derive ONE profile's deploy bundle = what is LIVE on that profile (bundle from origin/main)
# with only the W2c change set taken from the family-ai render (Mack, mack/2026-10-30-w2c 55a8d96), everything else
# kept byte-for-byte from live:
#   profiel-3: settings.json only (budget_usd -> $BUDGET; every other key byte-equal to live, incl. workspace_id)
#   profiel-1/2: config.yaml (the land-2 cloud provider block; removed lines must be exactly the two provider/default
#                lines) + the 4 family-cloud files; settings.json gets the live profiel-3 workspace_id and $BUDGET
#   every other file: live bytes; a file where live and render differ is KEPT LIVE and counted (never silently
#   replaced: e.g. profiel-1's live kennis/webeerlijk are a newer delivery than the render base)
# Interim cap (Atlas/Argus 30-10): budget_usd = 99 in all three bundles on the one shared ledger, so the month reset
# in family-cloud can allow at most 2 x 99 = 198 < 200 (October + 1-14 November, cut-off 2026-11-14T00:00Z).
#
#   BUDGET=99 hack/ops/chg-2026-10-20-010-derive-w2c.sh <render-root> <1|2|3> <out-root>
#
# Writes only <out-root> (must not exist; 0700). Never prints file content or the workspace id. Then:
#   hack/family-ai/build-bundle.sh <n> <out-root>/delivery
set -euo pipefail
RENDER="${1:?render root}"; N="${2:?profile number}"; OUT="${3:?out root}"; BUDGET="${BUDGET:-99}"
case "$N" in 1|2|3) ;; *) echo "profile must be 1, 2 or 3" >&2; exit 2;; esac
[[ "$BUDGET" =~ ^[0-9]+$ ]] && [ "$BUDGET" -gt 0 ] && [ "$BUDGET" -le 99 ] || { echo "BUDGET must be 1..99 (interim cap)" >&2; exit 2; }
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel)"
FC=plugins/model-providers/family-cloud
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
die() { echo "REFUSED: $*" >&2; exit 1; }
R="$RENDER/profiel-$N"; [ -d "$R" ] || die "no profiel-$N in render"
[ -z "$(cd "$R" && find . -type l)" ] || die "symlink in render"
mkdir -p "$OUT"; chmod 700 "$OUT"; mkdir -p "$OUT/live" "$OUT/live3" "$OUT/delivery/profiel-$N"

unpack() { # $1 profile, $2 dir: origin/main bundle -> dir, SHA256SUMS verified; prints the outer sha256
  git -C "$ROOT" show "origin/main:kubernetes/main/apps/family-ai/hermes/profiel-$1/bundle.sops.yaml" > "$OUT/p$1.sops.yaml"
  sops -d --extract '["data"]["bundle.tar.gz"]' "$OUT/p$1.sops.yaml" | base64 -d > "$OUT/p$1.tar.gz"
  tar -xzf "$OUT/p$1.tar.gz" -C "$2"
  ( cd "$2" && shasum -a 256 -c --strict --quiet SHA256SUMS ) || die "live profiel-$1 SHA256SUMS failed"
  sha "$OUT/p$1.tar.gz"; }
LIVE_OUTER=$(unpack "$N" "$OUT/live")
[ "$N" = 3 ] && cp -R "$OUT/live/." "$OUT/live3/" || unpack 3 "$OUT/live3" >/dev/null
L="$OUT/live"
live_files=$(cd "$L" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort)
render_files=$(cd "$R" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
added=$(LC_ALL=C comm -13 <(echo "$live_files") <(echo "$render_files"))
removed=$(LC_ALL=C comm -23 <(echo "$live_files") <(echo "$render_files"))
[ -z "$removed" ] || die "render drops live files"
if [ "$N" = 3 ]; then
  [ -z "$added" ] || die "render adds files to profiel-3"
  CHANGE="$FC/settings.json"
else
  [ "$added" = "$(printf '%s\n' $FC/__init__.py $FC/cloud-SOUL.md $FC/plugin.yaml $FC/settings.json)" ] || die "render adds an unexpected file set"
  echo "$live_files" | grep -q "^$FC/" && die "profiel-$N already has family-cloud live"
  CHANGE="config.yaml $FC/__init__.py $FC/cloud-SOUL.md $FC/plugin.yaml $FC/settings.json"
  gone_lines=$(diff "$L/config.yaml" "$R/config.yaml" | grep '^<' || true)
  [ "$gone_lines" = '<   provider: "custom"
<   default: "${FAMILY_LLM_MODEL}"' ] || die "config.yaml: removed lines are not exactly the provider/default pair"
fi

# copy live, then the change set from the render
( cd "$L" && COPYFILE_DISABLE=1 tar -cf - $live_files ) | ( cd "$OUT/delivery/profiel-$N" && tar -xf - )
for f in $CHANGE; do mkdir -p "$OUT/delivery/profiel-$N/$(dirname "$f")"; cp "$R/$f" "$OUT/delivery/profiel-$N/$f"; done
# family-cloud pins: __init__.py and plugin.yaml byte-equal to the live profiel-3 ones (the reviewed plugin); the
# cloud SOUL pin in settings matches the file; the SOUL pin matches this profile's live SOUL.md
D="$OUT/delivery/profiel-$N"
for f in $FC/__init__.py $FC/plugin.yaml; do [ "$(sha "$D/$f")" = "$(sha "$OUT/live3/$f")" ] || die "$f differs from live profiel-3"; done
python3 -I - "$D/$FC/settings.json" "$OUT/live3/$FC/settings.json" "$R/$FC/settings.json" "$D/SOUL.md" "$D/$FC/cloud-SOUL.md" "$N" "$BUDGET" <<'PY' || die "settings.json check failed"
import hashlib, json, sys
out, live3, rend, soul, csoul, n, budget = sys.argv[1:8]
l3, r = json.load(open(live3)), json.load(open(rend))
w = l3.get("workspace_id")
assert isinstance(w, str) and w.startswith("wrkspc_"), "live profiel-3 workspace id"
assert list(r)[-1] == "workspace_id", "render: workspace_id last"
drop = {"workspace_id", "budget_usd"}
if n == "3":
    assert {k: v for k, v in r.items() if k not in drop} == {k: v for k, v in l3.items() if k not in drop}, "profiel-3 settings: keys other than budget/workspace differ from live"
    d = dict(l3)
else:
    same = {k for k in ("provider", "endpoint", "model", "prices_usd_per_million", "soft_fraction", "timeout_seconds",
                        "input_token_ceiling", "output_token_ceiling", "price_source", "context_tokens", "vision")}
    assert all(r.get(k) == l3.get(k) for k in same), "profiel-%s settings: provider/price/ceiling keys differ from live profiel-3" % n
    assert r["person"] == "profiel-" + n and r["price_confirmed"] is True, "person/price_confirmed"
    d = dict(r)
d["budget_usd"] = int(budget)
d["workspace_id"] = w
d = {k: v for k, v in d.items() if k != "workspace_id"} | {"workspace_id": w}   # workspace_id stays the last key
t = open(soul, "rb").read().decode()
c = open(csoul, "rb").read().decode().strip()
assert hashlib.sha256(t[:d["soul_chars"]].encode()).hexdigest() == d["soul_sha256"], "soul pin != live SOUL.md"
assert len(c) == d["cloud_soul_chars"] and hashlib.sha256(c.encode()).hexdigest() == d["cloud_soul_sha256"], "cloud SOUL pin"
open(out, "w").write(json.dumps(d, indent=2) + "\n")
print("settings: budget_usd %s, person %s, price_confirmed %s, workspace id from live profiel-3 (not printed)"
      % (d["budget_usd"], d["person"], d["price_confirmed"]))
PY
kept_live=0; same=0
while IFS= read -r f; do
  case " $CHANGE " in *" $f "*) continue;; esac
  [ "$(sha "$L/$f")" = "$(sha "$D/$f")" ] || die "copy of live $f differs"
  if [ -f "$R/$f" ] && [ "$(sha "$R/$f")" != "$(sha "$L/$f")" ]; then kept_live=$((kept_live + 1)); echo "kept live (render differs): $f"; else same=$((same + 1)); fi
done <<<"$live_files"
( cd "$OUT/delivery" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS )
echo "derive-w2c profiel-$N: live outer ${LIVE_OUTER:0:12}; live files $(echo "$live_files" | wc -l | tr -d ' '); changed/added $(echo $CHANGE | wc -w | tr -d ' '); same as render $same; kept live $kept_live; delivery files $(grep -c . "$OUT/delivery/SHA256SUMS")"
for f in $CHANGE; do echo "set ${f}: $(sha "$D/$f" | cut -c1-12)"; done
