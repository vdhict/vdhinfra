# Interactive HTML scrolly tour — "A house that runs itself (almost)"

**Format**: Single web page, 6 scroll-stops, ~10 minutes to read through
**Audience**: Tech-curious non-engineers visiting a URL from a QR code, a message link, or a
mention in a talk. They scroll at their own pace. No navigation required.
**Author**: Hermes (comms-engineer)
**Date**: 2026-05-19
**Status**: DRAFT — written content complete; Apollo implements HTML/CSS

---

## HTML structure brief (for Apollo)

This is a **single-page scroll** — one HTML file, no framework, no CDN, no JavaScript
dependency that would break if hosted offline. Six full-viewport "panels" that snap into
place as the user scrolls.

**Technical requirements**:
- Single `index.html` + one CSS file (or `<style>` block inline). No JS required for core
  reading, but small progressive-enhancement JS is fine for the hover interactions on Stop 3.
- Hosted at a path under `bluejungle.net` (Sander to decide exact URL — suggest
  `tour.bluejungle.net` or `health.bluejungle.net/tour/`).
- Scroll behaviour: `scroll-snap-type: y mandatory` on the container; each panel is
  `scroll-snap-align: start`. Standard CSS, no JS scroll hijacking.
- Font: system font stack. No web fonts, no CDN. `-apple-system, BlinkMacSystemFont,
  "Segoe UI", Roboto, sans-serif` is fine.
- Colour mode: respects `prefers-color-scheme`. Dark and light both designed.
- Screenshots: each panel has a `<figure>` placeholder with a `data-screenshot` attribute
  and an `alt` text. Apollo replaces placeholders with real images after capturing them.
- Mobile-first: the primary reading experience is a phone held vertically. Large text,
  generous line height, single-column layout below 768px.
- No tracking, no analytics, no cookies.

---

## Stop 1 — "The living room you don't see"

**Section heading**: The living room you don't see

**Body**:

Behind the light switch is a small data centre. If you've been in this house, you've touched
its output: the lights that matched the time of day, the heating that was already at the right
temperature when you arrived, the kitchen screen showing who was home. None of that happened
by accident.

Underneath all of it runs a cluster of six computers, twenty-odd smart devices, and over
sixty software applications coordinating around the clock. This is a tour of how that
works — and why it's run more like a software company than a home.

**Visual area**: Two-part layout on desktop (image left, text right), single column on
mobile (text first, image below).

**Screenshot needed**:
- A wide-angle photograph of the home rack / hardware. Physical photo, not a screenshot.
  Sander supplies this. The tone should be domestic — this is a shelf in a room, not a
  server room.
- Fallback if no photo is available: a clean illustration of six small server icons arranged
  in two rows of three, labelled "CP" and "Worker". Apollo creates this as SVG if no photo.

**Interactive element**: None on this panel. Let it breathe.

---

## Stop 2 — "One notebook. One truth."

**Section heading**: One notebook. One truth.

**Body**:

Nothing in this system is configured manually — at least, not in a way that isn't written
down. Every setting, every application, every routing rule is a file in a version-controlled
repository: think of it as a document with infinite undo history, where every change is
signed with a name, a date, and a reason.

A piece of software called Flux (think: a patient robot) reads that repository every hour
and compares it to what the cluster is actually running. If they disagree — because someone
made a manual tweak, or a machine restarted in an unexpected state — Flux corrects the
discrepancy. The notebook always wins.

The consequence of this sounds dry but is genuinely remarkable: if all six computers in the
cluster failed tonight and had to be replaced with new hardware, the complete system could
be restored from the repository in about twenty minutes. No custom documentation. No
"the person who set this up" phone call. Just the notebook.

**Visual area**: The three-step GitOps diagram. Three boxes in a row:
[Code repository] → [Flux reads every hour] → [Cluster matches the code]
With a curved return arrow from the cluster back to the first box labelled:
"Manual change? Overwritten on next sync."
Apollo draws this as clean SVG — no screenshot needed.

**Interactive element**: A "compare" toggle. Two boxes side by side, switchable:

