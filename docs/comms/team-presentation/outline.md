# Outline — "A house that runs itself (almost)"

**Artefact set**: long-form slide deck (25 slides), short-form deck (5 slides),
interactive HTML scrolly tour.
**Author**: Hermes (comms-engineer)
**Date**: 2026-05-19
**Status**: DRAFT — for review before Apollo hand-off

---

## Audience

Tech-curious non-engineers — Sander's family, neighbours, colleagues from non-technical
departments, hypothetical interviewers from outside the industry. They know what an app
is, they know Wi-Fi, they've heard "the cloud". They have never run a server. They will
be politely patient for about 30 minutes (long deck), 3 minutes (short deck), or 10
minutes of focused scrolling (HTML tour).

---

## One-line takeaway

> **"Every change to our home infrastructure goes through the same review process as code
> at a professional software company — and a team of specialists makes sure nothing
> breaks."**

That is the thing they remember. Not the hardware. Not the specific apps. The *discipline*.

---

## Glossary (plain-language definitions for terms used in the artefacts)

| Term used | Plain-language definition |
|---|---|
| homelab | Private computer cluster — a small data centre in the home rack |
| Kubernetes | The coordination system that runs all our software in sync |
| GitOps | Every configuration change is written down in a shared notebook (Git) before it happens; the system applies it automatically |
| Git | A shared notebook that records every change, who made it, and why — and lets you reverse any of them |
| cluster | A group of computers that act as one |
| node | One physical computer inside the cluster |
| Flux | The robot that reads the notebook and keeps the cluster in sync with it |
| HelmRelease | A recipe for installing one application |
| pod | One running copy of an application inside the cluster |
| Talos | The operating system on each node — stripped down, no password logins, managed entirely by code |
| Cilium | The traffic cop inside the cluster — decides which computers can talk to which |
| Rook-Ceph | The cluster's shared hard-drive pool — data is spread across three physical drives so one failing loses nothing |
| Home Assistant | The home automation brain — connects lights, sensors, heating, EV charger, and over 200 other devices |
| Zigbee / Z-Wave | Short-range wireless protocols that smart-home sensors and switches use to talk to each other |
| MQTT | A lightweight message bus — sensors shout their readings onto it, and whoever cares listens |
| Envoy Gateway | The front door of the cluster — decides who gets let in from the internet and who only gets LAN access |
| Cloudflare | An internet infrastructure company that handles the public DNS and tunnels traffic safely to the house |
| cert-manager | Automatically renews the HTTPS security certificates (the padlock in the browser) |
| ExternalSecrets / 1Password | Passwords and API keys live in 1Password; the cluster fetches them automatically — they never sit in a config file |
| VolSync | Automatic hourly backups of application data to a local S3 store and then to Azure offsite |
| CNPG | CloudNativePG — a managed PostgreSQL database operator; runs the home-assistant database and others |
| Prometheus / Grafana | Prometheus collects metrics (numbers over time); Grafana draws charts from them |
| Loki | Collects log messages from every part of the system |
| evcc | EV charge controller — decides when to charge the car cheapest, ideally from our own solar |
| change record | A logged entry for every deliberate change: what, who, when, why, what could go wrong, and how to undo it |
| risk tier | Low / medium / high — determines how much review a change needs before it executes |
| QA gate | Automated checks that run before any medium or high change goes ahead |
| ADR | Architecture Decision Record — a short document that explains *why* we made a particular design choice |

---

## Anti-scope

These artefacts do NOT cover:
- Internal network security posture details (attack surface, firewall rules, VLAN topology)
- Incident war stories or past outages
- Specific cost numbers for hardware or cloud services
- Technical implementation details (YAML syntax, CRD schemas, Helm values)
- Comparisons with cloud provider pricing or enterprise tooling
- Anything that requires a GitHub account or command-line access to follow

---

## Long-deck section list (25 slides)

### Opening act (slides 1–4)
1. **Title** — Sets the stage; establishes a warm, confident tone
2. **The problem in one picture** — A modern home is 60+ software components; most people have a 3-person household and zero dedicated IT staff
3. **What happens without discipline** — Not an incident story; a hypothetical: "what if we treated our home network like most people treat their laptops?" (updates whenever, no backups, no change history)
4. **The principle** — One sentence: we treat home infrastructure like a small production system

