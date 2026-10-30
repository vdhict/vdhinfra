#!/usr/bin/env bash
# chg-2026-10-20-010 offline tests of the W2c post-checks (hack/ops/chg-2026-10-20-010-w2c-checks.sh), Atlas 30-10.
#
#   bash hack/ops/chg-2026-10-20-010-test-w2c-checks.sh [--mutants]
#
# Fixtures (hack/ops/fixtures/c010-w2c/), captured read-only 2026-10-30 ~10:03Z: the live profiel-3 pod (land-2 wiring),
# (route records: all 54 inside the recorded 27-10 go windows; timestamps made relative to the first record, Argus H2)
# its own ledger + marker, profiel-3's 54 land-2 route records (27-10, ts/route/rule/id_class only), the shared ledger +
# marker + seed, the guard logs of both stage A runs, the CNP names now, and the W2c pod templates rendered from the
# reviewed stage C2 tree. Synthetic (derived in the scratch dir from those): settings, ledger pairs for B/C turns,
# mutated pods/logs/records. Numbers only, no family data, no secret. --mutants: every mutant of the library must make
# at least one case red. No cluster, no network. No rm (scratch under $TMPDIR). Exit 0 iff all pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; LIB="${C010_W2C_LIB:-$HERE/chg-2026-10-20-010-w2c-checks.sh}"; FX="$HERE/fixtures/c010-w2c"
T=$(mktemp -d "${TMPDIR:-/tmp}/c010-w2c-checks-XXXXXX"); PASS=0; FAIL=0; QUIET="${C010_QUIET:-}"
# shellcheck source=/dev/null
. "$LIB"
t() { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?; [ "$rc" != 0 ] && rc=1
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); [ -n "$QUIET" ] || echo "PASS  $name"; else FAIL=$((FAIL+1)); [ -n "$QUIET" ] || echo "FAIL  $name (rc $rc, want $want)"; fi; }
G=0; R=1
j() { jq "$1" "$2" > "$3"; }   # derive a mutated fixture
PIN=$(jq -r '.spec.containers[] | select(.name=="app") | .image' "$FX/p3-pod-w2c.json")
RES=0.43008   # a synthetic reservation, used consistently by the ledger pairs below (the live go computes it from the pod's settings)

