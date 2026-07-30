# Research: moving the Shelly devices to the IOT network

- **Date**: 2026-07-30
- **Author**: Atlas (Infra OPS Manager)
- **Status**: ✅ **SUPERSEDED BY EXECUTION** — the user chose Option C (move + segment) the same
  day. Pilot device migrated (`chg-2026-07-30-001`) and the IoT firewall zone + policies are
  **live and measured** (`chg-2026-07-30-002`). Operational procedure now lives in
  **`docs/runbooks/iot-vlan-migration.md`** — use that to migrate further devices.
  This document is retained for the reasoning and the pre-change baseline.
- **Question**: can/should the 10 Shelly devices be moved from CLIENT-VLAN to IOT-VLAN?

> ### What execution changed about this document
>
> Three things this research recorded as unknown or planned turned out differently:
>
> 1. **mDNS reflection CLIENT ↔ IOT works** (§1.4 called it unproven). Confirmed twice: HA
>    self-healed the Shelly's config-entry IP with zero operator action, and a zeroconf browse
>    saw the device. It **also survives the `IoT → Internal` block**, because UniFi reflects via
>    the Gateway zone — so the planned `IoT → Internal` UDP/5353 allow was **never created**.
>    The result is stricter than designed with no loss of function.
> 2. **`WiFi.SetConfig` returns `restart_required: true`**, contradicting the docs quoted in §2.
>    It is advisory: the device reassociated in <10 s with uptime unbroken at 769 051 s. **Do not
>    reboot on seeing it** — the other 9 Shellys feed Sonos speakers.
> 3. **Creating a zone auto-generates a default-deny matrix**, including `Internal → IoT BLOCK`.
>    Access to the segment is lost until you add the ALLOW. Plan for that ~75 s gap.
>
> The core finding held exactly: before the change, a device on IOT-VLAN got **HTTP 200** from
> Home Assistant on CLIENT-VLAN. After it, connection refused.

---

## TL;DR

The move itself is **cheap, remote-only and reversible** — much easier than expected, because
the plumbing already exists (`VDHIOT` SSID already has a Private PSK that lands on IOT-VLAN,
and Shelly Gen3 can be re-homed to another Wi-Fi network over its own REST API with an
automatic fallback to the old network).

But **the move on its own buys nothing security-wise.** IOT-VLAN, CLIENT-VLAN and SERVER-VLAN
are all members of the same UniFi firewall zone (`Internal`), and `Internal → Internal` is
`Allow All Traffic`. There are **zero user-created firewall policies** on this UDM. Today
IOT-VLAN is a different subnet, not a security boundary.

So this is really **two** projects, and the second one is where all the value and all the risk
live:

| | What | Risk | Value |
|---|---|---|---|
| **Phase 1** | Re-home Shellys to IOT-VLAN | low–medium | ~none on its own |
| **Phase 2** | Make IOT-VLAN an actual zone with policies | **high** | the entire point |

Recommendation: **do it, but as one project with both phases planned up front**, starting with a
single-device pilot (`Verlichting Schuur` — the only Shelly that is not powering a Sonos speaker).
Do not do Phase 1 alone and call it segmentation.

---

## 1. Current state (measured 2026-07-30)

### 1.1 The devices

10 × **Shelly 1PM Mini Gen3** (`S3SW-001P8EU`, app `Mini1PMG3`), firmware **2.0.0**
(`20260710-101127/2.0.0-g87fbfa4`), all on `CLIENT-VLAN` via SSID **`VDHFEMFLEX`**, all on
2.4 GHz channel 6, all DHCP (no reservations).

| HA name | IP | MAC | RSSI | relay | W |
|---|---|---|---|---|---|
| Sonos Surround Rechtsachter | 172.16.3.146 | 34:b7:da:8b:a9:88 | -59 | on | 4.9 |
| Sonos Eetkamer | 172.16.3.200 | 34:b7:da:8b:b3:1c | -70 | on | 5.4 |
| Sonos Play:1 | 172.16.3.80 | 34:b7:da:8f:dc:60 | -71 | on | 2.7 |
| Sonos Achtertuin | 172.16.3.202 | 34:b7:da:8f:f2:0c | -65 | on | 3.9 |
| Sonos Keuken | 172.16.3.109 | 34:b7:da:90:7d:f0 | -54 | on | 5.4 |
| Sonos Bartafel | 172.16.3.54 | 34:b7:da:90:9a:14 | **-75** | on | 3.0 |
| Sonos Arc Ultra | 172.16.3.170 | 34:b7:da:92:1c:8c | -71 | on | 16.0 |
| Sonos Sub | 172.16.3.36 | 34:b7:da:92:6e:64 | -67 | on | 4.7 |
| **Verlichting Schuur** | 172.16.3.117 | 34:b7:da:93:30:74 | -65 | off | 0.0 |
| Sonos Surround Linksachter | 172.16.3.42 | 54:32:04:5f:2c:c4 | -61 | on | 4.8 |

