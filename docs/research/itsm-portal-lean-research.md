# Lean IT operations portal — IA research

## Question
What are the must-have sections and design choices for a lean IT operations portal serving a single-operator homelab (~30 CMDB components, ~5 changes/day, mix of human + AI agent contributors), and what do mature ITSM/SRE tools include — or deliberately leave out — that we should mirror?

## TL;DR
- Five surfaces recur across every mature tool: **(1) operational "now" view**, **(2) service/component catalog**, **(3) change/incident timeline**, **(4) on-call & ownership**, **(5) postmortem/ADR archive**. Build only these. [1][2][6]
- The "now" view should lead with the four golden signals (latency, traffic, errors, saturation) or their per-service SLI equivalents — not internal infra metrics. [2][3]
- Component catalogs converge on a minimum useful entity set: **Component → API/Resource → System → Owner** (Backstage's triad plus ownership). The homelab already has this in `ops/cmdb.yaml`. [4][5]
- Skip — and stay skipped on — public status page, customer comms, SLA contracts, multi-tenant RBAC, scorecard governance, ticketing/queue managment. These are all *organisational* features, not operational ones. [1][6][7][8]
- Recommendation: extend the current `cmd_dashboard` into **one auto-refreshing page** with five anchored sections; keep the event-sourced JSONL as source of truth; render server-side only. No SPA, no auth gate (already behind LAN/Cloudflare).

## What the world does

### PagerDuty (incident-first SaaS, mid-to-large eng orgs)
**Core pattern.** The Service Directory is the spine: each service shows current status (no incidents / triggered / acknowledged / in maintenance), the on-call user, and links to runbooks. Incident response is structured around a five-phase lifecycle — *being on-call, before, during, after, crisis* — and explicit roles (Incident Commander, Deputy, Scribe, SME, Customer/Internal Liaison). Severity is a numbered scale; SEV-1 auto-pages and assigns an IC. [1][6]
**Tradeoff.** Optimised for multi-team coordination during sev-1 outages; sacrifices simplicity. The role taxonomy and severity matrix only pay off above ~10 responders. For a single operator they're overhead — but the IA (service → status → on-call → runbook on one row) is gold and transfers down.

### Atlassian Compass (developer portal, large eng orgs)
**Core pattern.** Four surfaces: Components, Teams, Scorecards, Apps/Integrations. Components auto-populate from Bitbucket/GitHub; Scorecards weight criteria (has owner? has docs? deployment frequency? MTTR?) to grade each component. [7]
**Tradeoff.** Strong on *governance at scale* (forcing consistency across hundreds of services), weak on operational immediacy — Compass doesn't tell you what's broken right now, it tells you which services are below standard. Scorecards are a multi-team political instrument; useless for a single operator who already enforces conventions in code review.

### Backstage (open-source software catalog, self-hosted)
**Core pattern.** Seven entity kinds — Component, API, Resource, System, Domain, User, Group — wired into a typed graph. Lifecycle field on every entity (`experimental | production | deprecated`). YAML-in-Git is the canonical source; the UI is a view over the graph. [4][5]
**Tradeoff.** Maximally flexible; expensive to operate. Backstage itself is a non-trivial Node app with a database and plugins. The *data model* is the takeaway; the platform is not. Our `cmdb.yaml` is already a stripped-down Backstage entity file.

### Better Stack / Cachet (status-page tools, customer-facing comms)
**Core pattern.** Branded public page listing components (operational / degraded / outage), an incident feed with status updates, scheduled maintenance windows, optional uptime metrics. Incident management adds on-call rotation and escalation rules. [8][9][10]
**Tradeoff.** Optimised for *external trust* — customers reading a page during an outage. Everything is structured around public messaging cadence (status updates with ETA). For a household with one user, the "audience" is the operator themselves; the public-facing chrome is dead weight. The internal incident timeline pattern (event → investigated → mitigated → resolved → postmortem) is universal and worth keeping.

### Google SRE workbook (reference standard, no product)
**Core pattern.** Dashboards lead with the four golden signals — **latency, traffic, errors, saturation** — at the service boundary, not internal infra. Show intended changes (versions, flags, config) and dependency metrics alongside. Different audiences get different views of the same data. Alerts based on customer-visible symptoms, not internal causes. [2][3]
**Tradeoff.** Vendor-neutral and prescriptive on philosophy, silent on layout. You get principles, not templates. The "four golden signals" framing is the single most-cited piece of dashboard guidance in the industry and survives at any scale.

## Patterns that recur

**Essential (every tool has these in some form).**
- A "right now" surface — open incidents, active changes, on-call holder, anything red. [1][2][8]
- A typed component/service catalog with **ownership** as a first-class field. [4][7]
- A chronological event log per change and per incident (event-sourced, append-only). [1][6]
- A postmortem/learning archive linked from each closed incident. [6]
- Severity *and* risk taxonomies, deliberately small (3–5 levels). [11]

**Optional (axis of choice).**
- Public-facing status page — only if you have external customers. [8][9]
- Scorecards / golden-path enforcement — only with multiple contributing teams. [7]
- On-call rotation & escalation — only with multiple responders. [1][8]
- SLO/SLI tracking — only when you have a contract or a user-perceived target. [3]
- Ticket queue / request intake — only with a service desk model. [1]

## Recommendation (for vdhinfra)

Render a **single page** at `https://ops.bluejungle.net/` with five anchored sections, in this order, server-rendered HTML with 60s meta-refresh (Apollo's house style):

1. **Now** — active freeze (if any), open changes, open incidents, active locks. KPI strip stays. *(Already mostly present in `cmd_dashboard`.)*
2. **Recent activity (7d)** — change + incident tables, latest first. *(Already present; keep.)*
3. **Components** — CMDB rows grouped by `owner_agent`, with a `sensitive` flag column and dependency count. Click-through to the component's last 5 events. *(Add the grouping + last-events drill-down.)*
4. **Roster & on-call** — the 9 agents from `roster.md` with their domain. No rotation logic — there's one human + a cohort of agents, all reachable any time. *(New; cheap.)*
5. **Postmortems & ADRs** — list of closed incidents with `postmortem` events, plus `docs/adr/` index, plus `accepted_risks.yaml`. *(New; cheap.)*

Explicitly *not* building: public status page, SLO dashboard, scorecards, ticket queue, escalation policies, RBAC, search. If/when a section is wanted, it goes on the same page with a new anchor — no second route until the page exceeds one mobile scroll's worth of cognitive load. Cite-trail for the IA: PagerDuty service-row pattern [1], Backstage entity model [4][5], SRE golden-signals framing [2][3], Cachet/Better-Stack incident-feed pattern [8][9].

Two decisions the user needs to make:
- **D1.** Keep the legacy daily cluster-health report at `/` or move it to `/health` and put the ops portal at `/`? (Recommendation: portal at `/`, health at `/health` — ops portal is the higher-frequency need.)
- **D2.** Per-component drill-down: dedicated page per component (`/c/<id>`) or expand-in-place on the single page? (Recommendation: expand-in-place via `<details>` element — keeps "no router, no JS" constraint.)

## Sources

1. PagerDuty Support, "Service Directory." https://support.pagerduty.com/main/docs/service-directory (accessed 2026-05-13)
2. Google SRE Workbook, "Monitoring." https://sre.google/workbook/monitoring/ (accessed 2026-05-13)
3. Google SRE Book, "Monitoring Distributed Systems" (four golden signals). https://sre.google/sre-book/monitoring-distributed-systems/ (accessed 2026-05-13)
4. Backstage Docs, "System Model." https://backstage.io/docs/features/software-catalog/system-model/ (accessed 2026-05-13)
5. Backstage Docs, "Descriptor Format of Catalog Entities." https://backstage.io/docs/features/software-catalog/descriptor-format/ (accessed 2026-05-13)
6. PagerDuty Incident Response Documentation (roles, phases). https://response.pagerduty.com/ (accessed 2026-05-13)
7. Atlassian Support, "Learn how Compass works" (Components / Teams / Scorecards / Apps). https://support.atlassian.com/compass/docs/learn-how-compass-works/ (accessed 2026-05-13)
8. Better Stack, "Incident Management." https://betterstack.com/incident-management (accessed 2026-05-13)
9. Cachet, "Introduction." https://docs.cachethq.io/v3.x/introduction (accessed 2026-05-13)
10. Better Stack Docs, "Getting started with status pages." https://betterstack.com/docs/uptime/getting-started-with-status-pages/ (accessed 2026-05-13)
11. PagerDuty, "Severity Levels." https://response.pagerduty.com/before/severity_levels/ (accessed 2026-05-13)

— Athena