# ---------------------------------------------------------------- init containers (stage A 65d2c336 false RED)
t "init: live land-2 profiel-3 pod (seed-once ConfigMap env) is green"            $G w2c_init_no_secret "$FX/p3-pod-land2.json"
for n in 1 2 3; do t "init: W2c profiel-$n pod template green"                     $G w2c_init_no_secret "$FX/p$n-pod-w2c.json"; done
j '.spec.initContainers[0].env += [{"name":"X","valueFrom":{"secretKeyRef":{"name":"s","key":"k"}}}]' "$FX/p3-pod-w2c.json" "$T/i1.json"
t "init: a secretKeyRef in seed-once is red"                                       $R w2c_init_no_secret "$T/i1.json"
j '(.spec.initContainers[] | select(.name=="cloud-spend-init")).envFrom = [{"secretRef":{"name":"s"}}]' "$FX/p3-pod-w2c.json" "$T/i2.json"
t "init: an envFrom secretRef in cloud-spend-init is red"                          $R w2c_init_no_secret "$T/i2.json"
j '(.spec.initContainers[] | select(.name=="cloud-spend-init")).env = [{"name":"Y","valueFrom":{"configMapKeyRef":{"name":"c","key":"k"}}}]' "$FX/p3-pod-w2c.json" "$T/i3.json"
t "init: a ConfigMap env in cloud-spend-init stays green"                          $G w2c_init_no_secret "$T/i3.json"
# ---------------------------------------------------------------- image pin
t "image: W2c profiel-3 pinned + HERMES_IMAGE == image == PINNED"                  $G w2c_image_pinned "$FX/p3-pod-w2c.json" "$PIN"
t "image: W2c profiel-2 pinned"                                                     $G w2c_image_pinned "$FX/p2-pod-w2c.json" "$PIN"
t "image: W2c profiel-1 pinned"                                                     $G w2c_image_pinned "$FX/p1-pod-w2c.json" "$PIN"
j '(.spec.containers[] | select(.name=="app") | .env[] | select(.name=="HERMES_IMAGE")).value = "docker.io/nousresearch/hermes-agent:latest"' "$FX/p2-pod-w2c.json" "$T/m1.json"
t "image: HERMES_IMAGE drift is red"                                                $R w2c_image_pinned "$T/m1.json"
j '(.spec.containers[] | select(.name=="app")).image = "docker.io/nousresearch/hermes-agent:v0.22.5"' "$FX/p2-pod-w2c.json" "$T/m2.json"
t "image: image without digest is red"                                              $R w2c_image_pinned "$T/m2.json"
t "image: other pinned value than the plugin's is red"                             $R w2c_image_pinned "$FX/p3-pod-w2c.json" "docker.io/x:y@sha256:$(printf '0%.0s' {1..64})"
# ---------------------------------------------------------------- ledger mounts
for n in 1 2 3; do t "mounts: W2c profiel-$n on the shared ledger, old ledger only p3 guard ro" $G w2c_ledger_mounts "$FX/p$n-pod-w2c.json" $n; done
t "mounts: live land-2 profiel-3 (own ledger) is red as a W2c pod"                 $R w2c_ledger_mounts "$FX/p3-pod-land2.json" 3
j '(.spec.volumes[] | select(.name=="cloud-spend-old")).persistentVolumeClaim.readOnly = false' "$FX/p3-pod-w2c.json" "$T/v1.json"
t "mounts: profiel-3 old ledger writable is red"                                    $R w2c_ledger_mounts "$T/v1.json" 3
j '.spec.volumes += [{"name":"cloud-spend-old","persistentVolumeClaim":{"claimName":"hermes-profiel-cloud-spend-3","readOnly":true}}]' "$FX/p2-pod-w2c.json" "$T/v2.json"
t "mounts: profiel-2 mounting profiel-3's old ledger is red"                       $R w2c_ledger_mounts "$T/v2.json" 2
j '(.spec.volumes[] | select(.name=="cloud-spend")).persistentVolumeClaim.claimName = "hermes-profiel-cloud-spend-2"' "$FX/p2-pod-w2c.json" "$T/v3.json"
t "mounts: profiel-2 on an own ledger is red"                                       $R w2c_ledger_mounts "$T/v3.json" 2
# ---------------------------------------------------------------- settings
for n in 1 2 3; do echo "{\"budget_usd\": 99, \"price_confirmed\": true, \"person\": \"profiel-$n\"}" > "$T/s$n.json"
  t "settings: profiel-$n budget 99 / confirmed / person" $G w2c_settings "$T/s$n.json" $n; done
