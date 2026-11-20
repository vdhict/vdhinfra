#!/usr/bin/env bash
# chg-2026-11-20-080 (wq-017) envoy-gateway upgrade: per-hop readback gate R1-R12 + Argus G1/G3/G5.
# Plan: ops/evidence/chg-2026-11-20-080/envoy-replan-20261120T0920Z.txt, conditions:
# argus-envoy-replan-20261120T0926Z.txt.
#
# usage: STATE=<dir> envoy-gate.sh baseline <label>
#        STATE=<dir> envoy-gate.sh gate <label> <controller-tag> <gwapi-bundle>
#        STATE=<dir> envoy-gate.sh guard            (P1 authelia guard only)
# Writes nothing in the cluster. Side effects: kubectl dry-runs, short port-forwards (killed on exit),
# and, if Secret security/chg080-envoy-probe exists, one first-factor login of the no-group probe user
# (session destroyed at the end). Prints status codes and counts only: no hostnames, headers, cookies,
# config dumps or secret values (G3, G5). Exit 0 = all PASS.
set -u
MODE=${1:?mode}; LABEL=${2:-}; WANT=${3:-}; BUNDLE=${4:-}
STATE=${STATE:?set STATE}; mkdir -p "$STATE"
SINCE=$(cat "$STATE/hop-start-iso" 2>/dev/null || date -u -v-15M +%FT%TZ)
fail=0; PFS=""
ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*"; fail=1; }; info(){ echo "INFO $*"; }
cleanup(){ for p in $PFS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
gwip(){ case $1 in envoy-internal) echo 172.16.2.241;; envoy-external) echo 172.16.2.243;;
  envoy-forge) echo 172.16.2.251;; envoy-gezin) echo 172.16.2.253;; esac; }
host_of(){ kubectl -n "$1" get httproute "$2" -o jsonpath='{.spec.hostnames[0]}'; }
code(){ curl -s -o /dev/null -m 12 -w '%{http_code}' --resolve "$1:443:$2" "https://$1$3"; }
codek(){ curl -sk -o /dev/null -m 12 -w '%{http_code}' --resolve "$1:443:$2" "https://$1$3"; }
pf(){ kubectl -n "$1" port-forward "$2" "$3:$4" >/dev/null 2>&1 & PFS="$PFS $!"; disown $! 2>/dev/null; sleep 3; }

guard(){
  echo "== P1 authelia guard $(date -u +%FT%TZ) since=$SINCE"
  git -C "${REPO:-.}" fetch -q origin 2>/dev/null
  n=$(git -C "${REPO:-.}" log --since="$SINCE" --format=%h origin/main -- kubernetes/main/apps/security/authelia kubernetes/main/apps/security/lldap | wc -l | tr -d ' ')
  [[ $n == 0 ]] && ok "P1 no authelia/lldap commit on main since hop start" || bad "P1 $n authelia/lldap commits since $SINCE"
  cur="$(kubectl -n security get hr authelia -o jsonpath='{.status.lastAttemptedRevision}') gen=$(kubectl -n security get deploy authelia -o jsonpath='{.metadata.generation}') ready=$(kubectl -n security get deploy authelia -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
  if [[ -f $STATE/authelia-ref ]]; then
    [[ "$cur" == "$(cat "$STATE/authelia-ref")" ]] && ok "P1 authelia HR+deploy unchanged ($cur)" || bad "P1 authelia changed: $(cat "$STATE/authelia-ref") -> $cur"
  else echo "$cur" > "$STATE/authelia-ref"; info "P1 authelia ref recorded ($cur)"; fi
  pr=$(gh pr list --state open --search 'authelia in:title' --json number,autoMergeRequest --jq '[.[]|select(.autoMergeRequest!=null)]|length' 2>/dev/null)
  [[ "$pr" == 0 ]] && ok "P1 no open authelia PR with automerge" || bad "P1 authelia automerge PRs: [$pr]"
}

route_codes(){ # ns/name gw code, one line per spec parentRef on an https listener
  kubectl get httproute -A -o json | jq -r '.items[] | . as $r | .spec.parentRefs[] | select(.name|startswith("envoy")) | select((.sectionName // "") != "http") | "\($r.metadata.namespace) \($r.metadata.name) \(.name)"' | sort -u |
  while read -r ns n gw; do
    [[ $n == chg080-canary-* ]] && continue
    h=$(host_of "$ns" "$n"); [[ -z $h ]] && continue
    c=$(code "$h" "$(gwip "$gw")" /); echo "$ns/$n $gw $c"; done
}

