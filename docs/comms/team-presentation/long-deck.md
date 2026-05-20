# Long-form slide deck — "A house that runs itself (almost)"

**Format**: 25 slides for a 30-minute talk
**Audience**: Tech-curious non-engineers
**Author**: Hermes (comms-engineer)
**Date**: 2026-05-19
**Status**: DRAFT

---

## Slide 1 — Title

**Title**: A house that runs itself (almost)

**Headline**: How one household turned home infrastructure into a properly managed system

**Talking points**:
- No bullets on this slide. Title + subtitle + one image only.

**Image need**: A warm, slightly editorial photograph — the kitchen tablet mounted on the wall, softly lit. Pixel Tablet with dashboard visible. Communicates: this is a real house, not a lab.

**Spoken script**:
"Most people manage their home Wi-Fi by rebooting the router and hoping for the best. I do something a little different. Let me show you what that looks like — and why it matters."

---

## Slide 2 — The scale of a modern home

**Title**: Your house is already a data centre

**Headline**: A typical connected household runs 60+ pieces of software simultaneously

**Talking points**:
- Lights that run firmware. Heating that connects to the cloud. A router with a 50-page settings menu.
- Add a smart doorbell, an EV charger, a solar inverter, a media server, and a security camera: you are now operating a small IT estate.
- Most of this runs with no oversight, no backup, no change history.

**Image need**: A simple infographic — silhouette of a house with labelled dots at each smart-device location (doorbell, thermostat, sockets, tablet, EV charger, router). Not a product ad — abstract.

**Spoken script**:
"I counted the number of distinct software components coordinating in our house. We have 66 in the current inventory. Most households don't think of it that way — but the complexity is there whether you name it or not. And unnamed complexity has a way of biting you at the worst moment."

---

## Slide 3 — The alternative

**Title**: What it looks like without discipline

**Headline**: "Works on my machine" — until it doesn't

**Talking points**:
- Manual changes: nobody knows what was done two months ago when something breaks.
- No backups: a failing hard drive takes five years of automations with it.
- No change review: one wrong setting takes down the whole house at 2 a.m.
- This is the norm, not the exception, for home setups.

**Image need**: A clean two-column contrast graphic — "unmanaged" (scattered boxes, arrows pointing everywhere, question marks) vs "managed" (same boxes, ordered, arrows labelled). Keep it abstract — no logos, no real brand names.

**Spoken script**:
"This is not about what went wrong. It's about what *would* go wrong if we didn't treat this seriously. The honest answer is: the same things that go wrong in poorly-run IT departments. Untracked changes. No rollback. No one who knows why a decision was made."

---

## Slide 4 — The principle

**Title**: One principle

**Headline**: Treat home infrastructure like a small production system

**Talking points**:
- Every change is intentional.
- Every change is recorded.
- Every change is reversible.
- A team of specialists makes sure it stays that way.

**Image need**: Typography slide — the four bullet points rendered large, one per line, with generous white space. No decoration.

**Spoken script**:
"That's it. That's the whole philosophy. It sounds obvious when you say it out loud. The interesting part is what it takes to actually do it."

---

## Slide 5 — The team overview

**Title**: The team

**Headline**: Eleven specialists. One mandate each. All named after Greek deities.

**Talking points**:
- Atlas (me): the operations manager. The user talks to Atlas; Atlas routes to specialists.
- Five engineers: home automation, networking, cluster, design, research.
- Two guardians: QA gate, security analyst.
- One adversary (on our side): the pentester.
- Two communicators: frontend designer and me, Hermes.
- No one executes without a plan. No plan runs without a review.

**Image need**: A clean team grid — 11 deity icons or stylised portrait cards with name + one-line role. Apollo designs the visual; I'm providing the content. Suggested layout: 4×3 grid with one empty cell or 3 rows of 3/4/4.

**Spoken script**:
"This is the team. They're all software agents — specialist AI systems running inside the same conversation environment I do. But they have distinct roles, distinct authorities, and distinct things they're not allowed to do. Hephaestus will not delete a storage volume without your explicit sign-off. Themis will not approve a change she hasn't checked. The rules are written down."

---

## Slide 6 — The engineers

**Title**: The engineers

**Headline**: Each one owns a domain and refuses to touch anyone else's without asking