**9 of the 10 are the mains supply to a Sonos speaker.** Only `Verlichting Schuur` is not.
That makes the blast radius of a mistake "the hi-fi goes dark", not "a sensor goes stale".

Device posture, per `Shelly.GetDeviceInfo` / `*.GetConfig`:

- `auth_en: false` — **no RPC authentication on any of them.** Any host that can route to
  port 80 can flip the relay and read power data, unauthenticated.
- `Cloud.enable: true` → outbound to `shelly-142-eu.shelly.cloud:6022`.
- `MQTT.enable: false`, `Ws.enable: false` (no outbound websocket), `rpc_udp.dst_addr: null`.
- `sntp.server: time.cloudflare.com`.
- `sta1` (backup Wi-Fi slot) is **empty and unused** on all 10.
- `Switch.initial_state: match_input` on all 10 — relay state after a restart follows the
  physical input, it is not forced off.

### 1.2 How Home Assistant talks to them

HA **2026.7.4**, running `hostNetwork: true` on `vdhclu01node01` (172.16.2.81) — so HA sits
directly on CLIENT-VLAN L2, which is why zeroconf works today.

- All 10 config entries were created by `zeroconf` but store a **hard-coded `host` IP**
  (`{"gen":3,"host":"172.16.3.x","model":"S3SW-001P8EU","sleep_period":0}`).
- `iot_class: local_push`, and the device has `Ws.enable: false` → **HA opens the websocket
  outbound to the device**; the device never initiates to HA.
  → **Required traffic direction is HA → Shelly TCP/80 only.**
- Integration manifest: `zeroconf` discovery yes (`_shelly._tcp`, `_http._tcp` name `shelly*`),
  **`dhcp: None`** → there is **no DHCP-based rediscovery** for Shelly. If an IP changes,
  zeroconf is the *only* automatic self-heal path.
- The installed config flow **does** have `async_step_reconfigure` which writes
  `data_updates={CONF_HOST, CONF_PORT}` via `async_update_reload_and_abort`
  → **the host IP can be changed in-place from the UI without delete/re-add**, so entity IDs,
  `unique_id`s (MAC-based) and long-term statistics all survive.

**Existing latent fragility, independent of this project:** 10 hard-coded IPs on 24-hour DHCP
leases with no DHCP rediscovery. Today this survives only because the leases keep renewing.

### 1.3 What depends on them in HA

210 entities (10 × 21). Dependencies in config:

- `scripts.yaml` → **`sonos_alles_uit`** and **`sonos_power_cycle`**, each targeting the same
  15 switches. Of those 15: **9 are these Shellys, 6 are HomeWizard Energy Sockets**
  (`switch.sonos_play_3`, `sonos_one_sl_links`, `sonos_one_sl_rechts`, `sonos_amp`,
  `sonos_playbar_slaapkamer`, `sonos_port`).
- `automations.yaml:815-840` → **`Verlichting Schuur`**, motion + lux driven, toggles
  `switch.verlichting_schuur`. Its triggers are a Z-Wave/Zigbee multisensor, unaffected.

Note the Sonos *speakers themselves* are on CLIENT-VLAN with fixed IPs (172.16.2.10x) and are
**not** in scope — only the plugs feeding them.

### 1.4 The network as it actually is

Networks:

| Name | VLAN | Subnet | DHCP pool | DHCP DNS | IPv6 |
|---|---|---|---|---|---|
| CLIENT-VLAN | untagged | 172.16.2.1/23 | — | UDM | ULA + NAT66 |
| **IOT-VLAN** | **250** | **172.16.4.1/23** | 172.16.5.1–254 | **1.1.1.1** | none |
| SERVER-VLAN | 10 | 172.16.10.1/23 | — | — | — |
| GUEST-VLAN | 200 | 192.168.2.1/24 | — | — | — |

