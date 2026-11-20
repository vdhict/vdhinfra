#!/usr/bin/env python3
"""Atlas work queue + tick wake (team decision, tsk-2026-11-20-116).

Queue: ops/workqueue.jsonl, one JSON object per line:
  id, prio (1-3), due (ISO-8601 or null), reason (REQUIRED when due is set:
  the external reason), owner, card, status (open|done), note.
Atlas is the only writer. Every write is a temp file + rename (atomic).

Why launchd on the Mini and not a cluster CronJob: the wake file must land in
~/mypka-handoff/<date>/ on the Mini, where Atlas's pointer hook picks up new
handoff files. The cluster cannot write files on the Mini. So the `tick`
subcommand runs from launchd agent com.sheijden.workqueue-tick every 10 min,
from ~/.local/bin, with WORKQUEUE pointing at the main checkout's queue file.

tick rules:
  - wake only for open items that are due (due <= now) or prio-1 with no due;
  - at most one wake file per 30 min (state ~/.local/state/workqueue/last-tick);
  - never 23:00-07:00 local, except prio-1 items whose due has passed;
  - the wake file is silent (a file is not a sound); no secrets, no names;
  - every successful run stamps ~/.local/state/workqueue/last-run.
Env: WORKQUEUE (queue file), WORKQUEUE_STATE (state dir), WORKQUEUE_HANDOFF
(handoff root). Defaults: repo-relative queue, ~/.local/state/workqueue,
~/mypka-handoff.
"""
import argparse, json, os, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
DEFAULT_Q = Path(__file__).resolve().parents[2] / "ops" / "workqueue.jsonl"
Q = Path(os.environ.get("WORKQUEUE", DEFAULT_Q))
STATE = Path(os.environ.get("WORKQUEUE_STATE", HOME / ".local/state/workqueue"))
HANDOFF = Path(os.environ.get("WORKQUEUE_HANDOFF", HOME / "mypka-handoff"))
THROTTLE_S = 30 * 60


def parse_due(s):
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def load(missing_ok=False):
    items, errs, seen = [], [], set()
    if not Q.exists():
        return items, ([] if missing_ok else [f"{Q}: missing"])
    for n, line in enumerate(Q.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            o = json.loads(line)
            assert isinstance(o, dict)
        except Exception:
            errs.append(f"line {n}: bad json")
            continue
        i = o.get("id")
        if not i:
            errs.append(f"line {n}: no id")
        elif i in seen:
            errs.append(f"line {n}: duplicate id {i}")
        seen.add(i)
        if o.get("prio") not in (1, 2, 3):
            errs.append(f"line {n} ({i}): prio must be 1-3")
        if o.get("status") not in ("open", "done"):
            errs.append(f"line {n} ({i}): status must be open|done")
        if o.get("due"):
            if not o.get("reason"):
                errs.append(f"line {n} ({i}): due without reason")
            try:
                parse_due(o["due"])
            except Exception:
                errs.append(f"line {n} ({i}): bad due")
        items.append(o)
    return items, errs


def save(items):
    text = "".join(json.dumps(o, ensure_ascii=False) + "\n" for o in items)
    Q.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=Q.parent, prefix=".workqueue.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, Q)


def need_valid(missing_ok=False):
    items, errs = load(missing_ok)
    if errs:
        print("\n".join(errs), file=sys.stderr)
        sys.exit(2)
    return items


def cmd_add(a):
    items = need_valid(True)
    o = dict(id=a.id, prio=a.prio, due=a.due, reason=a.reason, owner=a.owner,
             card=a.card, status="open", note=a.note)
    if any(x["id"] == a.id for x in items):
        sys.exit(f"duplicate id {a.id}")
    if a.due and not a.reason:
        sys.exit("due requires --reason")
    if a.due:
        parse_due(a.due)
    save(items + [o])
    print("added", a.id)


def cmd_done(a):
    items = need_valid()
    for o in items:
        if o["id"] == a.id:
            o["status"] = "done"
            save(items)
            print("done", a.id)
            return
    sys.exit(f"unknown id {a.id}")


def cmd_list(a):
    for o in need_valid():
        if a.open and o["status"] != "open":
            continue
        print(f'{o["id"]} p{o["prio"]} {o["status"]} due={o.get("due")} '
              f'{o.get("card")} {o.get("note", "")}')


def cmd_validate(a):
    items, errs = load()
    if errs:
        print("\n".join(errs), file=sys.stderr)
        sys.exit(2)
    print(f"ok: {len(items)} items")


def stamp(name):
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / name).write_text(datetime.now(timezone.utc).isoformat() + "\n")


def cmd_tick(a):
    items, errs = load()
    if errs:
        print("\n".join(errs), file=sys.stderr)
        sys.exit(2)
    now = datetime.now(timezone.utc)
    night = not (7 <= now.astimezone().hour < 23)
    openi = [o for o in items if o["status"] == "open"]

    def passed(o):
        return bool(o.get("due")) and parse_due(o["due"]) <= now

    elig = [o for o in openi if passed(o) or (o["prio"] == 1 and not o.get("due"))]
    if night:
        elig = [o for o in elig if o["prio"] == 1 and passed(o)]
    if a.force and not elig:
        elig = openi
    last = STATE / "last-tick"
    throttled = (not a.force and last.exists()
                 and now.timestamp() - last.stat().st_mtime < THROTTLE_S)
    if elig and not throttled:
        loc = now.astimezone()
        d = HANDOFF / loc.strftime("%Y-%m-%d")
        d.mkdir(parents=True, exist_ok=True)
        f = d / f'{loc.strftime("%H%M%S")}-tick-to-atlas-{len(elig)}items.md'
        lines = ["Van: tick (workqueue)", "Aan: Atlas",
                 f"Onderwerp: werkrij, {len(elig)} item(s) aan de beurt", ""]
        for o in sorted(elig, key=lambda o: o["prio"]):
            lines.append(f'- {o["id"]} prio{o["prio"]} due={o.get("due") or "-"} '
                         f'kaart={o.get("card") or "-"} reden={o.get("reason") or "-"}: '
                         f'{o.get("note", "")}')
        lines += ["", "Bron: ops/workqueue.jsonl. Stil bestand, geen geluid."]
        tmp = f.with_suffix(".tmp")
        tmp.write_text("\n".join(lines) + "\n")
        os.replace(tmp, f)
        STATE.mkdir(parents=True, exist_ok=True)
        last.write_text(now.isoformat() + "\n")
        print("wrote", f)
    else:
        print("no wake" + (" (throttled)" if elig else ""))
    stamp("last-run")


def main():
    p = argparse.ArgumentParser()
    s = p.add_subparsers(dest="c", required=True)
    x = s.add_parser("add")
    x.add_argument("id"); x.add_argument("--prio", type=int, default=2)
    x.add_argument("--due"); x.add_argument("--reason"); x.add_argument("--owner", default="atlas")
    x.add_argument("--card"); x.add_argument("--note", default="")
    x.set_defaults(f=cmd_add)
    x = s.add_parser("done"); x.add_argument("id"); x.set_defaults(f=cmd_done)
    x = s.add_parser("list"); x.add_argument("--open", action="store_true"); x.set_defaults(f=cmd_list)
    x = s.add_parser("validate"); x.set_defaults(f=cmd_validate)
    x = s.add_parser("tick"); x.add_argument("--force", action="store_true"); x.set_defaults(f=cmd_tick)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
