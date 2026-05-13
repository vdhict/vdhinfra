# Topology CMDB extension — schema for the network-first dashboard

Author: Daedalus (design-engineer)
Change: `chg-2026-05-13-025`
Date: 2026-05-13
Companion ADR: `docs/adr/0002-cmdb-vs-live-data.md`

## Context

Apollo will build a network-first infrastructure dashboard, then expand to
cluster, storage, and services. The current `ops/cmdb.yaml` (36 components,
flat schema) carries ownership + dependency hints + sensitivity but no notion
of layer, group, or where to read live status from. ADR-0002 fixes the data
split (CMDB = overlay; live sources = topology + state). This doc specifies
the minimum schema extension to make that work and lays out the migration.

## Constraints (from ADR-0002 and the roster)

- CMDB stays YAML in git, edited via PR. No web form, no database.
- Every new field must be joinable against a live source or carry an explicit
  `health_source: none` reason — no fields that exist only to be hand-curated
  and never validated.
- Apollo's renderer must work without JS at <50 kB per page; the schema must
  not require a SPA to be useful.
- Existing `owner_agent` / `depends_on` / `sensitive` / `runbook` / `type` /
  `external_id` fields stay. New fields are additive.

## Layered model

| Tier | What lives here | CMDB carries | Live source |
|---|---|---|---|
| 0 — internet | WAN, Cloudflare edge | `net.dns.cloudflare`, ISP entry | HTTP probe, Cloudflare API (already used by external-dns) |
| 1 — perimeter | UDM Pro Max, WAN link, cloudflared | `net.udm`, `net.cloudflared`, `hw.plug.vdhngfw_power` | UniFi `/stat/health`, kubectl deploy |
| 2 — LAN backbone | switches, APs, VLANs | curated id per switch + AP (new), VLANs as `group:` only | UniFi integration API (`/devices`, `/clients`) |
| 3 — clients (non-cluster) | kiosks, Synology, Hue bridge, smart plugs | curated id per device | UniFi (last_seen) + HA entity probe |
| 4 — cluster substrate | nodes, Cilium, Rook-Ceph, Flux, ExternalSecrets, SOPS | one CMDB id per substrate component | kubectl, Rook CRDs, Flux CRDs |
| 5 — services | HA, CNPG, VolSync, Azure offsite, observability stack, integrations | one CMDB id per service | kubectl deploy + service-specific health (e.g. HA `/api/`, CNPG cluster CR, VolSync status) |

What the CMDB carries at every tier: identity, owner, group, sensitivity,
runbook, dependency hints, SLA tier, health source URI.
What it does **not** carry: which port an AP is plugged into, current pod
count, current PVC size, current cert expiry. Those are live joins.

## Schema extensions

Add the following optional fields to each component (existing fields unchanged):

```yaml
components:
  net.switch.poesw01:                       # NEW id (see naming below)
    type: network-device
    owner_agent: udm-engineer
    description: PoE switch in the kantoor rack, serves AP-kantoor + AP-zolder
    tier: 2                                  # NEW: layer 0–5 per the table above
    group: core-network                      # NEW: free-text sub-system tag
    sla_tier: family-critical                # NEW: family-critical | ops-only | nice-to-have
    health_source: unifi://device/74:ac:b9:xx:xx:xx   # NEW: URI; renderer joins on this
    physical_link_to: [net.udm]              # NEW: physical L2 uplink (network tier only)
    depends_on: [net.udm, hw.plug.vdhngfw_power]   # existing — logical/operational deps
    sensitive: false
    runbook: docs/runbooks/network-recovery.md
```

Field definitions:

- **`tier`** (int, 0–5). The layer above. Renderer groups + orders by tier.
- **`group`** (string). Free-text sub-system tag for visual clustering inside
  a tier: `core-network`, `ipv4-network`, `ha-stack`, `backup`, `observability`,
  `gitops`. Used for sectioning + colour-coding only; not a foreign key.