echo '{"budget_usd": 200, "price_confirmed": true, "person": "profiel-3"}' > "$T/sx1.json"; t "settings: budget 200 (land 2) is red" $R w2c_settings "$T/sx1.json" 3
echo '{"budget_usd": 99, "price_confirmed": false, "person": "profiel-3"}' > "$T/sx2.json"; t "settings: price_confirmed false (guard refusal) is red" $R w2c_settings "$T/sx2.json" 3
t "settings: wrong person is red"                                                   $R w2c_settings "$T/s2.json" 3
# ---------------------------------------------------------------- ledger / seed / guard / totals
t "ledger: real shared ledger schema green"                                        $G w2c_ledger_schema "$FX/shared-ledger.json"
t "ledger: real profiel-3 own ledger schema green"                                 $G w2c_ledger_schema "$FX/p3-own-ledger.json"
j '. + {"note": 1}' "$FX/shared-ledger.json" "$T/l1.json";      t "ledger: extra key is red" $R w2c_ledger_schema "$T/l1.json"
j '.usd = -1' "$FX/shared-ledger.json" "$T/l2.json";            t "ledger: negative usd is red" $R w2c_ledger_schema "$T/l2.json"
j 'del(.person_usd["profiel-1"])' "$FX/shared-ledger.json" "$T/l3.json"; t "ledger: missing person is red" $R w2c_ledger_schema "$T/l3.json"
t "seed: real seed green"                                                          $G w2c_seed "$FX/shared-seed.json"
j '.source = "created"' "$FX/shared-seed.json" "$T/sd1.json";   t "seed: other source is red" $R w2c_seed "$T/sd1.json"
t "guard A: first move (A run 1) green"                                            $G w2c_guard_ok "$FX/guard-log-A1-first-move.txt" A
t "guard A: already seeded, kept (A retry: today's case) green"                    $G w2c_guard_ok "$FX/guard-log-A2-already-seeded.txt" A
t "guard B: kept green"                                                            $G w2c_guard_ok "$FX/guard-log-A2-already-seeded.txt" B
t "guard B: a move outside stage A is red"                                         $R w2c_guard_ok "$FX/guard-log-A1-first-move.txt" B
for code in not-seeded ledger-missing ledger-corrupt old-ledger-invalid lock-unavailable; do
  echo "cloud-spend-init: REFUSED $code; ledger left as is; cloud off (price_confirmed=false)" > "$T/g-$code.txt"
  t "guard A: REFUSED $code is red" $R w2c_guard_ok "$T/g-$code.txt" A; done
: > "$T/g-empty.txt"; t "guard A: no guard log is red" $R w2c_guard_ok "$T/g-empty.txt" A
cat "$FX/guard-log-A2-already-seeded.txt" > "$T/g-mixed.txt"; echo "cloud-spend-init: REFUSED marker-future; x" >> "$T/g-mixed.txt"
t "guard A: kept + a REFUSED line is red"                                          $R w2c_guard_ok "$T/g-mixed.txt" A
t "total: real shared ledger == profiel-3 own total before the push"              $G w2c_total_equal "$FX/shared-ledger.json" "$FX/p3-own-ledger.json"
j '.usd += 0.01 | .person_usd["profiel-3"] += 0.01' "$FX/shared-ledger.json" "$T/t1.json"; t "total: differing total is red" $R w2c_total_equal "$T/t1.json" "$FX/p3-own-ledger.json"
j '.usd += 0.01' "$FX/shared-ledger.json" "$T/t4.json"; t "total: only the usd total differs (person amounts equal) is red" $R w2c_total_equal "$T/t4.json" "$FX/p3-own-ledger.json"
j '.person_usd["profiel-2"] = 0.1' "$FX/shared-ledger.json" "$T/t2.json"; t "total: differing person split is red" $R w2c_total_equal "$T/t2.json" "$FX/p3-own-ledger.json"
j '.usd = 0 | .person_usd["profiel-3"] = 0' "$FX/shared-ledger.json" "$T/t3.json"; t "total: a fresh (zero) ledger is red" $R w2c_total_equal "$T/t3.json" "$FX/p3-own-ledger.json"
cp "$FX/shared-ledger.json" "$T/same.json"; t "bytes: restart kept the ledger byte-for-byte" $G w2c_same_bytes "$T/same.json" "$FX/shared-ledger.json"
jq -c . "$FX/shared-ledger.json" > "$T/re.json"; t "bytes: a rewritten ledger is red" $R w2c_same_bytes "$T/re.json" "$FX/shared-ledger.json"
# ---------------------------------------------------------------- cloud CNPs (stage pre/post + rollback/cloud-off read-back)
t "cnp: now (after both rollbacks) == none (cloud-off read-back)"                  $G w2c_cloud_cnps "$FX/cnp-names-now.json" ""
t "cnp: now != {3} (stage A expectation) is red"                                    $R w2c_cloud_cnps "$FX/cnp-names-now.json" 3
j '. + ["hermes-profiel-3-cloud"]' "$FX/cnp-names-now.json" "$T/c3.json";            t "cnp: {3} after stage A green" $G w2c_cloud_cnps "$T/c3.json" 3
j '. + ["hermes-profiel-2-cloud"]' "$T/c3.json" "$T/c23.json"
t "cnp: an extra profiel-2 CNP in stage A/B1 is red"                                $R w2c_cloud_cnps "$T/c23.json" 3
t "cnp: {2,3} after B2 green"                                                      $G w2c_cloud_cnps "$T/c23.json" 2,3
t "cnp: profiel-2 CNP missing after B2 is red"                                     $R w2c_cloud_cnps "$T/c3.json" 2,3
t "cnp: a still present CNP after cloud-off is red"                                $R w2c_cloud_cnps "$T/c3.json" ""
yq -o=json '.' "$HERE/../../kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml" > "$T/cnp3.json" 2>/dev/null \
  || git -C "$HERE" show 12a9579d:kubernetes/main/apps/family-ai/network-policies/app/hermes-profiel-3-cloud.yaml | yq -o=json '.' > "$T/cnp3.json"
