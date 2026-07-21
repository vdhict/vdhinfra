# NEEO Universal Remote + Brain → Home Assistant (2026)

_Researched 2026-07-21 by Athena. Every figure below was fetched live this run unless marked "could not verify."_

## Question
Can a never-activated, Kickstarter-era NEEO Remote + Brain still be set up in 2026, and can it be integrated with Home Assistant — and if not, what's the realistic alternative?

## TL;DR
- **Gating answer: RED for a never-activated unit.** The normal first-run of a factory-fresh Brain needs the NEEO phone app + NEEO cloud (Wi-Fi provisioning, account, and download of the base firmware/recipe database). Control4/SnapAV shut that cloud down in **Q1 2021**, `neeo.com` now **301-redirects to snapav.com** (verified live), the community forum `planet.neeo.com` **no longer resolves** (verified live on two resolvers), and the setup app was pulled from the stores. There is **no documented supported path to activate a fresh Brain today.**
- A NEEO that was already set up before 2021 keeps working locally; a never-activated one has no happy path. The only conceivable route is a deep hacker project (see Recommendation) and it is **unproven for a never-activated unit**.
- HA integration, when it works, was mainly **direction (a): the NEEO controls HA** via a Node.js SDK driver the Brain discovers on the LAN. A minor direction (b) HA component ("recipes as switches") also existed. **Both are abandoned** (last commits 2018 and 2021).
- **Verdict for this homelab: don't invest in the NEEO.** Buy a **Broadlink RM4 Pro** (IR + 433/315 MHz RF, official *local* HA integration) instead. Logitech Harmony is discontinued and a dead end.

## The gating question in detail: can a fresh Brain even be activated?
Historically the classic NEEO onboarding was: power the Brain → the iOS/Android **NEEO app** finds it → app pushes Wi-Fi credentials → you create a **NEEO cloud account** → the Brain pulls its device/recipe database and firmware from **NEEO's cloud**. Every one of those legs is now broken:

