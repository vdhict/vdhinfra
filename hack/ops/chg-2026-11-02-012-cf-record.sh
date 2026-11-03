#!/usr/bin/env bash
# chg-2026-11-02-012 S7 (design D4, Argus C10): the ONE public DNS record for headscale, outside external-dns.
#   headscale.<zone> A -> KPN wan2 IP (read live from UniFi), proxied=false (Noise upgrade, DERP and UDP break behind the
#   proxy), TTL 300, no external-dns owner TXT, so neither Cloudflare external-dns instance ever touches it.
#
#   chg-2026-11-02-012-cf-record.sh plan                  read-only: zone, existing records, wan2 IP; what create would do
#   chg-2026-11-02-012-cf-record.sh create                create the A record; REFUSES if any record with this name exists
#   chg-2026-11-02-012-cf-record.sh gate <ip> <id>        DoH Cloudflare+Google == <ip>, LAN DNS == .249, no owner TXT;
#                                                         polls up to 35 min (zone negative TTL 1800s); on failure runs
#                                                         --delete <id> itself (automatic rollback)
#   chg-2026-11-02-012-cf-record.sh --delete <record-id>  rollback: delete that record (refuses unless it is the A record
#                                                         for headscale.<zone>), then DoH must return NXDOMAIN
#
# The Cloudflare call runs as a one-shot Job in namespace network (where external-dns and its secret live). The token is
# mounted as a 0440 file and only ever put in an HTTP header inside the Job: never env, argv, logs or this host. The Job
# prints RESULT lines with the record id and proxied=false only; ttlSecondsAfterFinished 300. No set -x anywhere.
# Exit: 0 ok, 1 failure, 3 refused, 64 usage. Each run writes one write-once evidence file and one change-log line.
set -euo pipefail
umask 077
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
CHG=chg-2026-11-02-012
EVD=$REPO/ops/evidence/$CHG
NS=network
ZONE=bluejungle.net
NAME=headscale.$ZONE
LANIP=172.16.2.249
IMG=docker.io/library/python:3.13.18-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
CURL=/usr/bin/curl   # vdhmini01 NECP: curl reaches the LAN, python/kubectl-direct do not
MODE=${1:-}; ARG=${2:-}; ARG2=${3:-}
cd "$REPO"
eval "$(mise env -s bash 2>/dev/null)" 2>/dev/null || true
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$EVD/6x-cf-record-${MODE#--}-$TS.txt
[ -e "$OUT" ] && { echo "evidence exists, refusing to overwrite: $OUT" >&2; exit 1; }
log() { echo "$*" | tee -a "$OUT"; }
event() { ./ops/ops change event "$CHG" executed --actor k8s-engineer --payload-json "$(jq -nc --arg s "$1" --arg e "${OUT#$REPO/}" '{step:"S7",summary:$s,evidence:$e}')" >/dev/null || echo "WARN change-log append failed" >&2; }

wan2_ip() {
  local k; k=$(cat "$REPO/../config/unifi-api-key")
  "$CURL" -sk --max-time 20 -H "X-API-KEY: $k" https://172.16.2.1/proxy/network/api/s/default/stat/device \
    | jq -r '[.data[] | select(.type=="udm" and .wan2.up==true) | .wan2.ip][0] // empty'
}
is_public_v4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  [ "$a" = 10 ] || [ "$a" = 127 ] || [ "$a" = 0 ] || [ "$a" -ge 224 ] && return 1
  { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } && return 1
  { [ "$a" = 192 ] && [ "$b" = 168 ]; } && return 1
  { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; } && return 1
  { [ "$a" = 169 ] && [ "$b" = 254 ]; } && return 1
  return 0
}

# Python run inside the Job. Reads the token from /cf/token, prints RESULT lines only (no token, no API bodies).
read -r -d '' PY <<'PYEOF' || true
import json, os, sys, urllib.request, urllib.error
tok = open("/cf/token").read().strip()
API = "https://api.cloudflare.com/client/v4"
mode, zone, name = os.environ["MODE"], os.environ["ZONE"], os.environ["NAME"]
def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try: codes = [x.get("code") for x in json.load(e).get("errors", [])]
        except Exception: codes = []
        print("RESULT api_error http=%d codes=%s" % (e.code, codes)); sys.exit(2)
z = call("GET", "/zones?name=" + zone)["result"]
if len(z) != 1: print("RESULT zone_not_found"); sys.exit(2)
zid = z[0]["id"]
if mode == "delete":
    rid = os.environ["RID"]
    r = call("GET", "/zones/%s/dns_records/%s" % (zid, rid))["result"]
    if r.get("name") != name or r.get("type") != "A":
        print("RESULT refused id=%s is not the A record for %s" % (rid, name)); sys.exit(3)
    d = call("DELETE", "/zones/%s/dns_records/%s" % (zid, rid))
    print("RESULT deleted id=%s success=%s" % (rid, str(d.get("success")).lower())); sys.exit(0 if d.get("success") else 1)
# exact-name lookups (any type): the name itself and both external-dns owner-TXT formats (txtPrefix k8s.)
recs = []
for n in (name, "k8s." + name, "k8s.a-" + name):
    recs += call("GET", "/zones/%s/dns_records?per_page=100&name=%s" % (zid, n))["result"]
for r in recs:
    print("EXISTING id=%s type=%s name=%s proxied=%s" % (r["id"], r["type"], r["name"], str(r.get("proxied")).lower()))
if recs:
    print("RESULT refused existing=%d" % len(recs)); sys.exit(3)
ip = os.environ["IP"]
if mode == "plan":
    print("RESULT plan would_create type=A name=%s proxied=false ttl=300 existing=0" % name); sys.exit(0)
body = {"type": "A", "name": name, "content": ip, "ttl": 300, "proxied": False,
        "comment": "chg-2026-11-02-012 headscale; manual, not external-dns; remove: cf-record.sh --delete"}  # free plan: comment <= 100 chars (CF 9313)
c = call("POST", "/zones/%s/dns_records" % zid, body)
if not c.get("success"): print("RESULT create_failed"); sys.exit(1)
rid = c["result"]["id"]
b = call("GET", "/zones/%s/dns_records/%s" % (zid, rid))["result"]
print("RESULT created id=%s proxied=%s ttl=%s content_match=%s" % (rid, str(b.get("proxied")).lower(), b.get("ttl"), str(b.get("content") == ip).lower()))
sys.exit(0 if (b.get("proxied") is False and b.get("content") == ip and b.get("ttl") == 300) else 1)
PYEOF

run_job() {  # $1 mode (plan|create|delete), env: IP, RID
  local job="hs-cf-record-$1-$(date -u +%H%M%S)" code=1
  kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $NS
  labels: { app.kubernetes.io/name: hs-cf-record, ops.vdh/chg: $CHG }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels: { app.kubernetes.io/name: hs-cf-record }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, fsGroup: 65534, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: cf
          image: $IMG
          command: ["python3", "-I", "-c", $(jq -Rs . <<<"$PY")]
          env:
            - { name: MODE, value: "$1" }
            - { name: ZONE, value: "$ZONE" }
            - { name: NAME, value: "$NAME" }
            - { name: IP, value: "${IP:-}" }
            - { name: RID, value: "${RID:-}" }
            - { name: PYTHONDONTWRITEBYTECODE, value: "1" }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
          resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 64Mi } }
          volumeMounts: [ { name: cf, mountPath: /cf, readOnly: true } ]
      volumes:
        - name: cf
          secret:
            secretName: external-dns-secret
            defaultMode: 0440
            items: [ { key: api-token, path: token } ]
YAML
  for _ in $(seq 1 40); do
    s=$(kubectl -n $NS get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}')
    [ -n "$s" ] && break; sleep 3
  done
  kubectl -n $NS get job "$job" -o jsonpath='{.status.succeeded}' | grep -q 1 && code=0
  log "job $job succeeded=$([ $code = 0 ] && echo yes || echo no)"
  # only RESULT/EXISTING lines leave the pod; the token never enters stdout
  kubectl -n $NS logs "job/$job" 2>/dev/null | grep -E '^(RESULT|EXISTING) ' | tee -a "$OUT" || true
  return $code
}

