# Runbook: Full Rack Relocation + CP Consolidation + Opportunistic OSD Swap

**Audience**: Atlas (OPS Manager, on standby at gates) coordinating Heph (cluster/Ceph), Iris (network), Hestia (Home Assistant). Operator on-site executes physical steps and pings Atlas at each gate.
**Goal**: Physically relocate the entire rack to the **Utility Room**: power down everything, move it, cold-start it. Same session: **consolidate** the 3 control-plane nodes (currently in the Office) into the relocated rack with the 3 workers. Same session: re-architect the L2 fabric around a **new UniFi Aggregation core**. Same session: **opportunistic Ceph OSD drive swap** (separate, high-risk, post-move phase).

> **Print this document.** It is designed to be executed **offline** — do not rely on connectivity mid-move. Every gate says explicitly what to WAIT FOR. Tick the checkboxes as you go.

---

## Geography — the six-area model (finalized cable plant)

This move spans **six** physical areas. The runbook uses these names throughout. The plant is a **two-hub star**: the **Utility Room core** and a **secondary distribution hub in the Trapkast**, joined by a backbone routed through the Meterkast wall hole + the Kruipkelder (underground crawlspace).

| Area | What lives there | Relation to the core |
|---|---|---|
| **Utility Room** | The **new rack**: UDM Pro Max, the new UniFi Aggregation core, USW Pro HD 24-PoE, **all 6 cluster nodes** (3 CP + 3 workers). **Also** the relocated Meterkast pegboard gear — **Hue Bridge**, **SLZB Zigbee bridge**, **AP05-Meterkast** — cabled **directly to the Pro HD 24** here. | The relocation destination + primary L2 core. |
| **Meterkast** | **ISP entry + backbone passthrough ONLY**: Ziggo modem + KPN ONT. **No switch here anymore.** | **Adjacent** to the Utility Room through a wall with a cabling HOLE — WAN handoff is a **short through-wall hop**; the backbone to the Trapkast passes through here. |
| **Trapkast** | **Old rack location — rack REMOVED.** A **2U wall bracket** holds the **remaining patch panel + the USW 24-PoE**, plus the **U7 Pro XGS** AP (AP01-Trapkast). **Secondary distribution hub**: the USW 24-PoE serves cameras / patch-panel gear and fans out to Zolder (4× CAT6) and Slaapkamer (1× CAT6); uplinks to the Aggregation over backbone fiber. | Reached from the Utility Room over the **backbone** (Meterkast wall hole + Kruipkelder). |
| **Zolder** | Attic = the "Office" / kantoor: **USW Flex 2.5G + USW 16-PoE + office PC + Sanders-Mini**. | Reached **via the Trapkast** over **4× CAT6**. (The Flex uplink is a multi-hop run patched through the Trapkast.) |
| **Slaapkamer** | An **AP** (bedroom). | Reached **via the Trapkast** over **1× CAT6**. |
| **Stube** | **AP + Camera Achtertuin (garden camera) + Sonos.** | Reached over a **NanoStation AC airMAX wireless bridge pair** — Zolder-side NanoStation ))) ((( Stube-side NanoStation. See `docs/research/nanostation-ac-management.md`. |

> **Two hubs, one backbone.** The **Utility Room core** (Aggregation + Pro HD 24) and the **Trapkast distribution hub** (USW 24-PoE) are the only switching points outside Zolder. Everything south of the Trapkast (Zolder switches, Slaapkamer AP, Stube via NanoStation) hangs off the **Trapkast USW 24-PoE**, which in turn hangs off the **backbone fiber** to the Aggregation. Blast radius is deep — see the household-impact + bring-up order.

### Cable-plant diagram (finalized)

```
   ISP feeds                 ┌──────────────── UTILITY ROOM (new rack — CORE) ────────────┐
   (Ziggo coax,              │  UDM Pro Max ── 10G SFP+ ── UniFi Aggregation (root bridge) │
    KPN fibre)               │                                   │   │                     │
        │                    │             ┌─────────────────────┘   │ Fiber#1 (1G)        │
   ┌────▼──── METERKAST ─────┤             │ LOCAL 10G fiber          │ + CAT6#1 (10G,U7)   │
   │ Ziggo modem + KPN ONT   │   ┌─────────▼──────────┐              ▼  (backbone)          │
   │ ISP ENTRY + BACKBONE    │   │ USW Pro HD 24-PoE  │       ┌──────────────┐              │
   │ PASSTHROUGH ONLY        │   │ "VDHPOESW01"(2.5G) │       │  (to Trapkast│              │
   │ (NO SWITCH)             │   │ ALL 6 NODES        │       │   backbone)  │              │
   │  ── WAN hop ──▶ UDM      │   │ + Hue Bridge       │       └──────┬───────┘              │
   │  ── backbone ──┐        │   │ + SLZB + AP05-Mtk  │              │                      │
   └────────────────┼────────┘   └────────────────────┘              │                      │
                    │ backbone: 2× fiber + 2× CAT6 (+6× legacy CAT6)  │                      │
                    │ via Meterkast wall hole + Kruipkelder           │                      │
   ┌────────────────▼──────── TRAPKAST (2U wall bracket — DIST HUB) ──▼──────────────────────┐
   │  patch panel + USW 24-PoE (1G)  ── Fiber#1 (1G SFP) ──▶ Aggregation                      │
   │  U7 Pro XGS (AP01) ── CAT6#1 (10G + PoE++) ──▶ Pro HD 24                                 │
   │  USW 24-PoE serves: cameras / patch-panel gear                                          │
   │        │ 4× CAT6 ──▶ ZOLDER          │ 1× CAT6 ──▶ SLAAPKAMER                            │
   └────────┼────────────────────────────┼──────────────────────────────────────────────────┘
            │                            │
   ┌────────▼──── ZOLDER (attic/Office) ─┴─┐        ┌──── SLAAPKAMER ────┐
   │ USW Flex 2.5G + USW 16-PoE            │        │ AP                 │
   │ office PC + Sanders-Mini              │        └────────────────────┘
   │ Flex uplink: CAT6#2 patched through   │
   │   Trapkast's 4× CAT6 ──▶ Aggregation  │
   │   (multi-hop; CAT6 not 6A → expect    │
   │    2.5G/5G, NOT a clean 10G)          │
   │                                       │
   │  NanoStation AC (Zolder side) )))     │
   └───────────────────│───────────────────┘
                       │  airMAX wireless bridge (re-link required)
                  ((( NanoStation AC (Stube side)
   ┌──────────────────▼──── STUBE ─────────────────┐
   │ AP   +   Camera Achtertuin (garden)   +  Sonos │
   └────────────────────────────────────────────────┘
```

> **Backbone (Utility Room ↔ Trapkast):** `2× fiber + 2× CAT6`, plus **6× legacy CAT6** between Meterkast and Trapkast (extra/redundant capacity), routed via the Meterkast wall hole + the Kruipkelder underground crawlspace. WAN handoff (ISP gear → UDM) is a short through-wall hop and does **not** consume the backbone budget. See Iris §1 for the full link allocation.

---

## Scope / Summary

| Aspect | This move |
|---|---|
| Physical | Rack relocates to the **Utility Room**. CP nodes leave the old location to join the workers in the relocated rack. A new UniFi Aggregation switch becomes the L2 core. The **old rack (Trapkast) is removed** — a 2U wall bracket there becomes a **secondary distribution hub** (USW 24-PoE + patch panel + U7 Pro XGS). |
| Network addressing | **UNCHANGED** — same subnet (172.16.2.0/23), same IPs, same untagged CLIENT-VLAN. What changes is the **L2 fabric** (new Aggregation core, CP re-home onto Pro HD 24, two-hub backbone to the Trapkast) and physical placement. |
| Target downtime | A few hours, same-day. |
| Execution model | Operator on-site does physical work; pings Atlas at each 📞 gate; Atlas confirms domain health before the next step. |
| Domains | Cluster/Ceph (Heph), Network (Iris), Home Assistant (Hestia). |
| Extra phase | Opportunistic Ceph OSD drive swap — **separate HIGH-RISK phase AFTER the move is fully green**, with its own user approval + Themis QA. |

This is a **synthesis** runbook. The per-domain command blocks below are reproduced from each engineer's section. The MASTER TIMELINE (below the confirm-before section) is the single ordered flow; per-domain sections hold the detail.

---

# ⚠️ CONFIRM BEFORE MOVE DAY

> **These are BLOCKERS.** They are physical unknowns the engineers flagged that cannot be resolved from the keyboard. Resolve every OPEN one — on-site, with eyes on the hardware — **before** committing to a move date. RESOLVED items are recorded so the cabling plan and bring-up order stay traceable.

## ✅ RESOLVED (recorded for traceability)

| # | Item | Resolution |
|---|---|---|
| R1 | **Switch layout / which switches go where** | Pro HD 24 relocates to the **Utility Room** rack; CP nodes re-home onto the Pro HD 24 (Iris §6). **USW 24-PoE → Trapkast** (2U wall bracket + patch panel, secondary dist hub). **USW Flex 2.5G + USW 16-PoE → Zolder** (attic/office). No switch in the Meterkast. |
| R2 | **AP06-Keuken placement** | PoE AP (Keuken). PoE from the Trapkast USW 24-PoE chain. |
| R3 | **Old-location uplink media** | **Fiber** (Trapkast USW 24-PoE SFP → Aggregation), **not** CAT6. Backbone routed via Meterkast wall hole + Kruipkelder. |
| R4 | **Office (Zolder) workstations** | **STAY at the Zolder** (PC + Sanders-Mini) on the **USW Flex 2.5G + USW 16-PoE** which are also at the Zolder. The Flex uplinks back to the Aggregation over CAT6 patched through the Trapkast. |
| R5 | **WAN port mapping + ONT/modem** | Ziggo modem + KPN ONT are in the **Meterkast** (ISP entry + passthrough only), adjacent to the UDM via the wall hole. Both WANs stay on their **CURRENT UDM WAN ports — no reassignment**. PPPoE/DHCP re-train on power-up. |
| R6 | **SLZB / Hue Bridge / AP05-Meterkast power+home** | **Relocate to the Utility Room**, cabled **directly to the Pro HD 24**, powered there (Hestia §3). They come up **WITH the rack / Pro HD 24** — no longer dependent on a Meterkast pegboard. |

## ☐ OPEN — confirm on-site before move day

### ☐ Aggregation transceiver / module count

- [ ] Tally **SFP+ / RJ45 modules** for the LOCAL Utility-Room links: UDM↔Agg, ProHD↔Agg (2× 10G LOCAL).
- [ ] **SFP+→10G-RJ45 transceiver** for the **Zolder Flex** backbone run if landed on copper at the Aggregation (CAT6#2; most UniFi Aggregations are SFP+-only — a copper run needs an SFP+-to-RJ45 module). Note this link is **CAT6 not 6A** and multi-hop — see the Flex-speed item below.
- [ ] **1G SFP transceiver + LC fiber** for the **Trapkast** USW 24-PoE backbone fiber uplink (Fiber#1) into an Aggregation SFP+ port (UniFi Aggregation ports are 1/10G — a 1G SFP is accepted).
- [ ] Buy spares of each.

### ☐ Zolder Flex link negotiates speed (CAT6, multi-hop — do NOT promise 10G)

- [ ] After bring-up, **verify the negotiated speed** on the Flex↔Aggregation link (CAT6#2, patched through the Trapkast's 4× CAT6). It is **CAT6 not 6A** and **multi-hop** — **10G is optimistic; expect it to negotiate 2.5G or 5G**. The Flex only serves the Zolder office (PC + Mini), so a fallback is **non-critical** — but **verify the actual negotiated speed and flag if it is not 10G. Do not promise 10G.**
- [ ] Physically trace the Zolder→Trapkast→Utility Room patch path before move day (multi-hop over the Trapkast bracket).

### ☐ Synology NAS (172.16.2.246) — physical location?

- [ ] Confirm whether the NAS is in the moving rack (Utility Room) or stays put. It is needed early in bring-up (CP nodes / Ceph / HA media). If it relocates, it powers up between network and CP nodes (see MASTER TIMELINE step B2).

### ☐ UDM static-dns table export

- [ ] **OPERATOR-VERIFY:** export / screenshot the UDM static-dns table (per-host `*.bluejungle.net` A records) before the move and re-verify after. Could not be read from the sandbox.

### ☐ PoE budgets (Trapkast USW 24-PoE + Zolder switches)

- [ ] Confirm the **Trapkast USW 24-PoE PoE budget** covers its loads: **cameras + AP06-Keuken** (PoE off this chain) + any patch-panel PoE gear.
- [ ] Confirm the **Zolder USW 16-PoE** PoE budget (now at the Zolder with the Flex, NOT the Meterkast) covers its loads.
- [ ] Note: **AP05-Meterkast + Hue Bridge + SLZB** are now on the **Utility Room Pro HD 24** — fold their PoE/power into the Pro HD 24 budget, not the Trapkast chain.

### ☐ U7 Pro XGS PoE++ budget on the Pro HD 24

- [ ] Confirm the **Pro HD 24 PoE++ (802.3bt)** budget covers the **U7 Pro XGS** (at the Trapkast, on the backbone CAT6#1 → Pro HD 24 10G port) (Iris §8).

### ☐ NanoStation AC airMAX bridge pair re-links (Stube)

- [ ] After bring-up, confirm the **NanoStation AC pair re-linked** (Zolder side )))  ((( Stube side) over airMAX — it must re-establish before the Stube comes back.
- [ ] **Verify the Stube devices recovered**: **Stube AP, Camera Achtertuin (garden camera), Stube Sonos** — these are the LAST things on the recovery chain. See `docs/research/nanostation-ac-management.md`.

### ☐ KPN ONT relocation vs inter-location handoff

- [ ] The ONT stays in the **Meterkast** (ISP entry + passthrough only), adjacent to the UDM, so its handoff is a **short through-wall hop** to the UDM WAN ports (RESOLVED in the normal case). **Confirm** the ONT remains a short hop and is not carried elsewhere. If for any reason it needs a longer carry, the **1 spare backbone fiber** (with an SFP/transceiver) is available. Flag as a move-day confirm.

---

# MASTER TIMELINE (single ordered flow)

> This is the canonical order. Each step cross-references the detailed per-domain section. **Do not duplicate commands here — go to the referenced section for exact commands.** Tick as you go; honor every 📞 Atlas-gate.

## Phase A — SHUTDOWN (in this order)

- [ ] **A1. HA safe-state.** Pause the 4 automations; record they were ON. → *Hestia §2*
- [ ] **A2. Cluster pre-shutdown readiness gate.** → *Heph §1*  📞 **GATE 1**
- [ ] **A3. Ceph quiesce flags** (noout/norebalance/nobackfill/norecover/nodown). → *Heph §2*
- [ ] **A4. Graceful cluster shutdown — WORKERS first, then CP last.** → *Heph §3*
- [ ] **A5. Network pre-move capture** (UniFi backup, screenshot port maps, photograph+label cabling, record dual-WAN, snapshot node IPs/MACs, export static-dns). → *Iris §3*
- [ ] **A6. Power network LAST** (Stube/Zolder/Slaapkamer edge → Trapkast USW 24-PoE → Aggregation → UDM). → *Iris §4 / Heph §3 note*

> Order rationale: HA quiesces so automations don't fight a dying cluster → cluster drains top-down (workers before CP so etcd quorum holds longest) → network dies last so management/SSH/Talos paths stay alive until the nodes are down.

## Phase B — BRING-UP (cold start, in this order)

> The network bring-up is now an **adopt-core-first** sequence: the new Aggregation, then Pro HD 24, then the **Trapkast USW 24-PoE** (backbone), then the **Zolder switches (Flex / USW 16-PoE)**, then the **Zolder-side NanoStation → Stube** must each be adopted/trunked and verified **one uplink at a time (loop-safe)** BEFORE any node powers on. The downstream recovery chain is **Utility Room core → backbone → Trapkast USW 24-PoE → Zolder switches → Zolder NanoStation → Stube** — so the **Stube (AP + Camera Achtertuin + Sonos) recovers LAST**. SLZB + Hue Bridge now come up **with the rack / Pro HD 24** (Utility Room), so they are available as soon as the core is up; SLZB LAN link must be confirmed before z2m recovery.

- [ ] **B1a. Power UDM + adopt/verify the Aggregation core** (UDM↔Agg 10G LOCAL link only, then bring up Pro HD 24, then the **Trapkast USW 24-PoE backbone fiber + U7 run**, then the **Zolder Flex / USW 16-PoE** over the Trapkast CAT6, then the **Slaapkamer AP** and the **NanoStation AC pair (Zolder ))) ((( Stube)** — **one uplink at a time**, loop-safe). Confirm the **NanoStation pair re-links** and the Stube edge comes up last. → *Iris §2 + §5*  📞 **GATE A (network core + backbone + edge healthy, loop-free)**
- [ ] **B1b. Confirm SLZB has power + LAN link on the Pro HD 24** (Utility Room — comes up with the rack core). → *Hestia §3*
- [ ] **B2. Power NAS** (Synology 172.16.2.246). → *Heph §4.0*
- [ ] **B3. Power CP nodes; verify etcd quorum.** → *Heph §4.1*
- [ ] **B4. Power workers.** → *Heph §4.2*
- [ ] **B5. Addressing sanity** (worker DHCP reservations restored, master statics, VIP) + CP re-home check (masters on Pro HD 24, not Flex). → *Iris §6 / §7*
- [ ] **B6. Ceph mons/OSDs come up.** → *Heph §4.3*  📞 **GATE 2 (before unsetting flags)**
- [ ] **B7. Unset Ceph flags.** → *Heph §4.4*
- [ ] **B8. Wait for `active+clean`.** → *Heph §4.5*  📞 **GATE 3 (Ceph healthy)**
- [ ] **B9. Flux reconcile.** → *Heph §4.6*
- [ ] **B10. Critical pods Ready.** → *Heph §4.7*
- [ ] **B11. Network post-bring-up verification** (internal DNS, external-dns on UDM, cloudflared, internet egress, AP/device re-adopt incl. **AP05-Meterkast (now on Pro HD 24), U7 Pro XGS, AP06-Keuken, Slaapkamer AP, Stube AP, Camera Achtertuin**, and **confirm the NanoStation AC pair re-linked**). → *Iris §7*  📞 **GATE B (full network path, incl. Stube edge)**
- [ ] **B12. HA + integrations recover** (HA RUNNING, trusted_proxies, z2m **after SLZB up**, z-wave, Hue **(comes up with the rack / Pro HD 24)**/HomeWizard/Sonos incl. **Stube Sonos + Camera Achtertuin after the NanoStation pair re-links**). → *Hestia §4.1–4.7*
- [ ] **B13. Kiosks render** (Pixel tablet, ThinkSmartView — render proof). → *Hestia §4*  📞 **GATE C (kiosks render)**
- [ ] **B14. Verify unavailable count near baseline (~286, NOT 739–761).** → *Hestia §4*
- [ ] **B15. RE-ENABLE the 4 paused automations.** → *Hestia §4*  📞 **GATE D (household restored)**

> Order rationale: the **network core adopts first** (Aggregation → Pro HD 24 → Trapkast USW 24-PoE → Zolder Flex / USW 16-PoE → Zolder NanoStation → Stube, one uplink at a time so a transient double-path can't storm the CLIENT-VLAN) before any node finds an address → the **Stube edge recovers LAST** behind the backbone + the NanoStation re-link → SLZB/Hue come up with the rack (Pro HD 24); SLZB link must precede z2m → NAS before nodes (some pods mount it) → CP before workers (etcd quorum must form first) → Ceph must reach `active+clean` before Flux drives workloads onto it → HA last because it depends on the cluster, DNS, and the Zigbee/Z-Wave coordinators being powered.

## Phase C — OPPORTUNISTIC OSD DRIVE SWAP (separate, HIGH-RISK, post-move)

> **DO NOT START until the move is fully GREEN** (B15 done, full `active+clean` on the *existing* drives). This phase needs its **own user approval + Themis QA**, separate from the move. → *Heph §5* + cross-ref `docs/runbooks/ceph-osd-disk-replacement.md`

- [ ] **C0.** Confirm full `active+clean` on existing drives. 📞 **GATE 4 (separate user approval to begin OSD swap)**
- [ ] **C1.** Rolling swap, one OSD at a time: `osd.2`/node03 → `osd.1`/node01 → `osd.0`. → *Heph §5*
- [ ] **C2.** Return to `active+clean` between each drive. Never more than one OSD absent.

---

# 📞 CONSOLIDATED ATLAS-GATE TIMELINE

> Single deduped list. Operator pings Atlas at each gate; Atlas confirms the named condition before the operator proceeds. (Gates that appeared in both Iris and Heph are merged — e.g. "network healthy before powering nodes".)

| # | When (timeline step) | WAIT FOR — Atlas confirms | Source gates merged |
|---|---|---|---|
| **GATE 1** | After A2, before A3/A4 shutdown | Cluster pre-shutdown readiness PASS — Ceph `HEALTH_OK`/`active+clean`, etcd healthy, no in-flight reconciles | Heph §1/§6 |
| **GATE A** | After B1a, before B1b/B2/B3 | **Network core + backbone + edge healthy, loop-free, BEFORE any node powers on** — UDM up, both/required WAN(s) up, Aggregation + Pro HD 24 + Trapkast USW 24-PoE (backbone fiber) + Zolder Flex/16-PoE + Slaapkamer + U7 uplinks all UP (one uplink per access switch), **NanoStation AC pair re-linked (Stube reachable)**, no L2 loop, DHCP serving, internal + external DNS resolving | Iris §5/§10 (A) **+** Heph "network before nodes" |
| **GATE 2** | After B6, before B7 | Mons in quorum, OSDs `up`, before flags are unset | Heph §4.3/§6 |
| **GATE 3** | After B8, before B9 | Ceph back to `active+clean`, flags cleared | Heph §4.5/§6 |
| **GATE B** | After B11, before B12 | Full network path verified — internal `*.bluejungle.net`, external-dns records on UDM, cloudflared, internet egress, all APs/devices re-adopted (AP05-Meterkast [now on Pro HD 24] + U7 Pro XGS + AP06-Keuken + Slaapkamer AP + Stube AP + Camera Achtertuin) and the **NanoStation AC pair re-linked** | Iris §7/§10 (B) |
| **GATE C** | After B13 | Kiosks render (Pixel tablet + ThinkSmartView) with render proof | Hestia §5 (C) |
| **GATE D** | After B15 | Household restored — HA RUNNING, integrations alive, unavailable near baseline, 4 automations re-enabled | Hestia §5 (D) |
| **GATE 4** | Before C1 | **Separate user approval + Themis QA** to begin the OSD swap; existing drives at `active+clean` | Heph §6 (OSD) |

---

# PER-DOMAIN DETAIL

> The sections below preserve each engineer's content, command blocks, and honest "could NOT verify live" caveats. Refer here for exact commands; the MASTER TIMELINE is the order of operations.

---

## CLUSTER / CEPH (Heph)

> Live-state baseline captured from the cluster. **Honest caveat:** the etcd member list below was read from a sandbox context and could NOT be fully verified live — re-verify member health at B3 before trusting quorum.

### Heph — Live-state baseline

| Item | Value |
|---|---|
| Control plane | vdhclu01master01/02/03 @ 172.16.2.84/85/86 |
| Workers | vdhclu01node01/02/03 @ 172.16.2.81/82/83 |
| VIP | 172.16.2.240 |
| Talos / k8s | v1.12.6 / v1.35.3 |
| Ceph | v19.2.1 (squid), Rook v1.16.5; 3 OSDs on `/dev/sda` per worker; `size:3`, `failureDomain:host` |
| Boot disk (workers) | NVMe by serial — node01 `2244E6801787`, node02 `2244E6801A88`, node03 `2244E6801A85` |

### Heph §1 — Pre-shutdown readiness gate  📞 GATE 1

```bash
# Ceph healthy and fully clean BEFORE we touch anything
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail
# Expect: HEALTH_OK (or only the known SSD-wear WARN), all PGs active+clean

# etcd quorum healthy
talosctl -n 172.16.2.84,172.16.2.85,172.16.2.86 etcd status

# No Flux reconciles mid-flight
flux get kustomizations -A
flux get helmreleases -A
```

> WAIT FOR Atlas (GATE 1): confirm `active+clean`, etcd healthy, no in-flight reconciles before proceeding to flags + shutdown.

### Heph §2 — Ceph quiesce flags

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set norebalance
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set nobackfill
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set norecover
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set nodown
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status   # confirm flags listed
```

**Rationale:** these flags tell Ceph the OSDs are *expected* to disappear (planned outage) so it does NOT start rebalancing/backfilling/marking-out when the whole cluster powers off together. `nodown` keeps OSDs from being marked down prematurely.

> **No `pause` note:** we deliberately do **NOT** set `ceph osd pause` / pause I/O via the cluster — a full graceful host shutdown handles client I/O quiesce, and `pause` would complicate the cold bring-up. The five flags above are sufficient and reversible.

### Heph §3 — Graceful shutdown (workers first, CP last)

```bash
# Workers FIRST
talosctl -n 172.16.2.81 shutdown
talosctl -n 172.16.2.82 shutdown
talosctl -n 172.16.2.83 shutdown

# Control plane LAST
talosctl -n 172.16.2.84 shutdown
talosctl -n 172.16.2.85 shutdown
talosctl -n 172.16.2.86 shutdown
```

**Why CP last:** the control plane runs etcd. Keeping CP nodes up while workers drain preserves etcd quorum and the API server for as long as possible, so the shutdown stays orderly. Once workers are down, CP nodes go down — and **network powers down only AFTER all nodes are confirmed off** (see Iris §4 / A6).

### Heph §4 — Cold bring-up

**§4.0 — NAS first** (if in the moving rack / Utility Room): power Synology (172.16.2.246), wait for it to be reachable. Several pods mount NFS from it.

**§4.1 — CP nodes / etcd quorum**

```bash
# Power on master01/02/03, then:
talosctl -n 172.16.2.84,172.16.2.85,172.16.2.86 etcd status
# Wait for all 3 members healthy, leader elected
kubectl get nodes   # CP nodes Ready, via VIP 172.16.2.240
```

**§4.2 — Workers**

```bash
# Power on node01/02/03, then:
kubectl get nodes -o wide   # all 6 Ready
```

**§4.3 — Ceph mons/OSDs**  📞 GATE 2

```bash
kubectl -n rook-ceph get pods | grep -E 'mon|osd'
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
# Expect mons in quorum, 3 OSDs up — BEFORE unsetting flags
```

> WAIT FOR Atlas (GATE 2): mons in quorum + OSDs up before unsetting.

**§4.4 — Atlas gate + unset flags**

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset nodown
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset norecover
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset nobackfill
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset norebalance
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
```

**§4.5 — active+clean**  📞 GATE 3

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
# Wait for all PGs active+clean (only known SSD-wear WARN acceptable)
```

> WAIT FOR Atlas (GATE 3): `active+clean` before driving Flux.

**§4.6 — Flux reconcile**

```bash
flux reconcile source git flux-system
flux get kustomizations -A
flux get helmreleases -A
```

**§4.7 — Critical pods**

```bash
kubectl get pods -A | grep -vE 'Running|Completed'
# Confirm cert-manager, external-dns, cloudflared, gateway, database, home-automation healthy
```

### Heph §5 — OSD swap SAFE sequence (POST-MOVE, HIGH-RISK)

> **Cross-reference:** full procedure in `docs/runbooks/ceph-osd-disk-replacement.md`. **Do not duplicate it.** Needs its own user approval + Themis QA (GATE 4).

- **Why not during the cold move:** the move already stresses redundancy (whole cluster down). Doing a disk swap in the same window would mean an OSD is *intentionally* absent while the cluster is still settling — too many simultaneous failure modes. The swap runs **only after** full `active+clean` on the existing drives.
- **Order:** `osd.2` / node03 (worst wear) → `osd.1` / node01 → `osd.0` (spare). One at a time; return to `active+clean` between each.
- **Auto-provision behavior:** a new blank disk enumerating as `/dev/sda` is auto-discovered by the Rook operator and a prepare job runs — no Git change needed (see ceph runbook §0 device-discovery finding).
- **node02 hostpath caveat:** node02 also backs some OpenEBS hostpath volumes — account for this when scheduling (see ceph runbook).
- **active+clean gate:** mandatory between every drive. Never allow two OSDs absent (`size:3`, `failureDomain:host` ⇒ only ONE OSD may be absent).

### Heph §6 — Atlas gates (cluster)

| Gate | Condition |
|---|---|
| Pre-shutdown (GATE 1) | `active+clean`, etcd healthy, no in-flight reconciles |
| Pre-unset (GATE 2) | mons in quorum, OSDs up |
| Post-unset (GATE 3) | `active+clean` restored |
| OSD swap (GATE 4) | separate user approval + Themis QA; existing drives `active+clean` |

### Heph §7 — Rollback / abort

If bring-up stalls:

- **etcd won't form quorum** → do NOT force; power-cycle CP nodes one at a time, re-check `etcd status`. Escalate to Atlas before any `etcd` member removal.
- **Ceph won't reach active+clean** → leave flags as needed, investigate per-OSD; do NOT proceed to Flux until clean.

**NEVER DO:**
- ❌ Never `etcd member remove` or rebuild etcd to "fix" a slow bring-up.
- ❌ Never wipe/zap an OSD disk to force recovery.
- ❌ Never start the OSD swap (Phase C) without GATE 4 approval.
- ❌ Never proceed to the next bring-up step before its gate clears.

### Heph — referenced files

- `kubernetes/main/talos/talconfig.yaml`
- `kubernetes/main/apps/rook-ceph/rook-ceph-cluster/app/helmrelease.yaml`
- `docs/runbooks/ceph-osd-disk-replacement.md`

---

## NETWORK (Iris) — revised for confirmed re-architecture

> **Major change from v1:** This is no longer a like-for-like move. The confirmed target introduces a **new UniFi Aggregation switch (10G SFP+) as the L2 aggregation core** in the **Utility Room**, the **CP nodes re-home onto the Pro HD 24**, and the plant becomes a **two-hub star**: the Utility Room core + a **secondary distribution hub in the Trapkast** (the relocated USW 24-PoE on a 2U wall bracket + patch panel + U7 Pro XGS), joined by a **backbone** routed through the Meterkast wall hole + the Kruipkelder. The **Flex 2.5G + USW 16-PoE live at the Zolder** (attic/office). The **Stube** hangs off a **NanoStation AC airMAX bridge pair** from the Zolder. Addressing is still **UNCHANGED** (same 172.16.2.0/23, same IPs, same untagged CLIENT-VLAN). What changes is the L2 fabric and physical placement.
>
> **Controller:** UniFi Network **10.4.57**. **READ-ONLY design task** — nothing was written to the live controller.

---

### Iris §0 — Confirmed target topology

```
   ISP feeds          ┌──────────────── UTILITY ROOM (new rack — CORE) ─────────────┐
   (Ziggo coax,       │   ┌──────────────────────┐                                  │
    KPN fibre)        │   │   UDM Pro Max        │  gateway / core router            │
        │            │   │   172.16.2.1         │  WAN1 Ziggo / WAN2 KPN (UNCHANGED)│
   ┌────▼─ METERKAST ─┤   └──────────┬───────────┘                                  │
   │ Ziggo modem      │              │ 10G SFP+ (LOCAL DAC/fiber)                   │
   │ KPN ONT          │   ┌──────────▼─────────────────────────┐                   │
   │ ISP ENTRY +      │   │  UniFi Aggregation (10G SFP+)       │  L2 agg CORE      │
   │ BACKBONE PASS-   │   │  *** ADOPT + CONFIG FIRST ***       │  (root bridge)    │
   │ THROUGH ONLY     │   └───┬───────────────────┬────────────┘                   │
   │ (NO SWITCH)      │       │10G fiber LOCAL     │ Fiber#1 (1G) + CAT6#1 (U7)     │
   │ ── WAN hop ──▶UDM │  ┌────▼──────────────┐    │ + CAT6#2 (Flex, multihop)      │
   │ ── backbone ─┐   │  │ USW Pro HD 24-PoE │    │ (backbone via wall hole +      │
   └──────────────┼───┘  │ "VDHPOESW01"(2.5G)│    │  Kruipkelder)                  │
                  │      │ ALL 6 NODES       │    │                                 │
   backbone:      │      │ + Hue + SLZB      │    │                                 │
   2× fiber +     │      │ + AP05-Meterkast  │    │                                 │
   2× CAT6        │      └───────────────────┘    │                                 │
   (+6× legacy    └───────────────────────────────┼─────────────────────────────────┘
    CAT6 Mtk↔Trap)                                │
   ┌──────────────────── TRAPKAST (2U bracket — DIST HUB) ──▼───────────────────────┐
   │ patch panel + USW 24-PoE (1G) ── Fiber#1 1G SFP ──▶ Aggregation                 │
   │ U7 Pro XGS (AP01) ── CAT6#1 10G+PoE++ ──▶ Pro HD 24                             │
   │ USW 24-PoE serves cameras / patch-panel gear                                   │
   │   │ 4× CAT6 ──▶ ZOLDER (Flex uplink = CAT6#2 patched through here)             │
   │   │ 1× CAT6 ──▶ SLAAPKAMER AP                                                  │
   └───┼────────────────────────────────────────────────────────────────────────────┘
       │
   ┌───▼──── ZOLDER (attic/Office) ────────┐        ┌──── SLAAPKAMER ────┐
   │ USW Flex 2.5G + USW 16-PoE            │        │ AP                 │
   │ office PC + Sanders-Mini              │        └────────────────────┘
   │ NanoStation AC (Zolder side) )))      │
   └──────────────│─────────────────────────┘
                  │ airMAX wireless bridge (re-link required)
             ((( NanoStation AC (Stube side)
   ┌──────────────▼──── STUBE ─────────────┐
   │ AP + Camera Achtertuin (garden) + Sonos│
   └────────────────────────────────────────┘
```

**Device inventory**

| Device | Role | Location | Uplink |
|---|---|---|---|
| UDM Pro Max (`172.16.2.1`) | Gateway / core router | Utility Room | WAN1 Ziggo + WAN2 KPN (ports UNCHANGED; ISP gear in Meterkast via wall hole); downlink 10G SFP+ → Aggregation (LOCAL) |
| **UniFi Aggregation (10G SFP+)** | **NEW L2 aggregation core / root bridge** | Utility Room | Up to UDM 10G; down to Pro HD 24 (LOCAL) + Trapkast backbone (fiber + CAT6) |
| USW Pro HD 24-PoE "VDHPOESW01" | Access — **all 6 cluster nodes** @2.5G + **Hue Bridge + SLZB + AP05-Meterkast** | Utility Room (relocates) | 10G fiber → Aggregation (LOCAL) |
| **USW 24-PoE (1G)** | **Secondary dist hub** — patch panel / cameras / **AP06-Keuken**; fans out to Zolder + Slaapkamer | **Trapkast** (2U wall bracket + patch panel) | **Fiber#1: 1G SFP → backbone fiber → Aggregation** |
| **USW Flex 2.5G 8 "VDHGSW01"** | Access — Zolder office workstations @2.5G | **Zolder** (attic/office) | **CAT6#2 → patched through Trapkast 4× CAT6 → Aggregation (multi-hop; CAT6 not 6A → expect 2.5G/5G, NOT 10G)** |
| **USW 16-PoE** | Access — extra ports (Zolder) | **Zolder** (with the Flex) | off the Zolder Flex / Trapkast CAT6 fan-out |
| U7 Pro XGS (AP01-Trapkast) | Wi-Fi 7 AP | Trapkast | **CAT6#1 dedicated → Pro HD 24 10G PoE++ (bt) port** (backbone) |
| AP06-Keuken | Wi-Fi AP | (Keuken; PoE from Trapkast chain) | PoE from Trapkast USW 24-PoE |
| AP05-Meterkast | Wi-Fi AP | **Utility Room** (relocated onto Pro HD 24) | direct to Pro HD 24 |
| Hue Bridge | Zigbee/Hue hub | **Utility Room** (relocated onto Pro HD 24) | direct to Pro HD 24 |
| SLZB Zigbee bridge | Zigbee coordinator | **Utility Room** (relocated onto Pro HD 24) | direct to Pro HD 24 (power + LAN) |
| Slaapkamer AP | Wi-Fi AP | Slaapkamer | **1× CAT6 → Trapkast USW 24-PoE** |
| **NanoStation AC pair** | **airMAX wireless bridge** (Zolder ))) ((( Stube) | Zolder ↔ Stube | Zolder side off the Zolder switch; **must re-link** |
| Stube AP | Wi-Fi AP | Stube | via NanoStation bridge |
| Camera Achtertuin | Garden camera | Stube | via NanoStation bridge |
| Stube Sonos | Audio | Stube | via NanoStation bridge |

---

### Iris §1 — Link allocation: LOCAL / through-wall / backbone

**Backbone media (Utility Room ↔ Trapkast, routed via Meterkast wall hole + Kruipkelder):** `2× fiber` + `2× CAT6`, plus **6× legacy CAT6** between Meterkast and Trapkast (extra/redundant capacity).

**Key distinction:**
- **LOCAL** (inside the Utility Room rack): UDM↔Agg, ProHD↔Agg — short patch cables / DACs / short fibers. The relocated Hue Bridge / SLZB / AP05-Meterkast are also LOCAL (direct to Pro HD 24). Do **not** count against the backbone budget.
- **Through-wall (Meterkast↔Utility Room):** short WAN hop through the wall hole (ISP gear → UDM ports). Short, not backbone.
- **Backbone (Utility Room↔Trapkast):** the 2× fiber + 2× CAT6 carrying the Trapkast distribution hub + everything south of it (Zolder, Slaapkamer, Stube).

**LOCAL links (Utility Room rack):**

| Link | Media | Speed |
|---|---|---|
| UDM Pro Max ↔ Aggregation | SFP+ DAC (short) or LC fiber | 10G |
| Pro HD 24 ↔ Aggregation | LC fiber (or DAC) | 10G |

**Backbone cable budget (2 fiber + 2 CAT6):**

| # | Media | Assigned to | Speed | Notes |
|---|---|---|---|---|
| 1 | **Fiber #1** | Trapkast USW 24-PoE → Aggregation | 1G SFP into SFP+ port | Cameras + AP06-Keuken + patch-panel + the whole Zolder/Slaapkamer/Stube fan-out hangs behind this. 1G chosen; needs 1G SFP + LC fiber. |
| 2 | **CAT6 #1** | Trapkast U7 Pro XGS → Pro HD 24 | 10G + PoE++ (bt) | Dedicated AP run; PoE from Pro HD 24. |
| 3 | **CAT6 #2** | Zolder USW Flex 2.5G → Aggregation (multi-hop, patched through Trapkast's 4× CAT6) | **2.5G/5G expected — NOT a clean 10G** | **CAT6 not 6A** + multi-hop → 10G is optimistic. Office-only, non-critical. **Verify negotiated speed; flag if not 10G; do not promise 10G** (§8). |
| 4 | **Fiber #2** | **SPARE** | 10G | Reserve (stays dark — redundancy/ring design reviewed separately). |

> **Shortfall check: NONE.** The required backbone runs (Trapkast 1G fiber + U7 + Zolder Flex) fit in **3 of 4** backbone cables, leaving **1 fiber spare**. The **6× legacy CAT6** (Meterkast↔Trapkast) is extra capacity available if a future link is needed. **Copper backbone budget is FULL** (both CAT6 used by U7 + Flex) — no spare new copper, but legacy CAT6 remains.

---

### Iris §2 — New-hardware adoption + config order (BEFORE any node reconnects)

> The Aggregation switch is **brand new** and the Pro HD 24 / Trapkast USW 24-PoE / Zolder switches are **re-homed** behind it. They must be **adopted, trunked and verified** before a single cluster node is patched in. **Adopt the core first, then the backbone, then the edge.**

1. **Cable UDM ↔ Aggregation only** (single 10G LOCAL link). Power UDM, then Aggregation.
2. **Adopt the Aggregation switch.** Confirm **Connected**; let it firmware-upgrade with nothing downstream.
3. **Set Aggregation port profiles:** UDM port = **trunk/All-VLAN**; ports to Pro HD 24 + the Trapkast backbone (Fiber#1 + CAT6#2/Flex) = **trunk/All-VLAN**.
4. **Cable + adopt Pro HD 24** (10G fiber LOCAL). Confirm adopted, uplink trunk, link UP at 10G. The relocated **Hue Bridge / SLZB / AP05-Meterkast** are direct on this switch (LOCAL).
5. **Cable the backbone to the Trapkast + adopt the USW 24-PoE** (Fiber#1, 1G SFP) and the **U7 Pro XGS** (CAT6#1). Confirm the secondary dist hub adopted + uplink UP.
6. **Cable + adopt the Zolder Flex 2.5G** (CAT6#2 patched through the Trapkast 4× CAT6) and the **Zolder USW 16-PoE**. Confirm adopted; **verify the negotiated speed** (§8 — CAT6 multi-hop, expect 2.5G/5G, NOT 10G).
7. **Cable the Slaapkamer AP** (1× CAT6 from the Trapkast 24-PoE) and bring up the **NanoStation AC pair** (Zolder side ))) ((( Stube side). **Confirm the bridge re-links** and the Stube edge (AP + Camera Achtertuin + Sonos) comes up — this is LAST.
8. **Set node port profiles on Pro HD 24** = **untagged CLIENT-VLAN** for the 6 node ports + the relocated-device ports; leave node ports empty for now.
9. **Only after all uplinks UP, the NanoStation pair re-linked, and fabric loop-free → node power-on (Phase B).**

**Loop-avoidance / STP (critical):**
- **Patch ONE uplink at a time**, confirm UP before the next. Do not pre-cable all switch-to-switch links then power on — a transient double-path storms the CLIENT-VLAN (and household internet).
- Confirm **RSTP enabled** (UniFi default on). Aggregation = intended **root bridge** (lowest STP priority).
- **No redundant ring during the move.** Star topology only (Agg = hub). The spare fiber stays **dark** until a redundancy design is reviewed separately.
- After uplinks up: controller topology view should show **exactly one** uplink per access switch.

| Port type | Profile |
|---|---|
| Node ports (Pro HD 24) | **untagged CLIENT-VLAN** (172.16.2.0/23) |
| AP port U7 (Pro HD 24) | untagged CLIENT-VLAN + PoE++ (bt) |
| Inter-switch uplinks | **trunk / All-VLAN** |

---

### Iris §3 — Pre-move capture (BEFORE powering anything down)

- [ ] **UniFi backup**: Settings → System → Backups → Download. Save off-box (carries DHCP fixed-IP reservations for `.81/.82/.83`).
- [ ] **Screenshot BOTH current switch port maps** — VDHPOESW01 (Pro HD 24) and VDHGSW01 (Flex). Masters currently on the Flex (ports 3/4/6), re-home to Pro HD 24.
- [ ] **Photograph + label every cable** at every switch, the UDM, the backbone runs (Meterkast wall hole + Kruipkelder), the Trapkast bracket, the Zolder switches, the Slaapkamer run, and the NanoStation pair. Tag: device, current port, target port.
- [ ] **Record dual-WAN**: WAN1 Ziggo (DHCP) + WAN2 KPN (PPPoE) — PPPoE username + which physical UDM WAN port each ISP uses (**these stay UNCHANGED**).
- [ ] **Snapshot node IPs**: workers `.81/.82/.83` = UDM DHCP fixed-IP (by MAC); masters `.84/.85/.86` = STATIC in Talos. VIP `172.16.2.240` on CP.
- [ ] **Record MACs** (authoritative — Flex shows masters as `DESKTOP-*`): m01 `78:55:36:03:d3:ab`, m02 `78:55:36:04:90:19`, m03 `78:55:36:04:97:ce`; n01 `88:ae:dd:62:1b:3c`, n02 `88:ae:dd:62:29:bf`, n03 `88:ae:dd:62:17:a6`.
- [ ] **OPERATOR-VERIFY:** export/screenshot the **UDM static-dns table** (per-host `*.bluejungle.net` A records). Could not be read from the sandbox.

---

### Iris §4 — Power-down: network LAST

- [ ] Confirm all 6 nodes + NAS powered off (Heph §3) **before** touching network.
- [ ] Power down edge-inward: **Stube (via NanoStation) / Zolder switches (Flex, USW 16-PoE) / Slaapkamer → Trapkast USW 24-PoE → Pro HD 24 → Aggregation → UDM last.**

---

### Iris §5 — Power-up: network FIRST (adopt-core-first) — GATE A

> Bring the fabric up **core-first, then backbone, then edge, one uplink at a time (loop-safe)**: **UDM → Aggregation → Pro HD 24 → Trapkast USW 24-PoE (backbone fiber) + U7 AP → Zolder Flex / USW 16-PoE → Slaapkamer AP → NanoStation pair → Stube**, verifying each uplink, **before any node powers on.**

- [ ] Power **UDM**; confirm WAN(s) train up (Ziggo DHCP + KPN PPPoE on their **unchanged** ports).
- [ ] Power **Aggregation**; confirm adopted + UDM uplink UP at 10G.
- [ ] Power **Pro HD 24**; confirm uplink UP at 10G to the Aggregation. Relocated **Hue Bridge / SLZB / AP05-Meterkast** (direct on Pro HD 24) come up here.
- [ ] Power **Trapkast USW 24-PoE**; confirm the **backbone Fiber#1 uplink UP** + the **U7 Pro XGS** (CAT6#1) link UP.
- [ ] Power the **Zolder Flex** (+ **USW 16-PoE**); confirm uplink UP — **verify negotiated speed** (CAT6 multi-hop; 2.5G/5G expected, NOT 10G — flag if not 10G, §8).
- [ ] Confirm the **Slaapkamer AP** link UP (1× CAT6 from the Trapkast 24-PoE).
- [ ] Bring up the **NanoStation AC pair** (Zolder ))) ((( Stube); **confirm the bridge re-links**, then the **Stube AP + Camera Achtertuin + Sonos** appear — this is LAST.
- [ ] Confirm **AP06-Keuken** link (PoE off the Trapkast 24-PoE).
- [ ] Confirm controller topology shows **one** uplink per access switch (no loop).

```bash
nslookup health.bluejungle.net 172.16.2.1
nslookup google.com 172.16.2.1
curl -sk -o /dev/null -w 'http=%{http_code} t=%{time_total}\n' --max-time 5 https://172.16.2.1/
```

> WAIT FOR Atlas (**GATE A**): UDM up, WAN(s) up, all switch uplinks UP (one per access switch) incl. the **Trapkast backbone fiber + Zolder switches + Slaapkamer**, the **NanoStation AC pair re-linked (Stube reachable)**, no L2 loop, DHCP serving, DNS resolving — BEFORE powering NAS/nodes.

---

### Iris §6 — CP-node re-home detail (Flex → Pro HD 24)

> Masters move from **Flex ports 3/4/6** to the **Pro HD 24**. Same untagged CLIENT-VLAN; static Talos IPs unaffected. Workers stay on Pro HD 24 (17/18/16). All 6 nodes end on the Pro HD 24 at 2.5G.

| Node | Old (Flex) | New (Pro HD 24) | Speed | Profile | MAC |
|---|---|---|---|---|---|
| master01 (.84) | port 3 | **port 19** | 2.5G | untagged CLIENT-VLAN | `78:55:36:03:d3:ab` |
| master02 (.85) | port 4 | **port 20** | 2.5G | untagged CLIENT-VLAN | `78:55:36:04:90:19` |
| master03 (.86) | port 6 | **port 21** | 2.5G | untagged CLIENT-VLAN | `78:55:36:04:97:ce` |
| node01 (.81) | port 17 | port 17 | 2.5G | untagged CLIENT-VLAN | `88:ae:dd:62:1b:3c` |
| node02 (.82) | port 18 | port 18 | 2.5G | untagged CLIENT-VLAN | `88:ae:dd:62:29:bf` |
| node03 (.83) | port 16 | port 16 | 2.5G | untagged CLIENT-VLAN | `88:ae:dd:62:17:a6` |

> Ports 19/20/21 are a **proposal** — on-site, pick free Pro HD 24 ports that are not the 10G uplinks (23/27/28) and not the U7 AP port. Keep masters adjacent + labelled. Node ports are port-agnostic for addressing, but set every chosen port to untagged CLIENT-VLAN **before** plugging in (§2 step 7).

```bash
ping 172.16.2.84; ping 172.16.2.85; ping 172.16.2.86   # masters (static)
ping 172.16.2.240                                       # VIP (CP only)
# Controller: confirm m01/m02/m03 now on Pro HD 24 at 2.5G, NOT on the Flex
```

---

### Iris §7 — Addressing sanity + post-bring-up verification — GATE B

- [ ] **Workers**: UDM DHCP fixed-IP reservations restored from backup — `.81/.82/.83` (by MAC; port-agnostic).
- [ ] **Masters**: static in Talos — `.84/.85/.86` regardless of switch/port.
- [ ] **VIP**: `172.16.2.240` answers (CP only).

```bash
nslookup health.bluejungle.net 172.16.2.1
kubectl -n network logs deploy/external-dns-unifi --tail=50
kubectl -n network get pods | grep cloudflared
kubectl -n network exec deploy/cloudflared -- wget -qO- https://1.1.1.1 || true
# APs/devices re-adopt — UniFi GUI: Devices -> all adopted/connected
#   (AP05-Meterkast [now on Pro HD 24] + U7 Pro XGS / AP01-Trapkast + AP06-Keuken
#    + Slaapkamer AP + Stube AP + Camera Achtertuin)
# Confirm the NanoStation AC pair re-linked (Zolder ))) ((( Stube) — airMAX link UP
```

> WAIT FOR Atlas (**GATE B**): internal `*.bluejungle.net` resolves on 172.16.2.1, static-dns matches §3 capture, cloudflared up, egress works, **all APs/devices re-adopted (AP05-Meterkast [on Pro HD 24] + U7 Pro XGS + AP06-Keuken + Slaapkamer AP + Stube AP + Camera Achtertuin)** and the **NanoStation AC pair re-linked**.

---

### Iris §8 — Port-profile / VLAN / speed gotchas (new layout)

- **Aggregation is SFP+ only (assume no RJ45).** The Trapkast USW 24-PoE uplinks via its **SFP port over the backbone FIBER#1** (the old "1G copper can't land on SFP+" caveat does not apply). Verify the Aggregation SFP+ port accepts a **1G SFP module** (UniFi Aggregation ports are 1/10G — fine) and that you have a 1G SFP transceiver + LC fiber.
- **Zolder Flex link (CAT6#2, multi-hop) is the marginal link to watch — do NOT promise 10G.** It is **CAT6 not 6A** and patched through the Trapkast (multi-hop), so 10GBASE-T can silently negotiate **DOWN to 5G/2.5G** (or flap). Expect **2.5G/5G**, not 10G. The Flex only serves the Zolder office (PC + Mini), so a fallback is **non-critical** — but **VERIFY the actual negotiated speed** after bring-up and **flag if it is not 10G; never promise 10G.** If landed on copper at the Aggregation, confirm an **SFP+→10G-RJ45 module** (most UniFi Aggregations are SFP+-only). Add to the SFP/transceiver count.
- **U7 Pro XGS lands on a Pro HD 24 10G PoE++ (802.3bt) port** (confirmed; at the Trapkast over backbone CAT6#1) — tally the **bt PoE** draw against the Pro HD 24 PoE budget.
- **AP06-Keuken PoE** comes from the **Trapkast USW 24-PoE**; **AP05-Meterkast / Hue Bridge / SLZB** are now **direct on the Utility Room Pro HD 24** (no longer a Meterkast pegboard chain). Confirm the **Trapkast 24-PoE PoE budget** covers AP06-Keuken + cameras, and fold AP05/Hue/SLZB into the **Pro HD 24** budget.
- **Stube edge is wireless (NanoStation AC airMAX bridge).** The Stube AP + Camera Achtertuin + Sonos are reachable **only after the NanoStation pair re-links** over airMAX (Zolder side ))) ((( Stube side). Confirm the bridge link before expecting any Stube device. See `docs/research/nanostation-ac-management.md`.
- **Pro HD 24 keeps all 6 nodes at 2.5G** — confirm every chosen node port negotiates **2.5G full-duplex** (not 1G).
- **Uplinks must be trunk/All-VLAN**; node/AP ports untagged CLIENT-VLAN. Diff every profile after adoption — a node port left on trunk, or an uplink left untagged-only, is the likeliest silent misconfig.
- **WAN (UNCHANGED ports):** both KPN (PPPoE) + Ziggo (DHCP) stay on their **current UDM WAN ports** — no port reassignment, no config change. PPPoE/DHCP simply **re-train** when the UDM powers back up (PPPoE can take longer than DHCP). The ISP gear (Ziggo modem, KPN ONT) is in the Meterkast adjacent to the UDM via the wall hole — short handoff, **does not consume the backbone budget**. The Ziggo modem may relocate onto the rack (its coax feed follows; coax is not in the LAN budget).

---

### Iris §9 — Updated CONFIRM-BEFORE-MOVE-DAY (network items)

> See the top-level **⚠️ CONFIRM BEFORE MOVE DAY** section for the master list. Network-specific status:

| # | Item | Status |
|---|---|---|
| 1 | Switch layout / CP re-home | **RESOLVED.** Pro HD 24 → Utility Room (CP re-home onto it, §6). **USW 24-PoE → Trapkast** (dist hub). **Flex + USW 16-PoE → Zolder.** No switch in the Meterkast. |
| 2 | AP06-Keuken placement | **RESOLVED.** PoE from the **Trapkast** USW 24-PoE chain. |
| 3 | Old-location uplink media | **RESOLVED.** Backbone **Fiber#1** (Trapkast USW 24-PoE SFP → Aggregation), not CAT6. Via Meterkast wall hole + Kruipkelder. |
| 4 | Office (Zolder) workstations | **RESOLVED.** Stay at the **Zolder** on the Flex + USW 16-PoE; Flex uplinks over CAT6#2 patched through the Trapkast. |
| 5 | WAN port mapping + ONT/modem | **RESOLVED.** ISP gear in the Meterkast (entry + passthrough only) adjacent to the UDM; both WANs on UNCHANGED ports. |
| 6 | SLZB / Hue / AP05 power+home | **RESOLVED.** Relocate to the **Utility Room**, direct on the Pro HD 24, powered there — come up with the rack. |
| 7 | **Aggregation SFP+/RJ45 transceiver + module count** | **CONFIRM.** 2× 10G LOCAL (UDM↔Agg, ProHD↔Agg) + **1G SFP** for the Trapkast backbone fiber + an **SFP+→10G-RJ45** if the Zolder Flex CAT6#2 lands on copper. Buy spares. |
| 8 | **Zolder Flex link negotiated speed (CAT6, multi-hop)** | **CONFIRM/VERIFY.** Trace the Zolder→Trapkast→Utility patch path; **expect 2.5G/5G — verify and flag if not 10G; do not promise 10G** (§8). |
| 9 | **Synology NAS (172.16.2.246) location** | **CONFIRM.** Utility Room or stays? Powers between network and CP nodes (Heph §4.0). |
| 10 | **UDM static-dns table** | **OPERATOR-VERIFY.** Export before, re-verify after. |
| 11 | **PoE budgets (Trapkast 24-PoE + Zolder 16-PoE + Pro HD 24)** | **CONFIRM.** Trapkast 24-PoE covers AP06-Keuken + cameras; Zolder 16-PoE covers its loads; Pro HD 24 covers AP05/Hue/SLZB + U7 (bt). |
| 12 | **U7 Pro XGS PoE++ on the Pro HD 24** | **CONFIRM.** Backbone CAT6#1 lands on a Pro HD 24 PoE++ (bt) port with enough budget (§8). |
| 13 | **NanoStation AC pair re-links / Stube + garden camera recover** | **CONFIRM/VERIFY.** airMAX bridge (Zolder ))) ((( Stube) must re-link; verify Stube AP + Camera Achtertuin + Sonos after. See `docs/research/nanostation-ac-management.md`. |

---

### Iris §10 — Atlas gates (network)

| Gate | Condition |
|---|---|
| **GATE A** | New core + backbone + edge healthy **before any node powers on**: UDM up, WAN(s) up, Aggregation + Pro HD 24 + Trapkast USW 24-PoE (backbone fiber) + Zolder Flex/16-PoE + Slaapkamer + U7 uplinks all UP (one per access switch), **NanoStation AC pair re-linked (Stube reachable)**, no L2 loop, DHCP serving, internal + external DNS resolving. |
| **GATE B** | Full path: internal `*.bluejungle.net` resolves, static-dns matches §3, cloudflared up, egress works, all APs/devices (AP05-Meterkast [on Pro HD 24] + U7 Pro XGS + AP06-Keuken + Slaapkamer AP + Stube AP + Camera Achtertuin) re-adopted, NanoStation pair re-linked. |

**Validation evidence:** GATE A — `nslookup` (internal+external) + UDM GUI showing WANs up + topology view showing one uplink per access switch (loop-free proof) + Zolder Flex link-speed readout (flag if not 10G) + the NanoStation airMAX link status (Stube reachable). GATE B — external-dns + cloudflared logs, a real pod egress fetch, static-dns GET diffed vs §3 export, UniFi Devices screenshot showing all APs/devices re-adopted (incl. Stube AP + Camera Achtertuin) and the NanoStation pair re-linked.

---

## HOME ASSISTANT (Hestia)

### Hestia §1 — Household impact

**What STOPS during the move:**
- All automations (those still enabled), kiosks, climate logic, Zigbee (z2m), Z-Wave, the alarm view.
- **Hue local control** — the Hue Bridge **relocates to the rack (Pro HD 24, Utility Room)**, so Hue is **DOWN during the move window** and returns when the core comes up with the rack. Low stakes (June, short window) but state it honestly: Hue is **not** a "keeps working" item this move.
- **The ENTIRE downstream estate** — with the Utility Room core down, everything south loses network: the **Zolder office**, the **Slaapkamer AP**, and the **Stube (AP + Camera Achtertuin garden camera + Stube Sonos)**. The Stube hangs off the Trapkast → Zolder → NanoStation chain, so it recovers **LAST**. Tell the family: **the garden camera and the Stube audio also drop during the move**, not just HA.

**What KEEPS working (independent of the cluster):**
- **Sonos (non-Stube)** — local. **NOTE:** the **Stube Sonos** is behind the NanoStation bridge and **does drop** until the chain is back.
- **Thermostat** — local schedules continue.
- **Fridge / freezer / wine-coolers** — on direct power. **DO NOT toggle these off** (lesson: an old "herstart" automation once cycled fridge/freezer plugs).
- **Internet / Wi-Fi** — once network is back (Phase B).
- **Physical door locks** — physical, unaffected.

### Hestia §2 — Pre-shutdown HA safe-state

- [ ] **Pause these 4 automations** (record that they were ON, to re-enable later):
  - `outdoor_power_blip_logger_observe_only`
  - `irrigatie_achtertuin`
  - `kantoor_aanwezig_verwarm_naar_21degc`
  - `keuken_tablet_*`
- [ ] Graceful pod shutdown is handled by Heph (Phase A4) — Hestia does **not** kill the HA pod directly.

### Hestia §3 — Devices needing separate power

| Device | Power note |
|---|---|
| **SLZB Zigbee coordinator** | **RESOLVED — relocates to the Utility Room, direct on the Pro HD 24, powered there.** Comes up **WITH the rack / Pro HD 24**. **Bring-up step (B1b):** SLZB must have **power + its LAN link live on the Pro HD 24 BEFORE z2m recovers**; verify the z2m bridge connection after (Hestia §4.3). Zigbee stays dead until SLZB is up. |
| Hue Bridge | **Relocates to the Utility Room (Pro HD 24).** Hue local control is **DOWN during the move**; verify it comes back once the rack core is up (Hestia §4.5). |
| AP05-Meterkast | **Now on the Utility Room Pro HD 24** (relocated); included in the post-bring-up AP re-adoption check (Iris §7). |
| **Stube (AP + Camera Achtertuin + Sonos)** | Behind the **NanoStation AC airMAX bridge** (Zolder ))) ((( Stube). Recovers **LAST** — only after the Trapkast USW 24-PoE + Zolder switch + the Zolder-side NanoStation are powered and the bridge **re-links**. Verify the garden camera + Stube Sonos after (Hestia §4.5). See `docs/research/nanostation-ac-management.md`. |
| Synology NAS (172.16.2.246) | Separate; see CONFIRM-BEFORE location item; powered at B2. |
| Pixel tablet (kiosk) | Separate power/charge. |
| ThinkSmartView (kiosk) | Separate power. |
| HomeWizard / Sonos | On their own power; verify reconnect. (Stube Sonos waits for the NanoStation chain — above.) |

### Hestia §4 — Post-bring-up verification (4.1–4.8)

```bash
# 4.1 HA running + version
curl -s -H "Authorization: Bearer $HA_TOKEN" https://ha.bluejungle.net/api/config | jq '{state,version}'
# Expect: state=RUNNING, version=2026.6.2

# 4.2 trusted_proxies present (MUST include node CIDR 172.16.2.0/23 — Cilium L2 SNAT)
# Confirm 172.16.2.0/23 is in http.trusted_proxies (lives in PVC; reapply on DR if missing)

# 4.3 z2m connection_state — ONLY meaningful after SLZB has power + LAN link (B1b)
curl -s -H "Authorization: Bearer $HA_TOKEN" https://ha.bluejungle.net/api/states/sensor/zigbee2mqtt_bridge_connection_state | jq '.state'
# Expect: on/online  (if offline, re-check SLZB power + LAN link on the Pro HD 24 first)

# 4.4 z-wave node alive
curl -s -H "Authorization: Bearer $HA_TOKEN" https://ha.bluejungle.net/api/states | jq '[.[]|select(.entity_id|startswith("sensor.")) ]' # check a known z-wave node alive

# 4.5 Hue / HomeWizard / Sonos / Stube reachable
# Hue Bridge relocated to the Utility Room Pro HD 24 — confirm a known Hue entity is no longer 'unavailable'
# once the rack core is up. Spot-check HomeWizard + (non-Stube) Sonos too.
# STUBE (LAST): confirm Camera Achtertuin (garden camera) + Stube Sonos are back ONLY after the
# NanoStation AC pair has re-linked (Iris GATE B). These recover after the whole downstream chain.

# 4.6 kiosks render
# Poke Fully Kiosk Browser REST API on Pixel tablet + ThinkSmartView; capture render proof (kiosk-verify)

# 4.7 unavailable count near BASELINE
curl -s -H "Authorization: Bearer $HA_TOKEN" https://ha.bluejungle.net/api/states | jq '[.[]|select(.state=="unavailable")]|length'
# Expect: ~286 (the true baseline) — NOT the stale 739-761 figure.

# 4.8 RE-ENABLE the 4 paused automations (from §2)
```

> **Honest caveats (Hestia):**
> - The **unavailable baseline is ~286**, NOT the stale **739–761** figure that has been quoted elsewhere — judge recovery against ~286.
> - **SLZB power source is RESOLVED** (Utility Room Pro HD 24, comes up with the rack) — but its **power + LAN link must be live before z2m recovers** (B1b → 4.3).
> - **Hue Bridge relocates to the rack** — Hue local control is DOWN during the move; verify it returns at 4.5 once the core is up.
> - **Stube (garden camera + AP + Sonos) recovers LAST** behind the NanoStation AC bridge — do not judge recovery complete until the bridge re-links and 4.5 confirms the garden camera + Stube Sonos (Iris GATE B).
> - **Z-Wave exists** in this install (don't assume Zigbee-only); verify a Z-Wave node is alive (4.4).
> - **No smart locks** integrated — physical locks only; nothing to verify there.

### Hestia §5 — Atlas gates (Home Assistant)

| Gate | Condition |
|---|---|
| GATE C | Kiosks render (Pixel + ThinkSmartView) with render proof |
| GATE D | HA RUNNING, integrations alive (incl. Hue back once rack core up, z2m after SLZB up, **Camera Achtertuin + Stube Sonos back after NanoStation re-link**), unavailable near ~286 baseline, 4 automations re-enabled |
| (also feeds B12–B15) | trusted_proxies present, SLZB power+link up → z2m alive, z-wave alive, **Stube edge recovered (garden camera + Sonos) via the NanoStation bridge** |

---

# Cross-referenced files

- `docs/runbooks/ceph-osd-disk-replacement.md` — full OSD swap procedure (Phase C; do not duplicate).
- `docs/research/nanostation-ac-management.md` — NanoStation AC airMAX bridge (Zolder ↔ Stube) management + re-link procedure.
- `docs/runbooks/disaster-recovery.md` — broader DR context (trusted_proxies reapply, etc.).
- `kubernetes/main/talos/talconfig.yaml` — node static IPs / boot disk serials.
- `kubernetes/main/apps/rook-ceph/rook-ceph-cluster/app/helmrelease.yaml` — Ceph OSD device list / pool replication.

---

## Validation plan (proves this runbook works in the real move)

The implementing operator + engineers prove the move succeeded by capturing, at the named gates, the following **real-world evidence** (not descriptions):

1. **GATE A (Iris)** — `nslookup` output for internal + external names against 172.16.2.1, plus UDM GUI screenshot showing both WANs up, **plus the controller topology view showing one uplink per access switch (loop-free proof)**, the **Zolder Flex link-speed readout** (flag if not 10G; 2.5G/5G expected), and the **NanoStation AC airMAX link status** (Stube reachable). Real DNS resolution, not a ping.
2. **GATE 2/3 (Heph)** — `ceph status` output showing mons in quorum, 3 OSDs up, then all PGs `active+clean`. Captured payload attached to the change.
3. **GATE B (Iris)** — `kubectl` logs for external-dns + cloudflared, a real egress fetch from a pod, and UniFi Devices screenshot showing **all APs/devices (AP05-Meterkast [on Pro HD 24] + U7 Pro XGS + AP06-Keuken + Slaapkamer AP + Stube AP + Camera Achtertuin) re-adopted** and the **NanoStation pair re-linked**, plus the static-dns GET diffed vs the §3 export.
4. **GATE C (Hestia)** — **kiosk-verify render proof** (browser-rendered screenshot) of both the Pixel tablet and ThinkSmartView showing the live dashboard — API value cross-check alone is insufficient.
5. **GATE D (Hestia)** — `/api/config` JSON showing `state=RUNNING`, `version=2026.6.2`; z2m connection_state `online` (after SLZB power+link confirmed); a known Hue entity not `unavailable` (once the rack core is up); **a known Camera Achtertuin (garden camera) entity + Stube Sonos not `unavailable` (after the NanoStation pair re-links)**; unavailable-count query result near ~286; confirmation the 4 automations are re-enabled.
6. **Phase C (Heph)** — `ceph status` `active+clean` between each OSD swap; cross-ref `ceph-osd-disk-replacement.md` validation.

If any end-to-end test cannot be run on the day (e.g. a physical screen can't be observed remotely, or the SLZB/Hue bring-up is awaiting rack power, or the Stube NanoStation has not yet re-linked), the operator hands that specific verification step to the user with reload instructions and does NOT mark the gate green until the user confirms.

— Daedalus