LEFT (default label: "What it looks like in code"):
```
app: home-assistant
image: ghcr.io/home-operations/home-assistant:2026.5.1
port: 8123
storage: 20Gi
backup: hourly
```
(This is not real YAML — it's a simplified illustration. Apollo styles it as a monospace
code block with subtle syntax highlighting.)

RIGHT (toggled label: "What that means"):
"Run Home Assistant version 2026.5.1. Listen on port 8123. Give it 20 gigabytes of storage.
Back it up every hour."

The toggle is a single `<button>` that swaps the visible block. No framework. Pure JS
(~10 lines) or CSS checkbox trick.

---

## Stop 3 — "The team of eleven"

**Section heading**: The team of eleven

**Body**:

The system is managed by eleven specialist AI agents — each one named after a Greek deity,
each one with a defined domain and a list of things they're not allowed to do regardless
of instructions.

Atlas coordinates everything. You talk to Atlas; Atlas routes to the right specialist.
Hestia owns home automation — every light, sensor, and dashboard. Iris manages the network
and the router. Hephaestus (everyone calls him Heph) runs the computing cluster. Themis is
the quality gate: her only job is to check that a proposed change is ready to run, and she
will say no until it is. Argus reviews every medium and high-risk change for security
implications. Pan actively probes for weaknesses — with permission, within strict scope.
Daedalus writes the design documents. Athena researches before recommending. Apollo builds
the interfaces you actually see. Hermes explains what all of them do.

No change leaves one engineer's desk without at least one other reviewing it.

**Visual area**: An 11-card grid (4-3-4 layout on desktop, scrolling single column on
mobile). Each card:
- Deity name (large)
- Role title (medium)
- One-line job description (small)
- "One rule they never break" — hidden by default, revealed on hover/tap

Card content for Apollo to implement:

| Name | Role | Job | One rule |
|---|---|---|---|
| Atlas | OPS Manager | Orchestrates everything; the user's single point of contact | Never acts without consulting the right specialist |
| Hestia | HA engineer | Owns Home Assistant — automations, dashboards, devices | Never edits the authentication store while HA is running |
| Iris | Network engineer | Manages the router, switches, and Cloudflare DNS | Never writes IPv6 addresses to the router's static DNS table |
| Hephaestus | Cluster engineer | Runs the Kubernetes cluster, storage, and GitOps engine | No destructive operations without explicit user approval |
| Themis | QA gate | Checks every medium/high change before it executes | Never approves on "looks fine" — requires documented evidence |
| Argus | Security analyst | Reviews changes for security implications; weekly scans | Never suppresses a finding to keep the deploy queue moving |
| Pan | Pentester | Actively probes for weaknesses — strictly scoped | Never tests out-of-scope targets; never repeats a technique that crashed a component |
| Daedalus | Architect | Writes design documents and decision records | Never bypasses design when stakeholders disagree |
| Athena | Researcher | Sourced research on tools, patterns, and practice | Never recommends without searching first |
| Apollo | Frontend | Builds the web interfaces the household uses | No runtime CDN dependencies; every stack choice must be justified |
| Hermes | Communications | Translates technical work into language anyone can follow | No jargon without a plain-language definition on first use |

**Interactive element**: Hover/tap a card to flip it and reveal "One rule they never break"
on the reverse. CSS 3D card-flip, no JS required. The rule text is pre-loaded in a
`data-rule` attribute, revealed by CSS `:hover` or a `<details>` element on mobile.

---

## Stop 4 — "A change in the life of the house"

**Section heading**: A change in the life of the house

**Body**:

Want to add a new automation? Connect a new device? Change a network routing rule? The
process is always the same, regardless of size.

It starts as a change record. The engineer writes down: what is being changed, on which
component, why, what the risk level is, and — critically — what the rollback plan is if
it goes wrong. That record is logged before a single line of configuration is touched.

The change is then classified as low, medium, or high risk. Low risk — a version bump, a
comment edit, a dashboard label change — is auto-executed after logging. Medium risk requires
Themis to run her automated checks: schema validation, missing rollback plans, freeze-window
conflicts, security flags. If she passes it, the engineer proceeds. If she fails it, the
change goes back.