### The team (slides 5–8)
5. **Meet the team** — Overview slide: 11 specialists, all named after Greek deities, each with one job
6. **Ensemble portrait — the engineers** — Four highlighted specialists with colour + voice
7. **Ensemble portrait — the guardians** — Themis (QA), Argus (security), Pan (pentest) — the "no" people
8. **Ensemble portrait — the builders** — Daedalus, Athena, Hermes, Apollo — the design + comms layer

### The stack, briefly (slides 9–12)
9. **The hardware** — 6 small computers in the home rack: 3 controllers, 3 workers; plus the router, the NAS, the Pi
10. **The operating system** — Talos: no password login, no SSH, every change via code; "if the OS can't be hacked through the keyboard, it's a lot harder to hack at all"
11. **What runs on it** — Home Assistant (the brain), plus 60+ supporting apps from database to media server to EV charger
12. **The shared notebook (GitOps)** — Everything described in code; pushed to Git; robot applies it. "If a computer dies tonight, we restore from the same notebook"

### The change rituals (slides 13–16)
13. **One change, from request to evidence** — The lifecycle in one diagram: request → plan → QA → execute → evidence → close
14. **The risk dial** — Low (auto, just log it) / medium (QA must pass) / high (user must approve, then QA, then execute)
15. **Who approves what** — Low: the engineer. Medium: Themis (QA gate). High: Sander (the human). Critical safety: ADR on file.
16. **The no-smart-plugs rule** — ADR-0003: after one hard-learned lesson, family-critical infrastructure never runs through a smart plug. "The rule is four words: unplug it from there."

### What it enables (slides 17–21)
17. **Energy intelligence** — Solar surplus charges the car; grid tariff awareness shifts charging to the cheapest hour; live dashboard shows the numbers
18. **Garden that waters itself** — Soil sensors in three spots; if moisture is above threshold or rain is forecast, the valve stays shut
19. **Room-by-room awareness** — Presence sensors, occupancy-linked heating, motion-linked lights; the house adjusts to where people actually are
20. **The family dashboard** — Kitchen tablet, the one glance that tells you: who's home, what the heating is doing, whether the car is charging
21. **Daily health report** — Every morning at 06:00 a report lands: are all six nodes healthy, is storage looking OK, did backups run, are any certificates about to expire

### Where it goes next (slides 22–24)
22. **Network upgrade** — Moving from Layer 2 ("who's shouting loudest") to BGP routing ("everyone knows the full map"); proper VLAN segmentation for IoT, servers, clients
23. **The ops portal** — One web page that shows the live topology — every device, every service, every health indicator — in plain colour: green, yellow, red
24. **IPv6 and the future** — The Dutch internet is IPv6-native; when Cilium's known issue is fixed, this cluster will get a /48 prefix and run dual-stack natively

### Close (slide 25)
25. **The one thing** — "A home where every change is deliberate, recorded, reversible — and reviewed by someone whose only job is to say no when it isn't ready."

---

## Short-deck slide list (5 slides)

1. **The setup** — "Our house has 60+ software components coordinating round the clock. This is how we keep them from chaos."
2. **The team** — 11 specialists, one principle: nobody executes a change without a plan and a QA check.
3. **The stack in one sentence** — Six computers, one home automation brain, sixty apps, all described in a shared notebook that a robot reads and applies.
4. **One example: the car charger** — Solar surplus and live grid prices combine to decide *when* the car charges. The system does this without a single manual action.
5. **The one thing** — "Every change is deliberate, recorded, reversible — and reviewed before it runs."

---

## Scrolly tour section list (6 scroll-stops)

### Stop 1: "The living room you don't see"
**Headline**: Behind the light switch is a small data centre.
**Body**: What visitors see is a tidy house. What runs underneath is a cluster of six computers, twenty-odd smart devices, and over sixty software applications keeping everything coordinated. This tour walks through how it works.
**Image needed**: Wide-angle photo of the home rack / hardware — small, domestic, not a server room.