t "cnp spec: live == repo green"                                                    $G w2c_cnp_spec_eq "$T/cnp3.json" "$T/cnp3.json"
j '.spec.egress[0].toPorts[0].ports += [{"port":"80","protocol":"TCP"}]' "$T/cnp3.json" "$T/cnp3x.json"; t "cnp spec: an extra port is red" $R w2c_cnp_spec_eq "$T/cnp3x.json" "$T/cnp3.json"
# ---------------------------------------------------------------- turns: real land-2 records (27-10)
/usr/bin/python3 -I - "$FX/p3-route-records-land2.json" "$T" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); t = sys.argv[2]
pick = lambda rule, n=1: [x for x in r if x[2] == rule][:n]
cf, ok1, pc = pick("cloud_failed")[0], pick("cloud_ok")[0], pick("private_context", 3)
w = lambda name, recs: json.dump({"records": recs}, open("%s/%s.json" % (t, name), "w"))
w("fb-1", [cf]); w("fb-0", []); w("fb-2", [cf, [cf[0] + 1] + cf[1:]]); w("fb-tool", [cf, pc[0]]); w("fb-cloud", [cf, ok1])
w("ct-1", [ok1]); w("ct-0", []); w("ct-studio", [pc[0]]); w("ct-2", [ok1, [ok1[0] + 1] + ok1[1:]])
w("web-ok", [ok1, [ok1[0] + 2] + pc[0][1:]]); w("web-only", [ok1]); w("web-hist", [ok1, [ok1[0] + 2, "studio", "history_not_cloud", "chatcmpl-"]])
w("priv-ok", pc); w("priv-cloud", [pc[0], ok1])
w("fb-c1run1", [pc[0]])                                   # C1 run 1 (30-10): the turn never reached the cloud
w("fb-late", [pc[0], [pc[0][0] + 1] + cf[1:]])             # a private record before the cloud attempt
w("web-studio", [pc[0], [pc[0][0] + 1] + pc[1][1:]]); w("web-cloud", [pc[0], [pc[0][0] + 2] + ok1[1:]])
w("web-failed", [pc[0], [pc[0][0] + 2] + cf[1:]]); w("web-other-first", [[pc[0][0] - 1, "studio", "not_interactive", "chatcmpl-"], pc[0]]); w("web-first-cloud", [[pc[0][0] - 1] + ok1[1:], pc[0]])
base = json.load(open(sys.argv[1].replace("p3-route-records-land2", "shared-ledger")))
def led(name, dusd=0.0, who="profiel-2", dtok=0, other=0.0):
    d = json.loads(json.dumps(base)); d["usd"] += dusd + other; d["person_usd"][who] += dusd; d["input_tokens"] += dtok
    if other: d["person_usd"]["profiel-1"] += other
    json.dump(d, open("%s/%s.json" % (t, name), "w"))