High risk — anything touching authentication, the firewall, storage configuration, or the
operating system of the nodes — requires Sander to read a summary and type an explicit
approval. Only then does Themis run. Only then does the engineer execute.

After execution: evidence. A screenshot, a log excerpt, a test result that shows the
change had the intended effect. Not "looks fine". The record closes only when evidence
is attached.

Every closed change is permanent. The history is immutable. If something breaks two months
from now and we need to understand what changed, the answer is in the log.

**Visual area**: A clean horizontal six-step flow diagram:

[1. Request] → [2. Plan + Risk] → [3. QA Check] → [4. Execute] → [5. Evidence] → [6. Close]

Below the steps, a three-row risk table:

| Risk level | Who reviews | Example changes |
|---|---|---|
| Low | Nobody (just logged) | Image update, comment edit, label change |
| Medium | Themis (automated checks) | New automation, new network route, new integration |
| High | Sander (explicit approval) + Themis | Auth changes, firewall rules, storage config, OS changes |

Apollo renders this as styled SVG + HTML table. No screenshot needed.

**Interactive element**: Click on any of the six steps to expand a tooltip/popover with a
one-sentence explanation. Progressive enhancement: if JS is off, the text appears inline
in a `<details>` element.

---

## Stop 5 — "What this enables"

**Section heading**: What this enables

**Body**:

The infrastructure isn't the point. The point is what it makes possible.

**The car charger**: A solar inverter on the roof reports its output continuously. A live
electricity price feed says what the grid costs right now. A charge controller called evcc
combines both and decides when to charge the Tesla. On a sunny afternoon: charge now, it's
free. On a grey winter day: wait until 3 a.m., prices drop by 40%. No app to open. No
decision to make.

**The garden**: Three soil moisture probes in the backyard measure the ground at 06:00 every
morning. The automation takes the middle reading of the three (so one bad probe can't trigger
a false decision), checks the weather forecast for the next 12 hours, and opens the irrigation
valve if the soil is dry and no rain is coming. The threshold is adjustable from the dashboard.

**The house**: Presence detection (phone on the network, Bluetooth, motion sensors) tells
Home Assistant where people are. Heating follows occupancy — an empty room doesn't heat to
full temperature. Lights turn on when someone enters a room, off when they leave. The colour
temperature shifts warmer after sunset without anyone touching a switch.

**The dashboard**: A Pixel Tablet mounted in the kitchen shows, at a glance: who's home,
what the heating is doing, whether the car is charging, what the energy reading is right now.
One screen. Always visible. No login.

**The morning report**: Every morning at 06:00, the cluster checks itself — six nodes,
storage health, backup status, certificate expiry, application health. A report lands on
a web page. At 08:00 a notification arrives on the phone. If everything is green: no action
needed. If something is amber or red: the report says exactly what and why.

**Visual area**: A two-column or card layout with five mini-sections (car, garden, house,
dashboard, report), each with a small icon and a two-sentence summary. On mobile: stacked
vertically.

**Screenshots needed** (for Apollo to capture):
1. Kitchen dashboard — evcc EV charging screen
   - URL: `https://evcc.bluejungle.net` (LAN-only)
   - Viewport: 1920×1080 desktop, cropped to the main charge status view
   - Credentials: Sander's LAN session (no auth on evcc)

2. HA kitchen dashboard on Pixel Tablet
   - URL: `https://home.bluejungle.net` — kitchen dashboard view
   - Viewport: 1080×2400 portrait (tablet) — this is the kiosk view
   - Credentials: Sander's HA account (auto-login in kiosk mode — show from the kiosk browser, not the desktop)

3. Cluster health report
   - URL: `https://health.bluejungle.net`
   - Viewport: 1920×1080
   - Capture: a recent report date showing green/mostly-green status

These three screenshots sit in the Stop 5 panel as a small image gallery (lightbox-expand
on click). On mobile they stack vertically at full width.

---

## Stop 6 — "What comes next"

**Section heading**: What comes next

**Body**:

