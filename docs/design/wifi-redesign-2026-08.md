# Design: Wi-Fi redesign

- **Date**: 2026-08-08
- **Author**: Atlas
- **Status**: survey + proposal — **nothing changed.** No radio settings will be touched while
  the household is away (8–31 Aug); a bad radio change is a remote lock-out.
- **Trigger**: user observation — Slaapkamer and Zolder APs are metres apart, and the Kantoor
  (directly above Slaapkamer) has poor reception.

---

## The headline: every AP is on 2.4 GHz channel 6

```
AP01 Trapkast    ng ch6   util 47%     na ch48  (+6E ch auto, 320MHz)
AP02 Stube       ng ch6   util 31%     na ch40
AP03 Slaapkamer  ng ch6   util 45%     na ch100
AP04 Zolder      ng ch6   util 41%     na ch48
AP05 Meterkast   ng ch6   util 67%     na ch36
AP06 Keuken      ng ch6   util 60%     na ch132
```

**All six APs share one 2.4 GHz channel.** They are not just interfering with the neighbours —
they are interfering with each other, and every frame any of them sends costs airtime for all
the others in range. Channel utilisation of 47–67% is the symptom.

This is almost certainly historical drift rather than a decision. `chg-2026-06-10-005` moved the
Keuken from ch1→ch6 to escape co-channel with the Trapkast; at some point everything else
converged on 6 as well.

5 GHz is fine by comparison — 48/40/100/48/36/132, only Trapkast and Zolder share a channel.

**This is the single highest-value fix, and it costs nothing but a channel plan.**

---

## The estate is 2.4 GHz-heavy, which makes the above worse

| Band | Clients |
|---|---|
| 2.4 GHz (`ng`) | **63** |
| 5 GHz (`na`) | 39 |
| 6 GHz (`6e`) | 1 |

Nearly two-thirds of the estate lives on the congested band, because most of it is IoT —
Shelly, HomeWizard, Tado, Tuya, ESP32. That is not going to change, so the 2.4 plan matters more
here than in a typical house.

Load is also very lopsided: **AP01 Trapkast carries 40 of 103 wireless clients (39%), 32 of them
on 2.4 GHz** — half the entire 2.4 GHz estate on one radio.

---

## Hardware: five of six APs are Wi-Fi 5

| AP | Model | Generation |
|---|---|---|
| AP01 Trapkast | **U7 Pro XGS** (`U7PROXGSB`) | Wi-Fi 7 — 6 GHz, 320 MHz |
| AP02 Stube | UAP-AC-Pro (`U7PG2`) | Wi-Fi 5 |
| AP03 Slaapkamer | UAP-AC-Pro (`U7PG2`) | Wi-Fi 5 |
| AP04 Zolder | UAP-AC-Pro (`U7PG2`) | Wi-Fi 5 |
| AP05 Meterkast | UAP-AC-LR (`U7LR`) | Wi-Fi 5 |
| AP06 Keuken | UAP-FlexHD (`UFLHD`) | Wi-Fi 5 wave-2 |

The three AC-Pros are a 2013-era design still on the 6.8.x firmware branch. They work, but they
have no OFDMA/BSS-colouring, which is exactly what helps in a dense 2.4 GHz environment.

---

## Your two observations, checked

### 1. Slaapkamer and Zolder are redundant — confirmed

Both UAP-AC-Pro, both on 2.4 ch6, 14 and 12 clients. Two Wi-Fi 5 radios metres apart, co-channel
on 2.4, contributing utilisation to each other for very little coverage gain.

**They are the obvious consolidation.** One of them relocated to the Kantoor solves a coverage
gap *and* removes a co-channel interferer — two problems, one move, no new hardware.

### 2. Kantoor reception — **the real devices are fine. Only 2.4 GHz is weak.**

This is the one place my first draft was heading somewhere wrong, and it is worth correcting
before it turns into a cabling project you don't need.

**Everything in the Kantoor that actually matters is well served, on 5 GHz, by AP04 Zolder:**

| Device | Signal | AP |
|---|---|---|
| Sonos Play:5 – Kantoor | **-52 dBm** | Zolder |
| tsvkantoor (ThinkSmart) | **-53 dBm** | Zolder |
| Tab-S10 van Sander | -58 dBm | Slaapkamer |
| iPad | -59 dBm | Slaapkamer |
| Sanders-iPad | -61 dBm | Zolder |
| Sonos Sub 1 – Kantoor | -64 dBm | Zolder |
| Sanders-Mini | **wired** | — |

Those are good numbers. **The office does not have a coverage problem for the things you use in
it.** What it has is a *2.4 GHz* weak spot — and the only device complaining is
`espresense-kantoor`, which you've rightly pointed out is not vitally important.

So: **an AP in the Kantoor is probably not warranted.** That removes the cabling question and a
chunk of Phase 2.

There is **no Kantoor AP** at all (the CMDB's `net.ap.kantoor` entry is stale — the live estate
is Trapkast, Stube, Slaapkamer, Zolder, Meterkast, Keuken). The office is served from below.

