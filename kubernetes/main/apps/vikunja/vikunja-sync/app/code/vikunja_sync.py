#!/usr/bin/env python3
"""vikunja_sync.py — two-way sync between the vault and Vikunja, as a cluster CronJob.

The owner, 2026-09-28: Vikunja trial; two-way sync; on the cluster. The vault stays
the record. Agents write the vault. Everything that comes back from Vikunja is an INTENT
(a file) in the vikunja-intents repo; the MacBook applies it (bin/bord-drain --forge),
so SOPs, the ledger and the audit trail apply unchanged. This job never writes the vault.

INPUTS (per run, fresh clones in an emptyDir):
  --vault DIR     checkout of the vault projection (tasks, project cards, intents ledger,
                  .claude/agents), pushed from the Mini. Read-only.
  --intents DIR   checkout of vikunja-intents; new intent files are committed and pushed.
  --state FILE    tsk <-> Vikunja map and per-field "pushed" values, on a small PVC.
  --config FILE   vault-specific settings (area names and rules, the owner's slug); JSON, see
                  deploy/vikunja-sync/config.example.json. Mounted from a Secret, not the
                  ConfigMap: area names can name a client, and this code is published.
  VIKUNJA_URL, VIKUNJA_TOKEN (bot-sync) from the environment (ESO from 1Password item "vikunja").

FIELD OWNERSHIP (plan 2026-09-28-bord-app-v1.1-plan):
  vault-owned  : title, description, priority, project  -> overwritten on every push
  owner-owned  : done, due date, owner label, comments, new tasks -> flow back as intents
  Conflict     : vault wins. Compare-and-set is a JSON Patch `test` op per field on the
                 value we last pushed (measured 2026-09-28 on unstable v2.6.0-525: If-Match
                 is NOT usable - a stale ETag applied, the current one returned 304; a failed
                 `test` returns 422 and applies nothing).

AREAS (the owner, 2026-09-28): one top-level project per configured area; project cards become
child projects; a task without a card goes to its area, or to the fallback area if nothing says
which. The rules are in the config (card_area, task_area below), explicit and logged; nothing is
guessed silently.

Run order: pull (Vikunja -> intents) first, push intents repo, save state, then push
(vault -> Vikunja), save state. A change made in Vikunja is therefore captured before we
could overwrite it, and a crash between steps re-derives rather than loses.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rebuild_index as ri  # noqa: E402
import vault_core as core  # noqa: E402
from vault_core import code_for, flat  # noqa: E402

try:
    from zoneinfo import ZoneInfo
    LOCAL_TZ = ZoneInfo("Europe/Amsterdam")
except Exception:  # pragma: no cover - image ships tzdata
    LOCAL_TZ = timezone.utc

NULL_DATE = "0001-01-01T00:00:00Z"
TRAILER_RE = re.compile(r"vault: (tsk-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3})")
OWNER_PREFIX = "owner:"
CONFIG = {}  # set by configure(); see load_config
PRIO_TO_VK = {1: 4, 2: 3, 3: 2, 4: 1}
PENDING_MAX = timedelta(days=7)
BOT = os.environ.get("VIKUNJA_BOT", "bot-sync")


def log(event, **kw):
    print(json.dumps({"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                      "service": "vikunja-sync", "event": event, **kw}, ensure_ascii=False), flush=True)


# ------------------------------------------------------------------ Vikunja client

class HTTPStatus(Exception):
    def __init__(self, code, detail=""):
        super().__init__(f"HTTP {code} {detail[:120]}")
        self.code = code


class VK:
    def __init__(self, base, token, attempts=3):
        self.base = base.rstrip("/") + "/api/v2"
        self.token = token
        self.attempts = attempts

    def req(self, method, path, body=None, ctype="application/json", params=None):
        url = self.base + path + ("?" + urllib.parse.urlencode(params) if params else "")
        data = None if body is None else json.dumps(body).encode()
        last = None
        # A POST is not idempotent: never retried. The next run reconciles (projects by their
        # vault-project marker, tasks by their trailer) instead of creating twice (codex d2a3763).
        for i in range(self.attempts if method != "POST" else 1):
            r = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": f"Bearer {self.token}", "Content-Type": ctype,
                "Accept": "application/json", "User-Agent": "pka-vikunja-sync/1"})
            try:
                with urllib.request.urlopen(r, timeout=30) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                if e.code < 500:
                    raise HTTPStatus(e.code, e.read().decode("utf-8", "replace"))
                last = f"HTTP {e.code}"
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
                last = type(e).__name__
            if i + 1 < self.attempts:
                time.sleep(2 ** (i + 1))
        raise RuntimeError(f"Vikunja onbereikbaar ({last})")

    def all(self, path, params=None):
        out, page = [], 1
        while True:
            d = self.req("GET", path, params={**(params or {}), "page": page, "per_page": 50})
            items = d.get("items") if isinstance(d, dict) else d
            out += items or []
            if not isinstance(d, dict) or page >= int(d.get("total_pages") or 1):
                return out
            page += 1

    def patch(self, tid, ops):
        return self.req("PATCH", f"/tasks/{tid}", ops, ctype="application/json-patch+json")


# ------------------------------------------------------------------ normalisation

def due_to_vk(d):
    return f"{d}T00:00:00Z" if d else NULL_DATE


def vk_due(raw):
    """Vikunja due_date -> 'YYYY-MM-DD' in the owner's timezone, or None."""
    if not raw or raw.startswith("0001-01-01"):
        return None
    ts = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    return ts.astimezone(LOCAL_TZ).date().isoformat()