res = 0.43008
led("L0"); led("L-res", res); led("L-0"); led("L-2res", 2 * res); led("L-res-tok", res, dtok=10); led("L-res-other", res, other=0.01)
led("L-turn", 0.0159, dtok=7500); led("L-turn0", 0.0, dtok=7500); led("L-turnbig", res + 0.01, dtok=7500); led("L-turn-notok", 0.0159)
led("L-turn-p3", 0.0159, who="profiel-3", dtok=7500)
PY
t "fallback: exactly one studio/cloud_failed (real record), one reservation"       $G w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-res.json" $RES 2 1
t "fallback: + a Studio tool follow-up (private_context) stays green"              $G w2c_fallback "$T/fb-tool.json" "$T/L0.json" "$T/L-res.json" $RES 2 1
t "fallback: C1 run 1 (only studio/private_context: never reached the cloud) is red" $R w2c_fallback "$T/fb-c1run1.json" "$T/L0.json" "$T/L-0.json" $RES 1 0
t "fallback: a private_context before the cloud attempt is red"                 $R w2c_fallback "$T/fb-late.json" "$T/L0.json" "$T/L-res.json" $RES 2 1
t "fallback: zero cloud_failed is red"                                             $R w2c_fallback "$T/fb-0.json" "$T/L0.json" "$T/L-res.json" $RES 2 1
t "fallback: two cloud_failed (a retry) is red"                                    $R w2c_fallback "$T/fb-2.json" "$T/L0.json" "$T/L-2res.json" $RES 2 1
t "fallback: two cloud_failed with one reservation is red"                      $R w2c_fallback "$T/fb-2.json" "$T/L0.json" "$T/L-res.json" $RES 2 1
t "fallback: a cloud_ok in the window is red"                                      $R w2c_fallback "$T/fb-cloud.json" "$T/L0.json" "$T/L-res.json" $RES 2 1
t "fallback: ledger unchanged (no reservation) is red"                             $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-0.json" $RES 2 1
t "fallback: two reservations is red"                                              $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-2res.json" $RES 2 1
t "fallback: tokens counted (a billed call) is red"                                $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-res-tok.json" $RES 2 1
t "fallback: another person's amount moved is red"                                 $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-res-other.json" $RES 2 1
t "fallback: reservation booked on the wrong person is red"                        $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-res.json" $RES 1 1
t "fallback: failure-line delta 0 is red"                                          $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-res.json" $RES 2 0
t "fallback: failure-line delta 2 is red"                                          $R w2c_fallback "$T/fb-1.json" "$T/L0.json" "$T/L-res.json" $RES 2 2
t "cloud turn: one cloud/cloud_ok (real), delta > 0 and <= cap, tokens rose"       $G w2c_cloud_turn "$T/ct-1.json" "$T/L0.json" "$T/L-turn.json" $RES 2 plain
t "cloud turn: delta 0 is red"                                                     $R w2c_cloud_turn "$T/ct-1.json" "$T/L0.json" "$T/L-turn0.json" $RES 2 plain
t "cloud turn: missing route record is red"                                        $R w2c_cloud_turn "$T/ct-0.json" "$T/L0.json" "$T/L-turn.json" $RES 2 plain
t "cloud turn: a Studio record instead is red"                                     $R w2c_cloud_turn "$T/ct-studio.json" "$T/L0.json" "$T/L-turn.json" $RES 2 plain
t "cloud turn: two cloud calls on a plain turn is red"                             $R w2c_cloud_turn "$T/ct-2.json" "$T/L0.json" "$T/L-turn.json" $RES 2 plain
t "cloud turn: delta above one reservation is red"                                 $R w2c_cloud_turn "$T/ct-1.json" "$T/L0.json" "$T/L-turnbig.json" $RES 2 plain
t "cloud turn: no tokens counted is red"                                           $R w2c_cloud_turn "$T/ct-1.json" "$T/L0.json" "$T/L-turn-notok.json" $RES 2 plain
t "cloud turn: spend booked on another person is red"                              $R w2c_cloud_turn "$T/ct-1.json" "$T/L0.json" "$T/L-turn-p3.json" $RES 2 plain
t "web turn: cloud_ok then the tool result on the Studio (private_context)"        $G w2c_cloud_turn "$T/web-ok.json" "$T/L0.json" "$T/L-turn.json" $RES 2 web
t "web turn: no tool call (cloud_ok only) is red"                                  $R w2c_cloud_turn "$T/web-only.json" "$T/L0.json" "$T/L-turn.json" $RES 2 web
t "web turn: follow-up with another rule is red"                                   $R w2c_cloud_turn "$T/web-hist.json" "$T/L0.json" "$T/L-turn.json" $RES 2 web
t "web question (profiel-1): Studio only, private_context first, ledger unchanged" $G w2c_web_stays_studio "$T/web-studio.json" "$T/L0.json" "$T/L0.json"
t "web question: a single private_context record green"                          $G w2c_web_stays_studio "$T/priv-ok.json" "$T/L0.json" "$T/L0.json"
t "web question: becomes cloud_ok is red"                                         $R w2c_web_stays_studio "$T/web-cloud.json" "$T/L0.json" "$T/L-turn.json"
t "web question: cloud_ok first is red"                                           $R w2c_web_stays_studio "$T/web-first-cloud.json" "$T/L0.json" "$T/L0.json"
t "web question: a cloud attempt (cloud_failed) is red"                           $R w2c_web_stays_studio "$T/web-failed.json" "$T/L0.json" "$T/L0.json"
t "web question: ledger moved is red"                                             $R w2c_web_stays_studio "$T/web-studio.json" "$T/L0.json" "$T/L-res.json"
t "web question: another Studio rule first (no pre-search seen) is red"          $R w2c_web_stays_studio "$T/web-other-first.json" "$T/L0.json" "$T/L0.json"
t "web question: no record at all is red"                                         $R w2c_web_stays_studio "$T/fb-0.json" "$T/L0.json" "$T/L0.json"
printf 'vergeet\tprivate\tok\tx\ta\nvergeet next\tnext\tok\tx\ta\nimage\tprivate\tok\tx\tb\nimage next\tnext\tok\tx\tb\n' > "$T/f6-ok.tsv"
t "private turns: 4 rows ok"                                                       $G w2c_private_rows "$T/f6-ok.tsv" 4
head -3 "$T/f6-ok.tsv" > "$T/f6-3.tsv"; t "private turns: 3 rows (a skipped turn) is red" $R w2c_private_rows "$T/f6-3.tsv" 4
sed '2s/\tok\t/\tred\t/' "$T/f6-ok.tsv" > "$T/f6-red.tsv"; t "private turns: a red row is red" $R w2c_private_rows "$T/f6-red.tsv" 4
t "private window: real private_context records green"                             $G w2c_private_window "$T/priv-ok.json"
t "private window: a private turn that went to the cloud is red"                   $R w2c_private_window "$T/priv-cloud.json"
t "private window: no record at all is red"                                        $R w2c_private_window "$T/fb-0.json"
echo '{"data":[{"id":"hermes-agent-profiel-2"},{"id":"gezin"}]}' > "$T/mo1.json"; t "models: only the own agent green" $G w2c_models_only "$T/mo1.json" 2
echo '{"data":[{"id":"hermes-agent-profiel-2"},{"id":"hermes-agent-profiel-3"}]}' > "$T/mo2.json"; t "models: another agent listed is red" $R w2c_models_only "$T/mo2.json" 2
t "http: 200 with content green"                                                   $G w2c_http_answer 200 "bytes=10 json=yes content=yes"
t "http: 000 is red"                                                               $R w2c_http_answer 000 "bytes=0 json=no content=no"
t "http: 200 without content is red"                                               $R w2c_http_answer 200 "bytes=10 json=yes content=no"

