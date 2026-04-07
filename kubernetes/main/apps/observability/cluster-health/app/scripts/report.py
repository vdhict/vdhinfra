#!/usr/bin/env python3
"""Generate the daily report (markdown + HTML) and refresh the web index.
Reads raw + triage + trends, computes a headline status, and writes:
  /data/reports/YYYY-MM-DD.md
  /data/web/YYYY-MM-DD.html
  /data/web/index.html
Old reports beyond 30 days are pruned.
"""
from __future__ import annotations

import html
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, "/scripts")
from lib import REPORTS_DIR, RAW_DIR, TRENDS_DIR, TRIAGE_DIR, WEB_DIR, log, read_json, today  # noqa: E402

REPORT_BASE_URL = os.environ.get("REPORT_BASE_URL", "")


# ---------- Severity classification ----------

def classify(raw: dict, trends: dict, triage: dict) -> tuple[str, str, list[dict]]:
    """Return (status_color, headline, issues[])."""
    issues: list[dict] = []
    sections = raw.get("sections", {})
    k8s = sections.get("k8s", {})

    # Nodes
    n = k8s.get("nodes", {})
    if n.get("ready", 0) < n.get("total", 0):
        issues.append({"sev": "crit", "area": "nodes",
                       "msg": f"{n['total'] - n['ready']}/{n['total']} nodes NotReady"})

    # Flux
    for label, plural in (("Kustomizations", "flux_ks"), ("HelmReleases", "flux_hr")):
        f = k8s.get(plural, {})
        failing = [i for i in f.get("items", []) if not i.get("ready") and not i.get("suspended")]
        if failing:
            issues.append({
                "sev": "warn" if len(failing) <= 3 else "crit",
                "area": "flux",
                "msg": f"{len(failing)} {label} not ready: " + ", ".join(f"{i['namespace']}/{i['name']}" for i in failing[:5]),
            })

    # Pods
    pods = k8s.get("pods", {})
    if pods.get("crashloop"):
        issues.append({
            "sev": "crit",
            "area": "pods",
            "msg": f"{len(pods['crashloop'])} container(s) in CrashLoopBackOff: " +
                   ", ".join(f"{c['namespace']}/{c['pod']}" for c in pods["crashloop"][:5]),
        })
    if pods.get("image_pull_back_off"):
        issues.append({
            "sev": "warn",
            "area": "pods",
            "msg": f"{len(pods['image_pull_back_off'])} ImagePullBackOff",
        })
    if pods.get("pending_long"):
        issues.append({
            "sev": "warn",
            "area": "pods",
            "msg": f"{len(pods['pending_long'])} pod(s) Pending >15min",
        })
    if pods.get("oom_killed"):
        issues.append({
            "sev": "warn",
            "area": "pods",
            "msg": f"{len(pods['oom_killed'])} OOMKilled in last 24h",
        })

    # Ceph
    ceph = sections.get("ceph", {})
    if ceph.get("health") not in (None, "HEALTH_OK"):
        sev = "crit" if ceph.get("health") == "HEALTH_ERR" else "warn"
        issues.append({"sev": sev, "area": "ceph", "msg": f"Ceph {ceph.get('health')}: " + ", ".join(ceph.get("health_checks", []))})
    if ceph.get("raw_used_pct", 0) > 80:
        issues.append({"sev": "warn", "area": "ceph", "msg": f"Ceph raw usage {ceph.get('raw_used_pct')}%"})

    # Postgres
    pg = sections.get("postgres", {})
    for c in pg.get("clusters", []):
        if not c.get("ready"):
            issues.append({"sev": "crit", "area": "postgres",
                           "msg": f"CNPG cluster {c['namespace']}/{c['name']} phase={c.get('phase')}"})

    # Certs (<14 days)
    for c in k8s.get("certs", {}).get("items", []):
        d = c.get("days_until_expiry")
        if d is not None and d < 14:
            issues.append({"sev": "crit" if d < 7 else "warn", "area": "certs",
                           "msg": f"Cert {c['namespace']}/{c['name']} expires in {d}d"})

    # External secrets
    es = k8s.get("external_secrets", {})
    if es.get("failed", 0):
        issues.append({"sev": "warn", "area": "external-secrets",
                       "msg": f"{es['failed']} ExternalSecret(s) failing"})

    # HTTPRoutes
    hr = k8s.get("httproutes", {})
    if hr.get("not_accepted", 0):
        issues.append({"sev": "warn", "area": "gateway",
                       "msg": f"{hr['not_accepted']} HTTPRoute(s) not Accepted"})

    # Home Assistant
    ha = sections.get("ha", {})
    if not ha.get("api_reachable"):
        issues.append({"sev": "crit", "area": "home-assistant", "msg": "HA API unreachable"})
    elif ha.get("seconds_since_latest_change") and ha["seconds_since_latest_change"] > 600:
        issues.append({"sev": "warn", "area": "home-assistant",
                       "msg": f"HA recorder stale: latest state change {ha['seconds_since_latest_change']}s ago"})
    if sections.get("z2m", {}).get("bridge_online") is False:
        issues.append({"sev": "warn", "area": "zigbee2mqtt", "msg": "Zigbee2MQTT bridge offline"})
    if sections.get("mqtt", {}).get("reachable") is False:
        issues.append({"sev": "crit", "area": "mqtt", "msg": "Mosquitto unreachable"})
    esphome = sections.get("esphome", {}) or {}
    if esphome.get("offline"):
        issues.append({"sev": "warn", "area": "esphome",
                       "msg": f"{esphome['offline']} ESPHome device(s) offline"})

    # Trend alerts (informational)
    for a in (trends or {}).get("alerts", []):
        issues.append({"sev": a["severity"], "area": "trend", "msg": a["message"]})

    crit = sum(1 for i in issues if i["sev"] == "crit")
    warn = sum(1 for i in issues if i["sev"] == "warn")
    if crit:
        color, emoji = "red", "🔴"
        headline = f"{emoji} {crit} critical issue(s), {warn} warning(s)"
    elif warn:
        color, emoji = "yellow", "🟡"
        headline = f"{emoji} {warn} warning(s), no critical issues"
    else:
        color, emoji = "green", "🟢"
        headline = f"{emoji} All systems healthy"
    return color, headline, issues