def trailer(desc):
    m = TRAILER_RE.search(desc or "")
    return m.group(1) if m else None


def html_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ------------------------------------------------------------------ vault side

def load_cards(vault):
    cards = {}
    d = Path(vault) / "PKM/My Life/Projects"
    for p in sorted(d.glob("*.md")) if d.is_dir() else []:
        fm, _ = ri.parse_frontmatter(p.read_text(encoding="utf-8"))
        cards[p.stem] = {"name": ri.fm_scalar(fm, "name", p.stem) or p.stem,
                         "key_element": (ri.fm_scalar(fm, "key_element", "") or "").lower(),
                         "tier": (ri.fm_scalar(fm, "confidentiality_tier", "") or "").split("#")[0].strip()}
    return cards


# ------------------------------------------------------------------ configuration

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")
AREA_KEYS = {"name", "slug", "slug_prefixes", "words", "key_elements"}


def _no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ConfigError("config: een sleutel staat er twee keer in")
    return dict(pairs)


def area_slug(name):
    """'Privé' -> 'prive', 'Client A' -> 'client-a'. The create intent carries gebied-<slug>."""
    folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", folded).strip("-")


class ConfigError(Exception):
    pass


def load_config(path):
    """Strict: an unknown key, a duplicate area or a key_element in two areas is an error,
    never a guess. Returns the normalised config with compiled word patterns."""
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=_no_duplicate_keys)
    except (OSError, ValueError) as ex:
        raise ConfigError(f"config onleesbaar: {type(ex).__name__}")
    if not isinstance(raw, dict) or set(raw) - {"owner", "areas", "fallback"}:
        raise ConfigError("config: alleen owner, areas en fallback")
    owner, fallback, areas = raw.get("owner"), raw.get("fallback"), raw.get("areas")
    if not isinstance(owner, str) or not SLUG_RE.fullmatch(owner):
        raise ConfigError("config: owner is een slug")
    if not isinstance(fallback, str) or not fallback.strip():
        raise ConfigError("config: fallback ontbreekt")
    if not isinstance(areas, list) or not areas:
        raise ConfigError("config: areas is een niet-lege lijst")
    out, names, by_ke = [], {fallback.strip()}, {}
    slugs = {fallback.strip(): area_slug(fallback)}
    for a in areas:
        if not isinstance(a, dict) or set(a) - AREA_KEYS or not isinstance(a.get("name"), str):
            raise ConfigError("config: een area heeft name en verder alleen slug_prefixes, words, key_elements")
        name = a["name"].strip()
        if not name or name in names:
            raise ConfigError("config: area-naam leeg of dubbel")
        names.add(name)
        lists = {}
        for k in ("slug_prefixes", "words", "key_elements"):
            v = a.get(k, [])
            if not isinstance(v, list) or not all(isinstance(x, str) and x.strip() for x in v):
                raise ConfigError(f"config: {k} is een lijst van niet-lege teksten")
            lists[k] = [x.strip() for x in v]
        if not all(re.fullmatch(r"\w(.*\w)?", w) for w in lists["words"]):
            raise ConfigError("config: een woord begint en eindigt met een letter of cijfer (anders past \\b nooit)")
        slug = a.get("slug", area_slug(name))
        if not isinstance(slug, str) or not SLUG_RE.fullmatch(slug) or not SLUG_RE.fullmatch("gebied-" + slug):
            raise ConfigError("config: area-slug ongeldig (geef een slug: a-z, 0-9, -)")
        slugs[name] = slug
        for ke in lists["key_elements"]:
            if ke.lower() in by_ke:
                raise ConfigError("config: een key_element hoort bij één area")
            by_ke[ke.lower()] = name
        out.append({"name": name, "slug_prefixes": lists["slug_prefixes"], "words": lists["words"],
                    # As before the move: a card NAME matches case-sensitively, a task case-insensitively.
                    "card_rx": [re.compile(r"\b" + re.escape(w) + r"\b") for w in lists["words"]],
                    "task_rx": [re.compile(r"\b" + re.escape(w) + r"\b", re.IGNORECASE) for w in lists["words"]]})
    fs = slugs[fallback.strip()]
    if not SLUG_RE.fullmatch(fs) or not SLUG_RE.fullmatch("gebied-" + fs) or len(set(slugs.values())) != len(slugs):
        raise ConfigError("config: area-slugs ongeldig of dubbel")
    return {"owner": owner, "fallback": fallback.strip(), "areas": out, "by_key_element": by_ke,
            "slugs": slugs, "area_names": tuple(a["name"] for a in out) + (fallback.strip(),)}


