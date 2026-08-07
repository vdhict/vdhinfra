# Runbook: migrating a device to IOT-VLAN

- **Created**: 2026-07-30, from the pilot (`chg-2026-07-30-001` + `chg-2026-07-30-002`)
- **Owner**: Iris (`udm-engineer`) for the network side, Hestia (`ha-engineer`) for the HA side
- **Scope**: any Wi-Fi IoT device the household wants behind the segmentation boundary
- **Background**: `docs/research/shelly-iot-vlan-migration-2026-07.md`

---

## What is already done (do not redo)

The boundary exists and is enforced. Verified by real traffic on 2026-07-30:

| Zone pair | Action |
|---|---|
| `Internal → IoT` | **ALLOW** — user policy `6a6b0cb0d71f730c128ea97a`, idx 10000, `create_allow_respond: true` |
| `IoT → Internal` | **BLOCK** (catch-all). Measured: a device on IOT-VLAN went from HTTP 200 to connection-refused against HA |
| `IoT → External` | ALLOW (cloud, SNTP, DNS 1.1.1.1) |
| `IoT → Gateway` | ALLOW + predefined `Allow mDNS` udp/5353 |
| everything else → IoT | BLOCK |

- Zone `IoT` = `6a6b0c0dd71f730c128ea73f`, contains only IOT-VLAN (`6226f5bddd6f9706a46a66cb`).
- **mDNS reflection to CLIENT-VLAN still works** through the Gateway zone, so Home Assistant's
  zeroconf auto-heal survives the block. No `IoT → Internal` 5353 rule is needed.

> The matrix shows **both** `ALLOW IoT→Internal (Return)` (idx 30000) and `BLOCK IoT→Internal`
> (idx max). Not a contradiction: the ALLOW is the stateful return companion for
> Internal-initiated connections. New IoT-initiated flows hit the BLOCK. Leave both alone.

**So migrating a further device is now a per-device job only.** No firewall work required —
it lands behind the policy automatically.

---

## ⚠️ First ask: does the device talk to us, or do we talk to it?

The IoT zone allows `Internal → IoT` and blocks `IoT → Internal`. That fits devices Home
Assistant **reaches into** — Shelly, HomeWizard, Tapo. All 10 Shellys moved cleanly on this
model.

**A device that PUSHES to a local service will go silent the moment it lands.** ESPresense did
exactly this on 2026-08-07: it publishes to mosquitto and its entire entity set went
`unavailable` within seconds of the move, while still being perfectly reachable over HTTP.

Before moving anything, check which way the traffic flows:

| Pattern | Moves cleanly? |
|---|---|
| HA polls / connects to the device (Shelly, HomeWizard, Tapo) | ✅ yes |
| Device publishes to MQTT | ⚠️ needs a broker allow (see below) |
| Device calls an HA webhook / pushes to any LAN service | ⚠️ needs its own allow |
| Device only talks to the internet (cloud plugs) | ✅ yes |

**MQTT is already handled** — `chg-2026-08-07-001` added one narrow policy:

| | |
|---|---|
| Source | zone IoT, any |
| Destination | `172.16.2.244` TCP `1883` only |
| Action | ALLOW (`_id` 6a75e6dd3c73884a000cb657) |

Verified by real traffic: the broker port opens from IoT, while HA, the NAS **and the same
broker IP on port 80** all stay blocked. Any further MQTT device needs no new firewall work.

For a *different* push target, add an equally narrow policy — one host, one port. Do not
widen `IoT → Internal` wholesale; that would undo the segmentation.

> Disproven hypothesis, recorded so nobody repeats it: IOT-VLAN hands out **external** DNS
> (1.1.1.1 / 8.8.4.4) while CLIENT-VLAN uses an internal resolver, so internal names looked
> like they should fail from IoT. They do not — `bluejungle.net` is a public zone carrying
> internal-IP records, and 1.1.1.1, 8.8.4.4 and the IOT gateway all resolve
> `mqtt.bluejungle.net` to 172.16.2.244. DNS is not a blocker on IOT-VLAN.

## Per-device procedure

### 0. Pre-flight

