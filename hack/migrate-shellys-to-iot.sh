#!/usr/bin/env bash
# Migrate the remaining 9 Shelly 1PM Mini Gen3 plugs from CLIENT-VLAN to IOT-VLAN.
#
# Every one of these 9 is the MAINS SUPPLY to a Sonos speaker.
#   1. The end-to-end test DOES cycle each relay off->on (~5s off), one device at a
#      time, always restoring the pre-migration state. The user explicitly authorised
#      actuation for this window: "at midnight the actuation doesn't really matter as
#      everyone will be asleep, that is why I asked for midnight". This briefly
#      power-cycles each speaker — the same thing script.sonos_power_cycle does.
#      If a turn_on ever fails, the script retries directly at the device before
#      aborting, so no speaker is left unpowered.
#   2. WiFi.SetConfig returns {"restart_required": true} — it is ADVISORY. We do NOT
#      reboot. A reboot is the one thing that would make this migration audible.
#
# Safety model: sta1 is set to VDHFEMFLEX on every device, so a failed VDHIOT join
# self-recovers to the current network. Worst realistic case is "nothing moved".
# The script ABORTS on the first device failure rather than ploughing through 9.
#
# Usage: migrate-shellys-to-iot.sh <chg-id> [--dry-run]
set -uo pipefail

CHG="${1:?usage: $0 <chg-id> [--dry-run]}"
DRY=0; [ "${2:-}" = "--dry-run" ] && DRY=1

REPO="/Users/sheijden/Code/homelab-migration/vdhinfra"
KEYFILE="/Users/sheijden/Code/homelab-migration/config/unifi-api-key"
UDM="172.16.2.1"
IOT_NET_ID="6226f5bddd6f9706a46a66cb"
EVID="$REPO/ops/evidence/$CHG"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

cd "$REPO" || exit 1
mkdir -p "$EVID"
LOG="$EVID/migration-$(date +%Y%m%dT%H%M%S).log"
say() { echo "$(date -u +%FT%TZ)  $*" | tee -a "$LOG"; }

# SAFETY WINDOW. This job power-cycles 9 Sonos speakers. That is only acceptable
# while the household is asleep — which is the entire reason the user asked for
# midnight. If launchd fires this late (machine was off/asleep and caught up on
# wake), running it at breakfast would be exactly wrong. Refuse instead.
# Override for a deliberate manual run: FORCE_WINDOW=1
HOUR=$(date +%-H)
if [ "${FORCE_WINDOW:-0}" != "1" ] && [ "$DRY" != "1" ]; then
  if [ "$HOUR" -ge 5 ]; then
    say "REFUSING TO RUN: local hour is ${HOUR}, outside the 00:00-04:59 safe window."
    say "This job briefly cuts power to 9 Sonos speakers and must only run while the household is asleep."
    say "Re-run deliberately with FORCE_WINDOW=1 if you really want it now."
    exit 3
  fi
fi

KEY=$(cat "$KEYFILE")
IOTPSK=$(curl -sk -H "X-API-KEY: $KEY" "https://$UDM/proxy/network/api/s/default/rest/wlanconf" \
  | jq -r --arg n "$IOT_NET_ID" '.data[]|select(.name=="VDHIOT")|.private_preshared_keys[]|select(.networkconf_id==$n)|.password')
FEMPSK=$(curl -sk -H "X-API-KEY: $KEY" "https://$UDM/proxy/network/api/s/default/rest/wlanconf" \
  | jq -r '.data[]|select(.name=="VDHFEMFLEX")|.x_passphrase')
if [ -z "$IOTPSK" ] || [ -z "$FEMPSK" ]; then say "ABORT: could not resolve passphrases"; exit 1; fi
say "passphrases resolved (never logged): IOT len=${#IOTPSK} FEMFLEX len=${#FEMPSK}"

# Deliberately NO kubectl dependency. kubectl from this Mac was failing with
# "no route to host" to 172.16.2.240:6443 on 2026-07-30 while curl to the same
# host:port returned 401 (i.e. cluster healthy, local tooling broken). An
# unattended job must not hinge on the least reliable component. Everything below
# verifies through the Home Assistant REST API, which IS the real consumer path:
# if HA reports the device's live wattage and its service calls reach the relay,
# then HA can reach the device across the VLAN boundary. That is a stronger proof
# than a curl issued from inside the pod.
HA_URL="http://172.16.2.237:8123/api"
HA_TOKEN=$(cat /Users/sheijden/Code/homelab-migration/config/hasskey)
ha_get() { curl -fsS -H "Authorization: Bearer $HA_TOKEN" --max-time 10 "$HA_URL$1" 2>/dev/null; }
if ! ha_get "/" >/dev/null; then say "ABORT: Home Assistant API not reachable at $HA_URL"; exit 1; fi
say "Home Assistant API reachable (no kubectl needed)"