**Talking points**:
- **Hestia** — Home Assistant: automations, dashboards, kiosks, integrations. Warm and careful. Her rule: never edit the authentication store while the system is running.
- **Iris** — Network: the UDM Pro router, UniFi switches, Cloudflare DNS. Precise. Her rule: never write AAAA records to the static DNS table (a hard-learned lesson from a router crash).
- **Hephaestus (Heph)** — The cluster: the computing infrastructure, storage, certificates, and the automated reconciliation loop that keeps the cluster in sync with the notebook. His rule: no destructive operations without an explicit approval from Sander.
- **Sibyl** — Observability: dashboards, metrics, alerting. Her rule: never add a panel that can't answer one clear question in plain English.

**Image need**: Four larger deity cards, each with a one-sentence job description and their "one rule". Portrait orientation cards, visual emphasis on the rule.

**Spoken script**:
"Notice the rules. They're not 'do your best'. They're specific, verifiable commitments. Iris won't write AAAA records to the router's DNS table — not because she doesn't know how, but because we found out that doing so crashed the router. The rule encodes the lesson."

---

## Slide 7 — The guardians

**Title**: The people who say no

**Headline**: A change doesn't run until someone whose job is checking it says it's ready

**Talking points**:
- **Themis** — QA gate: runs automated lint checks, schema validation, freeze checks, rollback verification. She approves medium-risk changes; she never approves on "looks fine".
- **Argus** — Security analyst: every medium and high-risk change gets a security review. His rule: never suppress a finding to keep the deploy queue moving.
- **Pan** — Pentester: probes the system for weaknesses, active attacks on our own infrastructure. Strictly scoped — he only tests what's been pre-approved, and he never uses a technique that previously crashed a component.

**Image need**: Three deity cards. Themis should look principled (scales motif is fine). Argus should look watchful. Pan should look mischievous but bounded.

**Spoken script**:
"These three exist specifically to catch what the engineers miss. Themis's automated checks catch structural mistakes — the wrong schema, a missing rollback plan, a change filed during a freeze window. Argus catches security implications. Pan actively tries to break in, with permission, so we find the gaps before someone else does."

---

## Slide 8 — The builders

**Title**: The design and communications layer

**Headline**: Four specialists who work upstream of implementation

**Talking points**:
- **Daedalus** — Architecture: writes design documents and decision records, never touches production. His rule: no bypassing design when stakeholders disagree.
- **Athena** — Research: sourced research on tools, patterns, industry practice. Two pages maximum. Her rule: no recommendations without searching first.
- **Apollo** — Frontend: builds the web interfaces the household actually uses. His rules: no runtime CDN dependencies, no tracking, no framework adopted without justification.
- **Hermes** — Communications: translates the team's work into language anyone can follow. My rule: no jargon without a plain-language definition on first use.

**Image need**: Four deity cards, same format as slides 6 and 7.

**Spoken script**:
"The reason I can stand here and explain this to you in plain language is that this is literally my job. Hermes: the messenger between worlds. Every technical decision this team makes goes through a translation layer before it reaches anyone outside the team."

---

## Slide 9 — The hardware

**Title**: The hardware

**Headline**: Six small computers in the home rack — three that coordinate, three that do the work

**Talking points**:
- 3 control-plane nodes: Beelink EQ14 Pro mini PCs (Intel N150, 16 GB RAM, 500 GB NVMe). The brain trust. They hold the cluster's state and coordinate everything.
- 3 worker nodes: Intel NUC 11s (i5, NVMe for the OS, 1 TB SATA SSD dedicated to storage). The muscle.
- The sixth machine type: the Synology NAS — a dedicated network-attached storage box for large media.
- Everything is wired. Wi-Fi is for phones and tablets, not for infrastructure.
- Total: 6 nodes, a router (UDM Pro Max), a NAS. That's the entire physical footprint.

**Image need**: A clean hardware diagram — 6 server icons labelled "CP1/CP2/CP3" and "W1/W2/W3", a router icon, a NAS icon. Connected by lines. No IP addresses on this slide. Optional: a small photo inset of the actual rack.

**Spoken script**:
"The hardware is deliberately modest. Six small boxes you could fit in a carry-on bag. The point is not the hardware — it's how we've organised what runs on it."

---

## Slide 10 — The operating system

**Title**: Talos: no keyboard, no password, no problem

**Headline**: The nodes run an operating system that cannot be configured manually

