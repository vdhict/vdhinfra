# Ops portal v2 — IA + build

Author: Apollo (frontend-engineer)
Change: chg-2026-05-13-018
Date: 2026-05-13

## Context

The ops portal at `https://ops.bluejungle.net/` currently surfaces a single
auto-refreshing page (`/ops.html`) rendered by `ops/ops dashboard --html`. The
nginx document root (`/data/web/`) also serves the cluster-health daily
reports (`<date>.html` + an `index.html` from `report.py`). Today `/` shows
the cluster-health index — the ops view is hidden behind `/ops.html`.

Goal: make `/` the ops portal landing, surface every operational data source
we already have, keep page weight under 50 kB per page, no JS framework, no
build step, no external CDNs. Single operator — IA should be quick to scan,
not enterprise-comprehensive.

## Page tree

| URL | Purpose | Data sources |
|---|---|---|
| `/` (index.html) | One-screen "is the lab on fire?" landing. KPIs, open changes, open incidents, active freezes, active locks, accepted risks count, links to deep views. | `changes.jsonl`, `incidents.jsonl`, `freeze.yaml`, `ops/locks/*`, `accepted_risks.yaml`, `cmdb.yaml` |
| `/changes.html` | Full change log. Filter chips: open / today / 7d / all. Each row links to a per-change detail. | `changes.jsonl` |
| `/incidents.html` | Full incident log, severity-colored. | `incidents.jsonl` |
| `/cmdb.html` | Component inventory grouped by owner_agent. Sensitive flag visible. | `cmdb.yaml` |
| `/risks.html` | Accepted risks with ADR links and review-by dates. | `accepted_risks.yaml`, `docs/adr/*.md` |
| `/team.html` | The roster (Atlas + 9 specialists). Useful when a CMDB row shows `owner_agent: ha-engineer` and you want to recall who that is. | `ops/roster.md` |
| `/reports.html` | Daily cluster-health reports index — was `index.html`, renamed by this change to free up `/`. Links to existing `<date>.html` pages (unchanged). | `report.py` output |

Daily report pages (`/2026-05-13.html`, etc.) keep working as-is. They link
back to `reports.html` instead of `index.html` (one-line patch in `report.py`).

## Component inventory

Reusable bits, each a tiny chunk of HTML:

- **header** — title, breadcrumb nav strip, generated timestamp + auto-refresh meta.
- **kpi-strip** — responsive grid of KPI cards (open changes, open incidents, active freeze, locks, accepted risks, components).
- **status-banner** — only rendered when a freeze is active or sev≤2 open incidents exist. Yellow/red border.
- **change-row** / **incident-row** — table rows with risk/sev coloured pill, status, resource, summary, updated-at.
- **cmdb-section** — one `<section>` per owner_agent with a table inside.
- **footer** — generated-at + link to repo + invocation hint (`./ops/ops status`).

Single shared stylesheet `style.css` (inlined per page; ~3 kB).

## Implementation

- Refactor `cmd_dashboard` in `ops/ops` so `--html` accepts a **directory**:
  writes `index.html`, `changes.html`, `incidents.html`, `cmdb.html`,
  `risks.html`, `team.html`. Old single-file semantics preserved when the
  arg ends in `.html` (writes the legacy mega-page — not used in production
  after this change).
- Update `ops_render.sh` to call `--html /data/web` (the directory).
- Update `report.py`: write daily reports list to `reports.html`, and patch
  the per-date page nav link from `index.html` → `reports.html`.

## Anti-scope

- **No SPA, no JS framework, no build step** — house rules.
- **No web fonts, no CDNs, no analytics** — house rules.
- **No live WebSocket updates** — page is regenerated every 10 min by the
  CronJob; meta-refresh handles the rest.
- **No write actions from the portal** — the CLI is the only writer. The
  portal is read-only.
- **No fancy charts** — KPI numbers + tables is enough. The cluster-health
  daily reports already carry the SVG trend charts. If a chart is needed
  on the portal, it goes via the daily report path.
- **No per-change permalink fragment IDs** that re-render the world — each
  page is one HTTP request, no client routing.
- **No authentication added** — relies on the existing envoy-internal /
  LAN scope (the route's parentRef is `envoy-internal`, so this is
  already LAN-only).

## Page-weight budget

| Page | HTML | CSS (inlined) | JS | Target total |
|---|---|---|---|---|
| index.html | ~10 kB | ~3 kB | 0 | <15 kB |
| changes.html | ~20 kB at 119 events | ~3 kB | 0 | <30 kB (grows with history; prune column list if needed) |
| incidents.html | ~5 kB | ~3 kB | 0 | <10 kB |
| cmdb.html | ~10 kB at 32 components | ~3 kB | 0 | <15 kB |
| risks.html | ~3 kB | ~3 kB | 0 | <8 kB |
| team.html | ~5 kB | ~3 kB | 0 | <10 kB |

All pages share the same CSS chunk (inlined for simplicity — could be
extracted to `/style.css` later if we want one HTTP request per asset, but
total bytes saved isn't worth the extra moving part).

## Heph (k8s-engineer) follow-up

- **`ops_render.sh`** must invoke `python3 ops/ops dashboard --html /data/web`
  (directory, not a file). I'll edit the script as part of this change since
  it's in the repo; no kustomize change needed, the ConfigMap will pick up
  the script change on next Flux reconcile. Heph: please force-reconcile
  `observability/cluster-health` after merge so the CronJob picks up the
  new ConfigMap. No HTTPRoute change (route already covers `ops.*` and `/`).
- The `ops-snapshot.json` write in `ops_render.sh` continues to work — it
  doesn't touch the new files.

## Rollback

`git revert <merge-sha>`. The portal degrades gracefully: until the next
CronJob run, `/` still serves whatever was last written (the v1 dashboard
or the previous index.html). After revert + reconcile, `index.html` is
once again the cluster-health reports list and `/ops.html` is the v1
portal.

## Validation

- Local: `python3 ops/ops dashboard --html /tmp/ops_v2` produces 6 HTML
  files. Open `/tmp/ops_v2/index.html` in a browser. Check all nav links.
- Page-weight: `wc -c /tmp/ops_v2/*.html` — each page <50 kB.
- Mobile width: visual check at 375 px via devtools.
- Dark mode: macOS dark mode → page inverts via `color-scheme: light dark`.