For completeness, `espresense-kantoor` (2.4 GHz) has been seen on three APs at three levels —
useful as a *measurement* of where 2.4 GHz coverage thins out, not as something to optimise for:

| AP | Signal |
|---|---|
| AP04 Zolder | -63 dBm |
| AP03 Slaapkamer | -70 dBm |
| AP06 Keuken | **-81 dBm** |

That spread is the signature of a client sitting at the edge of several cells with no strong
one to hold onto. It roams, and each roam is a disruption.

You were right to be suspicious of the module. ESP32 running ESPresense scans BLE continuously
on the same radio, so it is genuinely more fragile than the Shellys — its ping was 10–30× worse
than any other device even at comparable signal. Treat it as a **canary that reveals thin 2.4
GHz coverage**, not as a device whose comfort should drive the design.

### ⚠️ And one thing neither of us spotted: a min-RSSI kick threshold on Slaapkamer 2.4 GHz

```
AP03 Slaapkamer   ng   min_rssi_enabled=True   min_rssi=-80
```

**This contradicts the documented policy** in `net.wifi.min-rssi`, which says min-RSSI is kept
OFF by default and enabled only on **multi-homed APs' 5 GHz**, explicitly protecting
single-homed 2.4 GHz IoT.

`espresense-kantoor` sits on that exact radio at **-70 dBm** — only 10 dB from the kick
threshold, and it has been measured drifting to -81. **Every time it drifts past -80, the AP
deauthenticates it.** That is a plausible additional contributor to the flapping we chased,
alongside the min-rate floor you already lowered.

I have **not** changed it — it is a radio setting and you're away. But it's the first thing I'd
look at on your return, and it may be a one-line fix.

---

## Proposal

### Phase 1 — free, no hardware, biggest win

1. **Re-plan 2.4 GHz onto 1 / 6 / 11.** Six APs on one channel is the core problem.
   ⚠️ Constraint: Zigbee coexistence. Hue is on Zigbee ch11 (≈ Wi-Fi ch1) and z2m on Zigbee ch25
   (≈ upper Wi-Fi). See `24ghz-zigbee-interference` — the channel plan must be chosen *around*
   the Zigbee networks, not independently of them. Suggested starting point, to be validated:
   Trapkast 1, Keuken 6, Meterkast 11, Stube 1, and the surviving Slaapkamer/Zolder AP on 11.
2. **Remove min-RSSI from AP03's 2.4 GHz radio** — restores the documented policy and possibly
   fixes ESPresense outright.
3. **Consider disabling 2.4 GHz on one of Slaapkamer/Zolder** even before relocating it — an
   immediate reduction in co-channel contention at zero cost.

### Phase 2 — consolidate, don't relocate

4. **Retire one of Slaapkamer / Zolder rather than moving it to the Kantoor.** Since the office
   is already well covered on 5 GHz from Zolder, the gain is in *removing* a redundant
   co-channel radio, not adding one somewhere else. Keep **Zolder** on current evidence — it
   serves the Kantoor devices at -52 to -64 dBm and has the lowest weak-client count of any AP
   (0 clients ≤ -70).
5. If 2.4 GHz coverage in the office still bothers you afterwards, the cheap fix is to nudge the
   surviving AP's 2.4 GHz placement or power — not a new AP.
6. Switch capacity exists if you ever do want another AP (VDHPOESW01 12 free of 24 PoE,
   USW-24-PoE 18 free of 16 PoE, VDHPOESW02 13 free) — but **cabling is unverified remotely**,
   and on this evidence you don't need it.

### Phase 3 — hardware, optional

6. **Replace the three UAP-AC-Pros with Wi-Fi 6/7 units** as budget allows. In a 63-client 2.4
   GHz estate, OFDMA and BSS colouring are worth more than raw speed. Trapkast already shows
   what a modern AP does. Prioritise Trapkast's neighbours, since it is carrying 39% of clients
   and would benefit most from being able to hand some off.
7. Only then consider whether six APs are still needed — four modern, well-placed APs would
   likely beat six badly-planned ones, and every AP removed is one less 2.4 GHz interferer.

---

## What I deliberately did not do

- **No radio changes while you are away.** Channel, power and min-RSSI changes can drop clients
  or the AP itself; doing that with nobody home and no physical access is how you lose remote
  access to the house for three weeks.
- No AP reboots, no adoption changes, no firmware updates.

## Open questions for your return

1. ~~Is there an Ethernet drop in the Kantoor?~~ — **probably moot.** The office is well served
   on 5 GHz already; consolidation beats relocation.
2. **Budget appetite for Phase 3?** Three AC-Pro replacements is real money; the channel re-plan
   is free and may be enough.
3. **Keep six APs or consolidate to four/five?** Related to the UniFi power question — nine
   switches and six APs is a lot of always-on hardware for one house.
4. Should the Zolder AP survive, or the Slaapkamer one? Depends on where the Kantoor drop lands
   and which room genuinely needs local coverage.
