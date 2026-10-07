#!/usr/bin/env python3
"""
rebuild_index.py — executable form of SOP-rebuild-task-index.

Re-renders Team Knowledge/tasks/INDEX.md from the current state of the tasks tree.
Faithful to the SOP:
  - Walks tsk-*.md under open/, in-progress/, done/YYYY/MM/, cancelled/YYYY/MM/.
  - No blocked/ folder exists; blocked tasks live in in-progress/ (or open/ when
    blocked on input) with blocked_reason set.
  - Drift correction 1 (status-vs-folder): the folder wins. Frontmatter status is
    rewritten in place, updated is bumped, and an update line is appended:
      - <date> <time> (rebuild) — corrected status field to match folder
  - Drift correction 2 (filename-vs-title-slug): detected and reported. The git mv
    rename is implemented but gated behind --apply-renames because renaming a task
    file breaks existing [[wikilinks]] in session logs and journal entries. Default
    is warn-only. (Judgment call, 2026-07-16; the SOP's premise for the
    rename is "because the title was edited", which does not hold for legacy
    intentionally-short slugs like tsk-2026-07-10-002.)
  - Atomic write (temp file + os.replace), then header validation.

Descriptor style matches the live index: one informative line per task, derived
deterministically: blocked reason when blocked, else the latest ## Updates line,
else the first line of ## What this is, else the title. Truncated on a word
boundary with [[wikilink]] and ** balance preserved.

Usage:
  python3 rebuild_index.py [--vault /path/to/PKA] [--actor name]
                           [--apply-renames] [--dry-run]

Exit codes: 0 ok, 1 failure.

This file is import-safe: server.py (task-board) imports its parsing and editing
helpers so there is a single implementation of the task-file semantics.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_VAULT = os.environ.get("PKA_VAULT", str(Path.home() / "Documents" / "PKA"))
TASKS_REL = "Team Knowledge/tasks"

PRIORITY_LABELS = {
    1: "Priority 1 — urgent",
    2: "Priority 2 — high",
    3: "Priority 3 — normal",
    4: "Priority 4 — low",
}

# ---------------------------------------------------------------- time helpers

def now_utc_rfc3339():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def now_utc_human():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

def now_local_minute():
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")

# ------------------------------------------------------------- parsing helpers

def _strip_quotes(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v

def parse_frontmatter(text):
    """Parse the YAML-subset frontmatter between the first two --- lines.
    Returns (dict, end_line_index) where end_line_index is the line number of the
    closing ---, or (dict, None) if no frontmatter found."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, None
    fm = {}
    key = None
    end = None
    for i in range(1, len(lines)):
        line = lines[i]
        if line.strip() == "---":
            end = i
            break
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*:", line):
            k, _, v = line.partition(":")
            key = k.strip()
            v = v.strip()
            if v.startswith("[") and v.endswith("]"):
                inner = v[1:-1].strip()
                fm[key] = [_strip_quotes(x) for x in inner.split(",") if x.strip()] if inner else []
            elif v == "":
                fm[key] = []  # probable block list; items follow
            else:
                fm[key] = _strip_quotes(v)
        elif re.match(r"^\s+-\s+", line) and key is not None:
            if not isinstance(fm.get(key), list):
                fm[key] = []
            fm[key].append(_strip_quotes(re.sub(r"^\s+-\s+", "", line)))
    return fm, end

def fm_scalar(fm, key, default=None):
    v = fm.get(key, default)
    if isinstance(v, list):
        return default
    if v in ("null", "", None):
        return default
    return v

def find_section(text, heading_prefix):
    """Find a '## <heading>' section. heading_prefix matches the start of the
    heading text (so 'Outcome' matches '## Outcome' and '## Outcome (cancelled)').
    Returns (heading_line_idx, end_line_idx_exclusive) in line numbers, or None."""
    lines = text.split("\n")
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^##\s+" + re.escape(heading_prefix), line):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("## "):
            end = j
            break
    return (start, end)

