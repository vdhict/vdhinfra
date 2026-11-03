#!/usr/bin/env bash
# chg-2026-11-02-012 (Headscale stage 2): the two KPN (wan2) port forwards to the headscale LB 172.16.2.249.
# Created disabled in S5 (2026-11-03): HS443 tcp 443 and HS3478 udp 3478. Owner: udm-engineer.
#
#   chg-2026-11-02-012-forwards.sh status
#   chg-2026-11-02-012-forwards.sh off                 # PUT enabled=false on both + GET readback (auto-rollback path)
#   chg-2026-11-02-012-forwards.sh on --argus-green <flagfile>
#   chg-2026-11-02-012-forwards.sh delete              # DELETE both by _id + GET readback
#
# on: refuses unless <flagfile> exists and holds the line `argus-minimum-set: green` (Argus verdict
#     20-argus-stage2-verdict-20261103.md: B1-B6, C7, V0 0 API keys, T1 negatives, T2, S5 readback, off dry-run).
# Legacy private API rest/portforward with the integration X-API-KEY (no cookie). PUT sends the full object as read,
# with only `enabled` changed. Every run writes one write-once evidence file and one change-log line (actor
# udm-engineer). Exit 0 = readback matches intent; 1 = mismatch/API error; 64 = usage; 77 = `on` refused.
# Never prints the API key: no set -x, the key goes in a header from a file read, never in argv of a printed line.
set -euo pipefail
umask 077
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
CHG=chg-2026-11-02-012
EVD=$REPO/ops/evidence/$CHG
B=https://172.16.2.1/proxy/network/api/s/default
IDS=(6ae9d05f83cbbf8f2e36f907 6ae9d06183cbbf8f2e36f90b)   # HS443 headscale, HS3478 headscale derp-stun
K=$(cat /Users/sheijden/Code/homelab-migration/config/unifi-api-key)
CURL=/usr/bin/curl   # Mac Mini NECP: /usr/bin/curl reaches the LAN
CMD=${1:-}

api() { "$CURL" -sk --max-time 20 -H "X-API-KEY: $K" -H 'Content-Type: application/json' "$@"; }
event() { (cd "$REPO" && ./ops/ops change event "$CHG" "$1" --actor udm-engineer --payload-json "$2" >/dev/null) || echo "WARN: change-log append failed" >&2; }
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$EVD/5x-fwd-${CMD:-none}-$TS.txt"
[ -e "$OUT" ] && { echo "evidence file exists, refusing to overwrite: $OUT" >&2; exit 1; }

# status line per forward; exit 1 if a managed _id is missing (unless $1=absent-ok)
status() {
  api "$B/rest/portforward" | python3 -I -c '
import json,sys
ids=sys.argv[1:]
j=json.load(sys.stdin)
if j.get("meta",{}).get("rc")!="ok": print("API error", j.get("meta")); sys.exit(1)
by={d["_id"]:d for d in j["data"]}
for i in ids:
    d=by.get(i)
    if d is None: print(i, "ABSENT"); continue
    print(i, repr(d.get("name")), "enabled=%s %s %s -> %s:%s if=%s src=%s log=%s" % (d.get("enabled"), d.get("proto"),
      d.get("dst_port"), d.get("fwd"), d.get("fwd_port"), d.get("pfwd_interface"), d.get("src"), d.get("log")))
print("total forwards:", len(j["data"]), "| others:", "; ".join("%s enabled=%s %s/%s if=%s" % (d.get("name"), d.get("enabled"),
      d.get("proto"), d.get("dst_port"), d.get("pfwd_interface")) for d in j["data"] if d["_id"] not in ids))' "${IDS[@]}"
}