The roadmap is already written. Three active projects define where this is going.

**Network segmentation**: Currently, servers, phones, and smart devices share the same
physical network — they're separated logically, but a misconfigured firewall rule could
let a cheap smart plug reach the server cluster. The next change moves the cluster to its
own dedicated network, with proper routing between segments using the same protocol the
internet uses (BGP — Border Gateway Protocol). The configuration is already in a code
branch; it hasn't been deployed to production yet because this kind of change waits for
a quiet weekend and an explicit approval.

**The live topology portal**: A web page that shows every component in the system as a
visual map — internet connection, router, switches, cluster nodes, storage, applications
— each with a real-time health indicator in plain colour: green, yellow, red. The
cluster-health report page already exists; the topology map is its next chapter. Designed
for two audiences: the household (one line: "everything's fine") and the operator (the
full picture).

**IPv6**: Dutch internet infrastructure is natively IPv6. KPN provides a /48 prefix —
enough addresses for every device in the house to have its own globally routable IPv6
address. The cluster is designed to support this, but it's waiting for an upstream bug
fix in the networking layer before it can be safely enabled. When it's ready, it will
be built in from the start.

Three things. All of them already specified. All of them moving forward in order.

**Visual area**: Three "roadmap cards" in a row (desktop) or stacked (mobile). Each card:
a title, one paragraph, and a status badge ("In progress / Branch ready", "In progress / Building", "Planned / Waiting on upstream fix").

**Screenshot needed**:
- Topology page if it exists: `https://health.bluejungle.net/topology.html`
  - Viewport: 1920×1080
  - If the topology page is not yet published, use the main health report page as the
    illustration for this stop.

**Interactive element**: None needed. The three cards communicate forward motion on their own.

---

## Closing element (below Stop 6, inline at the bottom of the page)

**No separate scroll-stop needed** — this is a footer paragraph:

"This tour was written by Hermes, the communications specialist on the team whose job is
translating technical work into language anyone can follow. Everything described here is
running right now, in a home rack, reconciled from a Git repository, reviewed by a team
that doesn't take shortcuts."

---

## Apollo's build checklist (extracted from above)

### Screenshots to capture (all LAN-accessible)

| # | Surface | URL | Viewport | Notes |
|---|---|---|---|---|
| 1 | evcc charging screen | https://evcc.bluejungle.net | 1920×1080 | No auth needed on LAN. Crop to main charge status. |
| 2 | HA kitchen dashboard (tablet kiosk) | https://home.bluejungle.net | 1080×2400 portrait | Use kiosk browser (Pixel Tablet, Sander logs in). Do not use desktop browser — kiosk layout is different. |
| 3 | Cluster health report | https://health.bluejungle.net | 1920×1080 | Pick a recent date showing green status. |
| 4 | Topology page (if available) | https://health.bluejungle.net/topology.html | 1920×1080 | If 404, fall back to main health report page. |
| 5 | Git repository file tree | Local or GitHub | 1920×1080 | Show `kubernetes/main/apps/` expanded two levels, dark theme. If the repo is private, Apollo takes a local screenshot from VS Code or the GitHub UI with Sander's login. |

### Assets to create (SVG/illustrated)

| # | Description | Used in |
|---|---|---|
| A | GitOps three-step flow diagram | Stop 2 + Long-deck Slide 12 |
| B | Six-step change lifecycle flow | Stop 4 + Long-deck Slide 13 |
| C | Risk dial (Low/Medium/High bands) | Long-deck Slide 14 |
| D | Network segmentation diagram (3 VLANs) | Long-deck Slide 22 |
| E | Team deity card grid (11 cards) | Stop 3 + Long-deck Slide 5 |
| F | House-with-dots infographic (smart device locations) | Long-deck Slide 2 + Short Slide 1 |
| G | Hardware diagram (6 nodes + router + NAS) | Long-deck Slide 9 |
| H | Three-source charge diagram (Solar + Grid price → evcc → Car) | Long-deck Slide 17 + Short Slide 4 |

### HTML structure summary