# ---------- Markdown rendering ----------

def render_markdown(date: str, raw: dict, triage: dict, trends: dict, color: str, headline: str, issues: list[dict]) -> str:
    sections = raw.get("sections", {})
    k8s = sections.get("k8s", {})
    pods = k8s.get("pods", {})
    n = k8s.get("nodes", {})
    ceph = sections.get("ceph", {})
    pg = sections.get("postgres", {})
    ha = sections.get("ha", {})

    lines: list[str] = []
    lines.append(f"# Cluster Health — {date}")
    lines.append("")
    lines.append(f"**{headline}**")
    lines.append("")
    lines.append("## Key metrics")
    lines.append("")
    lines.append("| Area | Value |")
    lines.append("|---|---|")
    lines.append(f"| Nodes Ready | {n.get('ready', '?')}/{n.get('total', '?')} |")
    lines.append(f"| Flux Kustomizations Ready | {k8s.get('flux_ks', {}).get('ready', '?')}/{k8s.get('flux_ks', {}).get('total', '?')} |")
    lines.append(f"| Flux HelmReleases Ready | {k8s.get('flux_hr', {}).get('ready', '?')}/{k8s.get('flux_hr', {}).get('total', '?')} |")
    lines.append(f"| Pods | {pods.get('total', '?')} ({', '.join(f'{k}={v}' for k,v in pods.get('phases', {}).items())}) |")
    lines.append(f"| CrashLoopBackOff | {len(pods.get('crashloop', []))} |")
    lines.append(f"| OOMKilled (24h) | {len(pods.get('oom_killed', []))} |")
    lines.append(f"| Ceph Health | {ceph.get('health', 'unknown')} |")
    lines.append(f"| Ceph Raw Usage | {ceph.get('raw_used_pct', '?')}% |")
    lines.append(f"| Ceph OSDs Up/In/Total | {ceph.get('osd_up', '?')}/{ceph.get('osd_in', '?')}/{ceph.get('osd_total', '?')} |")
    lines.append(f"| CNPG Clusters Ready | {pg.get('ready', '?')}/{pg.get('total', '?')} |")
    lines.append(f"| HA API | {'reachable' if ha.get('api_reachable') else 'UNREACHABLE'} |")
    lines.append(f"| HA Entities | {ha.get('entity_count', '?')} |")
    lines.append(f"| HA Unavailable States | {ha.get('unavailable_states', '?')} |")
    lines.append("")

    # Issues
    lines.append("## Issues")
    lines.append("")
    if not issues:
        lines.append("_None — all checks passed._")
    else:
        for sev in ("crit", "warn"):
            for i in issues:
                if i["sev"] == sev:
                    badge = "🔴" if sev == "crit" else "🟡"
                    lines.append(f"- {badge} **{i['area']}** — {i['msg']}")
    lines.append("")

    # Auto-fix audit
    lines.append("## Auto-fix audit (overnight)")
    lines.append("")
    audit = (triage or {}).get("audit", []) if triage else []
    dry = (triage or {}).get("dry_run", "?")
    if not audit:
        lines.append(f"No actions taken. (DRY_RUN={dry})")
    else:
        lines.append(f"{len(audit)} action(s) — DRY_RUN={dry}")
        lines.append("")
        lines.append("| Time | Action | Target | Reason | Outcome |")
        lines.append("|---|---|---|---|---|")
        for e in audit[:50]:
            lines.append(f"| {e['ts']} | {e['action']} | `{e['target']}` | {e['reason']} | {e['outcome']} |")
    lines.append("")

    # Trends
    lines.append("## Trends (7d)")
    lines.append("")
    pvc = (trends or {}).get("pvc_fill", []) if trends else []
    if pvc:
        lines.append("### PVC fill projection")
        lines.append("")
        lines.append("| PVC | Current % | Growth/day | Days to full |")
        lines.append("|---|---|---|---|")
        for p in pvc[:15]:
            d = p.get("days_to_full")
            d_str = f"**{d}**" if d is not None and d < 30 else (str(d) if d else "—")
            lines.append(f"| {p['namespace']}/{p['pvc']} | {p['current_pct']}% | {p['growth_pct_per_day']}%/d | {d_str} |")
        lines.append("")
    if (trends or {}).get("ceph_raw"):
        c = trends["ceph_raw"]
        lines.append(f"### Ceph raw")
        lines.append("")
        lines.append(f"Current **{c['current_pct']}%**, growing **{c['growth_pct_per_day']}%/day**, "
                     f"projected to hit 80% in **{c.get('days_to_80pct', '—')}** days.")
        lines.append("")
    np = (trends or {}).get("node_pressure", {}) if trends else {}
    if np:
        lines.append("### Node pressure (7d avg / max)")
        lines.append("")
        lines.append("| Node | CPU avg | CPU max | Mem avg | Mem max |")
        lines.append("|---|---|---|---|---|")
        cpus = np.get("cpu", {})
        mems = np.get("mem", {})
        for inst in sorted(set(cpus) | set(mems)):
            c = cpus.get(inst, {})
            m = mems.get(inst, {})
            lines.append(f"| {inst} | {c.get('avg', '—')}% | {c.get('max', '—')}% | {m.get('avg', '—')}% | {m.get('max', '—')}% |")
        lines.append("")

    lines.append("---")
    lines.append(f"_Generated at {datetime.now().isoformat(timespec='seconds')} — raw report: `/data/raw/{date}.json`_")
    lines.append("")
    return "\n".join(lines)


