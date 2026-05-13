# Topology dashboard — family + ops on one page

## Question
How should a single page convey "is the network okay right now?" to a non-technical family viewer *and* enable proactive detection + root-cause drill-down for the ops team, given ~30 CMDB components, server-rendered HTML only, <50 kB page budget?

## TL;DR
- **Lead with one verdict, not a map.** Every mature status surface — Cloudflare, AWS Personal Health, Google Wifi LED, UniFi Mobile — answers "OK / not OK" in a single coloured token *before* anything else. Family viewers never need to look past the first 80 px. [1][3][6][8]
- **Layer the operator view beneath via native `<details>`, not tabs.** Cloudflare, AWS, and Statuspage all use a stacked accordion of component groups; collapse-by-default keeps mobile readable and degrades to plain HTML with zero JS. [1][2][9]
- **Render topology as a hierarchical SVG, generated server-side by Graphviz `dot`.** For ~30 nodes a left-to-right / top-to-bottom tree is the only layout that stays legible without pan/zoom. Force-directed becomes a hairball; radial wastes screen on a tablet. Inline SVG sits in HTML at ~6–12 kB and needs no JS. [4][5][10]
- **Don't render UniFi's topology — *reference* it.** UniFi already owns the L1/L2 picture and updates it live; we render a *service map* (WAN → UDM → cluster → app tier → family-visible service) that UniFi can't, and deep-link to the UniFi UI for switch-port detail. [3][7]
- **Refresh server-side every 60 s for the summary token, 10 min for the topology.** No SSE, no polling JS. The portal's existing `ops-dashboard-render` CronJob already runs every 10 min — add a lighter 60 s job that writes just the summary fragment, included via `<meta http-equiv="refresh">` on the index. [11][12]

## What the world does

### UniFi Network controller — Topology page (consumer + prosumer, free with hardware)
**Core pattern.** Auto-generated tree of `UDM → switch → AP → client`. Nodes are device icons; edges are physical links coloured by health (green / grey-warning). Hover for IP + status; click to reboot. Layout cannot be hand-arranged. UniFi 10.2 (Mar 2026) added an "Infrastructure Topology" view that overlays a rack diagram and flags "critical links". [3][7]
**Tradeoff.** Brilliant for physical-layer truth (port up/down, PoE draw, uplink); blind to anything above L2. Doesn't know what a "Kubernetes Service" or "Sonos group" is. So we **defer to it for physical wiring** (link out, do not duplicate) and build our service-level map on top.

### Cloudflare Status (public status page, the canonical pattern)
**Core pattern.** Top of page is a single sentence + colour: "All Systems Operational". Below it, an incident feed (empty most of the time). Below *that*, an A–Z component matrix grouped by product, with each region as a collapsible row. Mobile and desktop render identically — the matrix just wraps. [1]
**Tradeoff.** Optimised for "tell me if I'm affected" at any literacy level. Sacrifices depth (no metrics, no graphs) — that's left to the customer's own dashboard. The IA — *verdict → incidents → component matrix* — is the most-copied status-page layout in the industry; Statuspage.io, GitHub Status, OpenAI Status, Atlassian Status all clone it. [1][9]

### Datadog Service Map (mid-to-large eng orgs, APM customers)
**Core pattern.** Force-directed graph of services with edges coloured by call volume. Service node borders go yellow/red on health change. Clustering groups tightly-coupled services. Clicking a node isolates its upstream/downstream and lets you "pivot one hop at a time". [4]
**Tradeoff.** Spectacular at hundreds of services; over-engineered at thirty. Force-directed layouts re-shuffle on every render — bad for muscle memory on a stable homelab. The **edge-colour-by-health + click-to-isolate** interaction is worth borrowing; the layout algorithm is not.

### Backstage Catalog Graph (open-source dev portal, self-hosted)
**Core pattern.** SVG entity graph with configurable direction (`LR` / `TB`), max depth (default 2), and per-relation filtering. Comes in two flavours: a card on each entity showing direct neighbours, and a full-page explorer. Edges are typed (`ownerOf`, `dependsOn`, `partOf`). [5]
**Tradeoff.** Beautiful when entities have rich typed relations (our CMDB does: `depends_on`). The full-page graph becomes unreadable past ~50 nodes without depth limiting. The **card-with-direct-neighbours** pattern is the right primitive for CMDB drill-down: clicking `ha.pod` shows just its deps + dependents, not the whole graph.

### Google / Nest Wifi app (family-facing consumer)
**Core pattern.** Single coloured token + one sentence: solid white = fine, pulsing orange = no internet. The app's home screen is essentially one big status pill; everything else is buried two taps deep. [6]
**Tradeoff.** Maximises legibility at the cost of every nuance — a Nest router can't distinguish "DNS slow" from "ISP down" in the LED, both are orange. For a single-light family display that's correct; for the ops view we need the nuance, so we put it underneath.

## Patterns that recur

**Essential (every tool has these).**
- One colour-coded verdict above the fold, sized so it's readable from across a kitchen. [1][3][6]
- Active-incidents strip directly under the verdict; empty state explicit, not blank. [1][9]
- Components grouped by *meaningful tier*, not alphabetical. Cloudflare groups by product+region; Datadog by team; we should group by **family-visible tier**: `Internet → LAN → Cluster → Stateful → Family services`. [1][4]
- Each row collapsible; default-collapsed on mobile, default-open on desktop. Native `<details>` is enough. [1][2]
- Server-side render of the topology image (SVG); no client-side layout engine. [10]