- **`sla_tier`** (enum: `family-critical` | `ops-only` | `nice-to-have`).
  Drives the red/amber/grey of the status pill. Lights, heating, kitchen
  tablet = family-critical. Grafana, health-report = ops-only. The test
  cluster, archived experiments = nice-to-have.
- **`health_source`** (URI string, optional). Where the renderer reads live
  status from. One of:
  - `unifi://device/<mac-or-id>` — UniFi integration API; Iris's adapter.
  - `k8s://deploy/<ns>/<name>` (or `ds/`, `sts/`, `helmrelease/`, `kustomization/`, `pvc/`, `cluster.postgresql/`, `cephcluster/`) — Heph's kubectl adapter.
  - `prometheus://<promql-query>` — Heph's adapter; returns scalar.
  - `http://<url>` or `https://<url>` — generic HTTP probe; 2xx = up.
  - `none:<reason>` — explicitly no live source (e.g. `none:passive-device`).
- **`physical_link_to`** ([id, ...], network tier only). The physical L2 link
  topology for tier 2/3 devices. Kept *separate from `depends_on`* so the
  network diagram can be drawn without entangling logical dependencies. A
  switch's uplink to the UDM goes here; the fact that "everything depends on
  the UDM" stays in `depends_on`.

Total: 5 new optional fields. Existing entries without them render fine —
they default to `tier: unknown`, no live join.

## Naming convention for component ids

Existing flat ids (`net.udm`, `ha.pod`) stay. New ids follow:

```
<tier-prefix>.<kind>.<subject>[.<qualifier>]
```

Tier prefixes (one or two segments — keep readable):

| Prefix | Tier | Example |
|---|---|---|
| `net.` | 1–2 (perimeter + LAN) | `net.udm`, `net.switch.poesw01`, `net.ap.kantoor`, `net.vlan.iot` |
| `hw.` | 3 (physical non-cluster devices, IoT) | `hw.plug.vdhngfw_power`, `hw.kiosk.pixel_tablet` |
| `k8s.` | 4 (cluster substrate) | `k8s.cluster`, `k8s.node.master01`, `k8s.cni.cilium` |
| `k8s.app.<ns>.<name>` | 5 (cluster services) | `k8s.app.network.envoy-internal`, `k8s.app.database.cnpg` |
| `ha.` | 5 (HA service + configs + integrations) | `ha.pod`, `ha.config.automations_yaml`, `ha.integ.hue_bridge` |
| `db.` | 5 (databases) | `db.cnpg.postgres`, `db.cnpg.cluster.main` |
| `backup.` | 5 (backup chain) | `backup.volsync`, `backup.azure_offsite` |
| `obs.` | 5 (observability) | `obs.prometheus`, `obs.grafana` |
| `auth.` | 5 (identity) | `auth.onepassword_connect` |
| `ext.` | 0 (off-prem) | `ext.cloudflare.zone`, `ext.isp.kpn` |

Rules:
- Lowercase, dot-separated, ASCII. Hyphens allowed within a segment.
- Existing ids are grandfathered. Don't rename for cosmetics — it churns the
  change log (`resource` field of every prior event).
- New k8s services follow `k8s.app.<ns>.<name>` so they map 1:1 to
  `kubectl -n <ns> get deploy <name>` and the kubectl adapter doesn't need a
  lookup table.

## Migration plan (existing 36 entries)

Tier-by-tier, smallest blast radius first. One PR per tier.

| PR | Tier | What gets the new fields | Engineer |
|---|---|---|---|
| 1 | docs only | This design doc + ADR (no CMDB write yet) | Daedalus |
| 2 | tier 5 (services) | `ha.*`, `db.cnpg.postgres`, `backup.*`, `obs.*`, `auth.onepassword_connect`, `k8s.app.*` rename for cloudflared. Add `health_source: k8s://...` and `sla_tier`. | Heph + Hestia (HA entries) |
| 3 | tier 4 (cluster substrate) | `k8s.cluster`, `k8s.cni.cilium`, `k8s.storage.rook-ceph`, `k8s.gitops.flux`, `k8s.gateway.*`, `k8s.secrets.*`. Add 3 new node ids (`k8s.node.master01..03`, `k8s.node.node01..03`). | Heph |
| 4 | tier 1–3 (network) | `net.udm`, `net.dns.*`, add switches + APs as new ids with `physical_link_to`, add `hw.plug.vdhngfw_power` tier classification. | Iris |
| 5 | tier 0 | `ext.cloudflare.zone`, `ext.isp.kpn`. | Iris |