UPDATE_RE = re.compile(
    r"^-\s+(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})\s*\(([^)]*)\)\s*(?:—|–|--|-)\s*(.*)$"
)

def parse_updates(text):
    """Return update entries [{when, date, time, actor, text}] sorted oldest→newest.
    Robust to files that keep newest-first vs newest-last ordering."""
    span = find_section(text, "Updates")
    if not span:
        return []
    lines = text.split("\n")[span[0] + 1 : span[1]]
    out = []
    for line in lines:
        m = UPDATE_RE.match(line.strip())
        if m:
            date, tm, actor, body = m.groups()
            out.append({"when": f"{date} {tm}", "date": date, "time": tm,
                        "actor": actor.strip(), "text": body.strip()})
    out.sort(key=lambda u: u["when"])
    return out

def first_line_what_this_is(text):
    span = find_section(text, "What this is")
    if not span:
        return None
    for line in text.split("\n")[span[0] + 1 : span[1]]:
        s = line.strip()
        if s:
            return s
    return None

# ------------------------------------------------------------- editing helpers

def set_fm_field(text, key, value):
    """Rewrite (or insert) a scalar frontmatter field in place. value None → null.
    Strings containing ':' or starting with special chars get quoted."""
    if value is None:
        rendered = "null"
    elif isinstance(value, (int, float)):
        rendered = str(value)
    else:
        v = str(value)
        # Quote only when YAML actually needs it (colon+space, comment marker,
        # flow chars, leading/trailing space). Bare RFC3339 timestamps stay bare.
        needs_quote = bool(re.search(r'(:\s)|(\s#)|[\[\]{},]|^[\s"\'>|&*?%@`!]|\s$', v))
        rendered = f'"{v}"' if needs_quote else v
    lines = text.split("\n")
    fm, end = parse_frontmatter(text)
    if end is None:
        raise ValueError("no frontmatter found")
    key_rx = re.compile(r"^" + re.escape(key) + r"\s*:")
    for i in range(1, end):
        if key_rx.match(lines[i]):
            lines[i] = f"{key}: {rendered}"
            return "\n".join(lines)
    lines.insert(end, f"{key}: {rendered}")
    return "\n".join(lines)

def append_update_line(text, line):
    """Append a line at the end of the ## Updates list (SOP verb: append)."""
    span = find_section(text, "Updates")
    lines = text.split("\n")
    if not span:
        # create the section before ## Outcome if present, else at EOF
        out_span = find_section(text, "Outcome")
        insert_at = out_span[0] if out_span else len(lines)
        block = ["## Updates", "", line, ""]
        lines[insert_at:insert_at] = block
        return "\n".join(lines)
    start, end = span
    last_content = start
    for j in range(start + 1, end):
        if lines[j].strip():
            last_content = j
    lines.insert(last_content + 1, line)
    return "\n".join(lines)

def set_outcome(text, body_lines, cancelled=False):
    """Replace the ## Outcome section content (placeholder included) with body_lines.
    When cancelled, the heading becomes '## Outcome (cancelled)' per SOP-close-task §B."""
    heading = "## Outcome (cancelled)" if cancelled else "## Outcome"
    lines = text.split("\n")
    span = find_section(text, "Outcome")
    block = [heading, ""] + body_lines + [""]
    if span:
        start, end = span
        # keep anything after the section (usually nothing)
        lines[start:end] = block
    else:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(block)
    return "\n".join(lines)

def slugify(title):
    """SOP-create-task step 3, exactly."""
    s = re.sub(r"[^a-z0-9]+", "-", title.lower())
    s = s.strip("-")
    s = s[:50]
    s = re.sub(r"-+$", "", s)
    return s

def run_git(vault, args, allow_fail=False):
    r = subprocess.run(["git", "-C", str(vault)] + args,
                       capture_output=True, text=True)
    if r.returncode != 0 and not allow_fail:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r