→ `172.16.4.2 – 172.16.4.254` is **outside the DHCP pool and free for static reservations.**

**Firewall zones:**

```
Internal  -> CLIENT-VLAN, IOT-VLAN, SERVER-VLAN
External  -> Ziggo, KPN, 3× PIA
Gateway   -> (empty)
Vpn       -> VDHNGFW, VDHVPN02
Hotspot   -> GUEST-VLAN
Dmz       -> (empty)
```

`Internal → Internal` = **`ALLOW  Allow All Traffic`**.
Policy inventory: **82 policies, all `predefined: true`, 0 user-created.**

> **This is the headline. IOT-VLAN is currently a subnet, not a boundary.** A device moved there
> can still reach every cluster node, the NAS, the UDM and every other client, and vice versa.

**The `VDHIOT` SSID is already wired for this.** It uses UniFi **Private Pre-Shared Keys** —
one SSID, two passphrases, each mapped to a different network:

| PPSK | lands on |
|---|---|
| _(IoT PPSK — read live, never stored here)_ | **IOT-VLAN** (`6226f5bddd6f9706a46a66cb`) |
| _(CLIENT PPSK — read live, never stored here)_ | CLIENT-VLAN (`5e9afa144edb2e02cf522ef5`) |

Retrieve them at use time, never commit them:

```bash
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/wlanconf \
  | jq -r '.data[]|select(.name=="VDHIOT")|.private_preshared_keys[]
           |"\(.networkconf_id)  \(.password)"'
```

`VDHIOT` is 2.4 GHz-only, WPA2, PMF disabled, `enhanced_iot: true`, `iot_channel_lock: true`,
min-rate **11 Mbps** (vs `VDHFEMFLEX` at 12 Mbps — *more* permissive, so no new risk for the
-75 dBm outlier), AP group **"All APs" (all 6 APs)**. ESP32-friendly and fully covered.

**This is proven working:** 3 × TP-Link P115 are on `VDHIOT` and hold IOT-VLAN leases
(172.16.5.93 / .186 / .243).

**But it is inconsistently applied.** 6 clients are on `VDHIOT` yet landed on **CLIENT-VLAN**
because they were given the CLIENT PPSK — `espresense-kantoor`, `Presence-Sensor-FP2-F08E`,
`SIEMENS - Vaatwasser`, `SIEMENS-CT836LEB6`, a Tuya `wlan0`, and one unnamed 172.16.3.145.
So the IOT-VLAN plan is already half-built and half-wired. Worth fixing as part of this.

