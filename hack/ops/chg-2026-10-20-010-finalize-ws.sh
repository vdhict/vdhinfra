#!/usr/bin/env bash
# chg-2026-10-20-010 attempt 8: finalize the deploy candidate once the owner's Anthropic workspace id has arrived.
#
#   FAMILY_CLOUD_WORKSPACE_ID=... hack/ops/chg-2026-10-20-010-finalize-ws.sh <family-ai-render-worktree> <fai-commit> <revert-on-main>
#   (or put the id in <family-ai-render-worktree>/data/cloud-workspace-id, gitignored)
#
# Mechanical, so the review is of this script, not of a hand step:
#  1. the family-ai worktree is clean and at <fai-commit> (the reviewed render input, e.g. 32aae0c);
#  2. render-bundle (same procedure as before; the zeevaart refusal after profiel-3 is tolerated only if profiel-3
#     was written); config.yaml 0437f3f6, __init__.py 5c036956, plugin.yaml ba0794c5, cloud-SOUL.md b67506a7 by full
#     sha256; settings.json: workspace_id is wrkspc_<alnum> and settings.json minus workspace_id re-serialises to
#     exactly the reviewed settings bytes d3ea565e (so the id is the ONLY change);
#  3. derive-p3.sh and golive.sh: the settings.json pin d3ea565e -> sha256 of the new settings.json (one line each),
#     commit; 4. derive-p3 -> build-bundle -> git revert --no-commit <revert-on-main> + the new bundle -> wiring
#     commit last.
# Never prints the workspace id (only that it is valid) and never writes it outside the render dir and the encrypted
# bundle. Run with cwd = the vdhinfra deploy worktree at origin/main + the tooling commits. No rm.
set -euo pipefail
FAI="${1:?family-ai render worktree}"; FAI_COMMIT="${2:?family-ai commit}"; REVERT="${3:?the rollback revert on main}"
SRC="$(git rev-parse --show-toplevel)"; HACK="$SRC/hack"; CHG=chg-2026-10-20-010
TS=$(date -u +%Y%m%dT%H%M%SZ); OUT="$HOME/.cache/$CHG/finalize-ws-$TS"; mkdir -p "$OUT"; chmod 700 "$OUT"
OLD_SET=d3ea565e3280419b44567f57b87050d644cb25e26b015091eadb71ea99b7c542
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
die() { echo "REFUSED: $*" >&2; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain)" ] || die "vdhinfra worktree not clean"
[ "$(git -C "$FAI" rev-parse HEAD)" = "$(git -C "$FAI" rev-parse "$FAI_COMMIT")" ] || die "family-ai worktree not at $FAI_COMMIT"
[ -z "$(git -C "$FAI" status --porcelain)" ] || die "family-ai worktree not clean"
git -C "$SRC" merge-base --is-ancestor "$REVERT" HEAD || die "$REVERT is not in this tree"
# 1+2 render
( cd "$FAI" && bin/render-bundle --out "$OUT/render" --modus live --telt-vanaf 2026-09-27 > "$OUT/render.log" 2>&1 ) || true
R="$OUT/render/profiel-3"; [ -d "$R" ] || die "render wrote no profiel-3 (see $OUT/render.log)"
C="$R/plugins/model-providers/family-cloud"
for pin in "0437f3f6b58ecbc993bb00b1d7d7ab7c980ffb2da4fab715d884dd92c4e1b29f config.yaml" \
           "5c03695624140c0e0afe23e50d18ebb2b37ddbace7fb0c47cc8fde56c777fa33 plugins/model-providers/family-cloud/__init__.py" \
           "ba0794c5647d780f2edfddc806ba58f7519e80cc9975c86be7f0c7e950af4046 plugins/model-providers/family-cloud/plugin.yaml" \
           "b67506a71c1f29cbbacee91e487ad74c5a8736a32047cf6575ac61c70b356fd0 plugins/model-providers/family-cloud/cloud-SOUL.md"; do
  set -- $pin; [ "$(sha "$R/$2")" = "$1" ] || die "render pin mismatch: $2"