# assert every managed forward has enabled == $1 ("True"/"False") or is ABSENT ($1 == "ABSENT")
check() { status | python3 -I -c '
import sys
want=sys.argv[1]; lines=sys.stdin.read().splitlines(); ids=sys.argv[2:]
bad=[l for l in lines if l.split(" ")[0] in ids and (("ABSENT" not in l) if want=="ABSENT" else ("enabled="+want) not in l)]
print("\n".join(lines)); print("CHECK", "PASS" if not bad else "FAIL", "want", want); sys.exit(1 if bad else 0)' "$1" "${IDS[@]}"; }

put_enabled() { # <_id> <true|false> -> prints rc
  local obj
  obj=$(api "$B/rest/portforward" | python3 -I -c '
import json,sys
for d in json.load(sys.stdin)["data"]:
    if d["_id"]==sys.argv[1]:
        d["enabled"]=(sys.argv[2]=="true"); print(json.dumps(d)); break
else: sys.exit(3)' "$1" "$2") || { echo "absent"; return; }
  api -w '\n%{http_code}' -X PUT -d "$obj" "$B/rest/portforward/$1" | python3 -I -c '
import json,sys
body,_,code=sys.stdin.read().rpartition("\n")
try: m=json.loads(body)["meta"]
except Exception: print("error/http-"+code+"/unparsed"); sys.exit()
print(m["rc"] if m.get("rc")=="ok" else "error/http-%s/%s" % (code, m.get("msg","no-msg")))'
}

run() { # tee everything into the write-once evidence file
  { echo "# $CHG forwards $CMD at $(date -u +%FT%TZ)"; "$@"; } 2>&1 | tee "$OUT"; return "${PIPESTATUS[0]}"
}

do_toggle() { # <true|false>
  local want=$1 rc all=""
  for id in "${IDS[@]}"; do rc=$(put_enabled "$id" "$want"); echo "PUT $id enabled=$want: $rc"; all="$all $id=$rc"; sleep 2; done
  sleep 3
  if [ "$want" = true ]; then check True; else check False; fi
}

do_delete() {
  local rc
  for id in "${IDS[@]}"; do
    rc=$(api -w ' http=%{http_code}' -X DELETE "$B/rest/portforward/$id" | python3 -I -c '
import json,sys
s=sys.stdin.read(); body,_,code=s.rpartition(" ")
try: print(json.loads(body)["meta"].get("rc"), code)
except Exception: print("unparsed", code)')
    echo "DELETE $id: $rc"; sleep 2
  done
  sleep 3; check ABSENT
}

case "$CMD" in
  status) run status; exit ;;
  off)
    set +e; run do_toggle false; r=$?; set -e
    event executed "{\"step\":\"forwards off (script)\",\"result\":\"$([ $r = 0 ] && echo PASS || echo FAIL)\",\"evidence\":\"${OUT#$REPO/}\"}"
    exit $r ;;
  on)
    [ "${2:-}" = "--argus-green" ] && [ -n "${3:-}" ] || { echo "usage: $0 on --argus-green <flagfile>" >&2; exit 64; }
    if ! [ -f "$3" ] || ! grep -qx 'argus-minimum-set: green' "$3"; then
      echo "REFUSED: $3 missing or lacks the line 'argus-minimum-set: green' (Argus minimum set not confirmed)" >&2; exit 77
    fi
    set +e; run do_toggle true; r=$?; set -e
    event executed "{\"step\":\"forwards on (script)\",\"result\":\"$([ $r = 0 ] && echo PASS || echo FAIL)\",\"flagfile\":\"$3\",\"evidence\":\"${OUT#$REPO/}\"}"
    if [ $r != 0 ]; then echo "readback failed after on: turning off" >&2; sleep 1; "$0" off || true; fi
    exit $r ;;
  delete)
    set +e; run do_delete; r=$?; set -e
    event executed "{\"step\":\"forwards delete (script)\",\"result\":\"$([ $r = 0 ] && echo PASS || echo FAIL)\",\"evidence\":\"${OUT#$REPO/}\"}"
    exit $r ;;
  *) echo "usage: $0 status | off | on --argus-green <flagfile> | delete" >&2; exit 64 ;;
esac