**Talking points**:
- Talos Linux: immutable, API-driven. There's no SSH login. There's no keyboard terminal. Configuration is applied by sending a config file over the network.
- This means: every OS configuration is code. It lives in Git. It can be reviewed, versioned, and reproduced.
- It also means: an attacker who gets inside the network can't log in to a node and type commands. There's nothing to type on.

**Image need**: A simple conceptual diagram — a padlocked server icon, an API arrow pointing at it from a laptop, no keyboard/monitor. Clean, not alarming.

**Spoken script**:
"Most computers have a way in: a login screen, an SSH port, a console. Talos doesn't. If you want to change the OS configuration, you write a config file and apply it remotely via a verified API. That's the only way in. It's not convenient — but convenience is what attackers rely on."

---

## Slide 11 — The applications

**Title**: What runs on it

**Headline**: Home automation, media, databases, and the system that keeps all of it working

**Talking points**:
- **Home Assistant** — the brain of the house: 200+ connected devices, automations, dashboards.
- **Media layer**: Plex (video), Radarr (movie tracking), Calibre (ebooks).
- **Smart home backends**: Zigbee2MQTT (Zigbee device radio bridge), Z-Wave JS (Z-Wave device bridge), Node-RED (complex automation flows), ESPHome (custom sensor firmware).
- **EV charging**: evcc — decides when to charge the car based on solar output and electricity price.
- **Infrastructure glue**: a database cluster, a certificate manager, a secret vault, a log aggregator, a metrics system.
- 66 named components in the inventory, across 14 namespaces.

**Image need**: A categorised icon grid — four sections with small app logos or abstracted icons: Home Automation, Media, Infrastructure, Observability. Keep it clean; the point is density, not detail.

**Spoken script**:
"If you're wondering why this needs a team: the EV charger integrates with the solar inverter, which talks to Home Assistant, which sends data to evcc, which calls the Tesla Fleet API, which talks to the car. If any one link in that chain breaks, the car charges at the wrong time and the electricity bill goes up. Coordination isn't optional."

---

## Slide 12 — GitOps: the shared notebook

**Title**: The shared notebook

**Headline**: All configuration is code, stored in Git, applied automatically

**Talking points**:
- Git: a version-control system. Think of it as a document with infinite undo history, where every change is signed with a name, a date, and a reason.
- Everything about this cluster — every app, every network rule, every configuration value — is a file in this repository.
- Flux (a piece of software running inside the cluster) reads that repository every hour (or immediately when a change is pushed) and makes the live system match it.
- If a computer dies and has to be replaced: restore the OS, point Flux at the repository, wait 20 minutes.

**Image need**: A simple three-step diagram: [Git repository] → [Flux reads] → [Cluster matches]. Arrow from cluster back to repository labelled "any manual change gets overwritten". Clear, light, not technical.

**Spoken script**:
"This is the idea that everything else is built on. The notebook — Git — is the source of truth. Not the servers. Not what's running right now. If there's a disagreement between what the notebook says and what the servers are doing, the notebook wins. Flux enforces this every hour without being asked."

---

## Slide 13 — One change, from request to evidence

**Title**: How a change happens

**Headline**: Request. Plan. Check. Execute. Record evidence. Close.

**Talking points**:
- Every deliberate change follows the same lifecycle, regardless of size.
- It starts with a change record: what is being changed, on which resource, by whom, at what risk level, with what rollback plan.
- Before execution, it goes through a review gate.
- After execution, evidence is recorded — a screenshot, a log entry, a test result. Not "looks fine". Real evidence.
- The history is permanent. Every closed change is part of the audit trail.

**Image need**: A horizontal flow diagram with six labelled boxes: Request → Plan → QA Check → Execute → Evidence → Close. Below the diagram: a small excerpt of a real change record (anonymised if needed, or just the fields: chg, resource, risk, summary). Compact, not overwhelming.

**Spoken script**:
"This is where the principle becomes concrete. I'm going to show you what an actual change record looks like. The change that added Alertmanager notifications to the home automation system — that change is logged. The change that wired the energy dashboard to the electricity meter — logged. The change that upgraded the cluster's networking stack — logged. Every single one."

---

## Slide 14 — The risk dial

**Title**: The risk dial

**Headline**: How much review a change gets depends on how much could go wrong

