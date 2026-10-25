#!/usr/bin/env bash
# chg-2026-10-20-010 offline tests of hack/ops/chg-2026-10-20-010-c2-config.py, both C2 variants (Argus ruling pending).
#
#   bash hack/ops/chg-2026-10-20-010-test-c2-config.sh [<scratch-dir>]
#
# Synthetic YAML only (no profile content). Needs yq on PATH. Deletes nothing (AGR-121). Exit 0 iff all pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; C2="$HERE/chg-2026-10-20-010-c2-config.py"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-c2-XXXXXX")}"; mkdir -p "$B"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
run() { OUT=$(/usr/bin/python3 -I "$C2" "$@" 2>&1); RC=$?; export OUT; }
cat > "$B/bundle.yaml" <<'EOF'
model:
  default: family-studio
  provider: custom
auxiliary:
  voice_chat:
    provider: custom:family-studio
toolsets:
  - memory
  - gezin
plugins:
  enabled: [gezin, huiswerk, lesstof]
EOF
printf '["_config_version"]\t51\n' > "$B/allow.txt"; : > "$B/allow-empty.txt"
pod() { cp "$B/bundle.yaml" "$B/$1.yaml"; shift 0; }
pod ok; printf '_config_version: 51\n' >> "$B/ok.yaml"
run keys "$B/bundle.yaml" "$B/ok.yaml" "$B/allow.txt"
t "K1 keys: bundle + appended _config_version 51 (the measured v0.22.5 rewrite) -> PASS" bash -c "[ $RC = 0 ] && grep -q 'PASS C2 keys' <<< \"\$OUT\""
pod s52; printf '_config_version: 52\n' >> "$B/s52.yaml"; run keys "$B/bundle.yaml" "$B/s52.yaml" "$B/allow.txt"
t "K2 keys: allowed key with another value (52) -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'allowed keys with a value other than allowed' <<< \"\$OUT\""
pod extra; printf '_config_version: 51\nweb:\n  keyless_fallback: true\n' >> "$B/extra.yaml"; run keys "$B/bundle.yaml" "$B/extra.yaml" "$B/allow.txt"
t "K3 keys: pod adds a key not on the allow-list -> FAIL (names the path)" bash -c "[ $RC != 0 ] && grep -q 'not on the allow-list: .*web.*keyless_fallback' <<< \"\$OUT\""
sed 's/default: family-studio/default: family-cloud/' "$B/ok.yaml" > "$B/chg.yaml"; run keys "$B/bundle.yaml" "$B/chg.yaml" "$B/allow.txt"
t "K4 keys: a bundle value changed in the pod -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'different value in the pod: .*model.*default' <<< \"\$OUT\""
grep -v 'provider: custom$' "$B/ok.yaml" > "$B/rm.yaml"; run keys "$B/bundle.yaml" "$B/rm.yaml" "$B/allow.txt"
t "K5 keys: a bundle key missing in the pod -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'missing in the pod: .*model.*provider' <<< \"\$OUT\""
awk '{print} $0 == "  - gezin" {print "  - terminal"}' "$B/ok.yaml" > "$B/list.yaml"; run keys "$B/bundle.yaml" "$B/list.yaml" "$B/allow.txt"
t "K6 keys: a list in the pod gains an element (toolsets) -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'different value in the pod: .*toolsets' <<< \"\$OUT\""
run keys "$B/bundle.yaml" "$B/ok.yaml" "$B/allow-empty.txt"
t "K7 keys: empty allow-list, pod adds the stamp -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'not on the allow-list' <<< \"\$OUT\""
run keys "$B/bundle.yaml" "$B/bundle.yaml" "$B/allow.txt"
t "K8 keys: pod identical to the bundle (no stamp) -> PASS" bash -c "[ $RC = 0 ]"
printf 'model: [unclosed\n' > "$B/broken.yaml"; run keys "$B/bundle.yaml" "$B/broken.yaml" "$B/allow.txt"
t "K9 keys: pod config not YAML -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'cannot parse' <<< \"\$OUT\""
# ---------------------------------------------------------------- posthash
REF=$(/usr/bin/python3 -I "$C2" derive "$B/bundle.yaml"); printf '%s  config.yaml  # test\n' "$REF" > "$B/ref.txt"
run posthash "$B/ok.yaml" "$B/ref.txt"
t "H1 posthash: pod == bundle + stamp line == derived reference -> PASS" bash -c "[ $RC = 0 ] && grep -q 'PASS C2 posthash' <<< \"\$OUT\""
run posthash "$B/s52.yaml" "$B/ref.txt"
t "H2 posthash: stamp 52 instead of 51 -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'FAIL C2 posthash: pod config.yaml' <<< \"\$OUT\""
run posthash "$B/bundle.yaml" "$B/ref.txt"
t "H3 posthash: pod without the stamp -> FAIL" bash -c "[ $RC != 0 ]"
{ cat "$B/ok.yaml"; printf ' '; } > "$B/ws.yaml"; run posthash "$B/ws.yaml" "$B/ref.txt"
t "H4 posthash: one extra byte -> FAIL" bash -c "[ $RC != 0 ]"
printf '# no hash here\n' > "$B/noref.txt"; run posthash "$B/ok.yaml" "$B/noref.txt"
t "H5 posthash: reference file without a sha256 -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'no sha256' <<< \"\$OUT\""
t "H6 the committed reference = derive(profiel-3 wiring config.yaml) when that file is given" bash -c "[ -z \"\${C010_WIRING_CONFIG:-}\" ] || [ \"\$(/usr/bin/python3 -I '$C2' derive \"\$C010_WIRING_CONFIG\")\" = \"\$(awk '!/^#/ && NF {print \$1; exit}' '$HERE/chg-2026-10-20-010-c2-posthash.txt')\" ]"
# ---------------------------------------------------------------- gate = posthash AND keys (Argus ruling_c2)
run gate "$B/bundle.yaml" "$B/ok.yaml" "$B/allow.txt" "$B/ref.txt"
t "G1 gate: computed ref == committed, pod hash == ref, keys PASS -> PASS" bash -c "[ $RC = 0 ] && grep -q 'PASS C2 gate: posthash AND keys' <<< \"\$OUT\""
cp "$B/bundle.yaml" "$B/bundle2.yaml"; printf 'extra: 1\n' >> "$B/bundle2.yaml"; run gate "$B/bundle2.yaml" "$B/ok.yaml" "$B/allow.txt" "$B/ref.txt"
t "G2 gate: bundle no longer matches the committed reference -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'reference computed now from the bundle' <<< \"\$OUT\""
printf '["_config_version"]\t51\n["web", "x"]\t1\n' > "$B/allow-wide.txt"; run gate "$B/bundle.yaml" "$B/ok.yaml" "$B/allow-wide.txt" "$B/ref.txt"
t "G3 gate: allow-list wider than exactly _config_version = 51 -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'allow file must be exactly' <<< \"\$OUT\""
printf '["_config_version"]\t"51"\n' > "$B/allow-str.txt"; run gate "$B/bundle.yaml" "$B/ok.yaml" "$B/allow-str.txt" "$B/ref.txt"
t "G4 gate: allow value \"51\" (string, not integer) -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'allow file must be exactly' <<< \"\$OUT\""
pod qs; printf '_config_version: "51"\n' >> "$B/qs.yaml"; run keys "$B/bundle.yaml" "$B/qs.yaml" "$B/allow.txt"
t "G5 keys: pod stamps the string \"51\" instead of the integer -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'allowed keys with a value other than allowed' <<< \"\$OUT\""
printf '"a/b": 1\n' > "$B/alias-b.yaml"; printf 'a:\n  b: 1\n' > "$B/alias-p.yaml"; run keys "$B/alias-b.yaml" "$B/alias-p.yaml" "$B/allow.txt"
t "G6 keys (E1): key \"a/b\" does not alias the path a -> b (tuple paths) -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'missing in the pod' <<< \"\$OUT\""
printf 'not-json-path\t51\n' > "$B/allow-bad.txt"; run keys "$B/bundle.yaml" "$B/ok.yaml" "$B/allow-bad.txt"
t "G7 keys: allow file line not <JSON path><TAB><JSON value> -> FAIL" bash -c "[ $RC != 0 ] && grep -q 'allow file line is not' <<< \"\$OUT\""
run gate "$B/bundle.yaml" "$B/ok.yaml" "$HERE/chg-2026-10-20-010-c2-allow.txt" "$B/ref.txt"
t "G8 the committed allow file is exactly the ruling (gate accepts it)" bash -c "[ $RC = 0 ]"
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