def git_mv(vault, src_rel, dst_rel):
    """git mv with two recoveries: untracked source (add first) and a transient
    index.lock held by a concurrent agent (retry once)."""
    import time
    r = run_git(vault, ["mv", src_rel, dst_rel], allow_fail=True)
    if r.returncode == 0:
        return
    err = r.stderr.strip()
    if "not under version control" in err:
        run_git(vault, ["add", src_rel])
        run_git(vault, ["mv", src_rel, dst_rel])
        return
    if "index.lock" in err:
        time.sleep(1.5)
        run_git(vault, ["mv", src_rel, dst_rel])
        return
    raise RuntimeError(f"git mv failed: {err}")

# ----------------------------------------------------------------- collection

def collect_tasks(vault):
    """Walk the four status roots. Returns a list of task dicts."""
    root = Path(vault) / TASKS_REL
    tasks = []
    for status_dir, pattern in [("open", "tsk-*.md"),
                                ("in-progress", "tsk-*.md"),
                                ("done", "*/*/tsk-*.md"),
                                ("cancelled", "*/*/tsk-*.md")]:
        base = root / status_dir
        if not base.is_dir():
            continue
        for p in sorted(base.glob(pattern)):
            if not p.is_file():
                continue
            text = p.read_text(encoding="utf-8")
            fm, _ = parse_frontmatter(text)
            updates = parse_updates(text)
            tasks.append({
                "path": p,
                "rel": str(p.relative_to(vault)),
                "basename": p.stem,
                "folder_status": status_dir,
                "fm": fm,
                "text": text,
                "updates": updates,
                "what": first_line_what_this_is(text),
            })
    return tasks

# ---------------------------------------------------------------- descriptors

def truncate_md(s, n=180):
    s = " ".join(s.split())
    if len(s) <= n:
        return s
    cut = s[:n]
    if " " in cut:
        cut = cut.rsplit(" ", 1)[0]
    while cut.count("[[") != cut.count("]]") and "[[" in cut:
        cut = cut[: cut.rfind("[[")].rstrip(" ,;:")
    if cut.count("**") % 2 == 1:
        cut = cut[: cut.rfind("**")].rstrip(" ,;:")
    return cut.rstrip(" ,;:.") + " …"

def latest_informative_update(task):
    for u in reversed(task["updates"]):
        if u["text"] and not re.match(r"^created\b", u["text"], re.IGNORECASE):
            return u
    return None

def descriptor(task):
    fm = task["fm"]
    blocked = fm_scalar(fm, "blocked_reason")
    if blocked and task["folder_status"] == "open":
        return "**blocked on input**: " + truncate_md(blocked, 160)
    u = latest_informative_update(task)
    if u:
        return truncate_md(u["text"])
    if task["what"]:
        return truncate_md(task["what"])
    return fm_scalar(fm, "title", task["basename"])

# ------------------------------------------------------------ drift correction

def fix_status_drift(vault, tasks, dry_run=False):
    """Folder wins. Returns list of corrected basenames."""
    fixed = []
    for t in tasks:
        fm_status = fm_scalar(t["fm"], "status")
        if fm_status == t["folder_status"]:
            continue
        fixed.append(t["basename"])
        if dry_run:
            continue
        text = t["text"]
        text = set_fm_field(text, "status", t["folder_status"])
        text = set_fm_field(text, "updated", now_utc_rfc3339())
        text = append_update_line(
            text, f"- {now_local_minute()} (rebuild) — corrected status field to match folder")
        t["path"].write_text(text, encoding="utf-8")
        t["text"] = text
        t["fm"], _ = parse_frontmatter(text)
        t["updates"] = parse_updates(text)
    return fixed

ID_RE = re.compile(r"^(tsk-\d{4}-\d{2}-\d{2}-\d{3})-(.*)$")

def check_filename_drift(vault, tasks, apply_renames=False, dry_run=False):
    """Filename slug vs title slug. The id portion is authoritative and never
    changes. Returns list of (basename, expected_basename, applied)."""
    drifts = []
    for t in tasks:
        m = ID_RE.match(t["basename"])
        title = fm_scalar(t["fm"], "title")
        if not m or not title:
            continue
        tid, actual_slug = m.groups()
        expected = slugify(title)
        if actual_slug == expected:
            continue
        new_basename = f"{tid}-{expected}"
        applied = False
        if apply_renames and not dry_run:
            src = t["rel"]
            dst = str(Path(src).with_name(new_basename + ".md"))
            git_mv(vault, src, dst)
            t["path"] = Path(vault) / dst
            t["rel"] = dst
            t["basename"] = new_basename
            applied = True
        drifts.append((t["basename"] if applied else t["basename"], new_basename, applied))
    return drifts