**Talking points**:
- **Low risk** — an image version bump, a comment in a config file, a dashboard tweak: auto-execute, just log it. No human approval needed.
- **Medium risk** — a new automation, a network routing rule, a new integration: Themis (QA) must pass it. If she fails it, it goes back to the engineer.
- **High risk** — anything touching authentication, the firewall, storage configuration, or Talos OS settings: Sander (the human) must explicitly approve before Themis even runs.
- This is not bureaucracy. It's proportional oversight.

**Image need**: A dial or three-band visual — Low (green), Medium (amber), High (red). Each band lists two example changes. Clean, readable at distance.

**Spoken script**:
"The mistake people make is treating every change the same — either everything is a big deal, or nothing is. The risk dial is how we calibrate. A typo fix in a comment doesn't need the same review as changing who can access the front door camera. This is just common sense, written into the process."

---

## Slide 15 — Who approves what

**Title**: Who decides

**Headline**: Three levels: the engineer, Themis, or Sander

**Talking points**:
- Low risk: the engineer decides and executes. Themis doesn't block it, but the change is logged.
- Medium risk: Themis runs her automated checks. She looks for: schema errors, missing rollback plans, freeze-window conflicts, security flags from Argus. Pass = go. Fail = back to engineer.
- High risk: Sander gets a summary, reads it, and types "approved" or "not now". Only then does Themis run. Only then does the engineer execute.
- Safety decisions (like ADR-0003 — no smart plugs on critical infrastructure) are written into permanent Architecture Decision Records. Even the team can't override them without another ADR.

**Image need**: A three-row approval table — row per risk level, columns: Who approves, What triggers it, What a fail means. Simple table, readable font.

**Spoken script**:
"One thing I want to be clear about: the human in this loop isn't ceremonial. High-risk changes touch things that can take the house offline, or worse. Sander reads the summary, asks questions if he has them, and gives an explicit yes. The agents wait. We don't auto-execute critical changes to avoid bothering someone."

---

## Slide 16 — The no-smart-plugs rule

**Title**: The lesson that became a rule

**Headline**: Family-critical infrastructure never runs through a smart plug

**Talking points**:
- ADR-0003: "Architecture Decision Record number 3."
- After one investigation that pointed toward software problems and turned out to be a failing relay in a smart plug, this rule was written.
- The router — the device the whole house depends on — must be on direct mains or a passive UPS. Not a smart plug. Not a managed power distribution unit. Nothing with firmware.
- "Dumb UPS" = pure battery backup with no Wi-Fi, no app, no firmware update.
- The rule is written down. Future hardware additions are checked against it. Argus scans for violations.

**Image need**: A split-image: left side — a smart plug icon with a red X through it; right side — a simple wall socket or UPS icon with a green check. Keep it iconic, not photographic.

**Spoken script**:
"This one's my favourite. Six hours of investigation. Multiple software fixes deployed. Multiple hypotheses chased. The answer? A relay clicking 20 times a second, inside a consumer smart plug, faster than the energy monitoring could see. The fix was unplugging a cable. The lesson is now an Architecture Decision Record. The rule is: if it's family-critical, it does not go through a smart plug. Period."

---

## Slide 17 — Energy intelligence

**Title**: The car charges when it's cheapest (or free)

**Headline**: Solar surplus and live grid tariffs combine to decide when the EV charges

**Talking points**:
- The house has a solar inverter. On a sunny afternoon, it produces more electricity than the house uses.
- The EV charger (Tesla Wall Connector Gen 3) reads that surplus via evcc — a specialist charge controller running in the cluster.
- evcc also reads the live Zonneplan electricity price. It knows the cheapest hour of the day.
- The result: on a cloudy winter day, the car charges at 3 a.m. when prices are lowest. On a sunny summer afternoon, it charges for free from the roof.
- None of this requires manual action. It runs continuously, in the background.

**Image need**: A three-source diagram: [Solar inverter reading] + [Live grid price] → [evcc logic] → [Car charging]. Simple, with a sunlight icon and a price tag icon. Not a product screenshot.

**Spoken script**:
"This is the most satisfying automation in the house. The car charges itself at the optimal time, automatically, every day. On good solar days it costs nothing. On expensive days it waits. The car doesn't know or care — it just wakes up full."

---

## Slide 18 — The garden

**Title**: The garden waters itself — when it needs to

**Headline**: Three soil sensors and a rain forecast decide whether the irrigation runs