```bash
KEY=$(cat ~/Code/homelab-migration/config/unifi-api-key)
MAC=aa:bb:cc:dd:ee:ff

./ops/ops freeze status                       # must be clear for medium+
./ops/ops lock list                           # no one else holding the resource

# current state + the client's rest/user _id (needed for the reservation)
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/stat/sta \
  | jq -r --arg m "$MAC" '.data[]|select(.mac==$m)|{mac,ip,network,essid,ap_mac,rssi}'
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/user \
  | jq -r --arg m "$MAC" '.data[]|select(.mac==$m)|{_id,mac,fixed_ip,use_fixedip,network_id}'
```

Pick a free address in **172.16.4.2–254** (the DHCP pool is 172.16.5.x, so the .4.x half is
reservation space) and prove it is free:

```bash
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/user \
  | jq -r '.data[]|select(.fixed_ip!=null and (.fixed_ip|startswith("172.16.4.")))|.fixed_ip'
```

Open a change record (**medium** risk) and acquire locks before writing anything.

### 1. Reserve the IOT-VLAN address

Merge onto the **full** existing object — partial bodies get fields dropped.

```bash
CID=<rest/user _id>
BODY=$(curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/user \
  | jq -c --arg id "$CID" '.data[]|select(._id==$id)
      | .use_fixedip=true | .fixed_ip="172.16.4.NN"
      | .network_id="6226f5bddd6f9706a46a66cb"
      | .name="<friendly name>"')
curl -sk -X PUT -H "X-API-KEY: $KEY" -H "Content-Type: application/json" -d "$BODY" \
  "https://172.16.2.1/proxy/network/api/s/default/rest/user/$CID" | jq -r .meta.rc
```

Read it back — do **not** trust `rc=ok` alone.

> ⚠️ **`rc=ok` means stored, NOT live.** UniFi accepts and persists the reservation
> immediately, but the DHCP server does not honour it for a further while. Wait **~30 s**
> before letting the device re-DHCP. Evidence (`inc-2026-07-31-001`): the pilot had a 21 s
> gap and got its reserved address; the batch run had 2 s and the device got a *pool*
> address instead.
>
> ⚠️ **And do not treat a wrong IP as a failure.** The objective is *the device is on
> IOT-VLAN and HA can reach it*. The reserved address is a convenience for lease
> stability. Landing on IOT-VLAN with a pool IP is a **success that needs a nudge**
> (re-apply the wifi config to force a fresh DHCP request), not a reason to roll back.
> Conflating the two is exactly what aborted the first batch run at device 1 of 9.

### 2. Re-home the device's Wi-Fi

The VLAN is chosen by **passphrase**, not by SSID. Both PPSKs live on the `VDHIOT` WLAN:

```bash
IOTPSK=$(curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/wlanconf \
  | jq -r '.data[]|select(.name=="VDHIOT")|.private_preshared_keys[]
           |select(.networkconf_id=="6226f5bddd6f9706a46a66cb")|.password')
```

Never echo it, and never let it reach a change record or evidence file.

**Shelly Gen2/Gen3** — remote, reversible, no physical access:

```bash
FEMPSK=$(curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/wlanconf \
  | jq -r '.data[]|select(.name=="VDHFEMFLEX")|.x_passphrase')
REQ=$(jq -nc --arg ip "$IOTPSK" --arg fp "$FEMPSK" '{config:{
  sta:  {ssid:"VDHIOT",     pass:$ip, enable:true, ipv4mode:"dhcp"},
  sta1: {ssid:"VDHFEMFLEX", pass:$fp, enable:true, ipv4mode:"dhcp"}}}')
curl -s --max-time 8 -X POST -H "Content-Type: application/json" -d "$REQ" \
  http://<current-ip>/rpc/WiFi.SetConfig
```

`sta1` is the self-recovery net: if the VDHIOT join fails the device falls back to VDHFEMFLEX
and stays reachable. **Set it every time.**

> ⚠️ **`WiFi.SetConfig` returns `{"restart_required": true}`. IGNORE IT — do not reboot.**
> Measured on the pilot: the device reassociated to VDHIOT within 10 s and `Sys.GetStatus`
> uptime stayed at 769 051 s, so no reboot happened and the relay never opened. This matters:
> the other 9 Shellys are the **mains supply to Sonos speakers**, and a needless reboot is the
> one way to make this change audible.