# order: strongest signal first, weakest (Bartafel, -75 dBm) LAST
#        mac | rest/user _id | new ip | old ip | ha switch entity | label
DEVICES=(
"34:b7:da:90:7d:f0|677932c4fe53ff1afe656662|172.16.4.21|172.16.3.109|switch.sonos_keuken|Sonos Keuken"
"34:b7:da:8b:a9:88|674dffd6e59a484d42e65515|172.16.4.22|172.16.3.146|switch.sonos_surround_rechtsachter|Sonos Surround Rechtsachter"
"34:b7:da:8f:f2:0c|677bdcaffe53ff1afe674346|172.16.4.23|172.16.3.202|switch.sonos_achtertuin|Sonos Achtertuin"
"54:32:04:5f:2c:c4|674e045ce59a484d42e657c6|172.16.4.24|172.16.3.42|switch.sonos_surround_linksachter|Sonos Surround Linksachter"
"34:b7:da:8f:dc:60|68aad52491302542a9723283|172.16.4.25|172.16.3.80|switch.sonos_play_1|Sonos Play:1"
"34:b7:da:92:1c:8c|677bcffffe53ff1afe6739c5|172.16.4.26|172.16.3.170|switch.sonos_arc_ultra|Sonos Arc Ultra"
"34:b7:da:92:6e:64|677935b6fe53ff1afe656a81|172.16.4.27|172.16.3.36|switch.sonos_sub|Sonos Sub"
"34:b7:da:8b:b3:1c|67792f83fe53ff1afe65635e|172.16.4.28|172.16.3.200|switch.sonos_eetkamer|Sonos Eetkamer"
"34:b7:da:90:9a:14|67794001fe53ff1afe657380|172.16.4.29|172.16.3.54|switch.sonos_bartafel|Sonos Bartafel"
)

sta_field() { # sta_field <mac> <jq-field>
  curl -sk -H "X-API-KEY: $KEY" "https://$UDM/proxy/network/api/s/default/stat/sta" \
    | jq -r --arg m "$1" ".data[]|select(.mac==\$m)|.$2 // empty"
}
ha_state() { ha_get "/states/$1" | jq -r '.state // empty'; }   # <entity> -> state
ha_call()  { # ha_call <domain/service> <entity>
  curl -fsS -H "Authorization: Bearer $HA_TOKEN" -H "Content-Type: application/json" \
    --max-time 15 -X POST -d "{\"entity_id\":\"$2\"}" "$HA_URL/services/$1" >/dev/null 2>&1
}