Each PR is `risk: low` (additive YAML edits only). Themis gate: kustomize
+ yamllint pass; `./ops/ops cmdb show <id>` still works.

**Deprecation path** (if a field turns out wrong):

1. Mark the field deprecated in this design doc (add a "## Deprecated fields"
   section with date + reason).
2. The renderer stops reading it. CMDB entries keep the field for one release
   cycle so historical changes referencing it still parse.
3. After the cycle, a single PR removes the field across all entries.

No field is sacred. If `sla_tier` turns out to be noise because everything is
family-critical anyway, drop it.

## Hand-offs (live-data adapters)

Each adapter is a pure read function: `(cmdb_id) -> {status, label, last_seen, link?}`. The renderer calls them at HTML build time.

| Tier | Live source | Adapter | Engineer |
|---|---|---|---|
| 0 — internet | Cloudflare API, HTTP probes | `ext_http_adapter` | Iris |
| 1 — perimeter | UniFi `/stat/health`, kubectl (cloudflared) | extend `unifi_exporter` read path; `k8s_adapter` | Iris (UniFi) + Heph (kubectl) |
| 2 — LAN backbone | UniFi integration API `/devices`, `/clients` | `unifi_adapter` (new) | **Iris** |
| 3 — clients | UniFi `/clients` for last_seen; HA REST for kiosks | `unifi_adapter` + `ha_adapter` | Iris (UniFi) + **Hestia** (HA) |
| 4 — cluster substrate | `kubectl get nodes/cilium/cephcluster/kustomization/helmrelease` | `k8s_adapter` (new) | **Heph** |
| 5 — services | `kubectl get deploy/sts/ds`, Rook-Ceph dashboard, CNPG cluster CR, VolSync status, Prometheus | `k8s_adapter` + `prometheus_adapter` + `ha_adapter` (for `ha.*`) | **Heph** (cluster + storage + DB + backup + obs) + **Hestia** (HA stack only) |

The adapters live next to `ops/ops` (e.g. `ops/adapters/unifi.py`, `ops/adapters/k8s.py`) and are imported by `cmd_dashboard`. Each adapter ships with a 60-second on-disk cache so the renderer is idempotent and the UDM is not hammered (existing `unifi-exporter` kindness rules apply — see memory `unifi-exporter-archived`).

## Anti-scope

- ❌ No CMDB UI editor. Edits flow through PR review. (ADR-0002.)
- ❌ No new dashboard tech stack. Apollo's house style (server-rendered HTML +
  <50 kB) applies.
- ❌ No fields without a live join. If a field would only ever be hand-curated
  and never validated, it's noise — drop it.
- ❌ No renaming of existing ids for cosmetics — the change log references them
  by id.
- ❌ No reconciliation worker writing back into `cmdb.yaml`. The CMDB is human
  input only.

## Open questions

1. **Should `physical_link_to` be optional on tier 4/5 entries too** (e.g.
   `k8s.node.master01 physical_link_to: [net.switch.poesw01]`)? Lean yes — it
   lets the dashboard draw a single connected graph from internet to pod. But
   it adds maintenance burden when a node moves rack. Default: leave off for
   now; revisit after tier-2 PR lands.
2. **`group` taxonomy**: free-text vs enum?  Lean free-text initially; let it
   stabilise over the migration; convert to enum once we see the actual list
   on a real diagram.
3. **What does `sla_tier` of the cluster itself mean?** The cluster as a
   whole is family-critical (HA depends on it), but individual cluster
   services vary (Grafana is ops-only). Decision: `sla_tier` is per-CMDB-id,
   so `k8s.cluster: family-critical` and `obs.grafana: ops-only` can both
   hold.
