# Design: Team-presentation artefact set

**Author**: Apollo (frontend-engineer)
**Date**: 2026-05-19
**Change**: chg-2026-05-19-005
**Status**: Implemented

---

## Context

Three presentation artefacts for Hermes's "A house that runs itself (almost)" content:

1. Long deck — 25 slides for a 30-minute live talk
2. Short deck — 5 slides for a 3-minute coffee-chat handout
3. Interactive scrolly tour — a public-facing URL for QR-code sharing

The audience is tech-curious non-engineers. The words are fixed (Hermes did the read-aloud test).
Apollo owns: stack choice, visual design, SVG assets, screenshots, build tooling.

---

## Stack choice

### Artefacts 1 + 2 — Long deck and Short deck: Reveal.js standalone (no build)

**Chosen: Reveal.js bundled locally, single HTML file per deck.**

Alternatives considered:

| Option | Verdict |
|---|---|
| **Reveal.js standalone** | Single HTML file. No build pipeline. Exportable to PDF via `?print-pdf`. Speaker notes via `aside.notes`. Keyboard + touch navigation. Self-hostable with zero runtime deps. CSS custom properties allow shared visual language between long/short. |
| Marp (Markdown → slides) | Cleaner authoring, but requires a Node build step and produces less polished output. Speaker notes require extra fiddling. Worse for complex multi-column slides (hardware diagram, risk dial). Rejected. |
| WebSlides | No speaker notes support. Not maintained since 2019. Rejected. |
| Google Slides / PowerPoint | Runtime CDN or proprietary format. Rejected on self-hosting grounds. |
| SvelteKit (Stack D) | Massive overkill for a static slide deck. Rejected. |

Reveal.js wins because: one HTML file per deck, zero runtime deps, speaker notes built in, PDF export works, CSS variables shared across both decks for visual consistency, mobile-friendly with touch navigation.

**Page weight target**: Stack A / B territory. Both decks must be < 100 kB gzipped (they contain no JS framework, only Reveal.js at ~67 kB minified + gzip ≈ 22 kB, plus inline SVGs).

### Artefact 3 — Scrolly tour: Plain HTML + CSS + vanilla JS (Stack B equivalent)

**Chosen: Single-page HTML with inline CSS and vanilla JS (<30 lines). No build pipeline.**

Alternatives considered:

| Option | Verdict |
|---|---|
| **Vanilla HTML + Alpine.js inline** | Hermes already wrote the HTML skeleton and CSS snap recipe. She specified "no JS dependency that would break if hosted offline" and "single index.html + one CSS file". Alpine.js (15 kB) could handle the toggle/flip, but 30 lines of vanilla JS does it with zero dependencies. Chosen. |
| Astro (Stack C) | Hermes explicitly ruled out: "no framework, no CDN, no JS that would break offline". Astro would buy component composition I don't need for 6 static panels. The interactive elements (card flip = pure CSS :hover, compare toggle = 10 lines JS, step popover = details element) don't justify a build pipeline. Rejected. |
| HTMX + Alpine (Stack B) | HTMX is for partial server-fetched updates — there's no server here, just static panels. Rejected on grounds of adding a dependency for nothing. |

The scrolly tour's interactive requirements are:
- CSS 3D card flip (pure CSS `:hover` + `perspective` + `rotateY`) — zero JS
- Compare toggle (swap two pre-loaded divs) — 10 lines vanilla JS
- Step popover on click (expand/collapse via `details` or classList toggle) — 10 lines vanilla JS or pure `<details>`

Vanilla wins. The output is deployable by `python3 -m http.server` or any static file server.

**Page weight target**: Stack B < 100 kB. Tour has no external JS library; Alpine.js is not used. Estimated < 40 kB gzipped (HTML + CSS + inline SVGs + tiny JS).

---

## Visual language

- **Colour**: Two CSS variables — `--accent` (#3b82f6, blue-500) and `--accent-warm` (#f59e0b, amber-500). Everything else is neutral greys.
- **Mode**: `color-scheme: light dark`. Light: `--bg: #fff`, `--fg: #111`. Dark: `--bg: #0f172a`, `--fg: #e2e8f0`.
- **Typography**: System font stack. `font-variant-numeric: tabular-nums` on any numbers.
- **SVGs**: Inline, monochrome + single accent. Stroke-based, 2px lines, no fills except light greys. Designed to read equally in dark and light mode via `currentColor`.
- **Icons**: Inline SVG paths derived from Heroicons / Tabler icons set (paths hardcoded, no icon font dependency).

---

## Build and rebuild

```bash
# Decks (no build needed — open the file directly)
open web/presentation/long/index.html
open web/presentation/short/index.html

# Tour (no build needed — serve directory)
python3 -m http.server 8080 --directory web/tour/

# Or use Make:
make serve-long     # python3 -m http.server on long deck
make serve-short    # python3 -m http.server on short deck
make serve-tour     # python3 -m http.server on tour
make screenshots    # run kiosk-verify captures (requires kiosk-verify in PATH)
```

After Hermes edits a slide: edit the corresponding HTML in `web/presentation/long/index.html`
or `web/presentation/short/index.html` and reload. No rebuild step. The SVGs are inline so
editing them is a text edit.

For the tour: edit `web/tour/index.html` and reload. Single file.

---

## Open dependencies (for Iris + Heph)

- DNS A record: `tour.bluejungle.net` → cluster LoadBalancer IP
- HTTPRoute: `tour.bluejungle.net` → service in `tools` or `network` namespace
- The static files under `web/tour/` can be served by the existing nginx or a new minimal
  nginx deployment. No Node.js service needed.
- Same for `web/presentation/` if those are to be publicly accessible.

Mark: **deployment pending** — artefacts are locally complete and screenshot-verified.
Iris + Heph to handle DNS + HTTPRoute + nginx deployment in a follow-up change.
