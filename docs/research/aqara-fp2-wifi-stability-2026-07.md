# Aqara Presence Sensor FP2 — recurring wifi disconnects (root causes + fixes)

## Question
Why does the Aqara FP2 (PS-S02D, 2.4 GHz-only wifi) keep dropping off wifi / going
unavailable in Home Assistant, and is our UniFi config (2.4 GHz 12 Mbps min-rate floor +
min-RSSI on the AP) a documented cause? What are the community-recommended fixes?

## TL;DR
- The FP2 is a cheap, single-band, standards-lax 2.4 GHz client. The most-reported killers
  are **AP settings that police weak/slow clients**: min-RSSI deauth, high minimum-data-rate
  floors, band-steering, and 802.11r/k/v fast-roaming — plus **WPA3/PMF** and **cross-VLAN
  mDNS breakage** (the latter causes "unavailable" specifically in the HomeKit integration).
- **Yes — our exact config is documented to hurt devices like the FP2.** Min-RSSI "disconnects
  clients once their signal drops below a set threshold" and a raised minimum-data-rate "can
  block legacy or low-speed IoT devices." A 12 Mbps floor + min-RSSI is precisely the combo
  the community warns against for budget 2.4 GHz IoT.
- **Integration:** HomeKit Controller is the mainstream, most-stable path for the FP2 in HA;
  Matter support exists but is reported "a little flaky." Most "goes unavailable" reports trace
  to **network discovery (mDNS/multicast across VLANs)**, not the integration code itself.
- **Firmware:** no single blessed "stable" build; recent line is `1.3.1_0001_0096`
  (late 2025), with the older `1.2.5_0003.xxxx` line before it. Both have user-reported
  regressions (delays / false presence), fixed by reset+re-pair, not downgrade.
- **Fix for us:** put the FP2 on a dedicated IoT SSID (2.4 GHz, WPA2-AES, PMF off), and on that
  SSID turn **min-RSSI off**, drop the **min-data-rate to 1–6 Mbps**, **band-steering off**,
  **802.11r off**; confirm mDNS reflection reaches the FP2's VLAN.

## Most-reported disconnect causes (ranked)
1. **Min-RSSI deauth of weak clients.** "Min-RSSI disconnects clients once their signal drops
   below a set threshold"; set too aggressively it causes bouncing. Budget IoT that gets kicked
   repeatedly may then refuse to reconnect. [itman.ae 2025-07-02; community.ui.com min-rate threads]
2. **Minimum-data-rate floor too high.** Raising the min rate "can block legacy or low-speed
   IoT devices that rely on outdated data rates." A 12 Mbps floor is well above what a cheap
   sensor at range will sustain. [UniHosted / community.ui.com, 2024–2025]
3. **WPA3 / PMF (Protected Management Frames) required.** "Do you have WPA3 or PMF on the
   2.4 GHz-only SSID? That may keep some older, less standards-compliant devices from
   connecting… keep WPA3 and PMF both disabled." [community.ui.com "Aqara 2.4GHz issue", 2024-08-07]
4. **Band-steering / combined SSID.** Steering and a merged 2.4+5 GHz SSID confuse onboarding
   and can bounce a 2.4-only device; community fix is a separate "iot-only" 2.4 GHz WPA2 SSID.
   [community.ui.com "Aqara 2.4GHz issue", 2024-08-07 — user WPrince]
5. **802.11r/k/v fast roaming.** "Not all phones or laptops are compatible" — applies to budget
   IoT; disable fast roaming if seeing excessive disconnects. [itman.ae 2025-07-02]
6. **Cross-VLAN mDNS/multicast breakage (HomeKit path).** FP2 works in the Aqara app but goes
   "unavailable" in HA when mDNS discovery across VLANs fails; one user fixed it by replacing an
   mDNS Repeater with a UDP Broadcast Relay on `224.0.0.251`. [community.home-assistant.io
   t/939441, 2025-10]
7. **Firmware regressions.** `1.3.1_0001_0096` reported to add big sensor→HA delays (2025-05/10);
   `1.2.5_0003.0074` reported false presence/absence, resolved by reset+re-pair.
   [community.home-assistant.io t/703978 & t/704808]
8. **FP2 itself destabilising the 2.4 GHz band** (self-interference / router compatibility) is
   reported but unconfirmed; vendor suggests separating the band and disabling Wi-Fi 7 compat.
   [forum.aqara.com t/207127, 2026-01]