def configure(cfg):
    CONFIG.clear()
    CONFIG.update(cfg)


def card_area(slug, card):
    """AREA RULES for a project card, in order: a configured slug prefix, or a configured word
    in the card name (case-sensitive); else the card's key_element; else the fallback area."""
    for a in CONFIG["areas"]:
        if any(slug.startswith(p) for p in a["slug_prefixes"]) or any(rx.search(card["name"]) for rx in a["card_rx"]):
            return a["name"]
    return CONFIG["by_key_element"].get(card["key_element"], CONFIG["fallback"])


def task_area(raw):
    """A task without a project card: a configured word (any case) in its tier, tags or title,
    or anywhere in the tier's comment part (the frontmatter parser keeps an inline '# ...' in
    the value); else the fallback area. The same test dag.py applies for its client flag."""
    comment = raw["tier"].split("#", 1)[-1].lower()
    for a in CONFIG["areas"]:
        if any(rx.search(s) for rx in a["task_rx"] for s in (raw["tier"], *raw["tags"], raw["title"]) if s) \
                or any(w.lower() in comment for w in a["words"]):
            return a["name"]
    return CONFIG["fallback"]


def load_vault(vault):
    cards = load_cards(vault)
    tasks = {}
    root = Path(vault) / ri.TASKS_REL
    files = [(st, f) for st in ("open", "in-progress") if (root / st).is_dir()
             for f in sorted((root / st).glob("tsk-*.md"))]
    for status, path in files:
        t = core.task_from_file(path, status)
        if not t:
            continue
        fm, _ = ri.parse_frontmatter(path.read_text(encoding="utf-8"))
        linked = [s for s in t["projects"] if s in cards]
        card = linked[0] if linked else None
        area = card_area(card, cards[card]) if card else task_area(t["raw"])
        tasks[t["id"]] = {
            "id": t["id"], "title": t["title"], "tier": t["tier"] or "", "area": area, "card": card,
            "priority": t["priority"], "due": t["due"].isoformat() if t["due"] else None,
            "owner": (t["assignee"] or None), "blocked": t["blocked_reason"],
            "source": ri.fm_scalar(fm, "source"),
        }
    closed = {}
    for st in ("done", "cancelled"):
        for p in (root / st).glob("*/*/tsk-*.md") if (root / st).is_dir() else []:
            fm, _ = ri.parse_frontmatter(p.read_text(encoding="utf-8"))
            closed[p.name[:18]] = {
                "id": p.name[:18], "title": ri.fm_scalar(fm, "title", p.stem) or p.stem,
                "tier": str(fm.get("confidentiality_tier", "") or "").split("#")[0].strip().lower(),
                "blocked": None, "priority": 3,
                "due": (lambda d: d.isoformat() if d else None)(core.parse_date(ri.fm_scalar(fm, "due"))),
                "owner": (ri.fm_scalar(fm, "assignee", "") or "").lower() or None,
                "source": ri.fm_scalar(fm, "source")}
    return cards, tasks, closed


def ledger_state(vault, iid):
    root = Path(vault) / core.INTENTS_REL
    for st in ("applied", "rejected"):
        if (root / st).is_dir() and any((root / st).glob(f"*/*/{iid}.md")):
            return st
    return None


def desired(t):
    title = t["title"] if t["tier"] != "tier-a" else f"Taak {code_for('task', t['id'])}"
    lines = []
    if t["blocked"] and t["tier"] != "tier-a":
        lines.append(f"<p>Wacht: {html_escape(t['blocked'])}</p>")
    lines.append("<p><em>Titel, beschrijving, prioriteit en project komen uit de vault. "
                 "Afvinken, datum, eigenaar-label en opmerkingen mag je hier wijzigen.</em></p>")
    lines.append(f"<p>vault: {t['id']}</p>")
    return {"title": title, "description": "".join(lines),
            "priority": PRIO_TO_VK.get(int(t["priority"] or 3), 2),
            "due": t["due"], "owner": t["owner"], "done": False}


# ------------------------------------------------------------------ state

def load_state(path):
    try:
        s = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        s = {}
    s.setdefault("version", 1)
    s.setdefault("projects", {})     # "area:<name>" / "card:<slug>" -> vk project id
    s.setdefault("tasks", {})        # tsk -> {vk, pushed{done,due,owner}, pending{}, last_comment, gone}
    s.setdefault("created", {})      # vk id -> intent id (new task from the owner)
    s.setdefault("labels", {})       # "owner:<slug>" -> label id
    s.setdefault("last_poll", None)
    return s


def save_state(path, s):
    p = Path(path)
    tmp = p.with_name("." + p.name + ".tmp")
    tmp.write_text(json.dumps(s, ensure_ascii=False, indent=1, sort_keys=True))
    os.replace(tmp, p)


# ------------------------------------------------------------------ structure

SAVE = [None]  # set per run: persist the state right after anything is created in Vikunja


def checkpoint(state):
    if SAVE[0]:
        save_state(SAVE[0], state)


CHECKED = set()  # project keys reconciled in this run