# ---------- HTML rendering ----------

CSS = """
body { font: 14px/1.5 -apple-system, system-ui, sans-serif; max-width: 1100px; margin: 2em auto; padding: 0 1em; color: #222; }
h1 { border-bottom: 2px solid #eee; padding-bottom: 0.3em; }
h2 { margin-top: 2em; color: #444; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; }
th, td { border: 1px solid #ddd; padding: 6px 10px; text-align: left; font-size: 13px; }
th { background: #f6f8fa; }
tr:nth-child(even) td { background: #fafbfc; }
.headline { font-size: 20px; padding: 1em; border-radius: 8px; margin: 1em 0; }
.green  { background: #e8f5e9; border-left: 6px solid #2e7d32; }
.yellow { background: #fff8e1; border-left: 6px solid #f9a825; }
.red    { background: #ffebee; border-left: 6px solid #c62828; }
code { background: #f3f4f6; padding: 1px 5px; border-radius: 3px; font-size: 12px; }
.chart { display: block; margin: 1em 0; max-width: 100%; height: auto; }
nav { background: #f6f8fa; padding: 1em; border-radius: 8px; margin-bottom: 1em; }
nav a { margin-right: 1em; }
"""


def md_to_html(md: str) -> str:
    """Tiny markdown subset → HTML. Tables, headings, bold, code, lists."""
    out_lines: list[str] = []
    in_table = False
    table_buf: list[list[str]] = []
    in_list = False

    def flush_table():
        nonlocal in_table, table_buf
        if not table_buf:
            in_table = False
            return
        out_lines.append("<table>")
        head = table_buf[0]
        out_lines.append("<thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead>")
        out_lines.append("<tbody>")
        for row in table_buf[2:]:
            out_lines.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
        out_lines.append("</tbody></table>")
        table_buf = []
        in_table = False

    def inline(s: str) -> str:
        s = html.escape(s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        # Italic _x_ — only when surrounded by non-word chars (avoids DRY_RUN being eaten)
        s = re.sub(r"(?<![A-Za-z0-9])_([^_\n]+?)_(?![A-Za-z0-9])", r"<em>\1</em>", s)
        return s

    for line in md.splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not in_table:
                in_table = True
                table_buf = []
            table_buf.append(cells)
            continue
        elif in_table:
            flush_table()

        if line.startswith("- "):
            if not in_list:
                out_lines.append("<ul>")
                in_list = True
            out_lines.append(f"<li>{inline(line[2:])}</li>")
            continue
        elif in_list:
            out_lines.append("</ul>")
            in_list = False

        if line.startswith("### "):
            out_lines.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("## "):
            out_lines.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("# "):
            out_lines.append(f"<h1>{inline(line[2:])}</h1>")
        elif line.strip() == "---":
            out_lines.append("<hr>")
        elif line.strip() == "":
            out_lines.append("")
        else:
            out_lines.append(f"<p>{inline(line)}</p>")
    if in_table:
        flush_table()
    if in_list:
        out_lines.append("</ul>")
    return "\n".join(out_lines)


def render_svg_chart(series: list[tuple], width: int = 600, height: int = 120, color: str = "#1976d2") -> str:
    if not series or len(series) < 2:
        return ""
    xs = [p[0] for p in series]
    ys = [p[1] for p in series]
    xmin, xmax = min(xs), max(xs)
    ymin, ymax = min(ys), max(ys)
    if xmax == xmin:
        xmax = xmin + 1
    if ymax == ymin:
        ymax = ymin + 1
    pad = 8

    def sx(x):
        return pad + (x - xmin) / (xmax - xmin) * (width - 2 * pad)

    def sy(y):
        return height - pad - (y - ymin) / (ymax - ymin) * (height - 2 * pad)

    pts = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in series)
    return (
        f'<svg class="chart" viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg">'
        f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{pts}"/>'
        f'<text x="{pad}" y="14" font-size="11" fill="#888">min {ymin:.1f} / max {ymax:.1f}</text>'
        f"</svg>"
    )


