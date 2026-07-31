# Research: moving the HomeWizard devices to IOT-VLAN

- **Date**: 2026-07-31
- **Author**: Atlas (Infra OPS Manager)
- **Status**: research only — nothing changed, no change record opened
- **Question**: can the HomeWizard plugs follow the Shellys onto IOT-VLAN?
- **Prior art**: `docs/research/shelly-iot-vlan-migration-2026-07.md`, `docs/runbooks/iot-vlan-migration.md`
  (the boundary itself is already built and proven — see `chg-2026-07-30-002`)

---

## TL;DR

**Technically yes. Practically this is a completely different job from the Shellys, and the
difference is not small.**

The Shelly migration was cheap because Shelly exposes `WiFi.SetConfig` — we re-homed all 10
devices from a laptop, with `sta1` as an automatic fallback, without touching a single one.

**HomeWizard has no equivalent. There is no Wi-Fi configuration endpoint in the local API at
all.** Verified two ways: the official helpdesk says the only supported method is the
HomeWizard mobile app *plus physically holding the button on the device*, and an exhaustive
probe of our own firmware (4.09) found no such endpoint.

And the scope is **much larger than the six Sonos plugs**: there are **30 HomeWizard devices
in Home Assistant** (302 entities), 28 currently online.

So: roughly **30 × (walk to the device, hold its button, drive the app)**, across the whole
house including Zolder, Trapkast, Voortuin and Schuur. Call it 1.5–2.5 hours of physical work,
with **no remote rollback** if one misbehaves.

**My recommendation: worth doing, but not as one sitting, and not soon.** The security case is
genuinely *stronger* than it was for the Shellys — but the cost is a house walk, so it should
ride along with something else rather than be a project of its own. Details in §6.

---

## 1. Scope — it is not six devices

| Type | Count |
|---|---|
| Energy Socket (`HWE-SKT`) | **25** |
| P1 Meter | 1 |
| kWh meter 3-phase (`HW-energymeter`) | 1 |
| Water meter | 1 |
| **Online on the network** | **28** |
| **Known to Home Assistant** | **30** devices / **302** entities |

All are on `CLIENT-VLAN` via `VDHFEMFLEX`. The six "Sonos" plugs everyone thinks of
(`sonos_play_3`, `sonos_one_sl_links`, `sonos_one_sl_rechts`, `sonos_amp`,
`sonos_playbar_slaapkamer`, `sonos_port`) are **6 of 25 sockets**.

Spread by area: Woonkamer, Keuken, Stube, Slaapkamer (×3), Kantoor (×2), Trapkast (×4),
Zolder, Schuur, Voortuin, Meterkast, Main Equipment Room.

> ⚠️ HA device naming is poor here. Most sockets are literally called "Energy Socket" and
> appear as `switch.energy_socket_11`, `_12`, `_13`… Only a handful have meaningful names.
> Before any physical round, someone has to map serial → socket → what it actually powers,
> or the walk will be guesswork. This is the same class of trap as the Shelly `sonos_eetkamer`
> mislabel that nearly cost us half the kitchen stereo.

---

## 2. The decisive finding: no remote re-home

Probed live against `172.16.3.172` (Energy Socket, firmware **4.09**, `api_version: v1`):

| Endpoint | Result |
|---|---|
| `/api` | 200 — product info |
| `/api/v1/data` | 200 — measurements, incl. **`wifi_ssid` (read-only)** |
| `/api/v1/state` | 200 — `power_on`, `switch_lock`, `brightness` |
| `/api/v1/system` | 200 — `cloud_enabled` only |
| `/api/v1/identify` | 405 on GET (PUT blinks the LED) |
| `/api/v1/wifi`, `/api/v1/network`, `/api/v1/config`, `/api/v1/settings`, `/api/v1/system/wifi` | **404** |
| `/api/v2`, `/api/v2/data`, `/api/v2/system` | **404** (no v2 on this firmware) |
| `PUT /api/v1/system {"wifi_ssid": …}` | rejected — `"No parameters found in body"` |

`wifi_ssid` is telemetry, not configuration. There is no way in.