# -------------------------------------------------------------------- render

def _due_str(fm):
    due = fm_scalar(fm, "due")
    return f" — due {due}" if due else ""

def render_index(tasks, actor):
    now = datetime.now(timezone.utc)
    month_key = now.strftime("%Y/%m")
    week_ago = now - timedelta(days=7)

    open_tasks = [t for t in tasks if t["folder_status"] == "open"]
    inprog = [t for t in tasks if t["folder_status"] == "in-progress"]
    done = [t for t in tasks if t["folder_status"] == "done"]
    cancelled = [t for t in tasks if t["folder_status"] == "cancelled"]

    def created_date(t):
        c = fm_scalar(t["fm"], "created", "")
        return c[:10] if c else ""

    def updated_dt(t):
        u = fm_scalar(t["fm"], "updated", "")
        try:
            return datetime.strptime(u, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            return datetime.fromtimestamp(t["path"].stat().st_mtime, tz=timezone.utc)

    def in_month(t):
        return str(t["path"]).split("/tasks/")[-1].startswith(
            (f"done/{month_key}/", f"cancelled/{month_key}/"))

    blocked_inprog = [t for t in inprog if fm_scalar(t["fm"], "blocked_reason")]
    done_month = [t for t in done if in_month(t)]
    canc_month = [t for t in cancelled if in_month(t)]

    L = []
    L.append("# Tasks Index")
    L.append("")
    L.append("_Auto-generated. Do not edit by hand. Run `SOP-rebuild-task-index` to regenerate._")
    L.append("")
    L.append(f"_Last rebuilt: {now_utc_human()} ({actor})_")
    L.append("")
    L.append("## Summary")
    L.append(f"- Open: {len(open_tasks)}")
    L.append(f"- In progress: {len(inprog)} ({len(blocked_inprog)} blocked)")
    L.append(f"- Done (this month): {len(done_month)}")
    L.append(f"- Cancelled (this month): {len(canc_month)}")
    L.append("")
    L.append(f"## Open ({len(open_tasks)})")

    open_ids = {fm_scalar(t["fm"], "id"): t for t in open_tasks}
    children = {}
    top_level = []
    for t in open_tasks:
        parent = fm_scalar(t["fm"], "parent")
        if parent and parent in open_ids and parent != fm_scalar(t["fm"], "id"):
            children.setdefault(parent, []).append(t)
        else:
            top_level.append(t)

    for prio in (1, 2, 3, 4):
        L.append("")
        L.append(f"### {PRIORITY_LABELS[prio]}")
        rows = [t for t in top_level
                if int(fm_scalar(t["fm"], "priority", 3) or 3) == prio]
        rows.sort(key=lambda t: (created_date(t), t["basename"]))
        if not rows:
            L.append("- (none)")
        for t in rows:
            L.append(f"- [[{t['basename']}]] — {fm_scalar(t['fm'], 'assignee', 'unassigned')}"
                     f" — created {created_date(t)}{_due_str(t['fm'])} — {descriptor(t)}")
            for c in children.get(fm_scalar(t["fm"], "id"), []):
                L.append(f"  - sub: [[{c['basename']}]] — assignee: "
                         f"{fm_scalar(c['fm'], 'assignee', 'unassigned')}")

    L.append("")
    L.append(f"## In progress ({len(inprog)})")
    inprog_sorted = sorted(inprog, key=updated_dt, reverse=True)
    if not inprog_sorted:
        L.append("- (none)")
    for t in inprog_sorted:
        blocked = fm_scalar(t["fm"], "blocked_reason")
        assignee = fm_scalar(t["fm"], "assignee", "unassigned")
        if blocked:
            L.append(f"- [[{t['basename']}]] — {assignee} — BLOCKED: {truncate_md(blocked, 200)}")
        else:
            L.append(f"- [[{t['basename']}]] — {assignee}{_due_str(t['fm'])} — {descriptor(t)}")

    L.append("")
    L.append("## By assignee")
    by_assignee = {}
    for t in open_tasks + inprog:
        a = fm_scalar(t["fm"], "assignee", "unassigned")
        state = t["folder_status"]
        extra = ""
        if fm_scalar(t["fm"], "blocked_reason"):
            extra += ", blocked"
        due = fm_scalar(t["fm"], "due")
        if due:
            extra += f", due {due}"
        by_assignee.setdefault(a, []).append(
            f"{fm_scalar(t['fm'], 'id', t['basename'])} ({state}{extra})")
    if not by_assignee:
        L.append("- (none)")
    for a in sorted(by_assignee):
        L.append(f"- {a}: " + ", ".join(sorted(by_assignee[a])))

    L.append("")
    L.append("## Recently closed (last 7 days)")
    recent = [(updated_dt(t), t, "done") for t in done if updated_dt(t) >= week_ago]
    recent += [(updated_dt(t), t, "cancelled") for t in cancelled if updated_dt(t) >= week_ago]
    recent.sort(key=lambda x: x[0], reverse=True)
    if not recent:
        L.append("- (none)")
    for dt, t, kind in recent:
        u = latest_informative_update(t)
        desc = truncate_md(u["text"]) if u else descriptor(t)
        L.append(f"- {dt.strftime('%Y-%m-%d')} [[{t['basename']}]] — {kind} — {desc}")
    L.append("")
    return "\n".join(L)

# --------------------------------------------------------------------- main

def rebuild(vault=DEFAULT_VAULT, actor="task-board", apply_renames=False, dry_run=False):
    vault = Path(vault)
    tasks_root = vault / TASKS_REL
    if not tasks_root.is_dir():
        raise SystemExit(f"tasks root not found: {tasks_root}")

    tasks = collect_tasks(vault)
    status_fixes = fix_status_drift(vault, tasks, dry_run=dry_run)
    drifts = check_filename_drift(vault, tasks, apply_renames=apply_renames, dry_run=dry_run)

    content = render_index(tasks, actor)

    if dry_run:
        print(content)
        if status_fixes:
            print(f"\n[dry-run] status drift fixes: {status_fixes}", file=sys.stderr)
        for cur, exp, applied in drifts:
            print(f"[dry-run] filename drift: {cur} → {exp} "
                  f"({'would rename' if apply_renames else 'warn-only'})", file=sys.stderr)
        return

    # Atomic write per SOP §5
    fd, tmp = tempfile.mkstemp(dir=str(tasks_root), prefix=".index-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, str(tasks_root / "INDEX.md"))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    # Validate per SOP §6
    head = (tasks_root / "INDEX.md").read_text(encoding="utf-8").split("\n")
    if not any(l.startswith("_Auto-generated.") for l in head[:5]):
        raise SystemExit("rebuild failed: header validation")

    for b in status_fixes:
        print(f"drift-fix: corrected status to match folder on {b}", file=sys.stderr)
    for cur, exp, applied in drifts:
        note = "renamed" if applied else "WARN filename/title-slug drift (not renamed; use --apply-renames)"
        print(f"{note}: {cur} → {exp}", file=sys.stderr)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Rebuild Team Knowledge/tasks/INDEX.md per SOP-rebuild-task-index")
    ap.add_argument("--vault", default=DEFAULT_VAULT)
    ap.add_argument("--actor", default="task-board")
    ap.add_argument("--apply-renames", action="store_true",
                    help="apply filename/title-slug drift renames via git mv (default: warn only)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the rendered index to stdout; write nothing")
    args = ap.parse_args()
    rebuild(vault=args.vault, actor=args.actor,
            apply_renames=args.apply_renames, dry_run=args.dry_run)