**Optional (only some).**
- Live updates via SSE/WebSocket — Datadog yes, Cloudflare no, Google Wifi yes. For a 6-node cluster nothing changes <60 s that the family needs to see; **skip**. [4][11][12]
- Geographic / rack overlay — UniFi 10.2 added it, Datadog never did. Useful at DC scale, not at a single rack. Skip for now. [3]
- Per-edge tooltips — universal in interactive tools, costs JS. Substitute: the edge's *destination* node is itself clickable to its CMDB row. [4][5]

## Recommendation

**Build one page (`/topology.html` or merged into `/index.html` overview) with three vertical zones:**

1. **Family verdict (top, ~120 px, no scroll on phone).** One big pill: green dot + "Network OK" / amber + "Slow" / red + "Down". Below it, one sentence: "Internet up · Wi-Fi up · 6/6 nodes · 47/47 apps healthy". Tabular numerals. Auto-refresh meta=60s. This is *the entire view* a family member ever needs and the operator's morning glance.

2. **Tiered service map (middle, SVG).** Server-rendered by `graphviz dot` (LR direction). Five rows, top-to-bottom: **Internet** (Cloudflare, ISP) → **Edge** (UDM, VLANs, Wi-Fi) → **Cluster** (CP, workers, Cilium, Flux) → **Stateful** (Ceph, CNPG, VolSync) → **Family services** (HA, Sonos, Plex, Frigate, kiosks). Nodes coloured green/amber/red from live state (kubectl + UniFi + HA). Edges drawn from `cmdb.yaml depends_on`. ~30 nodes fits in ~800×500 px, ~10 kB inline SVG. Each node is an `<a>` link to its `cmdb.html#id` row — no JS needed for drill-down.

3. **Operator drill-down (bottom, collapsible `<details>` per tier).** Each tier in the map has a `<details>` block with the same components as a flat table: name, status, owner agent, last-changed, deep-link to UniFi/kubectl/HA. Collapsed by default on mobile (`@media (max-width: 640px)` opens only the tier with failures). Failed components auto-expand their tier regardless.

**Rendering technique — Graphviz `dot` server-side, inline SVG.** It's already a mise-managed dep candidate, produces deterministic layouts (no random re-shuffle = preserves operator muscle memory), and the `svg_inline` output mode (Graphviz ≥10.0.1) drops in to HTML at single-digit kB. Fallback: hand-written SVG `<g>` blocks generated by Python — feasible at 30 nodes if Graphviz proves a pain to package on Talos. **Reject** force-directed (Datadog-style), D3/canvas, and any client-side layout. [4][5][10]

**Refresh cadence — 60 s for the summary, 10 min for the SVG.** Apollo's house style allows `<meta http-equiv="refresh" content="60">`; the existing `ops-dashboard-render` CronJob runs every 10 min, which is fine for topology (edges in `cmdb.yaml` change ~weekly). Add a smaller 60 s CronJob that writes only the verdict fragment + status JSON, and have index.html `@import` or inline-fetch via a tiny iframe (no SPA). Avoid SSE/WebSocket — adds infra without changing the family's experience. [11][12]

**What we explicitly do NOT build.**
- A re-implementation of UniFi's physical topology. Link out instead.
- Interactive pan/zoom/drag on the SVG. Pre-laid-out is enough at 30 nodes.
- A JS framework, a graph library, an npm dep, or a CDN asset. Permanently denied.
- Per-edge tooltips. The node is the click target; its `cmdb.html#anchor` is the drill-down.

## Sources

1. Cloudflare Status page IA — visited 2026-05-13. https://www.cloudflarestatus.com/
2. Cloudflare Status API + structure — Cloudflare Support docs, visited 2026-05-13. https://developers.cloudflare.com/support/cloudflare-status/
3. "UniFi Topology Page: How to Read, Use, and Troubleshoot Your Network Map" — UniFiNerds, visited 2026-05-13. https://unifinerds.com/unifi-topology-page-how-to-read-use-and-troubleshoot-your-network-map/
4. Datadog Service Map docs — https://docs.datadoghq.com/tracing/services/services_map/, visited 2026-05-13.
5. Backstage Catalog Graph plugin — Roadie plugin reference + backstage.io entity-graph docs, visited 2026-05-13. https://roadie.io/backstage/plugins/catalog-graph/ and https://backstage.io/docs/features/software-catalog/creating-the-catalog-graph/
6. "Wifi device light meanings" — Google Nest Help, visited 2026-05-13. https://support.google.com/googlenest/answer/6191584
7. "UniFi Network 10.2: New Features for MSPs" — UniHosted, Mar 2026. https://www.unihosted.com/blog/unifi-network-10-2-features
8. AWS Personal Health Dashboard docs, visited 2026-05-13. https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
9. Statuspage.io / GitHub Status / OpenAI Status — pattern survey, visited 2026-05-13.
10. Graphviz SVG output documentation — `svg_inline` since v10.0.1, visited 2026-05-13. https://graphviz.org/docs/outputs/svg/
11. "Polling vs Long Polling vs SSE vs WebSockets vs Webhooks" — algomaster.io, 2025. https://blog.algomaster.io/p/polling-vs-long-polling-vs-sse-vs-websockets-webhooks
12. "Server-Sent Events vs WebSockets vs Long Polling: What's Best in 2025" — dev.to/haraf, 2025. https://dev.to/haraf/server-sent-events-sse-vs-websockets-vs-long-polling-whats-best-in-2025-5ep8

— Athena
