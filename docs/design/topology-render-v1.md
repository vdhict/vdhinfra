# topology-render-v1 — family pill + /topology.html

Author: Apollo (frontend-engineer)
Change: `chg-2026-05-13-027`
Date: 2026-05-13
Companions: `docs/research/topology-dashboard-research.md`, `docs/design/topology-cmdb-extension.md`, `docs/adr/0002-cmdb-vs-live-data.md`

## Scope of this PR (phase 2a)

1. Add a single family-facing health pill at the top of `index.html`.
2. Add a new `/topology.html` page rendering the five-tier service map.
3. Extend the network-tier CMDB entries with the five new schema fields
   (`tier`, `group`, `sla_tier`, `health_source`, `physical_link_to`).

Out of scope (deferred): cluster/services tier CMDB rollout, live adapters
(those are Iris/Heph/Hestia phase 2b), interactive drill-down, SSE/WS.

## Files touched

| File | Change |
|---|---|
| `ops/ops` | Add `_compute_health_state`, `_render_family_pill`, `_render_topology_page`, `_render_topology_via_graphviz`, `_render_topology_via_css_grid`, `_load_unifi_topology`. Wire pill into `_render_index`; add `topology.html` to pages dict; add `topology.html` to tab strip in `_page()`. |
| `ops/cmdb.yaml` | Add 5 new optional fields to the 7 network-tier entries named below; add new placeholder ids `net.isp.kpn`, `net.switch.poesw01` (TODO), `net.ap.kantoor` (TODO) for the diagram to be representative. |
| `docs/design/topology-render-v1.md` | This file. |

## Pill state machine

Priority order — first match wins. Implemented in `_compute_health_state(state) -> (level, reason, details)`:

```
level := "down"     if any open incident has severity == "sev1"
       | "down"     if any cmdb component with sla_tier=family-critical
                    has live_status == "down"            # phase 2b
       | "degraded" if any open incident has severity in {"sev2","sev3"}
       | "degraded" if any active freeze window
       | "degraded" if any family-critical component live_status == "warning"  # phase 2b
       | "degraded" if any change in state "executed" but not "validated"
                    AND last_ts older than 30 min       # stuck-change detector
       | "ok"       otherwise
       | "unknown"  if we couldn't load the inputs at all (yaml/jsonl missing)
```

Phase 2a reads only `ops/incidents.jsonl`, `ops/changes.jsonl`,
`ops/freeze.yaml`. The CMDB live-status branches are wired in as code paths
but read `health_source` results from a dict that is empty in phase 2a — they
become live in phase 2b when Iris's `/data/unifi-topology.json` adapter lands.
Footnote under the pill states this explicitly.

## Render plumbing

```python
def _render_family_pill(state) -> str:
    level, reason, details = _compute_health_state(state)
    # one big pill + one sentence + a small footnote
    # uses .pill-family CSS class (added to _PORTAL_CSS)

def _render_index(state) -> str:
    # existing body … prepended with _render_family_pill(state)

def _render_topology_page(state) -> str:
    if _has_graphviz():
        svg = _render_topology_via_graphviz(state)
    else:
        svg = _render_topology_via_css_grid(state)
    return _page("Topology", "topology.html", body, …)
```

## DOT template (Graphviz path)

```
digraph topology {
  rankdir=TB; bgcolor="transparent"; fontname="system-ui";
  node [shape=box, style="rounded,filled", fontname="system-ui",
        fontsize=11, color="#888", fillcolor="#fff"];
  edge [color="#888", arrowsize=0.6];

  // one subgraph per tier with rank=same to force horizontal alignment
  subgraph cluster_t0 {
    label="0 — internet"; style="dashed"; color="#ccc";
    rank=same; ext_cloudflare; ext_isp_kpn;
  }
  subgraph cluster_t1 { label="1 — edge"; rank=same; net_udm; … }
  // tiers 2..5 likewise

  // edges from depends_on
  net_udm -> hw_plug_vdhngfw_power;
  net_cloudflared -> net_dns_cloudflare;
  // …
}
```

Each node gets `URL="cmdb.html#<id>"` so the SVG anchor renders as an
`<a xlink:href>` and a click drills into the CMDB row. Output is piped
through `dot -Tsvg` and embedded inline.

## CSS-grid fallback (no Graphviz)

Five rows, each row a flex container of coloured boxes grouped by `group`.
Dependency edges are shown as a small `↓` glyph between rows (not drawn
between specific boxes — keeps the markup trivial and the page <8 kB).
Each box is `<a href="cmdb.html#<id>">` so drill-down still works.

```html
<section class="topo">
  <div class="topo-row" data-tier="0">
    <h3>Internet</h3>
    <div class="topo-group" data-group="wan">…</div>
  </div>
  <div class="topo-arrow">↓</div>
  <div class="topo-row" data-tier="1">…</div>
  …
</section>
```

CSS lives in `_PORTAL_CSS`. Each box is a `.topo-node` with a status dot
(green/amber/red/grey). Status defaults to grey (`unknown`) in phase 2a;
phase 2b reads `/data/unifi-topology.json` when present.

## Live data join (phase 2b stub)

`_load_unifi_topology()` reads `/data/unifi-topology.json` if it exists
and returns `{cmdb_id: {status, last_seen, link}}`. If the file is
missing it returns `{}` and the topology page shows everything as
"unknown" — the page degrades gracefully per ADR-0002.

Expected JSON schema (documented here so Iris's adapter has a target):

```json
{
  "ts": "2026-05-13T18:00:00Z",
  "components": {
    "net.udm": {"status": "ok", "last_seen": "2026-05-13T17:59:55Z",
                 "link": "https://172.16.2.1/network/default/devices/..."},
    "hw.plug.vdhngfw_power": {"status": "warning", "last_seen": "…"}
  }
}
```

`status` is one of `ok | warning | down | unknown`. The renderer maps
that 1:1 to the pill colours.

## Page weight budget

| Page | HTML+CSS target | Notes |
|---|---|---|
| index.html | < 12 kB | existing ~9 kB + pill block (~1 kB) |
| topology.html | < 30 kB | CSS-grid path ~8 kB; Graphviz SVG inline ~10–15 kB |

CSS additions ~600 bytes (pill + topo classes). All within Apollo's
50 kB-per-page house budget.

## Anti-scope

- No client-side JS. Pill state computed server-side; auto-refresh via
  existing `<meta http-equiv="refresh" content="600">`.
- No SSE / WebSocket. Existing 10-min CronJob (`ops_render.sh`) writes
  the page; Iris's separate 60-s job (phase 2b) will write
  `/data/unifi-topology.json`.
- No new CMDB ids beyond two TODO placeholders for the topology diagram
  (`net.switch.poesw01`, `net.ap.kantoor`, `net.isp.kpn`). Cluster-tier
  ids are phase 2c.
- No reconciliation worker. CMDB stays human-input only per ADR-0002.

— Apollo
