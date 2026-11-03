#!/usr/bin/env bash
# chg-2026-11-02-012 Headscale stage 2: verify + automatic rollback (design s5/s8, Argus verdict B3/Q5).
# Runs on vdhmini01 (macOS NECP: LAN probes only via /usr/bin/curl and nc; kubectl via its loopback proxy).
#
#   chg-2026-11-02-012-stage2-verify.sh            check only; the rollback branch is printed as DRY-RUN
#   chg-2026-11-02-012-stage2-verify.sh --act      on a ROLLBACK-class failure: forwards off, git revert, push
#   HS_VERIFY_DRILL=1 <either mode>                 inject one synthetic failure (drill; with --act it REALLY rolls back)
#
# Classes:
#   ROLLBACK  a negative test failed (exposure or authorisation is wrong), the canary is stale (>30 min), or an
#             envoy-internal / Home Assistant regression. Action (--act): 1) forwards.sh off (PUT + GET readback, by
#             Hermod's script and _ids), 2) git revert of the newest stage-2 commit on origin/main that is not reverted
#             yet (allow-list below; NEVER 590dfc38 = stage 1, prune would delete the PVC and the Noise key), push to
#             main, Flux reconcile, 3) one change-log line + one ntfy push (priority min 23-07, AGR-074).
#   WARN      worth a line in the digest, no action (vdhnblin01 offline: it is a laptop; lease/pin drift).
# Output: PASS/FAIL/WARN lines; a write-once evidence file per run; a change-log line on the first run, on any
# failure and on any action. Exit 0 all pass, 1 rollback-class failure, 2 warn only, 3 inconclusive (kubectl down).
# Never prints secrets: no set -x; headscale output is reduced to ids/names/tags/flags by jq before it is shown.
set -uo pipefail
umask 077
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
CHG=chg-2026-11-02-012
EVD=$REPO/ops/evidence/$CHG/stage2-verify
FWD=$REPO/hack/ops/chg-2026-11-02-012-forwards.sh
GUARD="$(cd "$(dirname "$0")" && pwd)/chg-2026-11-02-012-g1-guard.sh"   # shipped next to this script
STAGE1=590dfc38
# stage-2 commits this script may revert, newest last (commit A policy, commit B exposure prep). Extend per commit.
REVERTABLE=(eb57efdd 90e738cd)
LB=172.16.2.249
CURL=/usr/bin/curl
ACT=0; [ "${1:-}" = "--act" ] && ACT=1
FIRST_RUN_MARK=$EVD/.first-run-logged
# Latch: after ONE real rollback, later runs only report (no second revert, no push storm). A human clears it with
# `mv $EVD/.rolled-back <scratch>` after the cause is fixed.
LATCH=$EVD/.rolled-back

cd "$REPO" || exit 3
eval "$(mise env -s bash 2>/dev/null)" 2>/dev/null || true
command -v kubectl >/dev/null && command -v jq >/dev/null || { echo "INCONCLUSIVE kubectl/jq missing"; exit 3; }
mkdir -p "$EVD"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$EVD/verify-$TS$([ $ACT = 1 ] && echo -act).txt
[ -e "$OUT" ] && { echo "evidence exists, refusing to overwrite: $OUT" >&2; exit 3; }
exec > >(tee "$OUT") 2>&1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hs-verify.XXXXXX")

RB=0; WN=0; FAILS=()
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; RB=1; FAILS+=("$1"); }
warn() { echo "WARN $*"; WN=1; }
hs() { kubectl -n network exec deploy/headscale -- headscale "$@"; }
ts() { kubectl -n network exec deploy/headscale-canary -- tailscale --socket=/tmp/tailscaled.sock "$@"; }
open_tcp() { nc -z -G3 "$1" "$2" >/dev/null 2>&1; }

echo "# $CHG stage-2 verify $(date -u +%FT%TZ) mode=$([ $ACT = 1 ] && echo act || echo check) origin/main=$(git rev-parse --short origin/main 2>/dev/null)"
kubectl -n network get deploy headscale >/dev/null 2>&1 || { echo "INCONCLUSIVE kubectl cannot reach the cluster"; exit 3; }

# ---- T2 exposure on the LAN (negatives with a known-open control) ----
if open_tcp $LB 443; then
  pass "T2 control tcp/443 open on $LB"
  open_tcp $LB 9090 && fail "T2-9090 tcp/9090 OPEN on $LB (metrics must be ClusterIP only)" || pass "T2 tcp/9090 closed on $LB"
  open_tcp $LB 50443 && fail "T2-50443 tcp/50443 OPEN on $LB" || pass "T2 tcp/50443 closed on $LB"
  open_tcp $LB 8443 && fail "T2-8443 tcp/8443 OPEN on $LB" || pass "T2 tcp/8443 closed on $LB"