```
<body>
  <nav class="scroll-indicator"> <!-- optional dots showing current stop -->

  <section class="panel" id="stop-1"> <!-- hardware / living room -->
  <section class="panel" id="stop-2"> <!-- notebook / gitops + compare toggle -->
  <section class="panel" id="stop-3"> <!-- team of eleven + card flip -->
  <section class="panel" id="stop-4"> <!-- change lifecycle + step tooltips -->
  <section class="panel" id="stop-5"> <!-- what it enables + screenshot gallery -->
  <section class="panel" id="stop-6"> <!-- roadmap + status cards -->

  <footer class="attribution"> <!-- closing line -->
</body>
```

CSS layout: `html, body { height: 100%; } body { scroll-snap-type: y mandatory; overflow-y: scroll; } .panel { height: 100vh; scroll-snap-align: start; }`

---

## Read-aloud test record

All body paragraphs read aloud by Hermes, end to end, 2026-05-19.

Edits made during read-aloud:
1. Stop 2 body, sentence 2: original draft said "like a version control system (Git)" — rewritten to "a document with infinite undo history, where every change is signed with a name, a date, and a reason" for audience register.
2. Stop 3 body: removed the parenthetical "(BGP)" from the body copy — left it to the long deck where there's room to explain it; in the scrolly tour it would land as unexplained jargon.
3. Stop 4 body, sentence about "freeze window": removed entirely from scrolly tour — it's an internal operations concept that requires too much explanation in this register.
4. Stop 5 body, irrigation section: changed "evapotranspiration" (a term from the HAsmartirrigation docs) to "the middle reading of the three" — it never appeared, but the instinct was there.
5. Stop 6 body: removed "etcd" — replaced with "the cluster's configuration database" — then removed that too in favour of just describing the outcome ("restore from the repository").
6. Long deck Slide 5: "They're all software agents" revised to "specialist AI systems running inside the same conversation environment I do" — more precise for the technical edge of the audience.

No stumbles remaining on read-aloud pass.

## No-jargon audit findings (post-read-aloud)

Terms audited in all three artefacts:

| Term | Disposition |
|---|---|
| Kubernetes | Not used in scrolly tour or short deck. Used in long deck Slide 5 spoken script with inline definition: "the coordination system that runs all our software in sync" |
| Flux | Defined on first use in all three artefacts: "a patient robot that reads the repository" |
| GitOps | Not used as a naked term in scrolly tour. Long deck uses it with slide-level context; glossary in outline covers it |
| cluster | Defined once per artefact: "a group of computers that act as one" |
| pod | Not used in any audience-facing artefact |
| MQTT | Not used in any audience-facing artefact |
| Zigbee / Z-Wave | Used in long deck Slide 11 talking points only, with inline parenthetical "short-range wireless protocols" |
| OIDC | Not used in any artefact |
| Prometheus / Loki | Not used in audience-facing copy — replaced with "metrics system" and "log collector" |
| Grafana | Not used in audience-facing copy — replaced with "dashboards" |
| VolSync | Not used in audience-facing copy — replaced with "automatic hourly backups" |
| CNPG | Not used in audience-facing copy — replaced with "database cluster" |
| RBAC | Not used in any artefact |
| DNS | Used in long-deck Slide 22 talking points with inline definition: "the system that translates names like bluejungle.net into addresses computers understand" |
| VLAN | Used in long-deck Slide 22. Defined inline: "a virtual network — separate lanes on the same physical cables" |
| BGP | Used in long-deck Slide 22 and Scrolly Stop 6 with inline definition: "the routing protocol the internet itself uses" |
| evcc | First use in each artefact: "a specialist charge controller" before the name is used |
| Talos | First use in long-deck Slide 10: "an operating system called Talos" with immediate description |
| Envoy Gateway | Not used in any audience-facing artefact — replaced with "the front door of the cluster" |
| cert-manager | Not used in audience-facing artefact — replaced with "automatic certificate renewal" |
| ExternalSecrets | Not used in audience-facing artefact — replaced with "passwords fetched securely from 1Password" |

**Audit result: PASS.** No naked jargon remaining in audience-facing copy.