**Talking points**:
- Three capacitive soil moisture probes in the backyard — one at the front, one in the middle, one near the tree.
- Every morning at 06:00, an automation takes the median of their readings.
- If moisture is above 30% → skip. If rain is forecast in the next 12 hours → skip. Otherwise, open the valve for 10 minutes.
- The threshold and duration are adjustable via sliders in the dashboard. No YAML editing.

**Image need**: A garden diagram: three probe icons in a backyard layout, a weather icon above (sun/cloud), a valve icon at the hose tap. Arrow from the three probes and the weather icon converging to "decision". Simple.

**Spoken script**:
"Three sensors handle a single unreliable probe gracefully — if one gives a weird reading, the median of three is still sensible. The rain-forecast guard means we don't water on Tuesday morning if the forecast says heavy rain at noon. Common sense, automated."

---

## Slide 19 — Room-by-room awareness

**Title**: The house adjusts to where people actually are

**Headline**: Presence detection, occupancy-linked heating, motion-linked lights

**Talking points**:
- Motion sensors in every room. Presence sensors (Bluetooth, Wi-Fi device tracking) for who's home.
- Heating responds to occupancy: a room nobody is in doesn't heat to full temperature.
- Lights turn on when someone enters, off after a configurable timeout when they leave.
- The evening lighting scene shifts colour temperature after sunset — warmer, lower, without anyone touching a switch.
- All of this is configured in Home Assistant and runs without cloud dependencies.

**Image need**: A floor-plan outline (simplified) with icons at each room: motion sensor, thermostat, light. Arrows showing "occupancy → temperature target" and "motion → light state". Abstract, not a blueprint.

**Spoken script**:
"The point isn't automation for automation's sake. The point is that I'm not thinking about whether I left the office light on. The house handles it. My attention is elsewhere."

---

## Slide 20 — The family dashboard

**Title**: One glance

**Headline**: The kitchen tablet shows the state of the house in plain language

**Talking points**:
- A Pixel Tablet mounted in the kitchen, running in kiosk mode (no home button, no notifications, just the dashboard).
- One screen: who's home, what's the indoor temperature, what's the heating doing, is the car charging, what's the energy reading.
- Updated in real time. No refresh button. No login.
- A second tablet in the office shows the same data with an operational overlay for when Sander is working.

**Image need**: An actual screenshot of the kitchen dashboard on the Pixel Tablet (kiosk view). Apollo captures this from the live system. Viewport: 1080×2400 portrait (tablet resolution).

**Spoken script**:
"This is the single most-used interface in the house. It replaced five apps on a phone and a mental load of 'wait, did I check the heating?' It's one picture that answers the question before you've asked it."

---

## Slide 21 — The daily health report

**Title**: Every morning: a clean report

**Headline**: At 06:00, the system checks itself. At 08:00, the summary lands on Sander's phone.

**Talking points**:
- Nine automated collectors run at 02:00: node health, storage health, backup status, certificate expiry, pod restarts, Ceph storage usage, energy sensors.
- A triage step at 03:00 applies four auto-fix rules: clean up failed pods, unstick stalled deployments, restart genuinely crashed services with a cooldown.
- At 06:00 the report is generated and published to https://health.bluejungle.net.
- At 08:00 a push notification lands on the phone with a link.
- The report catches slow-burn problems — a drive filling up, a certificate due in 10 days — before they become urgent.

**Image need**: Screenshot of the health report web page at https://health.bluejungle.net. Viewport 1920×1080. The report should be a recent one showing green status.

**Spoken script**:
"The hardest thing in infrastructure is not the fires. It's the slow smoulder nobody notices until it's a fire. The health report is the smoke alarm. Nine data collectors, one report, one notification. If you wake up and the notification is green, you can have your coffee without checking anything."

---

## Slide 22 — Network upgrade roadmap

**Title**: What comes next: proper network segmentation

**Headline**: Moving from "everything on one network" to servers, clients, and IoT on separate lanes

**Talking points**:
- Currently everything — servers, laptops, phones, smart plugs, cameras — shares one physical network. Segmented logically, but one misconfiguration would let a smart plug talk to the cluster.
- The next change: move cluster nodes to their own VLAN (a virtual network), and switch from Layer 2 network announcements (shouting on the local network) to BGP routing (a more robust, production-grade approach).
- BGP (Border Gateway Protocol — the protocol the internet itself uses to route between networks) is already configured in a branch; it hasn't been deployed to production yet.
- After this: IoT devices (cameras, sensors, smart plugs) on their own segment, unable to initiate connections to the server segment.

