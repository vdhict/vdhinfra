#!/usr/bin/env bash
# chg-2026-11-02-012 stage 2, G1 pre-merge guard (design s8, Argus verdict B1/B2/C12/Q2/Q7).
# Usage: hack/ops/chg-2026-11-02-012-g1-guard.sh <app-dir> [--config]
#   <app-dir>  kubernetes/main/apps/network/headscale/app (in the tree that is about to be pushed)
#   --config   also assert the commit-B config.yaml settings (DERP, expiry, D7)
# Checks:
#   1. `headscale policy check` in the RUNNING pinned v0.29.7 pod, policy fed over stdin (no file left in the pod).
#   2. Static policy guard: grants present and non-empty, acls absent or empty, no autoApprovers, no "*" / autogroup:internet /
#      danger-all, tagOwners all empty lists (B1), exactly one hosts entry and it is a single /32 (C12),
#      the canary grant is exactly B2.
#   3. (--config) DERP on, urls [], auto_update off, verify_clients on, ipv4 "", ipv6 "none", placeholders gone (Q2),
#      node.expiry 180d (Q7), taildrop off + register_cache_max_entries 64 (D7), grpc on loopback.
# Prints PASS/FAIL lines only; exit 0 only if every check passed.
set -uo pipefail
APP="${1:?app dir}"
POL="$APP/config/policy.hujson"
CFG="$APP/config/config.yaml"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

# 1. live policy check against the pinned image in the running pod
if out=$(kubectl -n network exec -i deploy/headscale -- headscale policy check -f /dev/stdin < "$POL" 2>&1); then
  pass "policy-check v$(kubectl -n network exec deploy/headscale -- headscale version 2>/dev/null | awk '/^headscale version/{print $3}'): $(echo "$out" | tail -1)"
else
  bad "policy-check: $(echo "$out" | tail -3 | tr '\n' ' ')"
fi

# 2. static guard
python3 -I - "$POL" <<'PY' || fail=1
import json, sys
src = open(sys.argv[1]).read()
# strip // comments outside strings (HuJSON), then trailing commas
out, i, n, s = [], 0, len(src), False
while i < n:
    c = src[i]
    if s:
        out.append(c)
        if c == '\\': out.append(src[i+1]); i += 2; continue
        if c == '"': s = False
    elif c == '"': s = True; out.append(c)
    elif src.startswith('//', i):
        while i < n and src[i] != '\n': i += 1
        continue
    else: out.append(c)
    i += 1
import re
txt = re.sub(r',(\s*[}\]])', r'\1', ''.join(out))
p = json.loads(txt)
ok = True
def chk(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg)
    ok = ok and cond
g = p.get("grants")
chk(isinstance(g, list) and len(g) > 0, "grants key present and non-empty")
chk(p.get("acls", []) == [], "acls absent or empty")
chk("autoApprovers" not in p, "no autoApprovers")
flat = json.dumps(p)
chk('"*"' not in flat and "autogroup:internet" not in flat and "danger-all" not in flat, "no * / autogroup:internet / danger-all")
to = p.get("tagOwners", {})
chk(all(v == [] for v in to.values()) and len(to) > 0, "B1 tagOwners all empty lists (%d tags)" % len(to))
h = p.get("hosts", {})
chk(len(h) == 1 and all(re.fullmatch(r"\d+\.\d+\.\d+\.\d+/32", v) for v in h.values()), "C12 exactly one hosts entry, a single /32")
chk(h.get("vdhnblin01") == "100.64.0.1/32", "hosts vdhnblin01 == 100.64.0.1/32")
can = [x for x in g if "tag:canary" in x.get("src", [])]
chk(can == [{"src": ["tag:canary"], "dst": ["tag:agenthost"], "ip": ["tcp:22"]}], "B2 canary grant exactly tag:canary -> tag:agenthost tcp:22")
chk(all("tag:agenthost" not in x.get("src", []) for x in g), "tag:agenthost is never a source")
chk(all(x.get("ip") == ["tcp:22"] for x in g), "every grant is tcp:22 only")
chk(p.get("ssh", []) == [], "ssh rules empty")
sys.exit(0 if ok else 1)
PY

# 3. commit-B config assertions
if [[ "${2:-}" == "--config" ]]; then
  y() { yq -r "$1" "$CFG"; }
  [[ "$(y .derp.server.enabled)" == "true" ]] && pass "derp.server.enabled true" || bad "derp.server.enabled"
  [[ "$(y '.derp.urls | length')" == "0" ]] && pass "derp.urls empty (own DERP only, Q1)" || bad "derp.urls not empty"
  [[ "$(y .derp.auto_update_enabled)" == "false" ]] && pass "derp.auto_update_enabled false" || bad "derp.auto_update_enabled"
  [[ "$(y .derp.server.verify_clients)" == "true" ]] && pass "derp verify_clients true" || bad "verify_clients"
  [[ "$(y .derp.server.ipv4)" == "" ]] && pass "derp ipv4 empty (Q2)" || bad "derp ipv4 not empty"
  [[ "$(y .derp.server.ipv6)" == "none" ]] && pass "derp ipv6 none (Q2)" || bad "derp ipv6"
  grep -qE '198\.51\.100\.1|2001:db8::1' "$CFG" && bad "placeholders 198.51.100.1 / 2001:db8::1 still present" || pass "placeholders gone"
  [[ "$(y .node.expiry)" == "180d" ]] && pass "node.expiry 180d (Q7)" || bad "node.expiry"
  [[ "$(y .taildrop.enabled)" == "false" ]] && pass "taildrop off (D7)" || bad "taildrop"
  [[ "$(y .tuning.register_cache_max_entries)" == "64" ]] && pass "register_cache_max_entries 64 (D7)" || bad "register_cache"
  [[ "$(y .grpc_listen_addr)" == 127.0.0.1:* ]] && pass "grpc on loopback" || bad "grpc_listen_addr"
  [[ "$(y '.trusted_proxies | length')" == "0" ]] && pass "trusted_proxies empty" || bad "trusted_proxies"
fi

[[ $fail -eq 0 ]] && echo "G1 RESULT PASS" || echo "G1 RESULT FAIL"
exit $fail