done
python3 -I - "$C/settings.json" "$OLD_SET" <<'PY' || die "settings.json: workspace id invalid or other keys changed"
import hashlib, json, re, sys
d = json.load(open(sys.argv[1]))
w = d.get("workspace_id")
assert isinstance(w, str) and re.fullmatch(r"wrkspc_[A-Za-z0-9]+", w), "workspace id"
assert list(d)[-1] == "workspace_id", "workspace_id must be the last key"
rest = {k: v for k, v in d.items() if k != "workspace_id"}
assert hashlib.sha256((json.dumps(rest, indent=2) + "\n").encode()).hexdigest() == sys.argv[2], "other keys changed"
assert open(sys.argv[1], "rb").read() == (json.dumps(d, indent=2) + "\n").encode(), "not the render's serialisation"
PY
NEW_SET=$(sha "$C/settings.json")
echo "finalize: render pins OK; settings.json = reviewed bytes + a valid workspace_id (not printed); new settings sha256 $NEW_SET"
# 3 pins
for f in "$HACK/ops/$CHG-derive-p3.sh" "$HACK/ops/$CHG-golive.sh"; do
  [ "$(grep -c "$OLD_SET" "$f")" = 1 ] || die "expected exactly one settings pin in ${f#$SRC/}"
  sed -i '' "s/$OLD_SET/$NEW_SET/" "$f"
  [ "$(grep -c "$NEW_SET" "$f")" = 1 ] || die "pin update failed in ${f#$SRC/}"
done
git -C "$SRC" add "$HACK/ops/$CHG-derive-p3.sh" "$HACK/ops/$CHG-golive.sh"
git -C "$SRC" -c user.name="${GIT_AUTHOR_NAME:-Sander van der Heijden}" -c user.email="${GIT_AUTHOR_EMAIL:-sheijden@vdhmini01.vdh.lan}" commit -q -F - <<EOF
chore(ops): $CHG pin settings.json with the owner's workspace id (family-ai $(git -C "$FAI" rev-parse --short HEAD))

settings.json $OLD_SET -> $NEW_SET: the reviewed settings bytes plus workspace_id (last key, wrkspc_<alnum>;
the value lives only in the encrypted bundle). Made by hack/ops/$CHG-finalize-ws.sh.

Uitgevoerd onder programmagoedkeuring family-ai (geldig tot 2026-10-31). AGR-109: tests are the gate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
PIN_COMMIT=$(git -C "$SRC" rev-parse HEAD)
# 4 derive + bundle + wiring
( cd "$SRC" && bash "$HACK/ops/$CHG-derive-p3.sh" "$OUT/render" "$OUT/derive" | head -1 )
DL="$OUT/derive/8d8d27a-web7m6-huiswerk1-lesstof4-f4-cloud-$(git -C "$FAI" rev-parse --short HEAD)-ws"
mv "$OUT/derive/delivery" "$DL"
( cd "$SRC" && git revert --no-commit "$REVERT" && bash "$HACK/family-ai/build-bundle.sh" 3 "$DL" | tail -1 | sed "s#$SRC/##" )
git -C "$SRC" add kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml
OUTER=$(grep -o 'bundle.tar.gz sha256 [0-9a-f]\{64\}' "$SRC/kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml" | awk '{print $3}')
git -C "$SRC" -c user.name="${GIT_AUTHOR_NAME:-Sander van der Heijden}" -c user.email="${GIT_AUTHOR_EMAIL:-sheijden@vdhmini01.vdh.lan}" commit -q -F - <<EOF
feat(family-ai): land 2 cloud canary wiring for hermes-profiel-3 ($CHG)

Wiring = revert of ${REVERT:0:8} (the last rollback) with the profiel-3 bundle re-derived from family-ai
$(git -C "$FAI" rev-parse --short HEAD) with the owner's workspace id: outer ${OUTER:0:8}. Wiring last, so the rollback reverts the
wiring and never the tooling. Made by hack/ops/$CHG-finalize-ws.sh.

Uitgevoerd onder programmagoedkeuring family-ai (geldig tot 2026-10-31). AGR-109: tests are the gate.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
echo "finalize: pin commit $PIN_COMMIT; wiring $(git -C "$SRC" rev-parse HEAD); bundle outer $OUTER; work dir $OUT"