For non-Shelly devices there is usually no API — reprovision Wi-Fi in the vendor app using the
IoT PPSK, or hold the device's own AP-mode setup.

### 3. Home Assistant

Usually **nothing to do**. The pilot self-healed: zeroconf discovery rewrote the config entry's
`host` from the old IP to the new one with no operator action
(`_abort_if_unique_id_configured({CONF_HOST: host})`).

If it does not self-heal within a few minutes:
Settings → Devices & Services → the integration → device → ⋮ → **Reconfigure** → new IP.
That path preserves entity IDs, `unique_id`s and long-term statistics. **Do not delete and
re-add** — you will orphan history.

Shelly has **no DHCP discovery** (`dhcp: null` in the manifest), which is exactly why step 1's
fixed reservation is not optional.

---

## Verification — all of it, every time

Do not report done on a config read. Minimum set, adapted from the pilot:

| # | Test | Pass condition |
|---|---|---|
| T1 | Both ends agree | UniFi `stat/sta`: `network=IOT-VLAN`, expected IP, `essid=VDHIOT`. Device side reports the same SSID + IP |
| T2 | **Isolation actually enforced** | From inside the segment, a connection to CLIENT-VLAN **fails**. For Shelly: `HTTP.GET http://172.16.2.237:8123/` must error (it returns 200 from an unsegmented network) |
| T3 | External survives | `HTTP.GET http://1.1.1.1/` still returns `-4 response too big` (= connected). Device clock advancing; cloud connected if it uses cloud |
| T4 | **End-to-end user-visible** | Drive the device from HA and confirm the *device* followed — for a relay, `Switch.GetStatus` `output` **and** `apower > 0` under real load. A state flag alone is not sufficient |
| T5 | Push path | Change state **at the device**; the HA entity must follow unprompted |
| T6 | mDNS | zeroconf browse from the HA pod still sees the device |
| T7 | No collateral | UDM responsive; client counts not down; other IOT-VLAN members' `assoc_uptime` unbroken; cluster nodes Ready |

Handy probe from the real consumer rather than from your laptop:

```bash
POD=$(mise exec -- kubectl -n home-automation get pods -o name \
      | grep home-assistant | head -1 | cut -d/ -f2)
mise exec -- kubectl -n home-automation exec $POD -c app -- sh -c \
  'ip route get 172.16.4.NN; curl -s --max-time 6 http://172.16.4.NN/rpc/Shelly.GetDeviceInfo'
```

Record every result to `ops/evidence/<chg-id>/`.

---

## Rollback

1. **Fast**: `WiFi.SetConfig` with `sta.ssid=VDHFEMFLEX` → device returns to CLIENT-VLAN.
2. **Device already unreachable on IOT**: it self-recovers to `sta1`; find it again via
   `stat/sta` and revert.
3. Revert HA's `host` (Reconfigure) if it does not self-heal.
4. Remove the 172.16.4.x reservation / revert `network_id`.
5. **Whole-boundary revert** (only if the segmentation itself is the problem): delete zone
   `6a6b0c0dd71f730c128ea73f`; UniFi returns IOT-VLAN to `Internal` and today's allow-all
   behaviour. Confirm by re-running T2 and expecting success again.
6. Escape hatch: the UDM GUI firewall page can disable any policy in one click.

---

## Status: COMPLETE (2026-07-31)

All 10 Shellys are on IOT-VLAN at 172.16.4.20–.29. Zero remain on CLIENT-VLAN.
This section is kept for the wider IoT sweep and for the lessons below.

### Lessons that cost us three false aborts

Every failure in this migration was the same defect shape: **sampling a state that had
not yet converged and treating "not yet" as "failed".** No device ever actually failed to
migrate. If you extend this script, watch for it.

1. **Don't require the reserved IP to call it landed.** The objective is *on IOT-VLAN and
   reachable*. Landing on a pool address is a success needing a nudge, not a rollback.