else
  fail "T2-control tcp/443 closed on $LB (headscale unreachable)"
fi
code=$($CURL -s -o /dev/null -w '%{http_code}' --max-time 6 --resolve headscale.bluejungle.net:443:$LB https://headscale.bluejungle.net/health)
[ "$code" = 200 ] && pass "T2 /health 200 with verified TLS" || fail "T2-health /health=$code"
code=$($CURL -s -o /dev/null -w '%{http_code}' --max-time 6 --resolve headscale.bluejungle.net:443:$LB https://headscale.bluejungle.net/api/v1/node)
[ "$code" = 401 ] && pass "T2 /api/v1/node 401 without a key" || fail "T2-api /api/v1/node=$code (expected 401)"
# STUN: Tailscale's server answers only requests with SOFTWARE=tailnode + FINGERPRINT (tailscale net/stun).
python3 -I -c '
import struct,sys,zlib,os
sw=b"tailnode"; a=struct.pack("!HH",0x8022,len(sw))+sw; tx=os.urandom(12)
m=struct.pack("!HHI",1,len(a)+8,0x2112A442)+tx+a
m+=struct.pack("!HHI",0x8028,4,(zlib.crc32(m)^0x5354554E)&0xFFFFFFFF)
open(sys.argv[1],"wb").write(m)' "$TMP/stunreq"
nc -u -w3 $LB 3478 < "$TMP/stunreq" > "$TMP/stunresp" 2>/dev/null
st=$(python3 -I -c '
import struct,sys
b=open(sys.argv[1],"rb").read()
if len(b)<20 or b[:2]!=b"\x01\x01": print("none"); sys.exit()
i=20; tx=b[8:20]
while i+4<=len(b):
    t,l=struct.unpack("!HH",b[i:i+4]); v=b[i+4:i+4+l]
    if t==0x20:
        a=bytes(x^y for x,y in zip(v[4:],b"\x21\x12\xa4\x42"+tx)); print(".".join(map(str,a[-4:]))); sys.exit()
    i+=4+l+((4-l%4)%4)
print("no-mapped")' "$TMP/stunresp")
case "$st" in none) fail "T2-stun no STUN reply from $LB:3478";; no-mapped) fail "T2-stun reply without mapped address";;
  172.16.*) pass "T2 STUN answered, mapped address = this host's LAN IP (source preserved)";;
  *) warn "T2 STUN answered, mapped first octet ${st%%.*} (not LAN: SNAT or hairpin?)";; esac