- **Vendor & cloud gone.** Control4 acquired NEEO on **5 Feb 2019**, stopped direct-to-consumer sales, and gave existing owners ~24 months of support → ~Feb 2021 ([essentialinstall](https://essentialinstall.com/news/smart-home/neeos-smart-home-platform-discontinued-after-control4-acquisition/)). The community knowledge base states the cloud — used "for installing new device support ... AND for recovering from logical damage to your remote (corrupted firmware / filesystem)" — shut down **Q1 2021** ([FindingNEEO FAQ, raw](https://raw.githubusercontent.com/jac459/neeo2021onward/main/FAQ.md), verified live).
- **Consumer site gone.** `https://neeo.com` returns **301 → https://www.snapav.com/** (verified live this run). There is no consumer NEEO cloud/login/app-download page anymore.
- **Community forum gone.** `planet.neeo.com` has **no A record** (verified live on system resolver and 8.8.8.8). `support.neeo.com` still points at a Zendesk CNAME but the product is EOL.
- **Setup app.** WebSearch and forum-thread titles ("iOS app not available anymore") indicate the setup app was removed from the App Store. **Could not verify** the exact removal/date via live fetch — the Apple discussions thread returned HTTP 429 on every attempt, and `planet.neeo.com` is dead.

Net: a never-activated Brain cannot complete its cloud-dependent first-run, and there is no vendor or community "activate offline" wizard.

## HA integration direction & the concrete paths
- **(a) NEEO controls HA — `jakeblatchford/neeo-homeassistant`** (Node.js on a LAN host the Brain discovers). Exposes HA `light`/`switch`/`scene`/`script` to the remote. Built on the NEEO SDK. README is labelled *"In Development"* with a list of known-broken behaviours; **last commit 2018-01-30** (verified via GitHub API). Requires the **`neeo-sdk`** npm package (latest **0.53.8**, last published **2022-06-20**, verified live on the npm registry) — abandoned but installable.
- **(b) HA sees the NEEO — `vinteo/hass-neeo`** custom component: exposes the Brain's **"recipes as switches"** in HA via `configuration.yaml` (old YAML-platform style, not a config flow). **Last commit 2021-06-04** (verified). Almost certainly broken on 2026 HA without a rewrite.
- **Community "Metadriver" / rooting (`jac459/*`, Telegram "FindingNEEO").** The maintained-ish effort. Rooting is done with the **DustBuilder** at `https://builder.dontvacuum.me/neeo.html` (site **live** this run; produces patched firmware giving SSH/sudo on the Brain; needs an original device; no cloud; last firmware note dated **2018-04-24**). Once rooted, custom/"Meta" drivers run **locally on the Brain or on a Raspberry Pi/NAS**, and the Meta explicitly "brings direct connectivity to ... Home Assistant, Homey, Node-red" (FAQ, verified live). This is a serious, undocumented-for-fresh-units hacking path — not a product setup.

## Patterns that recur
- **Every path is community-run, abandoned, and predates modern HA** (2018–2022 code, no config-flow, no HACS default listing). Nothing tracks current HA or NEEO firmware.
- **Runtime after setup is local** (the SDK/driver talks to the Brain over mDNS on the LAN; no cloud needed day-to-day). The cloud dependency is concentrated in **initial activation, new-device recipes, and firmware recovery** — exactly the legs that are dead for a never-activated unit.
- **Everyone who still uses a NEEO activated it before Q1 2021.** No source describes onboarding a fresh Brain after the shutdown.

## Recommendation (this homelab: single operator, HA-centric)
**Do not try to make the never-activated NEEO your HA remote.** Feasibility is **RED**: no supported activation, dead vendor cloud, dead forum, abandoned integrations. The only route that could work is expert-tier and unproven for a fresh unit — get the Brain on wired Ethernet, attempt a DustBuilder root/flash to bypass cloud onboarding, then run Meta/SDK drivers locally. Treat that as a weekend hardware-hacking gamble, not an integration. If you want to try it *for fun*, fine; if you want a working HA universal remote, skip it.

**Buy instead: Broadlink RM4 Pro.** IR + **433/315 MHz RF**, and it has an **official, local-polling** HA integration listing "RM4 pro" among supported universal remotes ([HA Broadlink docs](https://www.home-assistant.io/integrations/broadlink/), verified live). Cheap, current, no cloud dependency for control. Pair it with HA dashboards / a Zigbee button remote for the physical-button feel.

Alternatives ranked: **Broadlink RM4 Pro** (best fit, local) > **SwitchBot Hub 2** (IR, Matter/HA, but cloud-leaning) > **ESPHome IR blaster** (DIY `remote_transmitter`, most local, most effort). **Avoid Logitech Harmony** — Logitech stopped manufacturing in 2021 and retired the legacy Harmony software on **28 May 2025**; the HA `harmony` integration still exists for legacy hubs but it's a shrinking dead end ([WebSearch, Logitech Harmony status](https://en.wikipedia.org/wiki/Logitech_Harmony)).

## Sources
- FindingNEEO knowledge base / FAQ (cloud shutdown Q1 2021, rooting, Meta→HA/Homey/Node-red) — https://raw.githubusercontent.com/jac459/neeo2021onward/main/FAQ.md — fetched 2026-07-21, **verified live**
- `neeo.com` 301 → `snapav.com` — https://neeo.com — checked 2026-07-21, **verified live (redirect)**
- `planet.neeo.com` no DNS A record (system + 8.8.8.8) — checked 2026-07-21, **verified live**
- Control4 acquisition (5 Feb 2019) + ~24-month support — https://essentialinstall.com/news/smart-home/neeos-smart-home-platform-discontinued-after-control4-acquisition/ — fetched 2026-07-21, **verified live** (article gives no hard cloud-off date)
- `jakeblatchford/neeo-homeassistant` (direction a; last commit 2018-01-30) — https://github.com/jakeblatchford/neeo-homeassistant — API + raw README, 2026-07-21, **verified live**
- `vinteo/hass-neeo` (direction b; "recipes as switches"; last commit 2021-06-04) — https://github.com/vinteo/hass-neeo — API + raw README, 2026-07-21, **verified live**
- `neeo-sdk` npm 0.53.8, last modified 2022-06-20 — https://registry.npmjs.org/neeo-sdk — 2026-07-21, **verified live**
- DustBuilder NEEO rooting tool (live; SSH firmware; needs original device; no cloud) — https://builder.dontvacuum.me/neeo.html — fetched 2026-07-21, **verified live**
- HA Broadlink integration (RM4 pro, local polling) — https://www.home-assistant.io/integrations/broadlink/ — fetched 2026-07-21, **verified live**
- Logitech Harmony discontinued 2021 / legacy software retired 28 May 2025 — https://en.wikipedia.org/wiki/Logitech_Harmony , https://support.harmonyremote.com/ — WebSearch 2026-07-21, **snippet only, page content not individually fetched**
- NEEO iOS setup app removed — Apple discussions thread https://discussions.apple.com/thread/255751304 — **could not verify** (HTTP 429 on all attempts); title/WebSearch indicate removal only

— Athena

---

## Update 2026-07-21 — neeo2021onward (repo the first pass missed)

**Honest correction:** my first sweep cited `jac459/neeo2021onward`'s FAQ.md but did **not** open the repo itself or its main sibling `jac459/meta`. The user flagged it by name. I investigated both live. **Verdict is unchanged (RED for a never-activated unit)**, but here is the full, sourced picture so the call is defensible.

### What neeo2021onward actually is
A **knowledge base + installer material for `.meta`** (the "metadriver"): a community driver-development-and-execution platform for the classic NEEO remote, run by the Telegram "FindingNEEO" community (maintainer `jac459`). Repo README (raw, fetched live) states it holds install scripts for `.meta` on three targets: **NEEO-Brain** (no longer maintained), **Raspberry Pi** (the main path — points to `jac459/meta`), and **Docker** (under development). The repo itself is dormant (`pushed_at` **2021-10-28**, GitHub API), but the **active project is `jac459/meta`** (`pushed_at` **2026-01-27**, default branch `Release`, 24 stars, v1.0.1/v1.1 — live and maintained). meta needs **Node.js + MQTT (mosquitto) + Node-RED + pm2**; drivers exist for Hue, Yamaha, Broadlink, Roon, Volumio, Kodi, LG webOS, Android TV, etc.

### THE GATING QUESTION — fresh, never-activated Brain bring-up: **NO**
The project's own stated objective (FAQ.md, live): *"Make certain that the original NEEO-remote is still useable **after** NEEO/C4 shuts down their cloud."* It is a **preservation toolkit for already-activated units**, not a first-activation replacement. Concretely, none of its pieces provisions a virgin Brain:
- **First-time setup is cloud-bound.** NEEO's own FTUE has the Brain *"scan your network so you can create your NEEO account,"* and *"the database and every device will be downloaded from the server"* (NEEO support / Planet NEEO, via WebSearch — the support article itself returned **HTTP 403**, could not verify live; Planet NEEO DNS is dead). That server is gone. A never-activated Brain has never pulled its database and cannot create an account.
- **Rooting does not provision.** DustBuilder (`builder.dontvacuum.me/neeo.html`, fetched live) only *"generates a patched firmware which enables you to connect via SSH… **Your configuration remains untouched**"* and *"requires an original device."* It **patches existing firmware to add SSH**; it does not build the base config, account, or recipe database. It presupposes a working device.
- **meta is an add-on, not a bootstrapper.** The `jac459/meta` install ends with *"go to neeo and **search a new device**. You should find the meta-core driver"* — searching for a device requires an already-set-up Brain reachable from the NEEO app/remote. meta rides on top of a functioning NEEO application layer; it cannot create one.
- **No offline wizard / self-hosted cloud / first-activation firmware exists** anywhere in the repo tree, issues, FAQ, or `meta`. The name means *"keep your working remote alive from 2021 onward,"* not *"activate a new one after 2021."*

### HA connection
**Indirect, via Node-RED + MQTT; direction = the NEEO remote controls HA.** meta emits device actions over local MQTT (mosquitto, 127.0.0.1); Node-RED flows pick them up and drive targets, including HA/Homey (FAQ: meta *"brings direct connectivity to Home Assistant, Homey, Node-red"*; Node-RED flow instructions doc, live). Needs a rooted Brain **or** a Pi/NAS/Docker host running Node.js + mosquitto + Node-RED + pm2 + meta. No dedicated `meta-homeassistant` repo exists (checked `jac459` repo list, live); HA is reached through generic Node-RED HA nodes.

### Maintenance + viability
`meta` is genuinely alive (2026-01 commits, active Telegram; Discord marked deprecated in README). But every dependency **presumes an already-activated Brain**: an original unit + DustBuilder root (voucher `neeo`, needs original device) + the Node/MQTT/Node-RED stack. Difficulty: high (Linux CLI, firmware rooting). **No success report found — anywhere — for a fresh / never-activated / virgin-reset Brain.** All guidance assumes a functioning, previously-provisioned unit. Open issues are minor (Broadlink install, optional MQTT auth), none about first activation.

### Revised verdict: **RED — unchanged**
neeo2021onward / meta do **not** move the needle for THIS user (never-activated Brain). They are a preservation and driver-extension toolkit for units that were **activated before the Q1 2021 cloud shutdown**. The only conceivable path remains expert-tier and **doubly unproven**: (1) get SSH onto a *virgin* Brain — DustBuilder's flow presupposes an existing config and the historic patch-install relied on the Brain's own update mechanism, with **zero** documented fresh-unit cases; **and** (2) hand-reconstruct NEEO's application state (account + recipe DB) purely over SSH — **no method, no tooling, no report** of anyone doing this. Both unknowns must resolve favourably. Practically: RED. **Recommendation stands: buy a Broadlink RM4 Pro.**

### Sources (this update, all fetched live 2026-07-21)
- `jac459/neeo2021onward` README (raw) — https://raw.githubusercontent.com/jac459/neeo2021onward/main/README.md — **verified live**
- `jac459/neeo2021onward` repo metadata (pushed 2021-10-28) — GitHub API `/repos/jac459/neeo2021onward` — **verified live**
- `jac459/meta` repo metadata (pushed 2026-01-27, branch `Release`) + README + tree — GitHub API + https://raw.githubusercontent.com/jac459/meta/Release/README.md — **verified live**
- FindingNEEO FAQ (project objective, rooting, meta→HA/Homey/Node-red) — https://raw.githubusercontent.com/jac459/neeo2021onward/main/FAQ.md — **verified live**
- `Meta running in Brain/README.md` + `Instructions_for_Flows_Node-RED_FLOW.MD` (MQTT/Node-RED bridge) — raw.githubusercontent.com — **verified live**
- DustBuilder NEEO (patches existing firmware, config untouched, needs original device) — https://builder.dontvacuum.me/neeo.html — **verified live**
- NEEO FTUE requires account + server DB download — WebSearch (NEEO support / Planet NEEO); support article https://support.neeo.com/hc/en-us/articles/115005952825 returned **HTTP 403, could not verify live**; Planet NEEO DNS dead
- `jac459` repo list (no meta-homeassistant repo) — GitHub API `/users/jac459/repos` — **verified live**

— Athena

---

## Update 2026-07-21c — reverse-engineering feasibility (bypass activation)

**Question:** how hard would it be for *us* to close the "virgin-Brain can't activate" gap ourselves via RE — dump/patch the firmware, understand the firstboot/cloud handshake, and provision a never-activated Brain offline (DNS override + local/mock cloud)? Brutally honest scope; unknowns marked.

**Headline:** the firmware/OS and the Brain-local API are **well reverse-engineered**; root on a *virgin* unit is **plausible but undocumented**; the Brain↔**cloud** handshake (account + new-device DB) is **not captured, not archived, not mocked by anyone**. This is **not** a finish-someone's-work job. It is a **hard, unproven solo RE project** — but the starting position is materially better than "cloud data lost forever": root is obtainable and the Brain app is readable Node.js. Two undocumented unknowns gate success. **Net call: hard-but-maybe-doable, low-to-moderate odds, weeks of expert effort — buying a pre-2021-activated donor Brain is the pragmatic shortcut.** Recommendation for the homelab is unchanged: buy a Broadlink RM4 Pro.

### 1. Firmware / OS / boot — WELL understood
- **Brain (model "CP6") = Arch Linux on ARM.** Rootfs is **ext2 on `/dev/mmcblk0p2`, mounted read-only** by default; a `/steady` partition **survives firmware updates** (where community drivers are parked). Node.js **v8** ships stock; `pacman` present. (jac459/NeeoDriversInBrain README, raw, **fetched live 2026-07-21**.)
- **CP6 firmware image is OpenSSL-encrypted** (`binwalk` → "OpenSSL encryption, salted" at offset 0). **DustBuilder** (Dennis Giese) holds the passphrase: it decrypts the stock `0.53.8-20180424` image, injects an `authorized_keys` for SSH user `neeo` (sudoer), re-encrypts, and **emails you the patched image + install howto** — i.e. Dennis **self-hosts the firmware** now, which matters because the original download bucket is dead (next point). "Your configuration remains untouched… requires an original device." (builder.dontvacuum.me/neeo.html, **fetched live 2026-07-21**.)
- **Remote (model "TR2") = eCos RTOS**, firmware **not encrypted** (`binwalk` shows D-Link ROMFS + jffs2/eCos strings, no OpenSSL header). (planet.neeo.com CP6/TR2 hacking thread, Wayback 2021-06-13, **fetched live via web.archive.org 2026-07-21**.)
- **Recovery mode is bootloader-level and redirectable.** Hold the pair/lid button while powering on → host `neeo-recovery`, exposes an HTTP API: `http://<BRAIN_IP>/checkforfirmware?server=<URL>` and `/downloadfirmware?server=<URL>`. **The `server=` parameter takes an arbitrary URL** — the original was `https://neeo-cp6-recovery.s3.amazonaws.com/` (I checked it live 2026-07-21: **`NoSuchBucket` — dead**), but DustBuilder simply points recovery at its own mirror. **So the firmware-recovery leg is effectively solved** via a self-hosted/redirected firmware server. (Same hacking thread + NeeoDriversInBrain, **live**.)
- **What is NOT public:** the internals of the **firstboot/activation service** — the specific systemd unit(s), what they call upstream, and the exact gate that flips the Brain from "unconfigured" to "configured." Nobody has published that.

### 2. Activation / FTUE — the actual cloud dependency, partly mapped
- The Brain runs a **Node.js REST API on `:3000` under `/v1`**, fully enumerated by nklerk (Niels de Klerk) in the hacking thread. Relevant gates: `GET /v1/projects/home/configured → {"configured": false|true}`, `GET /v1/projects/home/activate`, `GET /v1/projects/home/scheduleactivation`, `/v1/account/backups`, `/v1/firmware/check`. Device lookups are **served locally**: `GET /v1/devicespecs/search?q=…` and `GET /v1/devicespecs/<id>`. (Wayback thread, **live**.)
- What a virgin Brain historically needed the **cloud** for (FindingNEEO FAQ, raw, **live 2026-07-21**): (a) **create the NEEO account**; (b) download **NEW device support** not already on the device; (c) **firmware recovery**; (d) **config backup**. The FAQ says explicitly you "can root the device at any time, **regardless of the situation with the NEEO cloud**" — rooting is cloud-independent.
- **Likely-cosmetic vs hard blocker (inference, not confirmed):** because `devicespecs` is a *local* endpoint and the cloud is described as adding *new* device support, the **base IR/device database is probably already on-device** in firmware — so a rooted virgin Brain likely ships with a usable code library, and only *new* codes are lost. The **hard blocker** is whatever gates account creation / the `configured` flip at firstboot. **Not documented; unverified.**

### 3. Cloud API captured / mocked? — NO (this is the real gap)
- **Captured:** the Brain's **local** `:3000` API and the **Brain↔Remote** protocol (`:3000` HTTP `guidata_xml`/`gui_xml`, plus UDP `:3201`) are documented, and nklerk built **`FakeBrainTool`** — a Node.js tool "for researching the NEEO TR2 and CP6 communications" (files `http3000.js`, `https.js`, `udp3201.js`, `neeo.xml`). **But that emulates the Brain *toward the Remote*** — the opposite direction from provisioning a virgin Brain. (GitHub repo now **deleted**; recovered via **Wayback 2020-10-14, fetched live 2026-07-21**. Note: `nklerk/root_cp6` and `nklerk/FakeBrainTool` both **404 today** — author removed his NEEO repos; only archives remain.)
- **NOT captured anywhere I could find:** the **Brain→cloud upstream** API (the endpoints the Brain itself calls for account/activation/new-device-DB). No packet capture, no archived spec, no OpenAPI. **No self-hosted / mock NEEO cloud exists** for a Brain to be pointed at (DNS override + local server) to complete *activation* offline. The only redirectable upstream that's been solved is **firmware recovery** (§1), not activation.

### 4. Device database (IR codes) offline — probably on-device, no standalone mirror
- Served locally by the rooted Brain (`/v1/devicespecs/*`), so the **base DB likely lives in firmware**; the encrypted CP6 image even shows `binwalk` MySQL-file signatures (**inconclusive — likely false positives on encrypted bytes; could not verify a real embedded DB**). **New** codes were cloud-only and are now unreachable. I found **no community mirror/export of the full NEEO IR database** as a standalone artefact — it was a curated cloud service ("NEEO built a large database… fast service through their driver team," WebSearch), not a downloadable pack.

### 5. Any in-progress virgin-provisioning / offline-activation attempt — NONE
Every artefact presumes a working or already-activated unit, or runs the wrong direction: **meta / neeo2021onward** (preserve an activated Brain), **NeeoDriversInBrain** (load drivers on a working Brain), **DustBuilder** (add SSH to firmware; "requires an original device"), **FakeBrainTool** (fake a Brain *to the Remote*). **No fork, issue, thread, or archived page documents booting a never-activated Brain to a usable state offline.** Greenfield for the activation-bypass specifically.

### 6. Effort / skill / risk — blunt assessment
- **Skills:** firmware flashing + Arch-ARM sysadmin; **Node.js source RE** (reading/patching the `:3000` app on the rooted rootfs — feasibility depends on whether it's plain JS or bundled/minified, **unknown**); HTTP/mDNS/UDP MITM; likely writing a **mock activation service** the Brain will accept.
- **The plan, if attempted:** (1) DustBuilder-root the virgin Brain via recovery-mode redirect; (2) SSH in, read the firstboot/activation service and the `configured` gate; (3) either **patch the app to stub activation + set `configured:true`** against the on-device device DB, or **stand up a local mock** of the cloud endpoints the Brain calls and DNS-redirect the Brain to it.
- **Two gating unknowns (both undocumented):** (i) does **recovery/root even work on a *never-activated* unit**? DustBuilder requires an *"original"* device, not an *activated* one, and recovery is bootloader-level — so **plausible, but zero documented virgin cases**; (ii) does the Brain app **hard-fail without a live cloud account**, or can the gate be stubbed locally? **Unknown.**
- **Most promising shortcut nobody has documented:** if you can root **any** already-activated donor Brain (borrow/buy a pre-2021 unit), you may be able to **image its `/steady` + config and transplant** onto the virgin one — sidestepping activation entirely. Plausible given root; **unproven.**
- **Probability / effort:** **low-to-moderate**, **weeks of expert effort**, real chance of dead-ending at the activation gate with no oracle to test against. **Nobody is close.** It is **not** "finish someone's work" and it is **not** quite "infeasible" — call it a **hard, unproven solo RE project** whose odds hinge on the base DB being on-device (likely) and the activation gate being locally stubbable (unknown). For a homelab remote, not worth it vs. a €40 Broadlink.

### Sources (this update, fetched/queried live 2026-07-21)
- jac459/NeeoDriversInBrain README (Arch Linux, ext2 `/dev/mmcblk0p2`, `/steady`, node v8, root via DustBuilder) — https://raw.githubusercontent.com/jac459/NeeoDriversInBrain/master/README.md — **verified live**
- DustBuilder for NEEO (OpenSSL-encrypted `0.53.8-20180424` image, injects SSH `neeo`/sudo, "requires an original device", self-hosted patched image) — https://builder.dontvacuum.me/neeo.html — **verified live (HTTP 200)**
- planet.neeo.com "Technical details, CP6 and TR2, Hacking" (nklerk) — recovery `checkforfirmware?server=`/`downloadfirmware?server=`, S3 bucket URL, `binwalk` CP6=OpenSSL/TR2=eCos, full `:3000 /v1` API incl. `activate`/`configured`/`devicespecs`, FakeBrainTool reference — Wayback https://web.archive.org/web/20210613072219/https://planet.neeo.com/t/63nb25/technical-details-cp6-and-tr2-hacking — **fetched live via web.archive.org**
- NEEO recovery firmware S3 bucket **dead** — https://neeo-cp6-recovery.s3.amazonaws.com/firmware_info.txt → **`NoSuchBucket` (HTTP 404), checked live**
- nklerk/FakeBrainTool ("researching NEEO TR2 and CP6 communications"; `http3000.js`,`udp3201.js`,`neeo.xml`) — repo **404 today**; Wayback https://web.archive.org/web/20201014025802/https://github.com/nklerk/FakeBrainTool — **fetched live**
- nklerk/root_cp6 — **404 today** (author removed); Wayback index confirms a 2020-09-14 snapshot existed — archive.org availability API, **checked live**
- FindingNEEO FAQ (cloud = account + new-device support + recovery + backup; "root… regardless of the situation with the NEEO cloud"; FTUE loads info from the Brain) — https://raw.githubusercontent.com/jac459/neeo2021onward/main/FAQ.md — **verified live**

— Athena

---

## Update 2026-07-21b — does the remote need the Brain?

**Question tested (could have flipped RED):** is the Brain required for the remote to work, or can the remote function without the original Brain (e.g. paired to a self-hosted controller)? If the remote didn't need the Brain, the RED verdict — which rests on "a never-activated Brain can't be activated post-cloud-shutdown" — would be moot.

**It does not flip. RED stands, and is reinforced.** The NEEO remote is architecturally a thin client that is useless without a Brain, and no project replaces the Brain.

### 1. Architecture roles — Brain is the controller, remote is a thin client
- **The Brain is the central controller.** It holds the device codes, recipes and config, and does all the actual device control. It "packs an IR blaster and four antennas for communicating with smart home and home entertainment products" ([TechHive](https://www.techhive.com/article/599539/neeo-is-a-sleeker-simpler-universal-smart-home-remote.html), **fetched live 2026-07-21**). It carries Wi-Fi, BLE, Z-Wave, ZigBee, 6LoWPAN and IR.
- **The remote is a Wi-Fi touchscreen with no control hardware of its own.** "The remote pairs to a 'Brain' hub" (TechHive, live). The remote has **no onboard IR transmitter** and cannot drive any device by itself — every command is relayed through the Brain, which fires the IR/RF. (Corroborated across the review/forum corpus via WebSearch; the two independent review pages I tried to fetch for a second live quote returned HTTP 500 and a TLS cert mismatch — **could not verify those two live**, but TechHive live + the FAQ below are sufficient.)
- **The dependency is one-way.** The Brain works without the remote (via the NEEO app) — "In addition to the remote, Neeo will offer an iPhone and Android app" (TechHive, live). The remote does **not** work without the Brain.

**What the remote can do without ANY Brain: nothing useful.** No IR/RF output, no device database, no way to be provisioned. It is a paperweight without a paired, working Brain.

### 2. Does the remote need its own cloud activation, independent of the Brain?
No independent path — and no bypass. The remote is provisioned **by the Brain, locally**: the FindingNEEO recovery procedure states "the remote will pair with the Brain and receive the new wifi-credentials" ([FAQ.md, raw](https://raw.githubusercontent.com/jac459/neeo2021onward/main/FAQ.md), **verified live 2026-07-21**). So the remote's setup chain is **remote → Brain → (dead NEEO cloud)**. The remote has no activation route that skips the Brain; it inherits the Brain's cloud dependency rather than having a separate one.

### 3. PIVOTAL — can meta / a Raspberry Pi act AS the Brain (Brain replacement)? **No — augment only.**
`jac459/meta` (Release branch README, **fetched live 2026-07-21**) lists **"1 Neeo Brain"** under the essential **"Hardware needed"** for setup. meta is a "drivers development and execution platform for neeo remote": it lets custom drivers **run** on a Raspberry Pi / Docker / the Brain, but the **remote still connects to the Brain**, which then reaches the meta drivers on the Pi. The install completes by "go to neeo and search a new device. You should find the meta-core driver" — i.e. you drive it from the NEEO app/remote against an already-activated Brain. The FAQ's own statement that you "can also run it on additional hardware yourself, like a Raspberry Pi" is about **where the drivers execute**, not about the Pi impersonating a Brain to the remote.

**No community project (meta, neeo2021onward, DustBuilder, or anything in the `jac459` tree) emulates or replaces the Brain to the remote.** There is no "brainless" mode, no Pi-as-Brain the remote can pair to, no self-hosted controller the remote talks to instead of a Brain. Every documented path presupposes a present, activated Brain. Replace-the-Brain: **not possible**. Augment-an-existing-Brain: yes, but that requires the Brain first.

### 4. Net effect on OUR user (never-activated remote AND never-activated Brain)
**No viable path.** The remote cannot control anything without a Brain (no IR, thin client), and it can only be provisioned by pairing to a Brain — which for this user is the never-activated, cloud-bricked one. Removing the Brain from the equation doesn't help because the remote then has nothing to talk to and no hardware to control devices. Bringing the Brain into the equation puts you right back on the dead-cloud activation wall from the main report. There is no self-hosted controller substitute the remote will accept.

### Revised verdict: **RED — unchanged (reinforced)**
The remote-vs-Brain angle does not rescue the NEEO. The remote is definitionally dependent on the Brain, and no project replaces the Brain. **Recommendation stands: buy a Broadlink RM4 Pro.**

### Sources (this update)
- NEEO architecture — remote pairs to Brain; Brain holds IR blaster + 4 antennas; Brain usable without remote via app — https://www.techhive.com/article/599539/neeo-is-a-sleeker-simpler-universal-smart-home-remote.html — **fetched live 2026-07-21**
- Remote provisioned by the Brain ("remote will pair with the Brain and receive the new wifi-credentials") — https://raw.githubusercontent.com/jac459/neeo2021onward/main/FAQ.md — **verified live 2026-07-21**
- `jac459/meta` Release README — "1 Neeo Brain" listed under essential "Hardware needed"; meta = driver execution platform, not a Brain replacement — https://raw.githubusercontent.com/jac459/meta/Release/README.md — **verified live 2026-07-21**
- Two secondary review pages attempted for a second independent live quote on "remote is useless without the Brain": allhomerobotics.com (HTTP 500) and universalremoteguide.com (TLS cert mismatch) — **could not verify live**; c4forums standalone thread returned HTTP 403 — **could not verify live**. Corroborated by WebSearch snippets only (not treated as evidence).

— Athena
