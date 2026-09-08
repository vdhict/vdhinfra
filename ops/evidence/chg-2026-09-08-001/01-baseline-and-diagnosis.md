# chg-2026-09-08-001 — baseline + diagnosis evidence (Iris)
Captured 2026-09-08T07:15–07:20Z. UniFi Network app 10.6.101 (was 10.5.62 in memory).

## A. Timeline CORRECTION (Atlas's 2026-09-07T14:34:57Z is an artefact)

| When (UTC) | Fact | Source |
|---|---|---|
| 2026-09-04T01:01:18Z | Shelly `assoc_time` to VDHFEMFLEX | UniFi `stat/sta` |
| 2026-09-04T01:01:47Z | `switch.verlichting_schuur` -> `unavailable` | HA `/history/period` 120h |
| 2026-09-04T01:02:34Z | Shelly `latest_assoc_time` (AP01 ng) | UniFi `stat/sta` |
| 2026-09-04T01:04:28Z | **AP06-Keuken finished booting** | HA sensor.flexhd_uptime |
| 2026-09-07T14:34:35Z | **HA restarted** (`sensor.uptime`) | HA |
| 2026-09-07T14:34:57Z | entity last_changed re-stamped, `restored:true` | HA |

Real outage = **4d 6h**, not 18h. The 09-07 timestamp is the HA restart re-stamping a
restored entity's `last_changed` — the exact footgun in memory `ha-presence`.

## B. Coverage shortfall: FALSIFIED

Shelly-side `WiFi.Scan` from the shed, 2026-09-08T07:16Z (device's own radio):

    -65  VDHIOT      6a:d7:9a:3d:ac:53  ch6   <- AP06-Keuken
    -65  VDHFEMFLEX  6a:d7:9a:1d:ac:53  ch6   <- AP06-Keuken
    -65  Guest       6a:d7:9a:2d:ac:53  ch6   <- AP06-Keuken
    -74  KPND86346   e4:75:dc:ab:9f:15  ch6   (neighbour)
    -79  KPN6F5436   8a:d7:aa:ad:46:ea  ch1   (neighbour)
    -81  VDHTESLA    96:78:48:c8:65:45  ch6   <- AP01-Trapkast ng

VDHIOT is audible at the shed at **-65 dBm** — joint strongest signal available, identical
to VDHFEMFLEX from the same AP. The -81 dBm is the shed's signal to a *different, distant*
AP (AP01-Trapkast), which it only uses because of the sta1 fallback.

2.4 GHz SSID coverage per AP (UniFi `stat/device` vap_table):

    AP05-Meterkast  VDHIOT=true   VDHFEMFLEX=false
    AP01-Trapkast   VDHIOT=true   VDHFEMFLEX=true
    AP03-Slaapkamer VDHIOT=true   VDHFEMFLEX=true
    AP06-Keuken     VDHIOT=true   VDHFEMFLEX=true
    AP04-Zolder     VDHIOT=true   VDHFEMFLEX=true
    AP02-Stube      VDHIOT=true   VDHFEMFLEX=true

VDHIOT = 6/6 APs (ap_group "All APs"). VDHFEMFLEX = 5/6. **VDHIOT has strictly broader
2.4 GHz coverage than VDHFEMFLEX.** There is no location in the house where VDHFEMFLEX is
reachable and VDHIOT is not.

## C. min-RSSI kick: FALSIFIED

`min_rssi` is a per-RADIO setting, so it cannot discriminate between two SSIDs on the same
radio. Per-AP 2.4 GHz (`radio_table`, radio=ng):

    AP05-Meterkast   min_rssi_enabled=false
    AP01-Trapkast    min_rssi_enabled=false     <- the AP it is on now
    AP03-Slaapkamer  min_rssi_enabled=true  -80 <- not audible from the shed at all
    AP06-Keuken      min_rssi_enabled=false     <- the AP it should be on
    AP04-Zolder      min_rssi_enabled=false
    AP02-Stube       min_rssi_enabled=false

Both relevant APs have NO kick threshold. The only AP with one (AP03) does not appear in the
shed's scan. Consistent with memory `aqara-fp2-wedge`: min-RSSI exonerated again, with fresh
numbers. **No change to min-RSSI is proposed.**

## D. min-rate kick: FALSIFIED, and in the opposite direction

    VDHIOT      minrate_setting_preference=manual  minrate_ng_data_rate_kbps=9000   (9 Mbps)
    VDHFEMFLEX  minrate_setting_preference=manual  minrate_ng_data_rate_kbps=12000  (12 Mbps)

VDHIOT's floor is 3 Mbps MORE PERMISSIVE than the SSID the device is currently holding at
-81 dBm (tx_rate 13000). A rate floor cannot evict from the permissive SSID while the
stricter one holds. **No change to min-rate is proposed** (memory `aqara-fp2-wedge`).

## E. Actual root cause: Shelly sta/sta1 failover is STICKY

`WiFi.GetConfig` (2026-09-08T07:16Z):
    sta  = VDHIOT      enable=true   ipv4mode=dhcp
    sta1 = VDHFEMFLEX  enable=true   ipv4mode=dhcp
    roam = { rssi_thr: -80, interval: 60 }

`WiFi.GetStatus`: ssid=VDHFEMFLEX bssid=84:78:48:c8:65:45 ch6 rssi=-81 sta_ip=172.16.3.117

Sequence: AP06-Keuken rebooted 2026-09-04T01:01Z. The shed lost the only VDHIOT BSSID it
hears well. Its `sta` join failed during the AP06 outage window, so firmware fell back to
`sta1` = VDHFEMFLEX and associated to AP01-Trapkast at -81 dBm on CLIENT-VLAN, reclaiming its
pre-migration lease 172.16.3.117. It has NEVER returned: Shelly only re-tries `sta` when
`sta1` fails, and `roam` only moves between BSSIDs *within the joined SSID* — and even that
did not fire (4 days at -81, below its own -80 rssi_thr, with a -65 VDHFEMFLEX BSSID from
AP06 in range and unused). Shelly device uptime 4221380 s (48.9 d) => the device never
rebooted; only the association changed.

HA impact: config entry 01JQKSQFN7ZQMG9793BQD2FNDD still stores host=172.16.4.20 (unchanged
since 2026-07-30T08:21:52Z) -> `device_communication_error` -> `setup_retry`. Zeroconf
self-heal did NOT rescue it this time. The other 9 entries store 172.16.4.21-.29, all loaded.

UniFi DHCP reservation for 34:b7:da:93:30:74 is INTACT: fixed_ip=172.16.4.20,
use_fixedip=true, network_id=6226f5bddd6f9706a46a66cb (IOT-VLAN). So a successful VDHIOT
rejoin restores 172.16.4.20 and HA needs NO change at all.

This is precisely the downside recorded in memory `shelly-iot-migration` on 2026-07-30:
"a device can silently re-enter CLIENT-VLAN and defeat the segmentation; strip sta1 once
stable." That prediction has now come true.
