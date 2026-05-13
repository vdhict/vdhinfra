# 0002 — CMDB is the human overlay; live systems are the topology source of truth

Status: proposed
Date: 2026-05-13
Decision-makers: user (Sander), Atlas, Apollo, Daedalus

## Context

Apollo is about to build a network-first infrastructure dashboard on top of the
existing ops portal. The portal already renders `ops/cmdb.yaml` as a flat
component list (36 entries today). Extending it into a topology view forces a
question we have not formally answered: **where does topology data live?**

We have three authoritative live sources already running in the lab:

- **UniFi controller** (UDM Pro Max, integration API at
  `https://172.16.2.1/proxy/network/integration/v1/...`) knows the entire
  physical L2 topology — uplinks, port assignments, AP-to-switch links, VLANs,
  client MACs, last-seen timestamps, hardware model strings. Iris already polls
  `/stat/health` from `unifi-exporter`; expanding to the integration API is
  cheap.
- **Kubernetes** (via `kubectl` and the Flux/CNPG/Rook CRDs) knows every Node,
  Namespace, Workload, Service, HTTPRoute, PVC, HelmRelease, Kustomization,
  Postgres cluster, and Ceph OSD that exists, along with health and last-seen.
- **Prometheus + cluster-health report** already aggregates uptime / saturation
  signals.

`ops/cmdb.yaml` today carries fields that none of those systems will ever know
on their own: `owner_agent`, `sensitive`, `runbook`, friendly description,
sub-system grouping hints. Some entries (e.g. `ha.kiosk.pixel_tablet`,
`hw.plug.vdhngfw_power`) are also things no system enumerates for us.

Two anti-patterns we want to avoid:

1. **Duplicating live state into the CMDB.** Writing the current uplink of every
   AP, or the current pod count of every Deployment, into a YAML file means the
   YAML is wrong within seconds and the dashboard lies. Backstage attempts this
   and pays for it with a heavy reconciliation pipeline that we explicitly do
   not want at this scale (cf. research `docs/research/itsm-portal-lean-research.md`).
2. **Modelling everything in live data.** Then we lose ownership, sensitivity,
   sub-system grouping, runbook pointers, the human "what is this thing for?"
   layer. Live systems do not know that `hw.plug.vdhngfw_power` is gating the
   UDM and must never be cycled (memory: `udm-crash-rootcause-10.3.x.md`).

## Decision

**CMDB holds the curated overlay (identity + ownership + sensitivity + grouping
+ runbook + dependency hints + sla_tier). Live systems hold topology + state.
The renderer joins them at render time by component id.**

Concretely:

- Every CMDB entry gets a stable `id` and (new) a `health_source` URI pointing
  at the live system that knows its real-time state — e.g.
  `unifi://device/<mac>`, `k8s://deploy/<ns>/<name>`, `prometheus://<query>`,
  `http://<url>`, or `none` for things we cannot poll (e.g. the kitchen
  tablet's battery).
- The renderer reads `cmdb.yaml` for the overlay, then issues read-only queries
  to the named live sources, then joins per-id at HTML build time. No state
  ever flows back into `cmdb.yaml`.
- Physical-link topology for the network tier (switch → AP → client) is
  **read from UniFi, not written in YAML**. The CMDB adds only what UniFi
  cannot tell us: which physical link is sensitive, which device is owned by
  Iris vs Hestia, which AP serves a kiosk we care about.

The rule, verbatim, for the renderer:

> **CMDB holds ownership, sensitivity, grouping and runbook; live sources hold
> topology and state; the renderer joins them by component id at render time.**

## Alternatives considered

1. **Model topology in CMDB (write physical links into YAML).** Rejected.
   First UniFi reboot or AP swap and the YAML is wrong; we discover it only
   when the dashboard misleads us. Adds a permanent reconciliation tax
   without a corresponding benefit (we already trust UniFi as source of truth).

2. **Drop the CMDB; derive everything live.** Rejected. We lose
   `owner_agent`, `sensitive`, `runbook` — fields the change/incident tooling
   already depends on (`ops/ops change new <resource>` validates against the
   CMDB; the QA gate routes by `owner_agent`). Some entries (the smart plug
   gating the UDM, the kiosks, the Synology) have no good live source anyway.

3. **Two CMDBs (one curated, one auto-discovered, reconciled nightly).**
   Rejected as scope creep. Two files mean two truth-claims and a sync
   process. The whole point of "live join at render time" is to never store
   the second copy.

## Consequences

**What this enables.**
- Apollo can ship the network-first dashboard against today's CMDB plus a tiny
  set of new fields (`tier`, `group`, `health_source`, `sla_tier`,
  `physical_link_to` for network only) — see the companion design doc
  `docs/design/topology-cmdb-extension.md`.
- Iris owns one new adapter (UniFi integration API → in-memory dict, keyed by
  CMDB id). Heph owns the kubectl adapter. Both are pure read paths.
- The CMDB stays a hand-curated YAML file in git, reviewed via PR, edited by
  humans + agents. No web form, no database, no reconciliation worker.

**What this constrains.**
- Every new CMDB id must be joinable to *something* live or be explicitly
  marked `health_source: none` (with a one-line reason). No fields that exist
  only to be hand-curated and never validated.
- The renderer is responsible for graceful degradation when a live source is
  down — e.g. UniFi unreachable means the network tier shows the curated
  overlay with a banner "live topology unavailable", not a crash.

**What we now owe.**
- A short documented adapter contract per live source (input: CMDB id pattern;
  output: `{status, label, last_seen, link?}`). Lives in
  `docs/design/topology-cmdb-extension.md`.
- A migration of the 36 existing CMDB entries to include the new fields,
  tier-by-tier (see migration plan in the design doc).

## Review

Revisit if any of the following become true:

- The renderer needs more than four live sources (UniFi, kubectl, Prometheus,
  HTTP). Then a thin abstraction layer becomes worth it.
- The CMDB grows past ~150 entries and hand-curation becomes painful.
- We need offline render (no live source reachable) for more than a graceful
  fallback — e.g. a printed disaster-recovery binder. Then a frozen snapshot
  format is justified.

Otherwise reviewed annually.

## Related

- Companion design doc: `docs/design/topology-cmdb-extension.md`
- Research: `docs/research/itsm-portal-lean-research.md` (Backstage entity
  model; Compass scorecard rejection; lean catalog principles)
- Prior ADR: `docs/adr/0001-flux-cluster-admin.md` (style reference)
- Memory: `migration-lessons` (UDM DNS interception, Cilium DSR — examples
  of "live system was already authoritative; we just needed to read it")
- Change: `chg-2026-05-13-025`