# ---- regression: envoy-internal and Home Assistant ----
code=$($CURL -sk -o /dev/null -w '%{http_code}' --max-time 6 https://172.16.2.241/)
[[ "$code" =~ ^[1-4][0-9][0-9]$ ]] && pass "REG envoy-internal .241 answers ($code)" || fail "REG-envoy envoy-internal .241 http=$code"
code=$($CURL -s -o /dev/null -w '%{http_code}' --max-time 6 http://172.16.2.237:8123/)
[ "$code" = 200 ] && pass "REG Home Assistant .237 200" || fail "REG-ha Home Assistant .237 http=$code"

# ---- control-plane state (B3, Q5, node set) ----
hs nodes list -o json > "$TMP/nodes.json" 2>/dev/null || echo '[]' > "$TMP/nodes.json"
jq -c '.[] | {id, name, given: .given_name, ip: .ip_addresses[0], tags, online}' "$TMP/nodes.json"
jq -e 'any(.[]; .id==1 and .name=="vdhnblin01" and (.ip_addresses|index("100.64.0.1")) != null and ((.tags//[])|length)==0)' "$TMP/nodes.json" >/dev/null \
  && pass "B3 100.64.0.1 == node id 1 vdhnblin01, untagged" || fail "B3 100.64.0.1 is not node id 1 vdhnblin01 (IP reuse?)"
jq -e '[.[] | select(.id!=1) | select(((.tags//[])|length)==0)] | length == 0' "$TMP/nodes.json" >/dev/null \
  && pass "NODES no untagged node other than id 1" || fail "NODES-untagged an untagged node other than id 1 exists"
unexpected=$(jq -r '.[] | select(.id!=1) | select(
    ((.tags//[]) == ["tag:canary"] and .name == "hs-canary") or
    ((.tags//[]) == ["tag:agenthost"] and .name == "vdhmini01") or
    ((.tags//[]) == ["tag:rekenkracht"] and (.name == "vdhllmsrv01" or .name == "vdhwslin01")) | not) | "\(.id):\(.name)"' "$TMP/nodes.json")
[ -z "$unexpected" ] && pass "NODES only the expected set (id1 + canary + named server tags)" || fail "NODES-unexpected node(s): $unexpected"
n=$(hs apikeys list -o json 2>/dev/null | jq 'length' 2>/dev/null)
[ "$n" = 0 ] && pass "Q5 API keys = 0" || fail "Q5-apikeys API key count = ${n:-?}"
hs preauthkeys list -o json 2>/dev/null | jq -c '[.[] | {id, tags: (.acl_tags // .aclTags), used, reusable}]' > "$TMP/pak.json"
echo "pre-auth keys (no material): $(cat "$TMP/pak.json")"
jq -e 'all(.[]; (.reusable != true) and ((.tags//[])|length) > 0)' "$TMP/pak.json" >/dev/null \
  && pass "PAK no reusable or untagged pre-auth key" || fail "PAK-unsafe reusable or untagged pre-auth key present"

# ---- live policy (G1 guard against what the server actually enforces) ----
mkdir -p "$TMP/live/config"
hs policy get > "$TMP/live/config/policy.hujson" 2>/dev/null
if "$GUARD" "$TMP/live" >"$TMP/guard.txt" 2>&1; then pass "POLICY live policy passes the G1 guard"
else fail "POLICY-guard live policy fails G1: $(grep FAIL "$TMP/guard.txt" | head -3 | tr '\n' ';')"; fi

# ---- canary (T1 negatives, staleness, own DERP) ----
ts status --json > "$TMP/cs.json" 2>/dev/null || echo '{}' > "$TMP/cs.json"
relay=$(jq -r '.Self.Relay // "none"' "$TMP/cs.json"); conline=$(jq -r '.Self.Online // false' "$TMP/cs.json")
ctags=$(jq -c '.Self.Tags // []' "$TMP/cs.json")
[ "$ctags" = '["tag:canary"]' ] && pass "CANARY tags = tag:canary" || fail "CANARY-tags canary tags = $ctags"
[ "$relay" = headscale ] && pass "T2 canary home DERP = headscale (own region 999)" || fail "T2-derp canary relay = $relay"
seen=$(jq -r '.[] | select(.name=="hs-canary") | .last_seen.seconds // empty' "$TMP/nodes.json")
online=$(jq -r '.[] | select(.name=="hs-canary") | .online' "$TMP/nodes.json")
if [ "$online" = true ] && [ "$conline" = true ]; then pass "CANARY online (headscale + tailscaled)"
elif [ -n "$seen" ] && [ $(( $(date +%s) - seen )) -le 1800 ]; then warn "CANARY not online now, last seen $(( ($(date +%s)-seen)/60 )) min ago"
else fail "CANARY-stale canary offline > 30 min"; fi
for t in "100.64.0.1 22" "100.64.0.1 443"; do
  kubectl -n network exec deploy/headscale-canary -- timeout 6 tailscale --socket=/tmp/tailscaled.sock nc $t </dev/null >/dev/null 2>&1 \
    && fail "T1-canary-nblin canary reached $t (must be denied)" || pass "T1 canary -> $t denied"
done
# Positive/negative toward tag:agenthost / tag:rekenkracht only once those nodes exist (S4).
mini=$(jq -r '.[] | select((.tags//[])==["tag:agenthost"]) | .ip_addresses[0]' "$TMP/nodes.json" | head -1)
studio=$(jq -r '.[] | select((.tags//[])==["tag:rekenkracht"]) | .ip_addresses[0]' "$TMP/nodes.json" | head -1)
if [ -n "$mini" ]; then
  kubectl -n network exec deploy/headscale-canary -- timeout 6 tailscale --socket=/tmp/tailscaled.sock nc "$mini" 22 </dev/null >/dev/null 2>&1 \
    && pass "T1 canary -> agenthost:22 open (positive control)" || warn "T1 canary -> agenthost:22 not reachable (positive control failed)"
  for p in 5900 445 9100; do kubectl -n network exec deploy/headscale-canary -- timeout 6 tailscale --socket=/tmp/tailscaled.sock nc "$mini" $p </dev/null >/dev/null 2>&1 \
    && fail "T1-canary-mini canary reached agenthost:$p" || pass "T1 canary -> agenthost:$p denied"; done
else echo "SKIP T1 agenthost tests: no tag:agenthost node yet (S4)"; fi
if [ -n "$studio" ]; then
  for p in 22 11434 5900; do kubectl -n network exec deploy/headscale-canary -- timeout 6 tailscale --socket=/tmp/tailscaled.sock nc "$studio" $p </dev/null >/dev/null 2>&1 \
    && fail "T1-canary-studio canary reached rekenkracht:$p (B2: must be denied)" || pass "T1 canary -> rekenkracht:$p denied"; done
else echo "SKIP T1 rekenkracht tests: no tag:rekenkracht node yet (S4); B2 asserted statically by the G1 guard above"; fi

# ---- warn-only drift ----
jq -e '.[] | select(.id==1) | .online' "$TMP/nodes.json" >/dev/null 2>&1 && [ "$(jq -r '.[] | select(.id==1) | .online' "$TMP/nodes.json")" = true ] \
  && pass "vdhnblin01 online" || warn "vdhnblin01 offline (laptop; informational)"
node=$(kubectl -n network get pod -l app.kubernetes.io/name=headscale,app.kubernetes.io/component=headscale -o jsonpath='{.items[0].spec.nodeName}')
lease=$(kubectl -n kube-system get lease cilium-l2announce-network-headscale -o jsonpath='{.spec.holderIdentity}')
[ "$node" = "$lease" ] && pass "D1 pod node == L2 lease holder ($node)" || warn "D1 pod on $node, lease on $lease (SNAT hop back)"

# ---- forwards (read-only status) ----
if [ -x "$FWD" ]; then echo "# forwards status:"; "$FWD" status 2>&1 | grep -viE 'key|token' | head -6; fi

# ---- verdict + action ----
rollback() {
  echo "# ROLLBACK triggered by: ${FAILS[*]}"
  target=""
  git fetch -q origin
  for c in "${REVERTABLE[@]}"; do
    git merge-base --is-ancestor "$c" origin/main 2>/dev/null || continue
    git log --format=%B origin/main | grep -q "This reverts commit $(git rev-parse "$c")" && continue
    target=$c
  done
  [ -n "$target" ] && [ "$(git rev-parse "$target")" = "$(git rev-parse $STAGE1 2>/dev/null)" ] && target=""   # never stage 1
  if [ -e "$LATCH" ]; then echo "LATCHED: a rollback already ran ($(cat "$LATCH")); report only, no action"; return; fi
  if [ $ACT = 0 ]; then
    echo "DRY-RUN would run: $FWD off   (PUT enabled=false on both forwards + GET readback)"
    echo "DRY-RUN would revert: ${target:-<nothing revertable>} on a worktree off origin/main, push to main, flux reconcile ks headscale"
    echo "DRY-RUN would push ntfy: 'chg-2026-11-02-012 stage-2 rollback: ${FAILS[*]}' (priority min 23-07)"
    return
  fi
  echo "$TS forwards-off + revert ${target:-none}" > "$LATCH"
  "$FWD" off; echo "forwards off exit=$?"
  if [ -n "$target" ]; then
    wt="$TMP/revert-wt"
    git worktree add -q --detach "$wt" origin/main && (
      cd "$wt" && git revert --no-edit "$target" && git push origin HEAD:main ) ; echo "revert $target push exit=$?"
    git worktree remove --force "$wt" 2>/dev/null
    flux reconcile source git flux-system -n flux-system >/dev/null 2>&1; flux reconcile ks headscale -n flux-system >/dev/null 2>&1
  fi
  if [ -f "$HOME/.config/aiops/ntfy.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.config/aiops/ntfy.env"
    h=$(TZ=Europe/Amsterdam date +%H); pr=4; { [ "$h" -ge 23 ] || [ "$h" -lt 7 ]; } && pr=1
    $CURL -s -o /dev/null -w 'ntfy http=%{http_code}\n' --max-time 10 -H "Priority: $pr" -H "Title: headscale stage-2 rollback" \
      -d "chg-2026-11-02-012: forwards off, reverted ${target:-nothing}. Failed: ${FAILS[*]}. Evidence: $OUT" "$NTFY_SERVER/$NTFY_ALERT_TOPIC"
  fi
}

# Drill (design T7): HS_VERIFY_DRILL=1 injects one synthetic rollback-class failure to exercise the action branch.
[ "${HS_VERIFY_DRILL:-0}" = 1 ] && fail "DRILL synthetic failure (HS_VERIFY_DRILL=1)"
echo "# RESULT rollback_class=$RB warn=$WN"
[ $RB = 1 ] && rollback
if [ $RB = 1 ] || [ ! -e "$FIRST_RUN_MARK" ]; then
  ./ops/ops change event "$CHG" executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "stage2-verify mode=$([ $ACT = 1 ] && echo act || echo check) rollback_class=$RB warn=$WN fails=${FAILS[*]:-none}" --arg e "${OUT#$REPO/}" '{step:"stage2-verify",summary:$s,evidence:$e}')" >/dev/null 2>&1 || echo "WARN change-log append failed"
  touch "$FIRST_RUN_MARK"
fi
# $TMP stays under $TMPDIR (no rm in unattended scripts, AGR-121); it holds no secrets (no key material is fetched).
[ $RB = 1 ] && exit 1; [ $WN = 1 ] && exit 2; exit 0