**Image need**: A network diagram with three lanes: SERVER-VLAN, CLIENT-VLAN, IOT-VLAN. Cluster nodes in server lane, laptops/phones in client lane, smart devices in IoT lane. Firewall icon between them. Clean, colour-coded.

**Spoken script**:
"BGP is the routing protocol the internet uses. We're not reinventing anything here — we're applying the same principles that ISPs use to route traffic between networks. The reason it matters at home is the same reason it matters everywhere: if an IoT device gets compromised, it should not be able to reach your servers."

---

## Slide 23 — The ops portal

**Title**: What comes next: one live picture of everything

**Headline**: A topology map where every component has a health indicator in plain colour

**Talking points**:
- Currently in progress: a web portal that shows the full topology — internet, router, switch, cluster nodes, storage, applications — as a visual map.
- Each component: green (healthy), yellow (warning), red (problem).
- Data pulled from the live cluster, the router, and the Prometheus metrics stack.
- Designed for two audiences: the household (family-facing pill: "everything is fine" / "one thing needs attention") and Sander (the full operational view).
- The cluster-health report page at https://health.bluejungle.net is the current prototype.

**Image need**: Screenshot of the ops portal topology view from https://health.bluejungle.net/topology.html (or the health.bluejungle.net main report page if topology isn't fully built). Viewport 1920×1080.

**Spoken script**:
"The long-term goal is to make the infrastructure invisible unless something is wrong, and obvious when something is. The ops portal is the instrument panel. Green across the board: don't think about it. One red: you know exactly where to look."

---

## Slide 24 — IPv6 and the future

**Title**: What comes next: full dual-stack IPv6

**Headline**: Dutch internet infrastructure is IPv6-native. The cluster will be too.

**Talking points**:
- KPN (the Dutch ISP in use here) provides a /48 IPv6 prefix — 65,000+ possible subnets, enough for every device to have its own globally routable address.
- IPv6 dual-stack is designed into the roadmap but is currently blocked by a known bug in Cilium (the cluster's network layer) related to how IPv6 addresses are announced on the local network.
- Once the bug is resolved upstream, the cluster will be rebuilt with dual-stack enabled from the start — it must be configured at creation time, not added later.
- Until then: IPv4 only, but the architecture is ready to extend.

**Image need**: A simple diagram — IPv4 address (a short number) alongside an IPv6 address (a longer string). An arrow from "today" to "dual-stack future". A small "blocked upstream" label on the arrow. Informational, not alarming.

**Spoken script**:
"This one is waiting on someone else to fix a bug. That's fine. The design is ready. The moment the upstream fix ships and Cilium supports IPv6 Layer 2 properly, we rebuild the networking layer and enable it. The patience here is deliberate — we don't force a half-working solution. We wait for the right foundation."

---

## Slide 25 — The one thing

**Title**: The one thing to remember

**Headline**: "Every change is deliberate, recorded, reversible — and reviewed by someone whose only job is to say no when it isn't ready."

**Talking points**:
- No bullets. Just the headline, a brief visual, and silence.
- If the audience remembers one sentence from this talk, this is it.
- It applies equally to home infrastructure and to any system where reliability matters.

**Image need**: Typography-only slide. The headline sentence, rendered at large size, centered, on a plain background. One colour. No decoration.

**Spoken script**:
"That's the whole argument in one sentence. Not 'we have the most sophisticated setup' — we don't, not by any professional standard. Not 'nothing ever goes wrong' — things go wrong. But when they go wrong, we know what changed, we know who made the change, we know how to reverse it, and someone checked it before it ran. That's the promise. That's what makes this different from a router you reboot and hope for the best."

---

## Notes for Sander: suggested delivery rhythm

- Slides 1–4: 4 minutes. Set the problem and the principle.
- Slides 5–8: 6 minutes. The team. Take questions here if the audience is curious.
- Slides 9–12: 5 minutes. Hardware and the notebook concept. Keep it light.
- Slides 13–16: 7 minutes. The change rituals. This is the heart of the talk.
- Slides 17–21: 5 minutes. What it enables. Stories welcome here.
- Slides 22–24: 2 minutes. Roadmap. Brief, forward-looking.
- Slide 25: 1 minute. Land the one thing. Don't rush it.

Total: 30 minutes, with 2–3 minutes for questions.