OK=0; FAILED=""
for entry in "${DEVICES[@]}"; do
  IFS='|' read -r MAC CID NEWIP OLDIP ENT LABEL <<<"$entry"
  say "──────── $LABEL ($MAC) $OLDIP -> $NEWIP ────────"

  CURNET=$(sta_field "$MAC" network)
  if [ "$CURNET" = "IOT-VLAN" ]; then say "  already on IOT-VLAN, skipping"; OK=$((OK+1)); continue; fi

  # pre-state: relay must be ON (these feed speakers); record it so we can prove we didn't change it
  PRE=$(curl -s --max-time 6 "http://$OLDIP/rpc/Switch.GetStatus?id=0" | jq -c '{output,apower}')
  say "  pre-state relay: $PRE"
  PRE_OUT=$(echo "$PRE" | jq -r '.output // empty')
  if [ -z "$PRE_OUT" ]; then say "  FAIL: device not reachable at $OLDIP before migration"; FAILED="$LABEL (unreachable pre-flight)"; break; fi

  if [ "$DRY" = "1" ]; then say "  [dry-run] would reserve $NEWIP and re-home to VDHIOT"; OK=$((OK+1)); continue; fi

  # 1. reservation (merge onto the FULL object; partial bodies drop fields)
  BODY=$(curl -sk -H "X-API-KEY: $KEY" "https://$UDM/proxy/network/api/s/default/rest/user" \
    | jq -c --arg id "$CID" --arg ip "$NEWIP" --arg n "$IOT_NET_ID" --arg nm "Shelly - $LABEL" \
      '.data[]|select(._id==$id)|.use_fixedip=true|.fixed_ip=$ip|.network_id=$n|.name=$nm')
  RC=$(curl -sk -X PUT -H "X-API-KEY: $KEY" -H "Content-Type: application/json" -d "$BODY" \
        "https://$UDM/proxy/network/api/s/default/rest/user/$CID" | jq -r '.meta.rc // "err"')
  say "  reservation rc=$RC"
  [ "$RC" = "ok" ] || { say "  FAIL: reservation rejected"; FAILED="$LABEL (reservation rc=$RC)"; break; }
  # Settle time before the device re-DHCPs. UniFi accepts and stores the reservation
  # immediately (rc=ok) but the DHCP server does not honour it for a further while.
  # inc-2026-07-31-001: a 2s gap gave the device a POOL address; the pilot's 21s gap
  # landed the reserved one. 30s with margin.
  say "  waiting 30s for the reservation to become live in the UDM's DHCP server"
  sleep 30

  # 2. re-home wifi, sta1 = current net as the self-recovery path
  REQ=$(jq -nc --arg ip "$IOTPSK" --arg fp "$FEMPSK" '{config:{
    sta:  {ssid:"VDHIOT",     pass:$ip, enable:true, ipv4mode:"dhcp"},
    sta1: {ssid:"VDHFEMFLEX", pass:$fp, enable:true, ipv4mode:"dhcp"}}}')
  RESP=$(curl -s --max-time 10 -X POST -H "Content-Type: application/json" -d "$REQ" "http://$OLDIP/rpc/WiFi.SetConfig")
  say "  WiFi.SetConfig -> ${RESP:-'(no body; reassociated immediately)'}   [restart_required is ADVISORY - not rebooting]"

  # 3. wait for it to land ON IOT-VLAN. The OBJECTIVE is the VLAN, not a specific IP.
  #    inc-2026-07-31-001: the original check demanded net==IOT-VLAN AND ip==reserved,
  #    so a device that had genuinely succeeded (IOT-VLAN, pool IP) was scored as a
  #    failure, rolled back, and aborted the whole run. A wrong IP is CORRECTABLE, not
  #    fatal — HA self-heals the config-entry host via zeroconf either way.
  LANDED=0; ACTUAL=""
  for i in $(seq 1 24); do
    sleep 5
    N=$(sta_field "$MAC" network); I=$(sta_field "$MAC" ip)
    if [ "$N" = "IOT-VLAN" ] && [ -n "$I" ]; then LANDED=1; ACTUAL="$I"; say "  landed on IOT-VLAN after $((i*5))s at $I"; break; fi
  done
  if [ "$LANDED" != "1" ]; then
    say "  FAIL: never associated to IOT-VLAN within 120s (net=$(sta_field "$MAC" network) ip=$(sta_field "$MAC" ip))"
    say "  rolling this device back to VDHFEMFLEX"
    TGT=$(sta_field "$MAC" ip); TGT=${TGT:-$OLDIP}
    RB=$(jq -nc --arg fp "$FEMPSK" '{config:{sta:{ssid:"VDHFEMFLEX",pass:$fp,enable:true,ipv4mode:"dhcp"}}}')
    curl -s --max-time 10 -X POST -H "Content-Type: application/json" -d "$RB" "http://$TGT/rpc/WiFi.SetConfig" >/dev/null 2>&1
    FAILED="$LABEL (no association on IOT-VLAN)"; break
  fi

  # 3b. got the VLAN but not the reserved address -> nudge it to re-DHCP once.
  #     Re-applying the same wifi config forces reassociation and a fresh DHCP request,
  #     which by now should see the settled reservation.
  if [ "$ACTUAL" != "$NEWIP" ]; then
    say "  on IOT-VLAN but at $ACTUAL, not the reserved $NEWIP — forcing one re-DHCP"
    curl -s --max-time 10 -X POST -H "Content-Type: application/json" -d "$REQ" "http://$ACTUAL/rpc/WiFi.SetConfig" >/dev/null 2>&1
    for i in $(seq 1 18); do
      sleep 5
      I=$(sta_field "$MAC" ip)
      if [ "$I" = "$NEWIP" ]; then ACTUAL="$NEWIP"; say "  picked up the reservation after $((i*5))s: $I"; break; fi
      [ -n "$I" ] && ACTUAL="$I"
    done
    if [ "$ACTUAL" != "$NEWIP" ]; then
      say "  WARNING (not fatal): staying on $ACTUAL. Objective met (device is on IOT-VLAN);"
      say "           lease stability is reduced until it renews onto the reservation."
    fi
  fi
  # everything downstream must use the address it ACTUALLY has
  NEWIP="$ACTUAL"

  # 4. prove HOME ASSISTANT (not this shell) is talking to the device across the
  #    boundary: its power sensor must be live and agree with the device's own reading.
  PWRENT="sensor.$(echo "${ENT#switch.}")_vermogen"
  sleep 6
  HAW=$(ha_state "$PWRENT"); DEVW=$(curl -s --max-time 6 "http://$NEWIP/rpc/Switch.GetStatus?id=0" | jq -r '.apower')
  say "  HA $PWRENT=${HAW:-<none>}W  device apower=${DEVW}W  (must agree => HA is reaching $NEWIP)"
  if [ -z "$HAW" ] || [ "$HAW" = "unavailable" ] || [ "$HAW" = "unknown" ]; then
    say "  FAIL: HA has no live power reading — it is not reaching the device"; FAILED="$LABEL (HA not reaching device)"; break
  fi
  DIFF=$(awk -v a="$HAW" -v b="$DEVW" 'BEGIN{d=a-b; print (d<0?-d:d)}')
  awk -v d="$DIFF" 'BEGIN{exit !(d<=2.0)}' || { say "  FAIL: HA ${HAW}W vs device ${DEVW}W diverge by ${DIFF}W"; FAILED="$LABEL (stale HA data)"; break; }

  # 5. relay must be UNCHANGED by the move (speaker must not have been interrupted)
  POST=$(curl -s --max-time 6 "http://$NEWIP/rpc/Switch.GetStatus?id=0" | jq -c '{output,apower}')
  POST_OUT=$(echo "$POST" | jq -r '.output')
  say "  post-state relay: $POST  (pre was $PRE)"
  [ "$POST_OUT" = "$PRE_OUT" ] || { say "  FAIL: RELAY STATE CHANGED $PRE_OUT -> $POST_OUT"; FAILED="$LABEL (relay changed!)"; break; }

  # 6. HA entity healthy and agreeing with the device
  sleep 8
  HASTATE=$(ha_state "$ENT")
  say "  HA entity $ENT = ${HASTATE:-<none>} (device output=$POST_OUT)"
  case "$HASTATE" in
    unavailable|unknown|"") say "  FAIL: HA entity not healthy"; FAILED="$LABEL (HA entity $HASTATE)"; break;;
  esac
  EXPECT=$([ "$POST_OUT" = "true" ] && echo on || echo off)
  [ "$HASTATE" = "$EXPECT" ] || { say "  FAIL: HA state '$HASTATE' != device '$EXPECT'"; FAILED="$LABEL (state mismatch)"; break; }

  # 7. FULL end-to-end control test: real off -> on cycle, both directions verified.
  #    Authorised by the user for the midnight window ("actuation doesn't really matter
  #    as everyone will be asleep"). One device at a time, off for ~5s only, and always
  #    restored to its pre-migration state. This briefly power-cycles the Sonos speaker,
  #    which is the same thing the existing script.sonos_power_cycle does deliberately.
  if [ "$POST_OUT" = "true" ]; then
    ha_call switch/turn_off "$ENT"
    sleep 5
    OFFV=$(curl -s --max-time 6 "http://$NEWIP/rpc/Switch.GetStatus?id=0" | jq -r '.output')
    say "  e2e turn_off -> device output=$OFFV (expect false)"
    if [ "$OFFV" != "false" ]; then
      say "  FAIL: turn_off did not reach the device — restoring power immediately"
      ha_call switch/turn_on "$ENT"
      FAILED="$LABEL (control path: turn_off)"; break
    fi
    ha_call switch/turn_on "$ENT"
    sleep 5
    ONV=$(curl -s --max-time 6 "http://$NEWIP/rpc/Switch.GetStatus?id=0" | jq -r '.output')
    ONW=$(curl -s --max-time 6 "http://$NEWIP/rpc/Switch.GetStatus?id=0" | jq -r '.apower')
    say "  e2e turn_on  -> device output=$ONV apower=${ONW}W (expect true, real load)"
    if [ "$ONV" != "true" ]; then
      say "  CRITICAL: speaker left WITHOUT POWER and turn_on failed. Retrying directly at the device."
      curl -s --max-time 6 "http://$NEWIP/rpc/Switch.Set?id=0&on=true" >/dev/null 2>&1
      sleep 3
      ONV=$(curl -s --max-time 6 "http://$NEWIP/rpc/Switch.GetStatus?id=0" | jq -r '.output')
      say "  direct device recovery -> output=$ONV"
      FAILED="$LABEL (control path: turn_on; power restored=$ONV)"; break
    fi
    say "  restored to pre-migration state (on), speaker re-powered"
  else
    say "  relay was off pre-migration; leaving it off (not energising a speaker that was deliberately off)"
  fi

  say "  ✅ $LABEL migrated and verified"
  OK=$((OK+1))
  sleep 5
done

say "════════ RESULT: $OK/9 migrated ════════"
if [ -n "$FAILED" ]; then
  say "ABORTED at: $FAILED"
  say "Remaining devices were NOT touched. Already-migrated devices are verified working."
  say "sta1=VDHFEMFLEX is armed on every migrated device, so none can be stranded."
  exit 2
fi
say "All 9 migrated. IOT-VLAN membership:"
curl -sk -H "X-API-KEY: $KEY" "https://$UDM/proxy/network/api/s/default/stat/sta" \
  | jq -r '.data[]|select(.network=="IOT-VLAN")|"  \(.name // .hostname)  \(.ip)  \(.essid)"' | tee -a "$LOG"
exit 0