def ensure_project(vk, state, key, title, parent_id=0):
    if key in state["projects"] and key in CHECKED:
        return state["projects"][key]
    if key in state["projects"]:
        # Once per run: title and parent follow the vault (a card that became tier-a is renamed
        # to its code; an area change moves it). Codex 9d21d2a P2.
        pid = state["projects"][key]
        try:
            pr = vk.req("GET", f"/projects/{pid}")
            ops = [{"op": "replace", "path": "/" + k, "value": v} for k, v in
                   (("title", title), ("parent_project_id", int(parent_id or 0)))
                   if (pr.get(k) or 0 if k == "parent_project_id" else pr.get(k)) != v]
            if ops:
                vk.req("PATCH", f"/projects/{pid}", ops, ctype="application/json-patch+json")
                log("project_reconciled", key=key, fields=[o_["path"] for o_ in ops])
            CHECKED.add(key)
            return pid
        except HTTPStatus as ex:
            if ex.code != 404:
                raise
            del state["projects"][key]  # deleted in Vikunja: recreated below
    # Crash-safe: a project we created in a run that died before saving is found again by
    # title and parent instead of being created twice (codex ca1b6ab P2).
    marker = f"vault-project: {key}"
    for pr in vk.all("/projects"):
        found = re.search(r"vault-project: ([^<\s]+)", pr.get("description") or "")
        if found and found.group(1) == key:  # exact key, never a prefix
            state["projects"][key] = pr["id"]
            checkpoint(state)
            return pr["id"]
    body = {"title": title, "description": f"<p>{html_escape(marker)}</p>"}
    if parent_id:
        body["parent_project_id"] = parent_id
    pid = vk.req("POST", "/projects", body)["id"]
    state["projects"][key] = pid
    CHECKED.add(key)
    checkpoint(state)
    log("project_created", key=key, id=pid)
    return pid


def project_for(vk, state, t, cards):
    parent = ensure_project(vk, state, "area:" + t["area"], t["area"])
    if not t["card"]:
        return parent
    c = cards[t["card"]]
    name = c["name"] if c["tier"] != "tier-a" else f"Project {code_for('project', t['card'])}"
    return ensure_project(vk, state, "card:" + t["card"], name, parent)


def ensure_label(vk, state, owner):
    key = OWNER_PREFIX + owner
    if key not in state["labels"]:
        found = [l for l in vk.all("/labels", {"q": key}) if l.get("title") == key]
        state["labels"][key] = found[0]["id"] if found else vk.req("POST", "/labels", {"title": key})["id"]
    return state["labels"][key]


def reset_owner(vk, state, tid, new, allowed):
    """All owner:* labels off, then the one the vault says. Re-read first (a fresh GET), so
    the race window is one request long; a second label shows up as AMBIGUOUS next pull."""
    vt = vk.req("GET", f"/tasks/{tid}", params={"expand": "labels"})
    if owner_of(vt) not in allowed:
        return False  # The owner assigned someone in between: leave it, the next pull captures it
    for l in vt.get("labels") or []:
        if str(l.get("title", "")).startswith(OWNER_PREFIX) and l["title"] != OWNER_PREFIX + (new or ""):
            try:
                vk.req("DELETE", f"/tasks/{tid}/labels/{l['id']}")
            except HTTPStatus as ex:
                if ex.code != 404:
                    raise
    have = {l.get("title") for l in vt.get("labels") or []}
    if new and OWNER_PREFIX + new not in have:  # kept above; attaching twice is a 409 (codex 07bfd65 P2)
        attach_label(vk, state, tid, new)
    return True


def attach_label(vk, state, tid, owner):
    try:
        vk.req("POST", f"/tasks/{tid}/labels", {"label_id": ensure_label(vk, state, owner)})
    except HTTPStatus as ex:
        if ex.code not in (400, 404, 422):
            raise
        state["labels"].pop(OWNER_PREFIX + owner, None)  # label deleted in Vikunja: look up / recreate once
        vk.req("POST", f"/tasks/{tid}/labels", {"label_id": ensure_label(vk, state, owner)})


def set_owner(vk, state, tid, old, new):
    if old:
        try:
            vk.req("DELETE", f"/tasks/{tid}/labels/{ensure_label(vk, state, old)}")
        except HTTPStatus as e:
            if e.code != 404:
                raise
    if new:
        attach_label(vk, state, tid, new)


# ------------------------------------------------------------------ pull

def area_of_project(state, pid):
    for key, v in state["projects"].items():
        if v == pid:
            kind, _, name = key.partition(":")
            return (name, None) if kind == "area" else (None, name)
    return (None, None)


AMBIGUOUS = "__ambiguous__"
OVERLAP = timedelta(seconds=60)


def event_id(when_raw, *parts):
    """Deterministic intent id per Vikunja event, so a retried run re-derives the SAME intent
    and the MacBook's ledger sees a duplicate, never a second application (codex d19a0f9 P2)."""
    when = datetime.fromisoformat(str(when_raw).replace("Z", "+00:00")).astimezone(timezone.utc)
    h = __import__("hashlib").sha256("|".join(map(str, parts)).encode()).hexdigest()[:6]
    return f"int-{when.strftime('%Y%m%d-%H%M%S')}-{h}", when