### Stop 2: "One notebook. One truth."
**Headline**: Every configuration lives in a shared notebook. The robot applies it.
**Body**: Nothing in this system is configured manually. Every setting, every app, every routing rule is written down in a version-controlled repository (think: a document with infinite undo history). A piece of software called Flux reads that repository and makes sure the cluster always matches it. If a computer dies and is replaced, restoring the exact configuration takes a single command.
**Image needed**: Screenshot of the Git repository's file tree showing `kubernetes/main/apps/` with a few named apps visible. Viewport 1920×1080, dark theme.
**Interactive**: A "compare then/now" toggle between a raw YAML snippet and a plain-English translation of what it says.

### Stop 3: "The team of eleven"
**Headline**: Eleven specialists, each with one job, each named after a Greek deity.
**Body**: Atlas coordinates. Hestia owns the home automation system. Iris manages the network. Hephaestus runs the cluster. Themis is the QA gate — her job is to say no when something isn't ready. Argus spots security issues. Pan probes for weaknesses. Daedalus designs. Athena researches. Apollo builds the interfaces. Hermes explains it all. No change leaves one engineer's desk without at least one other checking it.
**Image needed**: A visual grid of eleven deity cards — name, role, one-line job description. Apollo builds this.
**Interactive**: Hover/click each deity card for their "one rule they never break".

### Stop 4: "A change in the life of the house"
**Headline**: Request. Plan. Check. Execute. Evidence. Close.
**Body**: Want to add a new automation? It starts as a change record: what are you changing, what's the risk, what's the rollback plan? Themis runs the checks. If it's medium risk, she has to pass it. If it's high risk — anything touching authentication, the firewall, or storage — Sander approves it first. After execution, evidence goes on record (a screenshot, a log excerpt, a test result). The change closes. The history is permanent.
**Image needed**: A clean flow diagram: six boxes in a horizontal chain (Request → Plan → QA Check → Execute → Evidence → Close), with a risk dial graphic on the side.
**Interactive**: None needed; diagram does the work.

### Stop 5: "What this enables"
**Headline**: The house knows where people are, what the sun is doing, and how cheap the electricity is right now.
**Body**: Three soil sensors in the garden decide whether the irrigation valve opens today. The car charger waits for solar surplus or the cheapest grid hour. Room temperatures follow occupancy rather than a fixed schedule. The kitchen tablet shows one screen: who's home, is the car charging, what's the heating doing. Every morning at 6 a.m. a health report confirms nothing broke overnight.
**Image needed**: Composite screenshot — kitchen dashboard on a Pixel Tablet (portrait), and evcc EV charging screen. Viewport appropriate to each.
**Screenshot source**: HA dashboard at https://home.bluejungle.net — kitchen view; evcc at https://evcc.bluejungle.net. Both LAN-only, need Sander's credentials.

### Stop 6: "What comes next"
**Headline**: The roadmap is already written.
**Body**: Three active projects define where this is going. First: proper network segmentation — servers on their own network, IoT devices on another, with BGP routing between them. Second: a live topology portal where any household member can see at a glance whether everything is healthy. Third: full IPv6 dual-stack, as soon as an upstream software bug is resolved upstream. The notebook already has the entries; the team is working through them in order.
**Image needed**: Screenshot of the health portal at https://health.bluejungle.net (the existing cluster-health site), viewport 1920×1080.

---

## Technical sanity-check: load-bearing claims

| Claim | Source |
|---|---|
| "60+ software components" | CMDB has 66 named entries (`ops/cmdb.yaml`, `grep -c "^  [a-z]"` = 66) |
| "6 computers in the cluster (3 CP + 3 worker)" | `CLAUDE.md` memory, `ops/cmdb.yaml` k8s.node.* entries |
| "11 specialists" | `ops/roster.md` — 11 rows in the team table |
| "7 critical PVCs backed up hourly" | `memory/project_backup_plan.md` — lists all 7 by name |
| "Every morning at 06:00 a health report" | `memory/project_health_report.md` — CronJob at 06:00 |
| "Family-critical infra never through a smart plug" | `docs/adr/0003-no-critical-infra-on-smart-plugs.md` |
| "Solar + grid tariff charger control" | `memory/project_evcc.md` — evcc live at https://evcc.bluejungle.net |
| "3 soil sensors in the garden" | `memory/project_smart_irrigation.md` — three named sensors |
| "BGP migration ready on a branch" | `memory/project_bgp_ipv6_roadmap.md` — feat/bgp-migration branch |
