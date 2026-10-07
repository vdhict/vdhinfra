#!/usr/bin/env python3
"""vault_core.py - the task-file and intent-file semantics shared by the MacBook tools and the
cluster sync, in one place.

This module, rebuild_index.py and vikunja_sync.py are what the cluster CronJob mounts. They
are published as a plain ConfigMap in a public repository, so they name no person, no client
and no home path: anything specific to this vault (area names, the owner's slug) comes from
configuration at run time. bin/build-vikunja-bundle refuses a bundle that does.

Moved here unchanged from intents.py (write_intent and its checks), dag.py (task_from_file,
parse_date, as_list) and snapshot.py (code_for); those modules re-export the names, so
existing callers keep working. Two deliberate differences: task_from_file no longer computes
a client flag (dag.py adds it for the day page), and it returns the raw tier, tags and
frontmatter title under "raw" so callers can apply their own rules.
"""
import hashlib
import json
import os
import re
import secrets
import sys
from datetime import date, datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rebuild_index as ri  # noqa: E402

TASK_REF_RE = re.compile(r"tsk-\d{4}-\d{2}-\d{2}-\d{3}")


def _log_stderr(event, **kw):
    print(json.dumps({"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                      "service": "vault-core", "event": event, **kw}, ensure_ascii=False),
          file=sys.stderr, flush=True)

INTENTS_REL = "Team Knowledge/intents"
VERBS = ("comment", "done", "capture", "voice", "reopen", "due", "assign", "create")
# Vikunja-sync (2026-09-28): value/expect/source/project in de frontmatter, strikt gevormd.
DATE_OR_NULL_RE = re.compile(r"^(null|[0-9]{4}-[0-9]{2}-[0-9]{2})$")
SLUG_OR_NULL_RE = re.compile(r"^(null|[a-z0-9][a-z0-9-]{0,79})$")
SOURCE_RE = re.compile(r"^vikunja:[0-9]{1,12}$")
TASK_ID_RE = re.compile(r"^tsk-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}$")
REF_RE = re.compile(r"^vandaag:[0-9]{4}-[0-9]{2}-[0-9]{2}:[0-9]{1,3}$")
INTENT_ID_RE = re.compile(r"^int-[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$")
AUDIO_EXT = {"audio/webm": "webm", "audio/ogg": "ogg", "audio/mp4": "m4a", "audio/mpeg": "mp3",
             "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/wav": "wav", "audio/x-wav": "wav",
             "audio/3gpp": "3gp", "audio/amr": "amr"}
MAX_TEXT = 4000
MAX_AUDIO = 25 * 1024 * 1024

class Rejected(Exception):
    """Voor de schrijver: het verzoek is niet geldig (HTTP 400)."""


def utc_now():
    return datetime.now(timezone.utc)


def idempotency_key(verb, task, ref, waarde, day):
    """Ontwerpregel R2: hash van taak, werkwoord, waarde en de kalenderdag. Twee keer tikken in
    een tunnel levert een intent op, niet twee."""
    return hashlib.sha256(f"{verb}|{task or ''}|{ref or ''}|{waarde or ''}|{day}".encode()).hexdigest()[:20]


def find_by_key(qdir, key):
    for p in Path(qdir).glob("int-*.md"):
        try:
            head = p.read_text(encoding="utf-8")[:2000]
        except OSError:
            continue
        if f"idempotency_key: {key}\n" in head:
            return p
    return None


def write_intent(qdir, verb, task=None, ref=None, text="", actor="owner", surface="app",
                 audio=None, audio_type=None, now=None, value=None, expect=None, source=None,
                 project=None, intent_id=None):
    """Valideert, dedupliceert, schrijft atomair. Geeft (intent_id, nieuw?) terug.
    Schrijft niets buiten qdir. Leest niets van de vault."""
    now = now or utc_now()
    if verb not in VERBS:
        raise Rejected("onbekend werkwoord")
    task = (task or "").strip() or None
    ref = (ref or "").strip() or None
    if task and not TASK_ID_RE.fullmatch(task):
        raise Rejected("ongeldig taak-id")
    if ref and not REF_RE.fullmatch(ref):
        raise Rejected("ongeldige verwijzing")
    text = (text or "").strip()
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT] + " […afgekapt]"
    ext = None
    if verb == "comment":
        if not (task or ref):
            raise Rejected("een opmerking hoort bij een taak of een punt van vandaag")
        if not text:
            raise Rejected("lege opmerking")
    elif verb == "done":
        if not (task or ref):
            raise Rejected("afvinken hoort bij een taak of een punt van vandaag")
    elif verb == "capture":
        if not text:
            raise Rejected("lege notitie")
        task, ref = None, None
    elif verb == "voice":
        if not audio:
            raise Rejected("geen audio")
        if len(audio) > MAX_AUDIO:
            raise Rejected("audio groter dan 25 MB")
        base_type = (audio_type or "").split(";")[0].strip().lower()
        ext = AUDIO_EXT.get(base_type)
        if not ext:
            raise Rejected("onbekend audioformaat")
        task, ref = None, None

    if verb in ("reopen", "due", "assign") and not task:
        raise Rejected("hoort bij een taak")
    if verb == "due" and not (DATE_OR_NULL_RE.fullmatch(str(value)) and DATE_OR_NULL_RE.fullmatch(str(expect))):
        raise Rejected("ongeldige datum")
    if verb == "assign" and not (SLUG_OR_NULL_RE.fullmatch(str(value)) and value != "null"
                                 and SLUG_OR_NULL_RE.fullmatch(str(expect))):
        raise Rejected("ongeldige eigenaar")
    if verb == "create":
        if not text:
            raise Rejected("lege titel")
        if not (DATE_OR_NULL_RE.fullmatch(str(value or "null"))
                and SLUG_OR_NULL_RE.fullmatch(str(project or "null"))):
            raise Rejected("ongeldige velden")
        task, ref = None, None
    if source is not None and not SOURCE_RE.fullmatch(str(source)):
        raise Rejected("ongeldige bron")
    if verb not in ("due", "assign", "create"):
        value = expect = None
    if verb != "create":
        project = None

    if intent_id is not None and not INTENT_ID_RE.fullmatch(str(intent_id)):
        raise Rejected("ongeldig intent-id")
    waarde = hashlib.sha256(audio).hexdigest() if verb == "voice" else \
        f"{text}|{value}|{expect}|{source}|{project}|{intent_id or ''}"
    key = idempotency_key(verb, task, ref, waarde, now.astimezone().date().isoformat())
    qdir = Path(qdir)
    qdir.mkdir(parents=True, exist_ok=True)
    existing = find_by_key(qdir, key)
    if existing:
        return existing.stem, False
    if intent_id and (qdir / f"{intent_id}.md").exists():
        return intent_id, False  # zelfde gebeurtenis, al in de wachtrij (Vikunja-sync, deterministisch id)

    intent_id = intent_id or f"int-{now.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3)}"
    fm = [
        "---",
        # Vrije tekst van de eigenaar is onbewezen, dus de strengste tier die past (GL-002).
        "confidentiality_tier: tier-b",
        f"intent_id: {intent_id}",
        f"ts: {now.strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"actor: {actor}",
        f"surface: {surface}",
        f"verb: {verb}",
        f"task: {task or 'null'}",
        f"ref: {ref or 'null'}",
        f"idempotency_key: {key}",
        f"audio: {intent_id + '.' + ext if ext else 'null'}",
        f"value: {value or 'null'}",
        f"expect: {expect or 'null'}",
        f"source: {source or 'null'}",
        f"project: {project or 'null'}",
        "status: pending",
        "---",
        "",
        text,
        "",
    ]
    if ext:
        _atomic_bytes(qdir / f"{intent_id}.{ext}", audio)
    _atomic_bytes(qdir / f"{intent_id}.md", "\n".join(fm).encode("utf-8"))
    return intent_id, True


def _atomic_bytes(path, data):
    tmp = path.with_name("." + path.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def flat(text):
    """Vrije tekst van buiten (app, Vikunja) wordt een regel: geen kop, geen nieuwe sectie,
    geen frontmatter. Een markdown-kop of '---' aan het begin wordt geneutraliseerd."""
    t = " ".join(str(text or "").split())
    return re.sub(r"^(#+|-{3,}|>)\s*", "", t)



def parse_date(v):
    if not v or not isinstance(v, str):
        return None
    m = re.match(r"(\d{4}-\d{2}-\d{2})", v.strip())
    if not m:
        return None
    try:
        return date.fromisoformat(m.group(1))
    except ValueError:
        return None


def as_list(v):
    if v is None:
        return []
    if isinstance(v, list):
        return [x for x in v if x and x != "null"]
    if v in ("null", ""):
        return []
    return [v]


def task_from_file(p, status, log=_log_stderr):
    """Een taakbestand -> dict. None als het niet leesbaar is. Gedeeld met index_db.py
    (via dag.task_from_file, dat de klantvlag toevoegt) en vikunja_sync.py."""
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as ex:
        # The task id only: a filename slug or an OS error text can name a client (Argus F3).
        m = TASK_REF_RE.match(p.stem)
        log("task_read_error", task=m.group(0) if m else "unparsable", error=type(ex).__name__,
            errno=getattr(ex, "errno", None))
        return None
    fm, _ = ri.parse_frontmatter(text)
    m = TASK_REF_RE.match(p.stem)
    tid = ri.fm_scalar(fm, "id") or (m.group(0) if m else p.stem)
    tier = str(fm.get("confidentiality_tier", "") or "")
    tags = fm.get("tags") if isinstance(fm.get("tags"), list) else []
    try:
        prio = int(ri.fm_scalar(fm, "priority", "3"))
    except ValueError:
        prio = 3
    task = {
        "id": tid,
        "title": ri.fm_scalar(fm, "title", p.stem),
        "status": status,
        "assignee": (ri.fm_scalar(fm, "assignee", "") or "").lower(),
        "priority": prio,
        "due": parse_date(ri.fm_scalar(fm, "due")),
        "blocked_by": [x for x in as_list(fm.get("blocked_by")) if TASK_REF_RE.match(x)],
        "blocked_reason": ri.fm_scalar(fm, "blocked_reason"),
        "updates": ri.parse_updates(text),
        "what": ri.first_line_what_this_is(text),
        # Voor de app (snapshot.py): de tier zonder commentaar, de projecten
        # waar de taak naar wijst, en de persoon waarop hij wacht. De laatste
        # wordt alleen gelezen, nooit uitgegeven (ontwerpregel §9.4.3).
        "tier": tier.split("#", 1)[0].strip().lower(),
        "projects": as_list(fm.get("linked_my_life")),
        "blocked_by_person": (ri.fm_scalar(fm, "blocked_by_person", "") or "").lower(),
        "updated": ri.fm_scalar(fm, "updated"),
    }
    # Onbewerkt, voor regels van de aanroeper (dag.py: klantvlag; vikunja_sync: gebieden).
    # De frontmatter-parser leest een inline # als deel van de waarde: tier is dus met commentaar.
    task["raw"] = {"tier": tier, "tags": [str(t) for t in tags], "title": ri.fm_scalar(fm, "title", "") or ""}
    return task


def code_for(kind, key):
    """Stabiele, betekenisloze code. Zelfde slug geeft altijd dezelfde code, zodat
    de eigenaar hem op de MacBook (waar naam en code naast elkaar staan) kan leren."""
    h = hashlib.sha256(f"{kind}:{key}".encode()).hexdigest()[:4].upper()
    return f"{'P' if kind == 'project' else 'T'}-{h}"