def render_html(date: str, color: str, headline: str, md: str, trends: dict) -> str:
    body = md_to_html(md)
    # Inject SVG charts after the trends headings
    charts = []
    for p in (trends or {}).get("pvc_fill", [])[:5]:
        charts.append(f"<h4>{html.escape(p['namespace'])}/{html.escape(p['pvc'])}</h4>")
        charts.append(render_svg_chart(p.get("series", [])))
    if (trends or {}).get("ceph_raw", {}).get("series"):
        charts.append("<h4>Ceph raw usage</h4>")
        charts.append(render_svg_chart(trends["ceph_raw"]["series"], color="#ef6c00"))
    chart_block = "\n".join(charts)

    nav = '<nav><a href="index.html">← All reports</a></nav>'
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Cluster Health — {date}</title>
<style>{CSS}</style>
</head><body>
{nav}
<div class="headline {color}">{html.escape(headline)}</div>
{body}
<h2>Trend charts</h2>
{chart_block}
</body></html>
"""


def render_index(reports: list[dict]) -> str:
    rows = []
    for r in reports:
        rows.append(
            f'<tr><td><a href="{r["date"]}.html">{r["date"]}</a></td>'
            f'<td><span class="badge {r["color"]}">{html.escape(r["headline"])}</span></td></tr>'
        )
    badge_css = """
    .badge { padding: 4px 10px; border-radius: 999px; font-size: 12px; }
    .badge.green { background: #c8e6c9; color: #1b5e20; }
    .badge.yellow { background: #ffe082; color: #5d4037; }
    .badge.red { background: #ffcdd2; color: #b71c1c; }
    """
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Cluster Health</title>
<style>{CSS}{badge_css}</style></head><body>
<h1>Cluster Health Reports</h1>
<p>Daily reports for the homelab Kubernetes cluster. Most recent first.</p>
<table><thead><tr><th>Date</th><th>Status</th></tr></thead><tbody>
{''.join(rows)}
</tbody></table>
<p style="color:#888;font-size:12px;">Source: <code>kubernetes/main/apps/observability/cluster-health</code></p>
</body></html>
"""


def prune_old(days: int = 30) -> None:
    cutoff = datetime.now().date() - timedelta(days=days)
    for d in (RAW_DIR, REPORTS_DIR, WEB_DIR, TRENDS_DIR, TRIAGE_DIR):
        for f in d.glob("*.*"):
            m = re.match(r"(\d{4}-\d{2}-\d{2})", f.name)
            if not m:
                continue
            try:
                fdate = datetime.fromisoformat(m.group(1)).date()
            except Exception:
                continue
            if fdate < cutoff:
                try:
                    f.unlink()
                except Exception:
                    pass


def main() -> int:
    date = today()
    raw = read_json(RAW_DIR / f"{date}.json", {}) or {}
    triage = read_json(TRIAGE_DIR / f"{date}.json", {}) or {}
    trends = read_json(TRENDS_DIR / f"{date}.json", {}) or {}

    color, headline, issues = classify(raw, trends, triage)
    md = render_markdown(date, raw, triage, trends, color, headline, issues)
    html_doc = render_html(date, color, headline, md, trends)

    (REPORTS_DIR / f"{date}.md").write_text(md)
    (WEB_DIR / f"{date}.html").write_text(html_doc)

    # Build index from all dated HTML files (last 7)
    reports = []
    for f in sorted(WEB_DIR.glob("*.html"), reverse=True):
        m = re.match(r"(\d{4}-\d{2}-\d{2})\.html$", f.name)
        if not m:
            continue
        d = m.group(1)
        # Use the headline from the matching markdown if present
        md_path = REPORTS_DIR / f"{d}.md"
        h = ""
        c = "green"
        if md_path.exists():
            txt = md_path.read_text()
            mh = re.search(r"\*\*(.+?)\*\*", txt)
            if mh:
                h = mh.group(1)
            if "🔴" in h:
                c = "red"
            elif "🟡" in h:
                c = "yellow"
        reports.append({"date": d, "headline": h, "color": c})
        if len(reports) >= 14:
            break
    (WEB_DIR / "index.html").write_text(render_index(reports))

    prune_old(30)
    log(f"report done for {date}: {color}/{headline}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