doh() {  # $1 server url, $2 name, $3 type -> "status|answers"
  "$CURL" -s --max-time 10 -H 'accept: application/dns-json' "$1?name=$2&type=$3" \
    | jq -r '"\(.Status)|\([.Answer[]? | select(.type==1 or .type==16) | .data] | join(","))"'
}
lan_a() { dig +short +time=3 +tries=1 "$NAME" @172.16.2.1 A 2>/dev/null | tail -1; }

gate() {  # $1 ip, $2 record id
  local ip=$1 rid=$2 cf g lan t0 ok=0
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -le 2100 ]; do
    cf=$(doh https://cloudflare-dns.com/dns-query "$NAME" A); g=$(doh https://dns.google/resolve "$NAME" A)
    if [ "$cf" = "0|$ip" ] && [ "$g" = "0|$ip" ]; then ok=1; break; fi
    # a WRONG answer (not just a cached NXDOMAIN) fails at once
    { [ "${cf%%|*}" = 0 ] && [ "$cf" != "0|$ip" ]; } || { [ "${g%%|*}" = 0 ] && [ "$g" != "0|$ip" ]; } && break
    sleep 30
  done
  log "$(date -u +%FT%TZ) DoH cloudflare=$cf google=$g (want 0|$ip) after $(( $(date +%s) - t0 ))s"
  lan=$(lan_a); log "LAN dig @172.16.2.1 $NAME A = ${lan:-<none>} (want $LANIP)"
  local txt1 txt2; txt1=$(doh https://cloudflare-dns.com/dns-query "k8s.a-$NAME" TXT); txt2=$(doh https://cloudflare-dns.com/dns-query "k8s.$NAME" TXT)
  log "owner TXT k8s.a-$NAME=$txt1 k8s.$NAME=$txt2 (want status 3, no answer)"
  if [ $ok = 1 ] && [ "$lan" = "$LANIP" ] && [ "${txt1#*|}" = "" ] && [ "${txt2#*|}" = "" ]; then
    log "GATE PASS"; event "DNS gate PASS: DoH cloudflare+google = $ip, LAN = $LANIP, no owner TXT (record $rid)"; return 0
  fi
  log "GATE FAIL -> automatic rollback: --delete $rid"
  event "DNS gate FAIL (cf=$cf google=$g lan=${lan:-none}); rolling back record $rid"
  "$0" --delete "$rid"; return 1
}

case "$MODE" in
  plan|create)
    IP=$(wan2_ip)
    is_public_v4 "${IP:-x}" || { log "REFUSED wan2 IP '${IP:-none}' is not a public IPv4 (wan2 down?)"; exit 3; }
    log "# $CHG cf-record $MODE $(date -u +%FT%TZ): $NAME A -> $IP (UniFi stat/device wan2, read now), proxied=false ttl=300"
    export IP; set +e; run_job "$MODE"; rc=$?; set -e
    if [ "$MODE" = create ]; then
      rid=$(grep -oE '^RESULT created id=[0-9a-f]+' "$OUT" | sed 's/.*id=//' || true)
      event "create rc=$rc id=${rid:-none} -> $IP proxied=false ttl=300"
      [ $rc = 0 ] && [ -n "$rid" ] && log "next: $0 gate $IP $rid"
    else event "plan rc=$rc ($NAME -> $IP)"; fi
    exit $rc ;;
  gate)
    [ -n "$ARG" ] && [ -n "$ARG2" ] || { echo "usage: $0 gate <ip> <record-id>" >&2; exit 64; }
    log "# $CHG cf-record gate $(date -u +%FT%TZ) ip=$ARG id=$ARG2"; gate "$ARG" "$ARG2" ;;
  --delete)
    [[ "$ARG" =~ ^[0-9a-f]{32}$ ]] || { echo "usage: $0 --delete <32-hex record id>" >&2; exit 64; }
    log "# $CHG cf-record delete $(date -u +%FT%TZ) id=$ARG"
    export RID=$ARG; set +e; run_job delete; rc=$?; set -e
    cf=$(doh https://cloudflare-dns.com/dns-query "$NAME" A); log "DoH cloudflare after delete: $cf (want status 3)"
    event "delete id=$ARG rc=$rc; DoH cloudflare=$cf"; exit $rc ;;
  *) echo "usage: $0 plan | create | gate <ip> <record-id> | --delete <record-id>" >&2; exit 64 ;;
esac