def owner_of(task):
    owners = [l["title"][len(OWNER_PREFIX):] for l in (task.get("labels") or [])
              if str(l.get("title", "")).startswith(OWNER_PREFIX)]
    return owners[0] if len(owners) == 1 else (None if not owners else AMBIGUOUS)


NOW_STAMP = [None]  # first-observed time for pending expiry (codex 7f33358 P2), set per run


def pull(vk, state, vault, qdir, now, counts):
    NOW_STAMP[0] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    """Vikunja -> intents. Every intent carries a deterministic id and the event's own time."""
    rev = {e["vk"]: tsk for tsk, e in state["tasks"].items() if not e.get("gone")}
    params = {"expand": "labels"}
    if state["last_poll"]:
        # Overlap: an edit in the same second as the last one we saw is not skipped. Re-seeing
        # a change is harmless: diffs are against 'pushed'/'pending', comments by id.
        since = datetime.fromisoformat(state["last_poll"].replace("Z", "+00:00")) - OVERLAP
        params["filter"] = f"updated > {since.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    newest = state["last_poll"]
    for vt in vk.all("/tasks", params):
        newest = max(newest or "", vt.get("updated") or "")
        try:
            counts["intents"] += pull_one(vk, state, rev, vt, qdir, counts)
        except (core.Rejected, ValueError) as ex:
            counts["skipped"] += 1  # one bad value never blocks the run (codex d19a0f9 P2)
            log("skipped", vk=vt.get("id"), reason=str(ex)[:120])
    state["last_poll_next"] = newest


def pull_one(vk, state, rev, vt, qdir, counts):
    n = 0
    tsk = rev.get(vt["id"])
    if not tsk:
        tsk = trailer(vt.get("description"))
        if tsk and tsk in state["tasks"] and state["tasks"][tsk]["vk"] != vt["id"]:
            tsk = None  # a copy (Vikunja 'duplicate') carries someone else's trailer: a new task
    if tsk and tsk not in state["tasks"]:
        # State lost: re-map from the trailer. Past differences are unknowable, so the vault
        # wins on the next push; counted and visible, not silent.
        state["tasks"][tsk] = {"vk": vt["id"], "pending": {}, "last_comment": 0, "pushed": {
            "done": bool(vt.get("done")), "due": vk_due(vt.get("due_date")), "owner": owner_of(vt),
            "due_raw": vt.get("due_date") or NULL_DATE}, "remapped": True}
        log("remapped", task=tsk, vk=vt["id"])
        # Comments from zero: ids are deterministic, so ones already applied come back as
        # 'duplicate' in the ledger; unread ones are not lost (codex ed8463d P2).
        return pull_comments(vk, state["tasks"][tsk], tsk, vt, qdir)
    if not tsk:
        if str(vt["id"]) in state["created"]:
            return 0
        area, card = area_of_project(state, vt.get("project_id"))
        if area is None and card is None:
            return 0
        # An area no longer in the config: its derived slug, or the fallback's if none derives.
        proj = card or "gebied-" + (CONFIG["slugs"].get(area) or area_slug(area) or CONFIG["slugs"][CONFIG["fallback"]])
        iid, when = event_id(vt.get("created") or vt["updated"], vt["id"], "create")
        write_intent(qdir, "create", text=flat(vt.get("title")) or "(zonder titel)",
                             value=vk_due(vt.get("due_date")) or "null", source=f"vikunja:{vt['id']}",
                             project=proj, surface="vikunja", now=when, intent_id=iid)
        state["created"][str(vt["id"])] = iid
        return 1
    e = state["tasks"][tsk]
    if e.get("gone"):
        return 0
    if e.get("closed_text") and closed_view(vt) != e["closed_text"]:
        e.pop("closed_sig", None)  # text edited in Vikunja: re-checked (and reverted) on push
    cur = {"done": bool(vt.get("done")), "due": vk_due(vt.get("due_date")), "owner": owner_of(vt)}
    for f in ("done", "due", "owner"):
        if e.get("closed") and f != "done":
            continue  # closed in the vault: due/owner follow the vault, no intents (always rejected)
        pend = e["pending"].get(f)
        base = pend["value"] if pend else e["pushed"].get(f)
        if cur[f] == base:
            continue
        if f == "owner" and cur[f] in (None, AMBIGUOUS):
            continue  # removed or two labels: not an assignment; push restores the vault's owner
        try:
            n += emit_field(qdir, e, tsk, vt, f, cur, base)
        except (core.Rejected, ValueError) as ex:
            counts["skipped"] += 1
            log("skipped_field", task=tsk, field=f, reason=str(ex)[:120])  # comments still run
    return n + pull_comments(vk, e, tsk, vt, qdir)