echo "RESULT $PASS/$((PASS+FAIL)) PASS"
RC=$([ $FAIL = 0 ] && echo 0 || echo 1)
if [ "${1:-}" = --mutants ] && [ "$RC" = 0 ]; then
  M=0; CAUGHT=0
  while IFS='|' read -r label a b; do
    [ -n "$label" ] || continue
    M=$((M+1)); mut="$T/mut-$M.sh"
    /usr/bin/python3 -I -c 'import sys; s=open(sys.argv[1]).read(); a=sys.argv[2]; assert s.count(a)>=1, a; open(sys.argv[4],"w").write(s.replace(a, sys.argv[3], 1))' "$LIB" "$a" "$b" "$mut" || { echo "MUTANT $M not applicable: $label"; continue; }
    if C010_W2C_LIB="$mut" C010_QUIET=1 bash "$0" >/dev/null 2>&1; then echo "SURVIVED  mutant $M: $label"; else CAUGHT=$((CAUGHT+1)); echo "caught    mutant $M: $label"; fi
  done <<'EOF'
the stage-A bug: drop map(select(.))|map(select(.)) | length > 0|length > 0
the A-retry bug: stage A requires the first move|moved: month\.json|shared month\.json present, kept)|moved: month\.json)
guard: REFUSED ignored|grep -q 'REFUSED' "$1" && return 1|:
total: usd not compared|a["usd"]==b["usd"] and |
total: person split not compared|and a["person_usd"]==b["person_usd"] |
image: env not compared to the image|[ "$env" = "$img" ]|true
mounts: old ledger readOnly not required|{"claimName": "hermes-profiel-cloud-spend-3", "readOnly": True}|{"claimName": "hermes-profiel-cloud-spend-3"}
settings: budget not checked|[99,true,|[200,true,
cnp: extra CNPs ignored|[ "$got" = "$want" ]|[ -z "$want" ] || [[ ",$got," == *",$want,"* ]]
fallback: two cloud_failed allowed|and len(cf)==1 and|and len(cf)>=1 and
fallback: reservation not checked|ok=ok and abs((b["usd"]-a["usd"])-res)<1e-9|ok=ok or abs((b["usd"]-a["usd"])-res)<1e-9
fallback: failure-line delta not checked|ok=ok and sys.argv[6]=="1"|ok=ok
cloud turn: delta 0 allowed|0<d<=n*res|0<=d<=n*res
cloud turn: no cap|0<d<=n*res+1e-9|0<d
cloud turn: rule list not checked|if sys.argv[6]=="plain": ok=rules==["cloud/cloud_ok"]|if sys.argv[6]=="plain": ok=True
cloud turn: web follow-up rule not checked|all(x=="studio/private_context" for x in rules[1:])|True
private window: cloud allowed|all(x[1]=="studio" and not x[2].startswith("cloud") for x in r)|all(True for x in r)
private rows: count not checked|[ "$(wc -l < "$1" | tr -d ' ')" = "$2" ] && |
models: other agents ignored|select(startswith("hermes-agent"))|select(. == "hermes-agent-profiel-2")
fallback: first record not required to be the cloud attempt|sorted(r)[0][2]=="cloud_failed" and |
web: cloud records allowed|ok=bool(r) and sorted(r)[0][2]=="private_context" and all(x[1]=="studio" and not x[2].startswith("cloud") for x in r)|ok=bool(r) and sorted(r)[0][2]=="private_context"
web: first record not required private_context|sorted(r)[0][2]=="private_context" and all(|all(
web: ledger not compared|ok=ok and a["usd"]==b["usd"] and a["person_usd"]==b["person_usd"] and a["input_tokens"]==b["input_tokens"]|ok=ok
http: content not required|[ "$1" = 200 ] && grep -q 'content=yes' <<< "$2"|[ "$1" = 200 ]
EOF
  echo "MUTANTS $CAUGHT/$M caught"; [ "$CAUGHT" = "$M" ] || RC=1
fi
exit "$RC"