**mDNS:** site-level reflector is `enabled`, `mode: all`, for `network_ids` =
CLIENT-VLAN + IOT-VLAN + SERVER-VLAN. Config says reflection should work CLIENT ↔ IOT.
⚠️ **I could not prove this empirically** — an mDNS browse from the HA pod across 7 service
types saw 29 hosts, **none** on 172.16.4/5.x. But the only IOT-VLAN residents are Tapo P115s
(which don't advertise mDNS) and an offline Pi at 172.16.4.15, so the test was inconclusive
rather than negative. **The pilot device is the real test.** Note also that the `VDHIOT` WLAN
itself has `mdns_proxy_mode: off` (a separate per-WLAN feature from the site reflector).

---

## 2. What the move mechanically requires

Because `VDHIOT`/IOT-PPSK already exists, **no new SSID, no new WLAN, no AP re-provisioning,
and no physical access** are needed.

Per the [official Shelly Gen2/3 WiFi docs](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/WiFi):

- `sta1` "will be used as fallback when the device is unable to connect to the `sta` network."
- "the process of applying it causes the Shelly to perform reconnection to the AP(s) about a
  second after the new config is stored" — **no reboot**, so the relay is not power-cycled and
  the Sonos speaker does not drop.

That gives a self-recovering re-home, per device, over its own API:

```
POST http://<shelly>/rpc/WiFi.SetConfig
{"config":{
  "sta":  {"ssid":"VDHIOT",     "pass":"<IOT PPSK>",        "enable":true,  "ipv4mode":"dhcp"},
  "sta1": {"ssid":"VDHFEMFLEX", "pass":"<VDHFEMFLEX PSK>",  "enable":true,  "ipv4mode":"dhcp"}
}}
```

If the VDHIOT join fails for any reason, the device falls back to `sta1` = the network it is on
today and stays reachable. **That is the whole safety story, and it is why this is worth doing
remotely rather than with a ladder and a paperclip.**

Then, per device:

1. UniFi: create a **fixed-IP reservation in 172.16.4.x** (outside the 172.16.5.x pool) for the MAC.
2. HA: **Reconfigure** the Shelly config entry to the new host IP
   (Settings → Devices & Services → Shelly → device → ⋮ → Reconfigure). Preserves entity IDs and
   statistics — no delete/re-add.
3. Verify: `Shelly.GetDeviceInfo` from the HA pod returns the matching MAC on the new IP, and the
   HA entity leaves `unavailable`.
4. Once stable, optionally clear `sta1` (or leave it as a permanent safety net — see §4).

Static IP could also be set on the device itself (`ipv4mode: static`) instead of a DHCP
reservation. **Prefer the DHCP reservation** — it keeps the addressing authority on the UDM,
where the rest of the estate already is, and avoids a device that can't be recovered by DHCP.

---

## 3. Options

### Option A — do nothing
Shellys stay on CLIENT-VLAN. 10 unauthenticated relay-control devices remain flat-reachable
from all 82 wireless clients + the cluster. The hard-coded-IP fragility stays. **Not recommended**,
but honest: the current risk is "a guest device or compromised client can switch the hi-fi off",
not "the household is on fire".

### Option B — move to IOT-VLAN only
Re-home all 10, reserve IPs, reconfigure HA. Result: cleaner inventory and addressing, a real
foundation for later segmentation — but **no security gain today**, because `Internal → Internal`
is allow-all. Low–medium risk, low reward. Only defensible as an explicit "phase 1 of 2".

### Option C — move + make IOT-VLAN a real boundary  ← recommended
Phase 1 as above, then:
- Create a new firewall zone (e.g. `IoT`), move IOT-VLAN out of `Internal` into it.
- `Internal → IoT`: **ALLOW** (HA reaches the devices; this is the only direction the Shellys need).
- `IoT → Internal`: **BLOCK**, with narrow exceptions only if the pilot shows they're needed.
- `IoT → External`: ALLOW (Shelly cloud, `time.cloudflare.com`, DNS 1.1.1.1 — all already external).
- `IoT → Gateway`: ALLOW DHCP/67 + DNS/53 + ICMP.

The Shelly traffic profile makes this unusually clean: **nothing on IOT-VLAN needs to initiate
into Internal.** MQTT off, outbound-WS off, UDP-RPC off, DNS/NTP/cloud all external.

**The one thing `IoT → Internal: BLOCK` costs you** is zeroconf/mDNS auto-heal (mDNS is UDP/5353
and the reflected responses have to traverse). Mitigation: fixed IP reservations mean you don't
depend on it. If you want it, allow UDP/5353 both directions explicitly.

**And the one thing to watch:** HA is `hostNetwork` and can be rescheduled to node .81, .82 **or**
.83. Any policy that names a source must cover **all three node IPs**, or better, the whole
CLIENT-VLAN 172.16.2.0/23. A policy pinned to 172.16.2.81 will break the next time HA moves node.

---

## 4. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Device fails to join VDHIOT and is lost | low | high (needs physical access) | `sta1` fallback to VDHFEMFLEX — proven behaviour, official docs |
| 2 | Relay drops → Sonos speaker loses power | low | medium (visible to household) | Wi-Fi reconfig does **not** reboot the device; `initial_state: match_input` |
| 3 | HA holds stale IP → entities `unavailable` | **high if unmanaged** | medium | fixed 172.16.4.x reservation **before** the move + HA Reconfigure step |
| 4 | mDNS doesn't reflect → no auto-rediscovery | medium | low | don't depend on it; fixed IPs + explicit Reconfigure |
| 5 | Phase-2 policy blocks HA after pod reschedules | medium | high | scope policies to 172.16.2.0/23, not a single node IP |
| 6 | `sonos_power_cycle` script spans two VLANs mid-migration | certain | low | 9 Shelly + 6 HomeWizard is already a split; script is entity-based and VLAN-agnostic |
| 7 | Weakest device (-75 dBm, Sonos Bartafel) drops on the new SSID | low | medium | VDHIOT min-rate 11 Mbps < VDHFEMFLEX 12 Mbps; same band, same 6 APs. Migrate this one last |
| 8 | UDM instability from batched writes | low | high | one write per 1–2 s; never during household peak |

---

## 5. Recommended plan

**Phase 0 — pilot (1 device, `Verlichting Schuur` @ 172.16.3.117).** The only Shelly not feeding
a Sonos, and its relay is currently off. Reserve 172.16.4.20, `WiFi.SetConfig` with `sta1`
fallback, reconfigure HA, then **answer the open empirical questions**: does it get the IOT lease,
does HA reach it across the subnet, and does zeroconf see it (proving or disproving mDNS
reflection). Soak 48 h. — *risk: medium*

**Phase 1 — remaining 9, in waves.** Two or three at a time, weakest-signal device (Bartafel,
-75 dBm) last. Same per-device procedure. Soak between waves. — *risk: medium*

**Phase 2 — the actual segmentation.** New `IoT` zone + the policy set in Option C. This is
where Argus and Themis earn their keep, and it needs its own change record and explicit
approval. — *risk: **high**, needs user approval*

**Phase 3 — consistency (optional, recommended).** Re-home the 6 mis-PPSK'd devices already on
`VDHIOT`→CLIENT-VLAN, and consider the 6 HomeWizard Energy Sockets. ⚠️ The FP2 is in this set —
see `reference_aqara_fp2_wedge`; it is the only ground-floor lux+presence sensor and the morning
routine depends on it. **Treat the FP2 separately and last, if at all.**

Suggested change records: one per phase, `net.vlan.iot` + `ha.integration.shelly` as resources.
Phase 0/1 = medium (QA pass, auto-execute). Phase 2 = **high** (firewall — explicit approval).
No freeze windows currently active.

---

## 6. Open questions for the user

1. **Is segmentation actually the goal?** If yes → Option C, and Phase 2 must be committed to up
   front. If the goal is only tidier addressing → Option B is honest but low-value, and worth
   knowing that's what you're buying.
2. **Do you want `auth_en` turned on** on the Shellys (RPC password) as part of this? It's
   defence-in-depth that doesn't depend on the firewall, and HA supports Shelly credentials.
   Independent of the VLAN move and arguably higher value per unit of effort.
3. **Leave `sta1` fallback in place permanently?** Pro: a Shelly can never be stranded by a
   VDHIOT/PPSK change. Con: a device that fails onto VDHFEMFLEX silently re-enters CLIENT-VLAN
   and quietly defeats the segmentation. My lean: keep it during migration, remove it after
   Phase 2 is stable, and rely on the UniFi client list to catch strays.
4. **Scope**: Shellys only, or the wider IoT sweep (Phase 3)?

---

## Appendix — evidence

All findings above were read live from the UDM and HA on 2026-07-30.

```bash
# Networks, zones, policies, WLAN PPSK mapping
KEY=$(cat ~/Code/homelab-migration/config/unifi-api-key)
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/networkconf
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/v2/api/site/default/firewall/zone
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/v2/api/site/default/firewall-policies
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/rest/wlanconf
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/get/setting   # key=mdns
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/stat/sta

# Per-device Shelly posture
for m in Shelly.GetDeviceInfo WiFi.GetConfig WiFi.GetStatus Cloud.GetConfig \
         MQTT.GetConfig Ws.GetConfig Sys.GetConfig; do
  curl -s http://172.16.3.117/rpc/$m; done
curl -s 'http://172.16.3.117/rpc/Switch.GetConfig?id=0'

# HA side
kubectl -n home-automation exec <ha-pod> -c app -- python3 -c \
  "import json;print([e['data'] for e in json.load(open('/config/.storage/core.config_entries'))['data']['entries'] if e['domain']=='shelly'])"
grep -oE 'async_step_[a-z_]+' \
  /usr/local/lib/python3.14/site-packages/homeassistant/components/shelly/config_flow.py
```

Sources:
- [Shelly Gen2/Gen3 WiFi component — `WiFi.SetConfig`, `sta1` fallback, reconnect timing](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/WiFi)
- UniFi API surface / auth model: `docs/research/unifi-api-access-2026-06.md`
- FP2 caveat: `reference_aqara_fp2_wedge` memory