The [official helpdesk](https://helpdesk.homewizard.com/en/articles/5936435-how-do-i-change-the-wi-fi-settings-of-my-device)
confirms the only supported path:

> app → device → ⋮ → change Wi-Fi settings → *"put the device into pairing mode… by holding
> the button on the device for a few seconds until the light starts blinking"* → pick the
> 2.4 GHz network → enter the password.

**Good news buried in that:** it is **not** a factory reset. Measurement history and energy
totals survive. (A factory reset — holding the button >1 minute — *does* wipe graph history;
do not confuse the two.)

### Shelly vs HomeWizard, side by side

| | Shelly Gen3 | HomeWizard |
|---|---|---|
| Remote Wi-Fi change | ✅ `WiFi.SetConfig` | ❌ none |
| Automatic fallback network | ✅ `sta1` | ❌ none |
| Physical access needed | none | **every device** |
| Rollback | one API call | another physical round |
| Scriptable / unattended | ✅ (we did all 10) | ❌ |
| Devices | 10 | **30** |
| History preserved | n/a | ✅ (if not factory-reset) |

**The missing `sta1` equivalent is the real risk**, not the labour. With Shelly, a failed join
self-recovered to the old network and the device stayed reachable. With HomeWizard, a device
that fails to join VDHIOT has no fallback — recovery means going back to it physically. Whether
it reverts to the previous network on failure is **not documented and not verified**; assume it
does not.

---

## 3. What is already proven to work

The network side is a solved problem — the Shelly migration established all of it:

- **The boundary exists and is enforced** (`chg-2026-07-30-002`). New devices land behind it
  automatically; no firewall work needed.
- **`VDHIOT` is 2.4 GHz-only** — which happens to match HomeWizard's hard constraint
  ("only support 2.4 GHz Wi-Fi networks"). No conflict.
- **mDNS reflection CLIENT ↔ IOT works.** Confirmed HomeWizard advertises `_hwenergy._tcp`
  (`dns-sd` browse returned energysocket-1EB3A2, -1859BA, -17ADF6, -1E91DA, -179882, -1E926A,
  -1E36F2, -184A8C …). So **HA will re-discover them at their new addresses by itself**, exactly
  as it did for every Shelly.
- **`Internal → IoT` is ALLOW**, so HA keeps reaching them; and the phone app's local discovery
  will still work from CLIENT-VLAN.
- **`IoT → External` is ALLOW**, so the cloud connection keeps working. Relevant: **every**
  socket has `cloud_connection` switched **on** today.
- **Changing Wi-Fi does not touch the relay**, so nothing loses power — same as we proved ten
  times over with the Shellys.

---

## 4. The security case is *stronger* here than it was for Shelly

The Shelly argument was "10 unauthenticated relays". Here:

- **The local API has no authentication.** Our probe read `/api/v1/data` and `/api/v1/state`
  with no credential of any kind. `PUT /api/v1/state` is how HA switches these sockets — so
  anything that can route to port 80 can switch **25 mains sockets** across the house.
- **10 of them are `switch_lock: on`** — deliberately protected loads whose HA switch shows
  `unavailable` (verified 4/4 correlation; they are locked, not broken). The lock is a
  *device-side* protection, which is reassuring, but the other 15 are freely switchable.
- **Some feed things that matter**: `switch.main_equipment_room_mac_mini_1` is the **Mac Mini
  agent host's own power**, and its switch lock is **off**. `autolader` meters the EV charger
  (3047 kWh, 3-phase). The P1 Meter is the backbone of the Energy dashboard (15 087 kWh import).

So the exposure being closed is larger and more consequential than the Shelly one.

> Historical note: `hw.plug.vdhngfw_power` in the CMDB describes a HomeWizard plug that once
> powered the **UDM itself**. It is no longer on the network (172.16.3.205 absent), consistent
> with the CMDB's own instruction to move the UDM to direct mains. Worth confirming physically
> during any house walk, and retiring the CMDB entry if so.

---

## 5. Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | A device fails to join VDHIOT and is stranded (no `sta1`) | medium | medium | Do it room by room with the app in hand; a stranded device is recoverable on the spot, not later |
| 2 | Wrong socket identified, wrong load disturbed | **high if unprepared** | medium–high | Build the serial → socket → load map *before* walking. `PUT /api/v1/identify` blinks a socket's LED — use it to positively identify each one |
| 3 | Accidental factory reset (button held >1 min) wipes history | medium | medium | Hold "a few seconds", not a minute. Distinct gestures, easy to get wrong on 30 devices |
| 4 | Energy dashboard statistics disrupted | low | medium | Wi-Fi change preserves totals; HA re-discovers via mDNS. Do the P1 Meter **last**, alone, and verify the Energy dashboard before continuing |
| 5 | evcc / PV-surplus charging disturbed via `autolader` | low | medium | Migrate it outside a charging session; verify evcc afterwards |
| 6 | Mac Mini socket mishandled → agent host loses power | low | **high** | Its switch lock is OFF. Consider enabling `switch_lock` on it permanently, regardless of this project |
| 7 | Half-migrated fleet for a long period | **high** | low | Harmless — the two VLANs both reach HA. But it makes the inventory confusing; keep a checklist |

---

## 6. Options

### Option A — do nothing
25 unauthenticated switchable mains sockets stay on the main LAN with 114 other clients.
Given we just segmented the Shellys for exactly this reason, this is inconsistent — but it is
also the honest status quo and nothing is on fire.

### Option B — migrate only the 6 Sonos plugs
Tempting for symmetry with the Shelly work, but **poor value**: same physical effort per
device, and it leaves 19 sockets — including the more sensitive ones — on the main LAN. The
Sonos plugs are not the ones that matter. **Not recommended.**

### Option C — full fleet, room by room, opportunistically ← recommended
Treat it as a **house walk** rather than a project. One room at a time, whenever someone is
in that room anyway. Order:

1. **Prep (desk work, no walking)** — build the serial → socket → load map using
   `/api/v1/identify` and `/api/v1/data` power draw. This is the step that prevents the
   `sonos_eetkamer`-class mistake.
2. **Low-stakes rooms first** — Zolder, Schuur, Voortuin, Slaapkamer Jurre/Niko.
3. **Living areas** — Woonkamer, Keuken, Stube, Trapkast.
4. **Sensitive, individually, verified after each** — `autolader`, `main_equipment_room_mac_mini_1`.
5. **P1 Meter last, alone**, then verify the Energy dashboard over a full day.

Nothing here needs a maintenance window: no relay is interrupted, so unlike the Shelly batch
there is no reason to do it at midnight.

### Option D — replace rather than migrate
Not seriously proposed, but worth stating: 25 sockets is a meaningful sunk cost, and Shelly
equivalents *are* remotely manageable. If sockets fail or get replaced over time, preferring
API-manageable hardware would avoid repeating this. A consideration for future purchases, not
an action now.

---

## 7. Recommendation

**Option C, unhurried.** The segmentation value is real and larger than the Shelly case, but
the work is physical and unautomatable, so forcing it into a single session buys nothing and
raises the chance of a fumbled button press on 30 devices.

Concretely, I would:
- Do **step 1 (the mapping)** now — it is desk work, it is genuinely useful on its own, and it
  retires a real hazard (nobody currently knows which `energy_socket_17` is).
- Leave the physical rounds to be picked off room by room.
- **Not** migrate the P1 Meter until the socket fleet is done and stable.

If the answer is "not worth the walk", that is a perfectly defensible call — in which case I
would still recommend doing the mapping, and enabling `switch_lock` on the Mac Mini socket.

---

## 8. Open questions for the user

1. **Is a house walk acceptable at all?** Everything else follows from this. There is no
   remote path; if the answer is no, Option A is the honest outcome.
2. **Shall I build the serial → socket → load map now?** Desk work, no disruption, useful
   regardless of whether the migration happens.
3. **The P1 Meter, water meter and 3-phase kWh meter** — migrate them too, or leave the
   metering backbone on CLIENT-VLAN? They are pure sensors with no relay, so they carry less
   risk *and* less benefit.
4. **Should `switch_lock` be enabled on the Mac Mini socket** regardless of this project? It
   currently sits switchable, and it powers the host running all of this.

---

## Appendix — evidence

```bash
# Fleet inventory
KEY=$(cat ~/Code/homelab-migration/config/unifi-api-key)
curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/api/s/default/stat/sta \
  | jq -r '.data[]|select(.oui//""|test("homewizard";"i"))|(.name // .hostname)' \
  | sed -E 's/-[0-9A-F]{6}$//' | sort | uniq -c

# API surface + the absence of any wifi endpoint
for p in /api /api/v1/data /api/v1/state /api/v1/system \
         /api/v1/wifi /api/v1/network /api/v1/config /api/v2; do
  curl -s -o /dev/null -w "$p http=%{http_code}\n" http://172.16.3.172$p; done
curl -s -X PUT -H "Content-Type: application/json" \
  -d '{"wifi_ssid":"VDHIOT"}' http://172.16.3.172/api/v1/system

# mDNS advertisement (decides HA re-discovery after the move)
dns-sd -B _hwenergy._tcp local

# Positively identify a physical socket before touching it
curl -s -X PUT http://<ip>/api/v1/identify     # blinks its LED
```

Sources:
- [HomeWizard Helpdesk — How do I change the Wi-Fi settings of my device?](https://helpdesk.homewizard.com/en/articles/5936435-how-do-i-change-the-wi-fi-settings-of-my-device)
- [HomeWizard Helpdesk — How to install the Wi-Fi Energy Socket](https://helpdesk.homewizard.com/en/articles/5954005-how-to-install-the-wi-fi-energy-socket)
- [HomeWizard Energy Socket product page](https://www.homewizard.com/energy-socket/)
- [Zo reset je de HomeWizard Energy Socket (Duurzamerhand)](https://www.duurzamerhand.nl/blog/zo-reset-je-de-homewizard-energy-socket/) — factory-reset gesture vs Wi-Fi change
- Local API surface: probed directly against firmware 4.09 on 2026-07-31 (see appendix)