## Q2 — Is the FP2 killed by exactly our AP settings?
Yes, this is well documented for cheap 2.4 GHz IoT (the FP2 is a textbook example):
- **min-RSSI** → explicit deauth below threshold. [itman.ae 2025-07-02]
- **min-data-rate floor (our 12 Mbps)** → blocks/【drops】low-rate IoT. [UniHosted; community.ui.com]
- **band-steering** → community's #1 recommended thing to disable for Aqara. [community.ui.com 2024-08-07]
- **802.11r fast roaming** → budget IoT often incompatible. [itman.ae 2025-07-02]
Our AP carries **both** a 12 Mbps floor **and** a min-RSSI — the two most-cited culprits stacked.

## Q3 — Most stable HA integration + firmware
- **HomeKit Controller** is the primary and most-used integration for the FP2 in HA and is the
  more stable of the two; **Matter** works but is reported "a little flaky."
  [community.home-assistant.io t/703978, t/545374; forum.aqara.com t/306231, 2025]
- Most "unavailable" reports are **network/discovery** issues (mDNS/VLAN), not the integration.
- **Firmware:** recent line `1.3.1_0001_0096` (late 2025); prior `1.2.5_0003.0074`. No single
  build is universally "stable"; both had regressions cured by reset+re-pair.
  [community.home-assistant.io t/704808, t/703978]
- Aqara's own FP2 FAQ page (aqara.com → store-support) returned placeholder / "No content yet",
  so official 2.4-GHz/WPA spec **could not be verified** from the vendor this run.

## Q4 — Recommended UniFi / wifi settings for reliable FP2
On a dedicated IoT SSID (the recurring community recommendation):
- **2.4 GHz only**, **WPA2-PSK (AES)** — **not** WPA3; **PMF = Optional or Off**, never Required.
- **Band-steering: Off** on that SSID.
- **Min-RSSI: Off** (or set very low, e.g. -80 dBm) for the IoT SSID / on the serving AP.
- **Minimum data rate: 1–6 Mbps**, not 12 Mbps, on that SSID.
- **Fast roaming (802.11r): Off** for the IoT SSID.
- Assign a **DHCP reservation** for the FP2; ensure **mDNS/multicast reflection** reaches its VLAN
  if HomeKit/HA sits on a different VLAN.

## Sources
- community.ui.com — "Aqara 2.4GHz issue" (posted 2024-08-07; rendered via kiosk-verify/Playwright,
  WebFetch returned React shell): WPA3/PMF disable, band-steering off, separate WPA2 2.4 GHz IoT SSID.
  https://community.ui.com/questions/Aqara-2-4GHz-issue/212ff79f-aa6e-4a88-9b6e-9059ffdf620a
- itman.ae — "How UniFi Handles Seamless Roaming: Min-RSSI Band Steering Best Practices" (2025-07-02):
  min-RSSI disconnects below threshold; 802.11r IoT incompatibility. https://itman.ae/2025/07/02/how-unifi-handles-seamless-roaming/
- UniHosted — "UniFi Minimum Data Rate Control: A guide" (2024–2025): raised min-rate blocks legacy/
  low-speed IoT. https://www.unihosted.com/blog/unifi-minimum-data-rate-control
- community.home-assistant.io — "Broken connection with HomeKit and Aqara FP2 sensors" (2025-10):
  cross-VLAN mDNS fix via UDP Broadcast Relay 224.0.0.251. https://community.home-assistant.io/t/broken-connection-with-homekit-and-aqara-fp2-sensors/939441
- community.home-assistant.io — "Aqara FP2 Issues and New Version of Aqara Home" (2024-03 → 2025-10):
  HomeKit integration; firmware 1.3.1_0001_0096 delays. https://community.home-assistant.io/t/aqara-fp2-issues-and-new-version-of-aqara-home/703978
- community.home-assistant.io — "Has anyone updated their Aqara FP2 to the latest firmware yet?":
  firmware 1.2.5_0003.0074 false-presence regression, reset+re-pair fix. https://community.home-assistant.io/t/has-anyone-updated-their-aqara-fp2-to-the-latest-firmware-version-yet/704808
- forum.aqara.com — "FP2 Causing 2.4 GHz WiFi Instability…" (2026-01): vendor troubleshooting,
  isolate band / disable Wi-Fi 7 compat. https://forum.aqara.com/t/fp2-causing-2-4-ghz-wifi-instability-and-disconnecting-other-devices/207127
- help.ui.com — "Understanding and Implementing Minimum RSSI": **could not verify** (HTTP 403 this run).
- aqara.com FP2 FAQ (→ store-support.aqara.com): **could not verify** (page served placeholder / no content).

— Athena
