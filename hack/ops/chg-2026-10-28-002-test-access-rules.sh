#!/usr/bin/env bash
# chg-2026-10-28-002 F-T3: tests for the per-rule Access check.
#
#   hack/ops/chg-2026-10-28-002-test-access-rules.sh
#
# 1. access-rules.py on every fixture in testdata/chg-2026-10-28-002/*.yaml;
#    the expected verdict is the "Expect: PASS|FAIL" word on line 1. The four
#    Argus cases: a top-level only, b wrong team, c second hostname without
#    the block -> FAIL; d correct -> PASS. e-i harden it (wrong AUD, quoted
#    "true", catch-all to an origin, flow style, duplicate key).
# 2. live drift: a live ConfigMap whose AUD differs from the git copy FAILs.
# 3. fresh: pods started at/after the ConfigMap change PASS; a stale pod and
#    no pods FAIL.
# 4. golive-check end to end in a throwaway git repo: --ref HEAD with fixture
#    a (top-level only) is NOT READY, with fixture d READY.
# 5. no output ever contains the dummy AUD or the dummy domain.
#
# Fixtures use a dummy AUD, never the real one. Temporary files go under
# ${TMPDIR}; nothing is deleted (AGR-121). Exit 0 all green, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TD="${HERE}/testdata/chg-2026-10-28-002"
RULES="${HERE}/chg-2026-10-28-002-access-rules.py"
GOLIVE="${HERE}/chg-2026-10-28-002-golive-check.sh"
PY="${PYTHON:-/usr/bin/python3}"; [ -x "${PY}" ] || PY=python3
DUMMY_AUD=dummy-aud-not-real-1111aaaa
S="$(mktemp -d "${TMPDIR:-/tmp}/chg-2026-10-28-002-test.XXXXXX")"
pass=0; failn=0; OUT="${S}/all-output.txt"; : > "${OUT}"

t() { # t <name> <expected rc> <cmd...>
  local name="$1" want="$2" rc; shift 2
  "$@" >> "${OUT}" 2>&1; rc=$?
  if [ "${rc}" = "${want}" ]; then echo "ok   ${name} (rc=${rc})"; pass=$((pass + 1))
  else echo "FAIL ${name} (rc=${rc}, want ${want})"; failn=$((failn + 1)); fi
}

echo "== 1 fixtures"
for f in "${TD}"/*.yaml; do
  want="$(head -1 "${f}" | sed -n -E 's/.*Expect: (PASS|FAIL).*/\1/p')"
  case "${want}" in PASS) rc=0 ;; FAIL) rc=1 ;; *) echo "FAIL $(basename "${f}") has no Expect: line"; failn=$((failn + 1)); continue ;; esac
  t "$(basename "${f}") -> ${want}" "${rc}" "${PY}" -I "${RULES}" rules --cm-yaml "${f}"
done

echo "== 2 live drift"
t "live cm == git d-correct -> PASS" 0 "${PY}" -I "${RULES}" rules --cm-json "${TD}/fresh-cm.json" --expect-from-cm-yaml "${TD}/d-correct.yaml"
sed 's/dummy-aud-not-real-1111aaaa/dummy-aud-not-real-3333cccc/g' "${TD}/d-correct.yaml" > "${S}/git-other-aud.yaml"
t "live cm AUD != git AUD -> FAIL" 1 "${PY}" -I "${RULES}" rules --cm-json "${TD}/fresh-cm.json" --expect-from-cm-yaml "${S}/git-other-aud.yaml"
t "git copy has placeholder AUD -> FAIL" 1 "${PY}" -I "${RULES}" rules --cm-json "${TD}/fresh-cm.json" \
  --expect-from-cm-yaml <(sed 's/dummy-aud-not-real-1111aaaa/replace-aud/g' "${TD}/d-correct.yaml")

echo "== 3 fresh"
t "pods at/after cm change -> PASS" 0 "${PY}" -I "${RULES}" fresh --cm-json "${TD}/fresh-cm.json" --pods-json "${TD}/fresh-pods-ok.json"
t "one pod older than cm -> FAIL" 1 "${PY}" -I "${RULES}" fresh --cm-json "${TD}/fresh-cm.json" --pods-json "${TD}/fresh-pods-stale.json"
t "no pods -> FAIL" 1 "${PY}" -I "${RULES}" fresh --cm-json "${TD}/fresh-cm.json" --pods-json "${TD}/fresh-pods-empty.json"
t "usage error -> 64" 64 "${PY}" -I "${RULES}" fresh --cm-json "${TD}/fresh-cm.json"

echo "== 4 golive-check end to end"
REPO_SRC="$(git -C "${HERE}" rev-parse --show-toplevel)"
R="${S}/repo"; mkdir -p "${R}/hack/ops"
git -C "${REPO_SRC}" archive HEAD kubernetes/main/apps/cursus-gast | tar -x -C "${R}"
cp "${RULES}" "${GOLIVE}" "${R}/hack/ops/"
CMF="${R}/kubernetes/main/apps/cursus-gast/cloudflared/app/configmap.yaml"
git -C "${R}" init -q && git -C "${R}" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
golive_with() { # golive_with <fixture> : commit it as the configmap, run --ref HEAD
  cp "${TD}/$1" "${CMF}"
  git -C "${R}" add -A && git -C "${R}" -c user.name=t -c user.email=t@example.invalid commit -q -m "$1" >/dev/null
  bash "${R}/hack/ops/chg-2026-10-28-002-golive-check.sh" --ref HEAD
}
t "golive-check, a top-level only -> NOT READY" 1 golive_with a-toplevel-only.yaml
t "golive-check, c second host no block -> NOT READY" 1 golive_with c-second-host-no-block.yaml
t "golive-check, d correct -> READY" 0 golive_with d-correct.yaml

echo "== 5 no value leaks"
n_aud="$(grep -c -e "${DUMMY_AUD}" -e 3333cccc -e 2222bbbb "${OUT}" || true)"
n_dom="$(grep -c 'example\.invalid' "${OUT}" || true)"
if [ "${n_aud}" = 0 ] && [ "${n_dom}" = 0 ]; then echo "ok   output holds no AUD (0) and no domain (0)"; pass=$((pass + 1))
else echo "FAIL output leaked: aud lines=${n_aud} domain lines=${n_dom}"; failn=$((failn + 1)); fi

echo "== result: ${pass} ok, ${failn} failed (output: ${OUT})"
[ "${failn}" -eq 0 ]
