# Walk sheet: HomeWizard → IOT-VLAN

Parked 2026-07-31 at the user's request ("plan it when I have a second").
Background + the reasoning: `docs/research/homewizard-iot-vlan-migration-2026-07.md`

**There is no remote path.** Every device needs the HomeWizard app plus a physical button
hold. This sheet exists so the walk is short instead of a scavenger hunt.

## Before you start

- Have the HomeWizard app open, and the **IoT PPSK** to hand (the `VDHIOT` passphrase that
  maps to IOT-VLAN — read it live, see the runbook; do not write it down here).
- **Gesture matters**: hold the button *a few seconds* to enter pairing mode.
  Holding it **>1 minute is a factory reset and wipes the device's history.**
- No relay is interrupted, so nothing loses power and no maintenance window is needed.
- Not sure which physical socket you're looking at? Blink its LED:
  `curl -s -X PUT http://<ip>/api/v1/identify`
- Nothing needs doing on the network or in HA afterwards — the boundary already exists and
  HA re-discovers each device by mDNS (`_hwenergy._tcp`), exactly as it did for all 10 Shellys.

## Suggested order

Low-stakes rooms first, then living areas, then the two sensitive ones individually, then the
meters last. Stop whenever you run out of time — a half-migrated fleet is harmless.

## Sockets (25)

| ☐ | Room | HA entity | Serial | IP now | W | Lock |
|---|---|---|---|---|---|---|
| ☐ | Kantoor | `switch.energy_socket_7` | 5c2faf1eb3a2 | 172.16.3.182 | 0.000 | switchable |
| ☐ | Kantoor | `switch.energy_socket` | 5c2faf1873b2 | 172.16.3.60 | 2.246 | switchable |
| ☐ | Keuken | `switch.energy_socket_15` | 5c2faf184a8a | 172.16.3.67 | 1.320 | 🔒 locked |
| ☐ | Keuken | `switch.energy_socket_17` | 5c2faf1859ba | 172.16.3.104 | 32.925 | 🔒 locked |
| ☐ | Keuken | `switch.energy_socket_18` | 5c2faf179882 | 172.16.3.50 | 39.816 | 🔒 locked |
| ☐ | Keuken | `switch.energy_socket_19` | 5c2faf1e91da | 172.16.3.246 | 1.953 | 🔒 locked |
| ☐ | Keuken | `switch.energy_socket_24` | 5c2faf17adf6 | 172.16.3.49 | 0.568 | 🔒 locked |
| ☐ | Keuken | `switch.energy_socket_25` | 5c2faf188400 | 172.16.3.5 | 1.263 | 🔒 locked |
| ☐ | Keuken | `switch.energy_socket_5` | 5c2faf184a8c | 172.16.3.69 | 1.857 | 🔒 locked |
| ☐ | Main Equipment Room | `switch.main_equipment_room_mac_mini_1` | 5c2faf18831c | 172.16.3.221 | 2.645 | switchable |
| ☐ | Schuur | `switch.energy_socket_9` | 5c2faf1e9caa | 172.16.3.174 | 0.000 | switchable |
| ☐ | Slaapkamer Jurre | `switch.energy_socket_3` | 5c2faf1e60e4 | 172.16.3.22 | 104.598 | switchable |
| ☐ | Slaapkamer Niko | `switch.energy_socket_4` | 5c2faf1e2ab2 | 172.16.3.163 | 57.807 | switchable |
| ☐ | Slaapkamer | `switch.sonos_playbar_slaapkamer` | 5c2faf1803e8 | 172.16.3.232 | 10.792 | switchable |
| ☐ | Stube | `switch.sonos_one_sl_links` | 5c2faf1e36f2 | 172.16.3.16 | 3.369 | switchable |
| ☐ | Stube | `switch.sonos_one_sl_rechts` | 5c2faf1f8a3a | 172.16.3.26 | 3.870 | switchable |
| ☐ | Trapkast | `switch.energy_socket_10` | 5c2faf1f55ec | 172.16.3.209 | 86.556 | 🔒 locked |
| ☐ | Trapkast | `switch.energy_socket_13` | 5c2faf1e926a | 172.16.3.201 | 53.701 | 🔒 locked |
| ☐ | Trapkast | `switch.energy_socket_14` | ? | OFFLINE | - | 🔒 locked |
| ☐ | Voortuin | `switch.energy_socket_20` | 5c2faf178444 | 172.16.3.172 | 2.412 | switchable |
| ☐ | Woonkamer | `switch.energy_socket_11` | 5c2faf1ee3a0 | 172.16.3.94 | 2.381 | switchable |
| ☐ | Woonkamer | `switch.energy_socket_12` | 5c2faf1e4442 | 172.16.3.15 | 8.096 | switchable |
| ☐ | Woonkamer | `switch.energy_socket_22` | 5c2faf1f9b8e | 172.16.3.234 | 9.641 | switchable |
| ☐ | Woonkamer | `switch.sonos_amp` | 5c2faf1e7d12 | 172.16.3.233 | 6.967 | switchable |
| ☐ | Woonkamer | `switch.sonos_port` | 5c2faf1f5d00 | 172.16.3.1 | 3.797 | switchable |

🔒 = `switch_lock` on at the device. These are deliberately protected loads (HA shows the
switch as `unavailable`). The lock does **not** interfere with changing Wi-Fi.

## Do these individually, verifying after each

| ☐ | Device | Why it needs care |
|---|---|---|
| ☐ | `switch.main_equipment_room_mac_mini_1` (5c2faf18831c) | Powers the Mac Mini agent host. Its switch lock is **off** — consider enabling it permanently, independent of this project. |
| ☐ | `autolader` | Meters the EV charger (~3047 kWh, 3-phase). Do it outside a charging session, then check evcc. |

## Meters — last, and only if you want them moved at all

| ☐ | Device | Note |
|---|---|---|
| ☐ | P1 Meter (172.16.3.178) | Backbone of the Energy dashboard (15 087 kWh import). Do it **alone and last**, then watch the Energy dashboard for a full day. |
| ☐ | kWh meter 3-phase (`HW-energymeter-170832`, 172.16.3.228) | Pure sensor, no relay. |
| ☐ | Water meter (`HW-watermeter-3A87C4`, 172.16.3.87) | Pure sensor, no relay. |

These carry less risk *and* less benefit than the sockets — no relay to hijack. Leaving the
metering backbone on CLIENT-VLAN is a reasonable choice.

## Loose ends

- `switch.energy_socket_14` (Trapkast) is **offline** — no serial, no IP, unavailable in HA.
  Find out whether it still exists before hunting for it.
- CMDB `hw.plug.vdhngfw_power` describes a HomeWizard plug that once powered the **UDM**.
  172.16.3.205 is no longer on the network, consistent with the CMDB's own note to move the
  UDM to direct mains. Confirm physically while you're in the Meterkast, then retire the entry.
- Most sockets are still named `energy_socket_<n>` in HA. While you are physically at each
  one, renaming it to what it actually powers costs seconds and removes a real hazard — the
  Shelly `sonos_eetkamer` mislabel nearly cost half the kitchen stereo.