2. **Don't trust UniFi `stat/sta`'s `ip` field.** It goes stale for minutes after a VLAN
   move — observed still reporting the old CLIENT-VLAN address 165 s after the device had
   moved. The `network` field IS reliable. Find the address by probing candidates and
   matching the MAC the device reports back; that is self-validating.
3. **Don't single-sample Home Assistant.** HA re-discovers the new IP via zeroconf and its
   sensors go briefly unavailable. One abort came from checking 2 SECONDS too early. Poll
   to convergence.

### Also learned

- **`WiFi.SetConfig` returning `restart_required: true` is advisory** — never reboot.
- **Plug labels lie.** Verify what a plug actually feeds before actuating it. Query the
  Sonos zone directly (`http://<ip>:1400/status/zp`) rather than trusting an HA entity
  name, and correlate plug wattage across a play/pause transition.
- **A no-actuation re-home cannot disturb a Sonos stereo pair or surround bond.** The
  speakers are separate network clients from their plugs; moving the plug's Wi-Fi touches
  neither the speaker's power nor its own CLIENT-VLAN connection. Proven in live use: the
  Woonkamer home theatre played at 15.9 W through freshly migrated plugs.

## Remaining work

~~**9 Shellys still on CLIENT-VLAN**~~ — **DONE 2026-07-31.** Final addressing:

| HA name | IP | MAC | RSSI |
|---|---|---|---|
| Sonos Keuken | 172.16.3.109 | 34:b7:da:90:7d:f0 | -54 |
| Sonos Surround Rechtsachter | 172.16.3.146 | 34:b7:da:8b:a9:88 | -59 |
| Sonos Surround Linksachter | 172.16.3.42 | 54:32:04:5f:2c:c4 | -61 |
| Sonos Achtertuin | 172.16.3.202 | 34:b7:da:8f:f2:0c | -65 |
| Sonos Sub | 172.16.3.36 | 34:b7:da:92:6e:64 | -67 |
| Sonos Eetkamer | 172.16.3.200 | 34:b7:da:8b:b3:1c | -70 |
| Sonos Play:1 | 172.16.3.80 | 34:b7:da:8f:dc:60 | -71 |
| Sonos Arc Ultra | 172.16.3.170 | 34:b7:da:92:1c:8c | -71 |
| **Sonos Bartafel** | 172.16.3.54 | 34:b7:da:90:9a:14 | **-75** ← last |

Then the wider sweep:

- **6 HomeWizard Energy Sockets** (the other half of `sonos_alles_uit` / `sonos_power_cycle`).
- **6 devices already on the `VDHIOT` SSID but on CLIENT-VLAN** because they hold the *CLIENT*
  PPSK — `espresense-kantoor`, `SIEMENS - Vaatwasser`, `SIEMENS-CT836LEB6`, a Tuya `wlan0`,
  `172.16.3.145`, and `Presence-Sensor-FP2-F08E`. These need only a passphrase swap.
  ⚠️ **Leave the FP2 for last or not at all** — see `reference_aqara_fp2_wedge`: it is the only
  ground-floor lux+presence sensor, the morning routine and adaptive lighting depend on it, and
  it already wedges its IP stack periodically. Do not add a variable to that device casually.
- **Dead reservation**: `raspberrypi` 172.16.4.15, last seen Jan 2023. Safe to reap.

### Open decisions

- **`IoT → External` is currently ALLOW**, so Shelly cloud egress continues. Non-regressive, but
  worth revisiting — blocking it would also break SNTP (`time.cloudflare.com`) unless the UDM is
  handed out as NTP first (`dhcpd_ntp_enabled` is currently false on IOT-VLAN).
- **`Internal → IoT` is ALLOW on all ports.** Could be tightened to HA's source range only.
- **`auth_en: false` on all 10 Shellys.** Independent of segmentation and arguably better
  value per unit of effort. HA supports Shelly credentials.
- **`sta1` fallback** is currently left armed on the pilot. It means a device can silently
  re-enter CLIENT-VLAN if VDHIOT ever fails, quietly defeating the segmentation. Suggested:
  keep during migration, strip once stable, and watch the UniFi client list for strays.