def emit_field(qdir, e, tsk, vt, f, cur, base):
    ts = vt["updated"]
    if f == "done":
        # Closing comes after due/owner of the same moment: ids sort by time first, so done
        # gets +1 s and a same-poll date change is applied before the close (codex 72b2f96 P2).
        ts = (datetime.fromisoformat(ts.replace("Z", "+00:00")) + timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    iid, when = event_id(ts, vt["id"], f, cur[f])
    if f == "done":
        write_intent(qdir, "done" if cur[f] else "reopen", task=tsk, surface="vikunja",
                             now=when, intent_id=iid)
    else:
        # expect = the value the vault will hold once the previous intent is applied: a
        # superseding change applies after it, or is rejected with it (codex d19a0f9 P1).
        write_intent(qdir, "due" if f == "due" else "assign", task=tsk,
                             value=cur[f] or "null", expect=base or "null",
                             surface="vikunja", now=when, intent_id=iid)
    e["pending"][f] = {"value": cur[f], "intent": iid, "since": NOW_STAMP[0],
                       "raw": vt.get("due_date") if f == "due" else None}
    return 1


def pull_comments(vk, e, tsk, vt, qdir):
    n = 0
    for c in sorted(vk.all(f"/tasks/{vt['id']}/comments"), key=lambda c: c["id"]):
        if c["id"] <= e.get("last_comment", 0):
            continue
        if (c.get("author") or {}).get("username") != BOT:
            text = flat(re.sub(r"<[^>]+>", " ", c.get("comment") or ""))
            if text:
                if not c.get("created"):
                    raise ValueError("opmerking zonder 'created': geen deterministisch id mogelijk")
                iid, when = event_id(c["created"], vt["id"], "comment", c["id"])
                write_intent(qdir, "comment", task=tsk, text=text, surface="vikunja", now=when,
                                     intent_id=iid)
                n += 1
        e["last_comment"] = c["id"]
    return n


def write_intent(qdir, verb, **kw):
    """Every intent from Vikunja is the owner's change (bot-sync's own comments are skipped)."""
    return core.write_intent(qdir, verb, actor=CONFIG["owner"], **kw)


# ------------------------------------------------------------------ resolve + push

def resolve_pending(state, vault, now):
    for tsk, e in state["tasks"].items():
        for f, p in list(e["pending"].items()):
            st = ledger_state(vault, p["intent"])
            old = datetime.fromisoformat(p["since"].replace("Z", "+00:00"))
            if st or now - old > PENDING_MAX:
                # The LAST intent for this field is in the ledger (applied or rejected), or stale:
                # Vikunja holds the owner's value; record it as 'pushed', and push then overwrites it
                # only if the vault disagrees (vault wins).
                e["pushed"][f] = p["value"]
                if f == "due":
                    e["pushed"]["due_raw"] = p.get("raw") or due_to_vk(p["value"])
                del e["pending"][f]
                log("pending_resolved", task=tsk, field=f, ledger=st or "stale")


def cas(vk, tid, path, old_raw, new_raw):
    try:
        vk.patch(tid, [{"op": "test", "path": path, "value": old_raw},
                       {"op": "replace", "path": path, "value": new_raw}])
        return True
    except HTTPStatus as ex:
        if ex.code in (409, 412, 422):
            return False  # the owner changed it since our last push; the next pull reads it
        raise


def recover_projects(vk, state):
    """Before a pull: if the map misses an area (state lost or new), read the markers back so
    tasks the owner made in our tree are recognised on this very pull (codex d2ef540 P2)."""
    # Every run, not only when an area is missing: a card project created in a run that lost
    # its response must be known BEFORE the pull advances the cursor (codex cfb5f94 P2).
    for pr in vk.all("/projects"):
        m = re.search(r"vault-project: ([^<\s]+)", pr.get("description") or "")
        if m and m.group(1) not in state["projects"]:
            state["projects"][m.group(1)] = pr["id"]


def reconcile_projects(vk, state, cards):
    """Every known card project follows its card, also when it has no open tasks any more
    (a card that became tier-a is renamed to its code). Codex acc2c8f P2."""
    for key in [k for k in state["projects"] if k.startswith("card:") and k not in CHECKED]:
        slug = key[5:]
        c = cards.get(slug)
        if not c:
            continue  # card gone from the vault: project left as is, visible in Vikunja
        parent = ensure_project(vk, state, "area:" + card_area(slug, c), card_area(slug, c))
        name = c["name"] if c["tier"] != "tier-a" else f"Project {code_for('project', slug)}"
        ensure_project(vk, state, key, name, parent)


def closed_view(vt):
    return [vt.get("title"), vt.get("description"), vk_due(vt.get("due_date")), owner_of(vt)]


def sync_closed_text(vk, e, t, state=None):
    """A closed task still follows the vault's title and description (a title that became
    tier-a after closing is redacted). Only when the vault signature changed. Codex 602ca43."""
    d = desired(t)
    want = [d["title"], d["description"], d["due"], d["owner"]]
    sig = __import__("hashlib").sha256(json.dumps(want).encode()).hexdigest()[:16]
    if e.get("closed_sig") == sig:
        return
    vt = vk.req("GET", f"/tasks/{e['vk']}", params={"expand": "labels"})
    ops = [{"op": "replace", "path": "/" + k, "value": d[k]} for k in ("title", "description")
           if vt.get(k) != d[k]]
    if vk_due(vt.get("due_date")) != d["due"]:
        ops.append({"op": "replace", "path": "/due_date", "value": due_to_vk(d["due"])})
    if ops:
        vk.patch(e["vk"], ops)
    if state is not None and owner_of(vt) != d["owner"]:
        reset_owner(vk, state, e["vk"], d["owner"], (owner_of(vt),))
    e["closed_sig"] = sig
    e["closed_text"] = want


def push(vk, state, cards, tasks, closed, counts):
    for tsk, t in tasks.items():
        d = desired(t)
        e = state["tasks"].get(tsk)
        if e and e.get("gone"):
            continue
        pid = project_for(vk, state, t, cards)
        if not e and t["source"] and re.fullmatch(r"vikunja:[0-9]+", t["source"]):
            vid = int(t["source"].split(":")[1])
            try:
                vt = vk.req("GET", f"/tasks/{vid}", params={"expand": "labels"})
                # Baseline = the VAULT's values, so the owner's edits made after his create intent show
                # up as differences on the next pull instead of being overwritten (codex d19a0f9 P1).
                e = state["tasks"][tsk] = {"vk": vid, "pending": {}, "last_comment": 0, "pushed": {
                    "done": False, "due": d["due"], "due_raw": vt.get("due_date") or NULL_DATE,
                    "owner": d["owner"]}}
                state["created"].pop(str(vid), None)
                counts["adopted"] += 1
            except HTTPStatus as ex:
                if ex.code != 404:
                    raise
        if not e:
            vt = vk.req("POST", f"/projects/{pid}/tasks", {
                "title": d["title"], "description": d["description"], "priority": d["priority"],
                "due_date": due_to_vk(d["due"]), "done": False})
            if d["owner"]:
                set_owner(vk, state, vt["id"], None, d["owner"])
            state["tasks"][tsk] = {"vk": vt["id"], "pending": {}, "last_comment": 0, "pushed": {
                "done": False, "due": d["due"], "due_raw": vt.get("due_date") or due_to_vk(d["due"]),
                "owner": d["owner"]}}
            checkpoint(state)
            counts["created"] += 1
            continue
        try:
            vt = vk.req("GET", f"/tasks/{e['vk']}", params={"expand": "labels"})
        except HTTPStatus as ex:
            if ex.code == 404:
                e["gone"] = True  # the owner deleted it in Vikunja; not recreated, visible in health
                counts["gone"] += 1
                continue
            raise
        ops = [{"op": "replace", "path": "/" + k, "value": v} for k, v in
               (("title", d["title"]), ("description", d["description"]), ("priority", d["priority"]),
                ("project_id", pid)) if vt.get(k) != v]
        if ops:
            vk.patch(e["vk"], ops)
            counts["updated"] += 1
        p = e["pushed"]
        if "due" not in e["pending"] and d["due"] != p.get("due"):
            # Same day, other hour (the owner moved the time only): the fresh raw value is our
            # baseline; a different day fails the test and is captured by the next pull.
            base_raw = vt.get("due_date") if vk_due(vt.get("due_date")) == p.get("due") else p.get("due_raw")
            if cas(vk, e["vk"], "/due_date", base_raw or NULL_DATE, due_to_vk(d["due"])):
                p["due"], p["due_raw"] = d["due"], due_to_vk(d["due"])
            else:
                counts["cas_refused"] += 1
        if "done" not in e["pending"] and p.get("done") is not False:
            if cas(vk, e["vk"], "/done", p.get("done"), False):
                p["done"] = False
            else:
                counts["cas_refused"] += 1
        if "owner" not in e["pending"]:
            fresh = owner_of(vk.req("GET", f"/tasks/{e['vk']}", params={"expand": "labels"}))
            allowed = (p.get("owner"), None, AMBIGUOUS)
            if fresh != d["owner"] and fresh in allowed:
                # vault changed it, or the owner removed it / two labels: the vault's owner is restored
                if reset_owner(vk, state, e["vk"], d["owner"], allowed):
                    p["owner"] = d["owner"]
                else:
                    counts["cas_refused"] += 1
            elif d["owner"] != p.get("owner"):
                counts["cas_refused"] += 1

    for tsk in closed:
        e = state["tasks"].get(tsk)
        src = closed[tsk].get("source") or ""
        if not e and re.fullmatch(r"vikunja:[0-9]+", src):
            # Created from Vikunja and closed before we adopted it (codex 39ef786 P2): adopt now,
            # with the vault baseline, so the close below and later comments still flow.
            vid = int(src.split(":")[1])
            e = state["tasks"][tsk] = {"vk": vid, "pending": {}, "last_comment": 0, "pushed": {
                "done": False, "due": closed[tsk]["due"], "due_raw": NULL_DATE, "owner": closed[tsk]["owner"]}}
            state["created"].pop(str(vid), None)
            counts["adopted"] += 1
            checkpoint(state)
        if e and not e.get("gone"):
            # Text first, whatever done/pending says: a redaction never waits (codex fe7d000 P2).
            try:
                sync_closed_text(vk, e, closed[tsk], state)
            except HTTPStatus as ex:
                if ex.code != 404:
                    raise
                e["gone"] = True
                counts["gone"] += 1
        # Closed in the vault is closed in Vikunja: vault wins. A reopen by the owner became a
        # 'reopen' intent (the orchestrator makes a new task with parent); here the task is re-closed.
        if not e or e.get("gone") or "done" in e["pending"] or (e.get("closed") and e["pushed"].get("done")):
            continue
        try:
            closed_now = cas(vk, e["vk"], "/done", e["pushed"].get("done", False), True) or \
                vk.req("GET", f"/tasks/{e['vk']}").get("done") is True
        except HTTPStatus as ex:
            if ex.code != 404:
                raise
            e["gone"] = True
            counts["gone"] += 1
            continue
        if closed_now:
            e["pushed"]["done"] = True
            e["closed"] = True
            e["pending"].pop("done", None)
            counts["closed"] += 1


# ------------------------------------------------------------------ git (intents repo)

def git(repo, *a, check=True):
    return subprocess.run(["git", "-C", str(repo), *a], check=check, capture_output=True, text=True,
                          timeout=120)


def publish_intents(repo, n):
    # Whatever is in the worktree goes out, whatever the count says: a task that failed
    # half-way may still have written a valid intent (codex 7f33358 P1).
    # The identity lives in the clone itself, so commit AND a recovery rebase work in a
    # container without global git config (codex 6ad46a3 P2).
    git(repo, "config", "user.name", "vikunja-sync")
    git(repo, "config", "user.email", "vikunja-sync@cluster.invalid")
    git(repo, "add", "-A")
    if git(repo, "status", "--porcelain").stdout.strip():
        git(repo, "commit", "-q", "-m", f"{n} intent(s) uit Vikunja")
    for _ in range(3):
        if git(repo, "rev-list", "--count", "@{u}..HEAD", check=False).stdout.strip() in ("", "0"):
            return True
        if git(repo, "push", "-q", "origin", "HEAD:main", check=False).returncode == 0:
            return True
        if git(repo, "pull", "-q", "--rebase", "origin", "main", check=False).returncode != 0:
            git(repo, "rebase", "--abort", check=False)
            return False
    return False


# ------------------------------------------------------------------ main

def run(vk, vault, intents_repo, state_path, now=None):
    now = now or datetime.now(timezone.utc)
    state = load_state(state_path)
    SAVE[0] = state_path
    CHECKED.clear()
    cards, tasks, closed = load_vault(vault)
    counts = {k: 0 for k in ("intents", "created", "updated", "adopted", "closed", "gone", "cas_refused",
                             "skipped")}
    # 1. pull, and make the intents durable before anything else changes
    qdir = Path(intents_repo)
    recover_projects(vk, state)
    pull(vk, state, vault, qdir, now, counts)
    if not publish_intents(qdir, counts["intents"]):
        raise RuntimeError("intents niet gepusht; state niet bewaard, volgende run opnieuw")
    if state.get("last_poll_next"):
        state["last_poll"] = state.pop("last_poll_next")
    save_state(state_path, state)
    # 2. resolve what the vault has taken in, then push vault -> Vikunja
    resolve_pending(state, vault, now)
    push(vk, state, cards, tasks, closed, counts)
    reconcile_projects(vk, state, cards)
    save_state(state_path, state)
    areas = {a: sum(1 for t in tasks.values() if t["area"] == a) for a in CONFIG["area_names"]}
    return {**counts, "areas": areas, "pending": sum(len(e["pending"]) for e in state["tasks"].values())}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Vault <-> Vikunja")
    ap.add_argument("--vault", required=True)
    ap.add_argument("--intents", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--config", default=os.environ.get("VIKUNJA_SYNC_CONFIG"))
    ap.add_argument("--health", default=None, help="optional local diagnostics; alerting uses Job status")
    a = ap.parse_args(argv)
    try:
        configure(load_config(a.config or ""))
    except ConfigError as ex:
        log("config_error", detail=str(ex))
        return 78
    url, tok = os.environ.get("VIKUNJA_URL", ""), os.environ.get("VIKUNJA_TOKEN", "")
    if not url.startswith(("https://", "http://127.0.0.1", "http://vikunja")) or not tok.startswith("tk_"):
        log("config_error", detail="VIKUNJA_URL/VIKUNJA_TOKEN ontbreken of ongeldig")
        return 78
    ok, res = True, {}
    try:
        res = run(VK(url, tok), a.vault, a.intents, a.state)
        log("run", **res)
    except Exception as ex:
        ok, res = False, {"error": f"{type(ex).__name__}: {ex}"}
        log("run_failed", **res)
    if a.health:
        prev = {}
        try:
            prev = json.loads(Path(a.health).read_text())
        except (OSError, ValueError):
            pass
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        save_state(a.health, {"last_run": stamp, "last_success": stamp if ok else prev.get("last_success"),
                              "consecutive_failures": 0 if ok else int(prev.get("consecutive_failures") or 0) + 1,
                              "detail": res})
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