snapshot(){ # P3, write-once into $1
  { echo "# P3 snapshot $(date -u +%FT%TZ) (no Secret objects)"
    for k in gateways httproutes httproutefilters securitypolicies envoypatchpolicies backendtlspolicies referencegrants envoyproxies; do
      echo "---- $k"; kubectl get "$k" -A -o yaml | grep -v -E '^\s+(kubectl.kubernetes.io/last-applied-configuration|f:)' ; done
  } > "$1"
}

r_all(){
  local ip241=172.16.2.241
  echo "== gate $LABEL $(date -u +%FT%TZ) want=$WANT bundle=$BUNDLE since=$SINCE"
  # R1
  hr=$(kubectl -n network get hr envoy-gateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.lastAttemptedRevision}')
  [[ "$(echo "$hr" | sed "s/ v/ /")" == "True ${WANT#v}"* ]] && ok "R1 HR $hr" || bad "R1 HR [$hr] want ${WANT#v}"
  img=$(kubectl -n network get deploy envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}')
  rd=$(kubectl -n network get deploy envoy-gateway -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')
  [[ "$img" == *":$WANT" || "$img" == *":$WANT@"* ]] && [[ $rd == 1/1 ]] && ok "R1 controller $img $rd" || bad "R1 controller $img $rd"
  mem=$(kubectl -n network top pod -l app.kubernetes.io/name=gateway-helm --no-headers 2>/dev/null | awk '{print $3}' | head -1); info "R1 controller mem $mem"
  kubectl -n network get deploy -l app.kubernetes.io/managed-by=envoy-gateway -o jsonpath='{range .items[*]}{.metadata.name} {.status.readyReplicas}/{.spec.replicas} {.status.updatedReplicas}{"\n"}{end}' | sort > "$STATE/px-now"
  pxn=$(awk '{print $1}' "$STATE/px-now" | tr '\n' ' '); pxb=$(awk '{print $1}' "$STATE/px-base" | tr '\n' ' ')
  [[ "$pxn" == "$pxb" ]] && ok "R1 proxy deploy names unchanged (4)" || bad "R1 proxy deploys [$pxn] base [$pxb]"
  nr=$(awk '$2!="2/2" || $3!="2"' "$STATE/px-now" | wc -l | tr -d ' '); [[ $nr == 0 ]] && ok "R1 8/8 proxy pods ready+updated" || bad "R1 proxy not ready: $(awk '$2!="2/2"||$3!="2"' "$STATE/px-now" | tr '\n' ';')"
  info "R1 proxy image $(kubectl -n network get deploy -l app.kubernetes.io/managed-by=envoy-gateway -o jsonpath='{.items[0].spec.template.spec.containers[0].image}')"
  kubectl -n network get svc -l app.kubernetes.io/managed-by=envoy-gateway -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.spec.type} {.status.loadBalancer.ingress[0].ip} {.metadata.labels.gateway\.envoyproxy\.io/owning-gateway-name}{"\n"}{end}' | sort > "$STATE/svc-now"
  cmp -s "$STATE/svc-now" "$STATE/svc-base" && ok "R1 proxy Service names+UIDs+LB IPs unchanged (.241 .243 .251 .253)" || bad "R1 svc delta: $(diff "$STATE/svc-base" "$STATE/svc-now" | tr '\n' ';')"
  dup=$(awk '$3=="LoadBalancer"{print $5}' "$STATE/svc-now" | sort | uniq -d | wc -l | tr -d ' '); [[ $dup == 0 ]] && ok "R1 one LB Service per gateway" || bad "R1 duplicate LB Service per gateway"
  al=$(kubectl -n network get svc envoy-internal envoy-external -o jsonpath='{.items[*].spec.type}'); [[ $al == "ExternalName ExternalName" ]] && ok "R1 ExternalName aliases intact" || bad "R1 aliases [$al]"
  # R2
  for g in envoy-internal envoy-external envoy-forge envoy-gezin; do
    p=$(kubectl -n network get gateway $g -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status} {.status.addresses[0].value}')
    [[ "$p" == "True $(gwip $g)" ]] && ok "R2 $g Programmed addr ok" || bad "R2 $g [$p]"; done
  dl=$(kubectl -n network logs deploy/external-dns-unifi --since-time="$SINCE" 2>/dev/null | grep -i -c -E 'delet')
  [[ $dl == 0 ]] && ok "R2 external-dns-unifi: 0 delete lines since hop start" || bad "R2 external-dns-unifi delete lines: $dl"
  # R3 (G1: spec parentRefs with a current status parent; stale parents reported only)
  r3=$(kubectl get httproute -A -o json | jq -r '.items[] | . as $r | .spec.parentRefs[] as $p |
     ([$r.status.parents[]? | select(.parentRef.name==$p.name and ((.parentRef.sectionName//"")==($p.sectionName//"")))][0]) as $s |
     "\($r.metadata.namespace)/\($r.metadata.name) \($p.name)/\($p.sectionName//"-") " +
     (if $s==null then "NOSTATUS" else ([$s.conditions[]|select(.type=="Accepted" or .type=="ResolvedRefs")|"\(.type)=\(.status):\(.observedGeneration==$r.metadata.generation)"]|sort|join(",")) end)')
  tot=$(echo "$r3" | grep -v chg080-canary | wc -l | tr -d ' '); badr=$(echo "$r3" | grep -v chg080-canary | grep -v -c 'Accepted=True:true,ResolvedRefs=True:true')
  [[ $badr == 0 && $tot == $(cat "$STATE/r3-base") ]] && ok "R3 $tot/$tot spec parentRefs Accepted+ResolvedRefs current" || bad "R3 tot=$tot base=$(cat "$STATE/r3-base") bad=$badr: $(echo "$r3" | grep -v chg080-canary | grep -v 'Accepted=True:true,ResolvedRefs=True:true' | tr '\n' ';')"
  stale=$(kubectl get httproute -A -o json | jq -r '[.items[] | . as $r | .status.parents[]? | select(.parentRef.name as $n | ($r.spec.parentRefs|map(.name)|index($n))==null)] | length')
  info "R3 stale status parents (not in spec, reported only): $stale"
  ow=$(host_of family-ai open-webui-gezin); c=$(code "$ow" 172.16.2.253 /api/v1/auths/signin); [[ $c == 403 ]] && ok "R3 filter family-ai/open-webui-gezin-local-auth-403 -> 403" || bad "R3 gezin filter $c"
  nt=$(host_of ntfy ntfy); c=$(code "$nt" $ip241 /v1/account); [[ $c == 404 ]] && ok "R3 filter ntfy/ntfy-account-404 -> 404" || bad "R3 ntfy filter $c"
  # route code map (R4d, R7 functional, R10)
  route_codes > "$STATE/codes-now"
  mm=$(join -j1 <(awk '{print $1"|"$2, $3}' "$STATE/codes-base" | sort) <(awk '{print $1"|"$2, $3}' "$STATE/codes-now" | sort) | awk '$2!=$3')
  if [[ -n $mm ]]; then sleep 5; route_codes > "$STATE/codes-now"
    mm=$(join -j1 <(awk '{print $1"|"$2, $3}' "$STATE/codes-base" | sort) <(awk '{print $1"|"$2, $3}' "$STATE/codes-now" | sort) | awk '$2!=$3'); fi
  nn=$(wc -l < "$STATE/codes-now" | tr -d ' '); nb=$(wc -l < "$STATE/codes-base" | tr -d ' ')
  [[ -z $mm && $nn == $nb ]] && ok "R4d/R7/R10 $nn route probes on their gateway = baseline code" || bad "route codes n=$nn base=$nb delta: $(echo "$mm" | tr '\n' ';')"
  # R4 auth
  au=$(host_of security authelia); tr=$(host_of mypka teamregie)
  loc=$(curl -s -o /dev/null -m 12 -w '%{http_code} %{redirect_url}' --resolve "$tr:443:$ip241" "https://$tr/")
  [[ "$loc" == "302 https://$au/"* ]] && ok "R4a teamregie no cookie -> 302 to auth host" || bad "R4a teamregie [${loc%% *}] (redirect host match: $([[ $loc == *"//$au/"* ]] && echo y || echo n))"
  if kubectl -n network get httproute chg080-canary-authz >/dev/null 2>&1; then
    c=$(codek chg080-canary-authz.invalid $ip241 /); [[ $c == 403 || $c == 5* ]] && ok "R4b canary extAuth fail-closed $c" || bad "R4b canary extAuth $c (200 = failed OPEN)"
    spm=$(kubectl -n network get securitypolicy chg080-canary-authz -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}')
    info "R4b canary SP Accepted=$spm (False 'no ready endpoints' is expected from 1.6)"
  else info "R4b canary not deployed"; fi
  if kubectl -n security get secret chg080-envoy-probe >/dev/null 2>&1; then
    hdr=$(kubectl -n security get secret chg080-envoy-probe -o json | jq -r '.data.password|@base64d' | jq -Rc '{username:"chg080-envoy-probe",password:.,keepMeLoggedIn:false}' |
      curl -s -D - -o /dev/null -m 12 -H 'Content-Type: application/json' --data-binary @- --resolve "$au:443:$ip241" "https://$au/api/firstfactor")
    ffc=$(echo "$hdr" | head -1 | awk '{print $2}'); sess=$(echo "$hdr" | tr -d '\r' | grep -i '^set-cookie: authelia_session=' | head -1 | sed 's/^[^=]*=//; s/;.*//')
    unset hdr
    if [[ $ffc == 200 && -n $sess ]]; then
      c=$(printf 'Cookie: authelia_session=%s\n' "$sess" | curl -s -o /dev/null -m 12 -w '%{http_code}' -H @- --resolve "$tr:443:$ip241" "https://$tr/")
      [[ $c == 403 ]] && ok "R4c probe user (no groups) session -> teamregie 403 (cookie + ext-authz transport ok)" || bad "R4c probe session teamregie $c (want 403)"
      printf 'Cookie: authelia_session=%s\n' "$sess" | curl -s -o /dev/null -m 12 -X POST -H @- -H 'Content-Type: application/json' --data '{}' --resolve "$au:443:$ip241" "https://$au/api/logout"
      unset sess
    else bad "R4c probe firstfactor $ffc (session cookie set: $([[ -n $sess ]] && echo y || echo n))"; unset sess; fi
  else info "R4c probe user secret absent"; fi
  gr=$(host_of observability grafana); c=$(code "$gr" $ip241 /); [[ $c == 302 ]] && ok "R4d grafana 302" || bad "R4d grafana $c"
  owi=$(host_of family-ai open-webui); l=$(curl -s -o /dev/null -m 12 -w '%{http_code} %{redirect_url}' --resolve "$owi:443:$ip241" "https://$owi/oauth/oidc/login")
  [[ "$l" == 302\ https://$au/api/oidc/authorization* ]] && ok "R4d open-webui OIDC start 302 to authorization" || bad "R4d open-webui oidc [${l%% *}]"
  pc=$(kubectl get httproute -n mypka teamregie -o json | jq -r '.status.parents[]|select(.parentRef.name=="envoy-internal")|.conditions[]|select(.type=="Accepted").status')
  sp=$(kubectl -n mypka get securitypolicy teamregie-authelia -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}')
  [[ $sp == True ]] && ok "R4 SecurityPolicy mypka/teamregie-authelia Accepted" || bad "R4 teamregie SP Accepted=$sp"
  sn=$(kubectl get pod -n mypka -l app.kubernetes.io/name=teamregie --no-headers 2>/dev/null | wc -l | tr -d ' '); info "R4 positive path: passive count in R12 access-log check (teamregie route 2xx)"
  # R5 + R6 via proxy admin (G3: extracted entries only)
  pe=$(kubectl -n network get pod -l gateway.envoyproxy.io/owning-gateway-name=envoy-external -o name | head -1)
  pf network "$pe" 19110 19000
  ae=$(curl -s -m 10 'http://127.0.0.1:19110/config_dump?resource=dynamic_route_configs' | jq -c '[.configs[]?.route_config | select(.name=="network/envoy-external/https") | .response_headers_to_add[]? | select(.header.key|ascii_downcase=="alt-svc") | .header.value]')
  [[ "$ae" == '["clear"]' ]] && ok "R5 envoy-external RouteConfiguration network/envoy-external/https Alt-Svc=clear" || bad "R5 envoy-external alt-svc $ae"
  ah=$(curl -s -D - -o /dev/null -m 12 --resolve "$gr:443:$ip241" "https://$gr/" | tr -d '\r' | grep -i '^alt-svc:' | awk '{print tolower($2)}')
  [[ "$ah" == clear ]] && ok "R5 envoy-internal response alt-svc: clear (grafana)" || bad "R5 internal alt-svc [$ah]"
  for e in altsvc-clear-internal altsvc-clear-external; do
    s=$(kubectl -n network get envoypatchpolicy $e -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}/{.status.ancestors[0].conditions[?(@.type=="Programmed")].status}')
    [[ $s == True/True ]] && ok "R5 $e Accepted/Programmed" || bad "R5 $e $s"; done
  i=0; for p in $(kubectl -n network get pod -l gateway.envoyproxy.io/owning-gateway-name=envoy-internal -o name); do pf network "$p" $((19120+i)) 19000; i=$((i+1)); done
  st(){ for port in 19120 19121; do curl -s -m 10 "http://127.0.0.1:$port/stats?filter=(synology-nas|studio-ai|chg080-canary-btls).*ssl\.(handshake|fail_verify_error|fail_verify_san|fail_verify_hash|connection_error)$"; done |
        sed -E 's/^cluster\.[^ ]*(synology-nas|studio-ai|chg080-canary-btls)[^ ]*\.ssl\.([a-z_]+): ([0-9]+)/\1 \2 \3/' | awk 'NF==3{a[$1" "$2]+=$3} END{for(k in a) print k, a[k]}' | sort; }
  st > "$STATE/ssl-a"
  sy=$(host_of network synology-nas); stu=$(host_of network studio-ai)
  c=$(code "$sy" $ip241 /); [[ $c == $(awk '$1=="network/synology-nas"{print $3}' "$STATE/codes-base") ]] && ok "R6 synology-nas $c (baseline)" || bad "R6 synology-nas $c"
  c=$(code "$stu" $ip241 /); [[ $c == 401 ]] && ok "R6 studio-ai 401 from upstream" || bad "R6 studio-ai $c"
  if kubectl -n network get httproute chg080-canary-btls >/dev/null 2>&1; then
    c=$(codek chg080-canary-btls.invalid $ip241 /); [[ $c == 503 ]] && ok "R6 canary wrong-hostname BackendTLS -> 503" || bad "R6 canary btls $c (200 = validation bypassed)"
  fi
  sleep 2; st > "$STATE/ssl-b"
  d(){ local b a; b=$(awk -v k="$1 $2" '$1" "$2==k{print $3}' "$STATE/ssl-b" | head -1); a=$(awk -v k="$1 $2" '$1" "$2==k{print $3}' "$STATE/ssl-a" | head -1); echo $(( ${b:-0} - ${a:-0} )); }
  for b in synology-nas studio-ai; do
    fv=$(( $(d $b fail_verify_error) + $(d $b fail_verify_san) + $(d $b fail_verify_hash) + $(d $b connection_error) ))
    [[ $fv == 0 ]] && ok "R6 $b ssl fail_verify/connection_error +0 during probe (handshake +$(d $b handshake))" || bad "R6 $b ssl failures +$fv"; done
  if kubectl -n network get httproute chg080-canary-btls >/dev/null 2>&1; then
    cf=$(( $(d chg080-canary-btls fail_verify_san) + $(d chg080-canary-btls fail_verify_error) )); [[ $cf -gt 0 ]] && ok "R6 canary ssl verify failures +$cf" || info "R6 canary verify-failure counter +$cf (503 above is the gate)"; fi
  info "R6 ssl counters (sum of 2 internal pods): $(tr '\n' ';' < "$STATE/ssl-b")"
  for b in studio-ai synology-nas; do
    s=$(kubectl -n network get backendtlspolicy $b -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}')
    [[ $s == True ]] && ok "R6 BackendTLSPolicy $b Accepted" || bad "R6 BTLS $b Accepted=$s"; done
  cleanup; PFS=""
  # R7 labels, selectors, hubble
  for g in envoy-internal envoy-external envoy-forge envoy-gezin; do
    n=$(kubectl -n network get pod -l "gateway.envoyproxy.io/owning-gateway-name=$g,gateway.envoyproxy.io/owning-gateway-namespace=network,app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy" --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
    [[ $n == 2 ]] && ok "R7 selector owning-gateway-name=$g (+namespace, name=envoy) -> 2 pods" || bad "R7 $g selector -> $n pods"; done
  ns=$(kubectl get cnp -A -o json | jq '[.items[] | select(tostring|test("owning-gateway-name"))] | length'); nc=$(kubectl get ccnp -o json | jq '[.items[] | select(tostring|test("owning-gateway-name"))] | length')
  [[ "$ns $nc" == "$(cat "$STATE/cnp-base")" ]] && ok "R7 envoy-label policies present: $ns CNP + $nc CCNP (baseline)" || bad "R7 policies $ns/$nc base $(cat "$STATE/cnp-base")"
  pf kube-system svc/hubble-relay 14245 80
  hubble observe --server 127.0.0.1:14245 --since "$SINCE" --verdict DROPPED --from-label 'k8s:io.kubernetes.pod.namespace=network' --from-label 'k8s:app.kubernetes.io/component=proxy' -o jsonpb 2>/dev/null |
    jq -r '.flow.destination.namespace // "world"' | sort | uniq -c | awk '{print $2"="$1}' | tr '\n' ' ' > "$STATE/drops-now"
  hubble observe --server 127.0.0.1:14245 --since "$SINCE" --verdict DROPPED --to-label 'k8s:io.kubernetes.pod.namespace=network' --to-label 'k8s:app.kubernetes.io/component=proxy' -o jsonpb 2>/dev/null |
    jq -r '.flow.source.namespace // "world"' | sort | uniq -c | awk '{print "to-envoy-from-"$2"="$1}' | tr '\n' ' ' >> "$STATE/drops-now"
  newd=""; for kv in $(cat "$STATE/drops-now"); do k=${kv%%=*}; grep -q -w -- "$k" "$STATE/drops-base" || newd="$newd $kv"; done
  [[ -z $newd ]] && ok "R7 hubble: no DROPPED flows to/from envoy in a namespace without baseline drops [$(cat "$STATE/drops-now")]" || bad "R7 hubble new drop namespaces:$newd"
  fw=$(hubble observe --server 127.0.0.1:14245 --since "$SINCE" --verdict FORWARDED --from-label 'k8s:io.kubernetes.pod.namespace=network' --from-pod network/headscale-gezin-router --to-label 'k8s:gateway.envoyproxy.io/owning-gateway-name=envoy-gezin' -o compact 2>/dev/null | wc -l | tr -d ' ')
  info "R7 headscale-gezin-router -> envoy-gezin FORWARDED flows since hop start: $fw (0 = unobserved, no traffic)"
  cleanup; PFS=""
  # R8 mypka VAP
  dom=${tr#*.}
  vp(){ cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: chg080-vap-probe, namespace: mypka}
spec:
  parentRefs: [{name: envoy-internal, namespace: network, sectionName: https}]
  hostnames: [mypka-chg080vapprobe.$dom]
  rules:
    - backendRefs: [{name: chg080-none, port: 80}]
$1
EOF
  }
  o=$(vp '      filters: [{type: RequestHeaderModifier, requestHeaderModifier: {add: [{name: x-chg080, value: "1"}]}}]' | kubectl apply --dry-run=server -f - 2>&1)
  [[ $o == *"mypka: HTTPRoute filters are not allowed"* ]] && ok "R8 VAP denies mypka route with filter" || bad "R8 VAP filter: ${o:0:160}"
  o=$(vp '' | kubectl apply --dry-run=server -f - 2>&1); [[ $o == *"created (server dry run)"* ]] && ok "R8 VAP admits valid mypka shape (dry-run)" || bad "R8 VAP valid: ${o:0:160}"
  # R9 + G1
  for g in envoy-external envoy-internal; do c=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --resolve "$gr:80:$(gwip $g)" "http://$gr/"); [[ $c == 301 ]] && ok "R9 $g http -> 301" || bad "R9 $g http $c"; done
  c=$(code "$gr" 172.16.2.243 /); [[ $c == 404 ]] && ok "R9 envoy-external https -> 404 (no https routes)" || bad "R9 external https $c"
  for r in home-automation/home-assistant-main tools/it-tools; do h=$(host_of ${r%/*} ${r#*/})
    a=$(curl -s -m 10 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$h&type=A" | jq '[.Answer[]?|select(.type==1)]|length')
    [[ $a == 0 ]] && ok "G1 public DoH A answers for $r = 0" || bad "G1 $r public A answers $a"; done
  cu=$(kubectl -n network logs deploy/external-dns-cloudflare-external --since-time="$SINCE" 2>/dev/null | grep -c -E 'CREATE|UPDATE')
  [[ $cu == 0 ]] && ok "G1 external-dns-cloudflare-external: 0 CREATE/UPDATE since hop start" || bad "G1 external-dns-cloudflare-external CREATE/UPDATE $cu"
  cr=$(kubectl -n cursus-gast get deploy cloudflared -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'); [[ $cr == 2/2 ]] && ok "R9 cloudflared 2/2 (tunnel bypasses Envoy, control)" || bad "R9 cloudflared $cr"
  # R10 forge git smart-http
  fh=$(host_of devtools forgejo); c=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --resolve "$fh:443:172.16.2.251" "https://$fh/chg080/probe.git/info/refs?service=git-upload-pack")
  [[ $c == $(cat "$STATE/git-base") ]] && ok "R10 forge git smart-HTTP info/refs via .251 = baseline $c" || bad "R10 forge git $c base $(cat "$STATE/git-base")"
  # R11 CRDs
  kubectl get crd -o json | jq -r '.items[] | select(.spec.group=="gateway.networking.k8s.io") | "\(.metadata.name) \(.metadata.annotations["gateway.networking.k8s.io/bundle-version"]) \(.metadata.annotations["gateway.networking.k8s.io/channel"]) \(.status.storedVersions|join(","))"' | sort > "$STATE/crd-now"
  if [[ -n $BUNDLE ]]; then
    wr=$(grep -v -E '^(x|backendlbpolicies)' "$STATE/crd-now" | awk -v b="$BUNDLE" '$2!=b || $3!="experimental"' | wc -l | tr -d ' ')
    [[ $wr == 0 ]] && ok "R11 all bundled gateway.networking.k8s.io CRDs at $BUNDLE experimental" || bad "R11 CRDs off-bundle: $(grep -v -E '^(x|backendlbpolicies)' "$STATE/crd-now" | awk -v b="$BUNDLE" '$2!=b||$3!="experimental"' | tr '\n' ';')"
  fi
  info "R11 CRDs: $(tr '\n' ';' < "$STATE/crd-now")"
  vap=$(kubectl get validatingadmissionpolicy -o json | jq -r '.items[] | select(.metadata.name|test("safe-upgrades")) | "\(.metadata.name) owner=\(.metadata.annotations["meta.helm.sh/release-namespace"])/\(.metadata.annotations["meta.helm.sh/release-name"])"')
  info "R11 safe-upgrades VAP: [${vap:-none}]"
  # R12
  le=$(kubectl -n network logs deploy/envoy-gateway --since-time="$SINCE" 2>/dev/null | grep -i -E 'translat|skip|xds' | grep -i -c -E 'error|fail|skip')
  [[ $le == 0 ]] && ok "R12 controller log: 0 translation-error/skipped-xDS lines since hop start" || bad "R12 controller translation/xds error lines: $le"
  info "R12 controller error-level lines since hop start: $(kubectl -n network logs deploy/envoy-gateway --since-time="$SINCE" 2>/dev/null | grep -c '"level":"error"')"
  up=$(kubectl get --raw "/api/v1/namespaces/observability/services/prometheus-operated:9090/proxy/api/v1/query?query=count(up%7Bnamespace%3D%22network%22%2Cpod%3D~%22envoy-network-.*%22%7D%3D%3D1)" | jq -r '.data.result[0].value[1] // "0"')
  [[ $up == 8 ]] && ok "R12 Prometheus: 8/8 envoy proxy targets up" || bad "R12 envoy targets up=$up"
  lq=$(kubectl get --raw "/api/v1/namespaces/observability/services/loki:3100/proxy/loki/api/v1/query?query=sum(count_over_time(%7Bnamespace%3D%22network%22%2Ccontainer%3D%22envoy%22%7D%5B5m%5D))" 2>/dev/null | jq -r '.data.result[0].value[1] // "0"')
  [[ ${lq:-0} -gt 0 ]] && ok "R12 Loki: $lq envoy log lines in last 5m" || bad "R12 Loki envoy lines $lq"
  tg=$(kubectl get --raw "/api/v1/namespaces/observability/services/loki:3100/proxy/loki/api/v1/query?query=sum(count_over_time(%7Bnamespace%3D%22network%22%2Ccontainer%3D%22envoy%22%7D%20%7C~%20%60httproute%2Fmypka%2Fteamregie%60%20%7C~%20%60%22response_code%22%3A%5Cs%2A2%60%20%5B30m%5D))" 2>/dev/null | jq -r '.data.result[0].value[1] // "0"')
  info "R4/G5 passive positive path: teamregie 2xx access-log lines last 30m = $tg (0 = unobserved)"
  [[ $fail == 0 ]] && echo "GATE PASS $LABEL" || echo "GATE FAIL $LABEL"
}

baseline(){
  echo "== baseline $LABEL $(date -u +%FT%TZ)"
  kubectl -n network get deploy -l app.kubernetes.io/managed-by=envoy-gateway -o jsonpath='{range .items[*]}{.metadata.name} {.status.readyReplicas}/{.spec.replicas} {.status.updatedReplicas}{"\n"}{end}' | sort > "$STATE/px-base"
  kubectl -n network get svc -l app.kubernetes.io/managed-by=envoy-gateway -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.spec.type} {.status.loadBalancer.ingress[0].ip} {.metadata.labels.gateway\.envoyproxy\.io/owning-gateway-name}{"\n"}{end}' | sort > "$STATE/svc-base"
  info "proxies: $(awk '{print $1, $2}' "$STATE/px-base" | tr '\n' ';')"; info "svcs: $(awk '{print $1, $3, $4}' "$STATE/svc-base" | tr '\n' ';')"
  kubectl get httproute -A -o json | jq '[.items[] | select(.metadata.name|startswith("chg080-canary")|not) | .spec.parentRefs[]] | length' > "$STATE/r3-base"; info "R3 spec parentRefs: $(cat "$STATE/r3-base") on $(kubectl get httproute -A --no-headers | grep -v -c chg080-canary) routes"
  route_codes > "$STATE/codes-base"; info "route codes: $(awk '{print $1, $2, $3}' "$STATE/codes-base" | tr '\n' ';')"
  echo "$(kubectl get cnp -A -o json | jq '[.items[] | select(tostring|test("owning-gateway-name"))] | length') $(kubectl get ccnp -o json | jq '[.items[] | select(tostring|test("owning-gateway-name"))] | length')" > "$STATE/cnp-base"; info "envoy-label CNP CCNP: $(cat "$STATE/cnp-base")"
  fh=$(host_of devtools forgejo); curl -s -o /dev/null -m 12 -w '%{http_code}' --resolve "$fh:443:172.16.2.251" "https://$fh/chg080/probe.git/info/refs?service=git-upload-pack" > "$STATE/git-base"; info "forge git info/refs: $(cat "$STATE/git-base")"
  pf kube-system svc/hubble-relay 14245 80
  { hubble observe --server 127.0.0.1:14245 --since 10m --verdict DROPPED --from-label 'k8s:io.kubernetes.pod.namespace=network' --from-label 'k8s:app.kubernetes.io/component=proxy' -o jsonpb 2>/dev/null | jq -r '.flow.destination.namespace // "world"' | sort | uniq -c | awk '{print $2"="$1}'
    hubble observe --server 127.0.0.1:14245 --since 10m --verdict DROPPED --to-label 'k8s:io.kubernetes.pod.namespace=network' --to-label 'k8s:app.kubernetes.io/component=proxy' -o jsonpb 2>/dev/null | jq -r '.flow.source.namespace // "world"' | sort | uniq -c | awk '{print "to-envoy-from-"$2"="$1}'; } | tr '\n' ' ' > "$STATE/drops-base"
  info "P4 hubble DROPPED to/from envoy last 10m: [$(cat "$STATE/drops-base")]"
  cleanup; PFS=""
}

case $MODE in
  guard) guard; [[ $fail == 0 ]] && echo "GUARD PASS" || echo "GUARD FAIL" ;;
  baseline) baseline ;;
  snapshot) snapshot "${LABEL:?file}" ;;
  gate) guard; r_all ;;
esac
exit $fail
