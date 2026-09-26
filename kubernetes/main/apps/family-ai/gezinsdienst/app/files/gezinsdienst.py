#!/usr/bin/env python3
"""gezinsdienst: the family AI's signal and counter service (cluster, stdlib only).

Two record kinds, both from CLOSED vocabularies, neither able to hold free text:

  POST /v1/signaal   body exactly {"soort": "A"|"B"|"C"|"D"}   (Tess §5.2, §5.5)
  POST /v1/gedrag    body exactly {"soort": <one of GEDRAG>}           (Tess §12.4, the trust ladder)
  POST /v1/gebruik   body exactly {"soort": "bericht"}                 (one per user turn: hour only, no content)

Identity is never taken from the body. The caller authenticates with a per-profile bearer token; the
service maps the token's sha256 to a subject id from its config. A model therefore cannot misattribute
a signal, and the plugin cannot either.

Parents' page (GET /, POST /besproken/<id>) and the counts overview (GET /v1/overzicht) sit behind the
cluster's Authelia; this service reads the forwarded user and groups headers and refuses without them.
The NetworkPolicy must make envoy the only ingress for those paths (README).

Logs carry the event name and HTTP status only. Never the subject, never the category: cluster logs
live longer and are readable by more people than the 30-day signal record may be (Tess §5.11).

Configuration: GEZIN_CONFIG (path to JSON, no secrets in it: tokens are stored as sha256),
GEZIN_DB (path to SQLite), GEZIN_TEKSTEN (path to teksten.json), GEZIN_NTFY_TOPIC and
GEZIN_NTFY_TOPIC_TEST (secrets, env only). Startup refuses on anything missing or malformed.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import html
import json
import logging
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo

SOORTEN = ("A", "B", "C", "D")
GEEL_DREMPELS = {"huiswerk_doorgedrukt": 2, "omzeilpoging": 3, "gevaarlijke_vraag": 3, "gegevens_van_anderen": 2}
GEEL_LATE_AVONDEN = 3
GEDRAG = ("huiswerk_doorgedrukt", "omzeilpoging", "gevaarlijke_vraag", "gegevens_van_anderen", "leerpad_stap_af")
MAX_BODY = 1024
IDEM_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")  # UUID only: no free text
LOG = logging.getLogger("gezinsdienst")


# --------------------------------------------------------------------------- configuration


class ConfigFout(Exception):
    pass


def laad_config(pad: str) -> Dict[str, Any]:
    with open(pad, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    verplicht = ("onderwerpen", "gedrag", "toegang", "stille_uren", "tijdzone", "ntfy", "bewaren", "dedup_uren", "pagina_url")
    for k in verplicht:
        if k not in cfg:
            raise ConfigFout(f"config mist '{k}'")
    if not isinstance(cfg["onderwerpen"], dict) or not cfg["onderwerpen"]:
        raise ConfigFout("config.onderwerpen is leeg")
    gezien = set()
    for oid, o in cfg["onderwerpen"].items():
        if not re.fullmatch(r"[a-z0-9-]{1,32}", oid):
            raise ConfigFout("onderwerp-id ongeldig")
        if o.get("modus") not in ("test", "live"):
            raise ConfigFout(f"onderwerp {oid}: modus moet test of live zijn")
        if "token_env" in o:
            waarde = os.environ.get(str(o["token_env"]), "")
            if len(waarde) < 24:
                raise ConfigFout(f"onderwerp {oid}: {o['token_env']} ontbreekt of is korter dan 24 tekens")
            o["token_sha256"] = hashlib.sha256(waarde.encode("utf-8")).hexdigest()
        h = o.get("token_sha256", "")
        if not re.fullmatch(r"[0-9a-f]{64}", h):
            raise ConfigFout(f"onderwerp {oid}: token_sha256 ongeldig")
        if h in gezien:
            raise ConfigFout("twee onderwerpen delen een token")
        gezien.add(h)
        if not o.get("naam"):
            raise ConfigFout(f"onderwerp {oid}: naam ontbreekt")
        for vlag in ("signaal", "gedrag"):
            if not isinstance(o.get(vlag, False), bool):
                raise ConfigFout(f"onderwerp {oid}: {vlag} moet true of false zijn")
    gd = cfg["gedrag"]
    for k in ("telt_vanaf", "stil_na_signaal_uren", "avond_grens", "avond_grens_weekend", "avond_min_berichten", "vakantieweken"):
        if k not in gd:
            raise ConfigFout(f"gedrag mist '{k}'")
    if gd["telt_vanaf"] is not None and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(gd["telt_vanaf"])):
        raise ConfigFout("gedrag.telt_vanaf moet null of JJJJ-MM-DD zijn")
    parse_venster(cfg["stille_uren"])
    ZoneInfo(cfg["tijdzone"])
    t = cfg["toegang"]
    for k in ("header_gebruiker", "header_groepen", "ouders_groep", "eigen_pagina"):
        if k not in t:
            raise ConfigFout(f"toegang mist '{k}'")
    for login, oid in t["eigen_pagina"].items():
        if oid not in cfg["onderwerpen"]:
            raise ConfigFout("eigen_pagina verwijst naar een onbekend onderwerp")
    return cfg


def parse_venster(s: str) -> Tuple[int, int]:
    m = re.fullmatch(r"(\d{2}):(\d{2})-(\d{2}):(\d{2})", s or "")
    if not m:
        raise ConfigFout("stille_uren moet HH:MM-HH:MM zijn")
    a = int(m.group(1)) * 60 + int(m.group(2))
    b = int(m.group(3)) * 60 + int(m.group(4))
    if not (0 <= a < 1440 and 0 <= b < 1440) or a == b:
        raise ConfigFout("stille_uren ongeldig")
    return a, b


def in_stille_uren(ts: float, venster: Tuple[int, int], tz: ZoneInfo) -> bool:
    lokaal = _dt.datetime.fromtimestamp(ts, tz)
    m = lokaal.hour * 60 + lokaal.minute
    a, b = venster
    return (a <= m < b) if a < b else (m >= a or m < b)


# --------------------------------------------------------------------------- storage

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA secure_delete=ON;
CREATE TABLE IF NOT EXISTS signalen (
  id INTEGER PRIMARY KEY,
  onderwerp TEXT NOT NULL,
  soort TEXT NOT NULL CHECK (soort IN ('A','B','C','D')),
  modus TEXT NOT NULL CHECK (modus IN ('test','live')),
  aangemaakt REAL NOT NULL,
  geopend REAL,
  besproken REAL,
  deurbel_verstuurd REAL,
  deurbel_stil INTEGER NOT NULL DEFAULT 0,
  herhaling_verstuurd REAL,
  pogingen INTEGER NOT NULL DEFAULT 0,
  volgende_poging REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS gedrag (
  id INTEGER PRIMARY KEY,
  onderwerp TEXT NOT NULL,
  soort TEXT NOT NULL CHECK (soort IN ('huiswerk_doorgedrukt','omzeilpoging','gevaarlijke_vraag','gegevens_van_anderen','leerpad_stap_af')),
  modus TEXT NOT NULL CHECK (modus IN ('test','live')),
  uur REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'geldig' CHECK (status IN ('geldig','telt_niet'))
);
CREATE TABLE IF NOT EXISTS gebruik_uur (
  onderwerp TEXT NOT NULL,
  modus TEXT NOT NULL,
  dag TEXT NOT NULL,
  uur INTEGER NOT NULL CHECK (uur BETWEEN 0 AND 23),
  n INTEGER NOT NULL,
  PRIMARY KEY (onderwerp, modus, dag, uur)
);
CREATE TABLE IF NOT EXISTS week_samenvatting (
  onderwerp TEXT NOT NULL,
  week TEXT NOT NULL,
  modus TEXT NOT NULL,
  tellers TEXT NOT NULL,
  late_avonden TEXT NOT NULL,
  kleur TEXT NOT NULL CHECK (kleur IN ('groen','geel','rood')),
  gemaakt REAL NOT NULL,
  PRIMARY KEY (onderwerp, week, modus)
);
CREATE TABLE IF NOT EXISTS weekpush (
  week TEXT PRIMARY KEY,
  verstuurd REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS idem (
  sleutel TEXT PRIMARY KEY,
  onderwerp TEXT NOT NULL,
  antwoord TEXT NOT NULL,
  tijd REAL NOT NULL
);
"""


class Opslag:
    def __init__(self, pad: str):
        self._lock = threading.Lock()
        self.db = sqlite3.connect(pad, check_same_thread=False, isolation_level=None)
        self.db.executescript(SCHEMA)

    def tx(self, fn: Callable[[sqlite3.Connection], Any]) -> Any:
        with self._lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                r = fn(self.db)
                self.db.execute("COMMIT")
                return r
            except BaseException:
                self.db.execute("ROLLBACK")
                raise


# --------------------------------------------------------------------------- core logic (no HTTP)


class Dienst:
    def __init__(self, cfg: Dict[str, Any], opslag: Opslag, teksten: Dict[str, Any],
                 klok: Callable[[], float] = time.time,
                 verstuur: Optional[Callable[[str, str, str, int, str], None]] = None,
                 topics: Optional[Dict[str, str]] = None):
        self.cfg = cfg
        self.opslag = opslag
        self.teksten = teksten
        self.klok = klok
        self.tz = ZoneInfo(cfg["tijdzone"])
        self.venster = parse_venster(cfg["stille_uren"])
        self.per_hash = {o["token_sha256"]: oid for oid, o in cfg["onderwerpen"].items()}
        self.verstuur = verstuur or ntfy_verstuur
        self.topics = topics or {}
        if self.topics.get("live") and self.topics.get("live") == self.topics.get("test"):
            raise ConfigFout("live- en testtopic zijn gelijk")

    # identity ---------------------------------------------------------------
    def onderwerp_voor_token(self, token: str) -> Optional[str]:
        if not token:
            return None
        return self.per_hash.get(hashlib.sha256(token.encode("utf-8")).hexdigest())

    # signal -----------------------------------------------------------------
    def signaal(self, oid: str, body: Any, idem: Optional[str]) -> Tuple[int, Dict[str, Any]]:
        if not isinstance(body, dict) or set(body.keys()) != {"soort"}:
            return 400, {"fout": "alleen het veld soort is toegestaan"}
        soort = body["soort"]
        if soort not in SOORTEN:
            return 400, {"fout": "soort moet A, B, C of D zijn"}
        onderwerp = self.cfg["onderwerpen"][oid]
        if not onderwerp.get("signaal", False):
            return 403, {"fout": "signaal staat niet aan voor dit profiel"}
        if idem is not None and not IDEM_RE.fullmatch(idem):
            return 400, {"fout": "Idempotency-Key ongeldig"}
        nu = self.klok()
        venster_s = float(self.cfg["dedup_uren"]) * 3600

        modus = onderwerp["modus"]
        # The mode is part of the key: a test-mode retry can never answer for a live request (review 2).
        idem_h = hashlib.sha256(f"{modus}:{idem}".encode()).hexdigest() if idem else None

        def doe(db: sqlite3.Connection) -> Tuple[int, Dict[str, Any]]:
            if idem_h:
                r = db.execute("SELECT onderwerp, antwoord FROM idem WHERE sleutel=?", (idem_h,)).fetchone()
                if r:
                    if r[0] != oid:
                        return 409, {"fout": "Idempotency-Key hoort bij een ander profiel"}
                    return 200, json.loads(r[1])
            r = db.execute(
                "SELECT id FROM signalen WHERE onderwerp=? AND soort=? AND modus=? AND aangemaakt>=? ORDER BY id DESC LIMIT 1",
                (oid, soort, modus, nu - venster_s)).fetchone()
            if r:
                antwoord = {"nieuw": False, "zin": self.teksten["signaal_zin"]}
            else:
                db.execute(
                    "INSERT INTO signalen (onderwerp, soort, modus, aangemaakt, volgende_poging) VALUES (?,?,?,?,?)",
                    (oid, soort, modus, nu, nu))
                antwoord = {"nieuw": True, "zin": self.teksten["signaal_zin"]}
            if idem_h:
                db.execute("INSERT INTO idem (sleutel, onderwerp, antwoord, tijd) VALUES (?,?,?,?)",
                           (idem_h, oid, json.dumps(antwoord), nu))
            return 200, antwoord

        return self.opslag.tx(doe)

    # trust ladder ----------------------------------------------------------------
    def _telt(self, oid: str) -> bool:
        """Counting is on for test subjects always, for live subjects only from gedrag.telt_vanaf (Tess §12.9.5)."""
        o = self.cfg["onderwerpen"][oid]
        if not o.get("gedrag", False):
            return False
        if o["modus"] == "test":
            return True
        vanaf = self.cfg["gedrag"]["telt_vanaf"]
        vandaag = _dt.datetime.fromtimestamp(self.klok(), self.tz).strftime("%Y-%m-%d")
        return vanaf is not None and vandaag >= vanaf

    def gedrag(self, oid: str, body: Any) -> Tuple[int, Dict[str, Any]]:
        if not isinstance(body, dict) or set(body.keys()) != {"soort"}:
            return 400, {"fout": "alleen het veld soort is toegestaan"}
        soort = body["soort"]
        if soort not in GEDRAG:
            return 400, {"fout": "onbekende soort"}
        if not self.cfg["onderwerpen"][oid].get("gedrag", False):
            return 403, {"fout": "gedrag staat niet aan voor dit profiel"}
        leeg = {"geteld": False, "zin": ""}
        if not self._telt(oid):
            return 200, leeg
        nu = self.klok()
        stil_s = float(self.cfg["gedrag"]["stil_na_signaal_uren"]) * 3600

        def doe(db: sqlite3.Connection) -> Dict[str, Any]:
            # A safety signal for this subject recently: nothing is logged (Tess §12.1 rule 2). Nothing is
            # stored about the refusal either, so the ladder holds no pointer to a crisis.
            if db.execute("SELECT 1 FROM signalen WHERE onderwerp=? AND modus=? AND aangemaakt>=? LIMIT 1",
                          (oid, self.cfg["onderwerpen"][oid]["modus"], nu - stil_s)).fetchone():
                return leeg
            db.execute("INSERT INTO gedrag (onderwerp, soort, modus, uur) VALUES (?,?,?,?)",
                       (oid, soort, self.cfg["onderwerpen"][oid]["modus"], nu - (nu % 3600)))
            if soort == "leerpad_stap_af":
                return {"geteld": True, "zin": ""}
            label = self.teksten["gedrag"][soort]
            return {"geteld": True, "zin": self.teksten["gedrag_zin"].replace("<soort>", label)}

        return 200, self.opslag.tx(doe)

    def gebruik(self, oid: str, body: Any) -> Tuple[int, Dict[str, Any]]:
        if not isinstance(body, dict) or body != {"soort": "bericht"}:
            return 400, {"fout": "alleen {\"soort\": \"bericht\"}"}
        if not self._telt(oid):
            return 200, {"geteld": False}
        lokaal = _dt.datetime.fromtimestamp(self.klok(), self.tz)
        modus = self.cfg["onderwerpen"][oid]["modus"]
        self.opslag.tx(lambda db: db.execute(
            "INSERT INTO gebruik_uur (onderwerp, modus, dag, uur, n) VALUES (?,?,?,?,1) "
            "ON CONFLICT(onderwerp, modus, dag, uur) DO UPDATE SET n=n+1",
            (oid, modus, lokaal.strftime("%Y-%m-%d"), lokaal.hour)))
        return 200, {"geteld": True}

    def late_avonden(self, oid: str, van: str, tot: str) -> List[str]:
        """Evenings (date strings) with >= avond_min_berichten messages after the cut-off, counting the hours
        after midnight up to 05:00 toward the previous evening. From hour counts only (Tess §12.3)."""
        gd = self.cfg["gedrag"]
        rijen = self.opslag.tx(lambda db: db.execute(
            "SELECT dag, uur, n FROM gebruik_uur WHERE onderwerp=? AND modus=? AND dag>=? AND dag<=?",
            (oid, self.cfg["onderwerpen"][oid]["modus"], van, tot)).fetchall())
        per_avond: Dict[str, int] = {}
        for dag, uur, n in rijen:
            d = _dt.date.fromisoformat(dag)
            if uur < 5:
                avond = d - _dt.timedelta(days=1)
            else:
                avond = d
            week = avond.isocalendar()[1]
            weekend = avond.weekday() in (4, 5)  # Friday, Saturday evenings
            grens = int(gd["avond_grens_weekend"] if (weekend or week in gd["vakantieweken"]) else gd["avond_grens"])
            if uur < 5 or uur >= grens:
                k = avond.isoformat()
                per_avond[k] = per_avond.get(k, 0) + int(n)
        return sorted(k for k, v in per_avond.items() if v >= int(gd["avond_min_berichten"]) and van <= k <= tot)

    # doorbell -----------------------------------------------------------------
    def deurbel_ronde(self) -> int:
        """Send due doorbells and the one morning repeat. Returns the number of sends attempted."""
        rijen = self.opslag.tx(lambda db: db.execute(
            "SELECT id, modus, deurbel_verstuurd, deurbel_stil, herhaling_verstuurd, geopend, pogingen, volgende_poging "
            "FROM signalen WHERE besproken IS NULL").fetchall())
        pogingen = 0
        for (sid, modus, verstuurd, was_stil, herhaald, geopend, n, volgende) in rijen:
            nu = self.klok()  # per send: a batch that crosses 23:00 must not stay loud
            stil = in_stille_uren(nu, self.venster, self.tz)
            eerste = verstuurd is None
            herhaling = (not eerste) and was_stil and herhaald is None and geopend is None and not stil
            if not (eerste or herhaling) or nu < volgende:
                continue
            pogingen += 1
            prio = 2 if stil else 3
            topic, tekst = self._kanaal(modus)
            try:
                if topic:
                    self.verstuur(self.cfg["ntfy"]["server"], topic, self.teksten["deurbel_titel"], prio, tekst)
                ok = True
            except Exception:
                ok = False
            def boek(db: sqlite3.Connection, sid=sid, eerste=eerste, ok=ok, n=n) -> None:
                if not ok:
                    wacht = min(1800.0, 30.0 * (2 ** min(n, 6)))
                    db.execute("UPDATE signalen SET pogingen=pogingen+1, volgende_poging=? WHERE id=?", (nu + wacht, sid))
                elif eerste:
                    db.execute("UPDATE signalen SET deurbel_verstuurd=?, deurbel_stil=?, pogingen=0, volgende_poging=? WHERE id=?",
                               (nu, 1 if stil else 0, nu, sid))
                else:
                    db.execute("UPDATE signalen SET herhaling_verstuurd=?, pogingen=0 WHERE id=?", (nu, sid))
            self.opslag.tx(boek)
            LOG.info(json.dumps({"event": "deurbel", "resultaat": "ok" if ok else "fout", "herhaling": not eerste}))
        return pogingen

    def _kanaal(self, modus: str) -> Tuple[Optional[str], str]:
        if modus == "live":
            return self.topics.get("live"), self.teksten["deurbel_tekst"]
        return self.topics.get("test"), self.teksten["deurbel_test_tekst"]

    # retention ------------------------------------------------------------------
    def opruimen(self) -> None:
        nu = self.klok()
        b = self.cfg["bewaren"]
        grens_s = nu - float(b["signaal_dagen_na_besproken"]) * 86400
        grens_ruw = nu - float(b["ruw_weken"]) * 7 * 86400
        grens_dag = _dt.datetime.fromtimestamp(grens_ruw, self.tz).strftime("%Y-%m-%d")
        grens_idem = nu - float(self.cfg["dedup_uren"]) * 3600 * 4

        def doe(db: sqlite3.Connection) -> None:
            db.execute("DELETE FROM signalen WHERE besproken IS NOT NULL AND besproken < ?", (grens_s,))
            db.execute("DELETE FROM gedrag WHERE uur < ?", (grens_ruw,))
            db.execute("DELETE FROM gebruik_uur WHERE dag < ?", (grens_dag,))
            db.execute("DELETE FROM idem WHERE tijd < ?", (grens_idem,))
            db.execute("DELETE FROM week_samenvatting WHERE gemaakt < ?", (nu - 52 * 7 * 86400,))

        self.opslag.tx(doe)

    # weekly summary (Tess §12.5), deterministic, no model --------------------------
    def _week_grenzen(self, maandag: _dt.date) -> Tuple[float, float, str]:
        start = _dt.datetime.combine(maandag, _dt.time(0, 0), self.tz).timestamp()
        eind = _dt.datetime.combine(maandag + _dt.timedelta(days=7), _dt.time(0, 0), self.tz).timestamp()
        jaar, week, _ = maandag.isocalendar()
        return start, eind, f"{jaar}-W{week:02d}"

    def week_berekenen(self, oid: str, maandag: _dt.date) -> Dict[str, Any]:
        modus = self.cfg["onderwerpen"][oid]["modus"]
        start, eind, week = self._week_grenzen(maandag)
        rijen = self.opslag.tx(lambda db: db.execute(
            "SELECT soort, COUNT(*) FROM gedrag WHERE onderwerp=? AND modus=? AND uur>=? AND uur<? AND status='geldig' "
            "GROUP BY soort", (oid, modus, start, eind)).fetchall())
        tellers = {k: 0 for k in GEDRAG}
        tellers.update({k: int(n) for k, n in rijen})
        zondag = maandag + _dt.timedelta(days=6)
        avonden = self.late_avonden(oid, maandag.isoformat(), zondag.isoformat())
        geel = any(tellers[k] >= d for k, d in GEEL_DREMPELS.items()) or len(avonden) >= GEEL_LATE_AVONDEN
        vorige = self.opslag.tx(lambda db: db.execute(
            "SELECT kleur FROM week_samenvatting WHERE onderwerp=? AND modus=? AND week=?",
            (oid, modus, self._week_grenzen(maandag - _dt.timedelta(days=7))[2])).fetchone())
        kleur = "groen" if not geel else ("rood" if vorige and vorige[0] in ("geel", "rood") else "geel")
        return {"week": week, "tellers": tellers, "late_avonden": avonden, "kleur": kleur, "modus": modus}

    def week_opslaan(self, maandag: _dt.date) -> List[Dict[str, Any]]:
        uit = []
        for oid, o in self.cfg["onderwerpen"].items():
            if not o.get("gedrag") or not self._telt(oid):
                continue
            w = self.week_berekenen(oid, maandag)
            self.opslag.tx(lambda db, w=w, oid=oid: db.execute(
                "INSERT INTO week_samenvatting (onderwerp, week, modus, tellers, late_avonden, kleur, gemaakt) "
                "VALUES (?,?,?,?,?,?,?) ON CONFLICT(onderwerp, week, modus) DO UPDATE SET tellers=excluded.tellers, "
                "late_avonden=excluded.late_avonden, kleur=excluded.kleur, gemaakt=excluded.gemaakt",
                (oid, w["week"], w["modus"], json.dumps(w["tellers"]), json.dumps(w["late_avonden"]), w["kleur"], self.klok())))
            uit.append({"onderwerp": oid, **w})
        return uit

    def zondag_ronde(self) -> Optional[str]:
        """Sunday 18:00 summary, 19:00 push only if a boy is yellow or red (Tess §12.9.6). Idempotent per week."""
        nu = _dt.datetime.fromtimestamp(self.klok(), self.tz)
        if nu.weekday() != 6 or nu.hour < 18:
            return None
        maandag = nu.date() - _dt.timedelta(days=6)
        samen = self.week_opslaan(maandag)
        if nu.hour < 19:
            return "samengevat"
        week = self._week_grenzen(maandag)[2]
        if self.opslag.tx(lambda db: db.execute("SELECT 1 FROM weekpush WHERE week=?", (week,)).fetchone()):
            return "al gedaan"
        actie = [w for w in samen if w["kleur"] != "groen"]
        live = [w for w in actie if w["modus"] == "live"]
        if actie:
            topic, tekst = (self.topics.get("live"), self.teksten["weekpush_tekst"]) if live else \
                           (self.topics.get("test"), "TEST - " + self.teksten["weekpush_tekst"])
            if topic:
                self.verstuur(self.cfg["ntfy"]["server"], topic, self.teksten["deurbel_titel"], 3, tekst)
        self.opslag.tx(lambda db: db.execute("INSERT INTO weekpush (week, verstuurd) VALUES (?,?)", (week, self.klok())))
        LOG.info(json.dumps({"event": "weekpush", "nodig": bool(actie)}))
        return "push" if actie else "geen push"

    def telt_niet(self, gid: int) -> bool:
        return self.opslag.tx(lambda db: db.execute(
            "UPDATE gedrag SET status='telt_niet' WHERE id=? AND status='geldig'", (gid,)).rowcount == 1)

    # parents -------------------------------------------------------------------
    def rol(self, gebruiker: str, groepen: str) -> Tuple[str, Optional[str]]:
        """('ouder', None), ('kind', <onderwerp>) or ('geen', None). Deny by default."""
        t = self.cfg["toegang"]
        if not gebruiker:
            return "geen", None
        gs = {g.strip() for g in (groepen or "").split(",") if g.strip()}
        if t["ouders_groep"] in gs:
            return "ouder", None
        oid = t["eigen_pagina"].get(gebruiker)
        if oid:
            return "kind", oid
        return "geen", None

    def pagina(self) -> str:
        nu = self.klok()
        def lees(db: sqlite3.Connection) -> List[Tuple]:
            rijen = db.execute("SELECT id, onderwerp, soort, modus, aangemaakt, geopend, besproken FROM signalen "
                               "ORDER BY aangemaakt DESC").fetchall()
            db.execute("UPDATE signalen SET geopend=? WHERE geopend IS NULL", (nu,))
            return rijen
        rijen = self.opslag.tx(lees)
        regels = []
        for (sid, oid, soort, modus, t, geopend, besproken) in rijen:
            naam = html.escape(self.cfg["onderwerpen"].get(oid, {}).get("naam", "?"))
            wanneer = _dt.datetime.fromtimestamp(t, self.tz).strftime("%a %d %b %H:%M")
            status = "besproken" if besproken else ("nog niet geopend" if geopend is None else "geopend")
            test = " <strong>[TEST]</strong>" if modus == "test" else ""
            knop = "" if besproken else (f'<form method="post" action="/besproken/{sid}"><button>besproken</button></form>')
            regels.append(f"<li>{naam} · {html.escape(self.teksten['soorten'][soort])} · {wanneer} · {status}{test} {knop}</li>")
        lijst = "\n".join(regels) or "<li>Geen signalen.</li>"
        return ("<!doctype html><html lang=nl><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                "<title>Gezin</title><h1>Signalen</h1><ul>" + lijst + "</ul><p>" + html.escape(self.teksten["wat_nu"]) +
                "</p></html>")

    def ladder_html(self, rol: str, eigen: Optional[str]) -> str:
        """Tess §12.10. Parent: both boys, side by side, no ranking. Child: only his own page ("Mijn ladder").
        Shows counts, colours, dates and categories only. Never chat text, ids of chats, topics or memory."""
        e = html.escape
        nu = self.klok()
        vandaag = _dt.datetime.fromtimestamp(nu, self.tz).date()
        maandag = vandaag - _dt.timedelta(days=vandaag.weekday())
        labels = self.teksten["gedrag"]
        kolommen = []
        for oid, o in self.cfg["onderwerpen"].items():
            if not o.get("gedrag") or (rol == "kind" and oid != eigen):
                continue
            w = self.week_berekenen(oid, maandag)
            rijen = self.opslag.tx(lambda db, oid=oid, o=o: db.execute(
                "SELECT week, kleur FROM week_samenvatting WHERE onderwerp=? AND modus=? ORDER BY week DESC LIMIT 12",
                (oid, o["modus"])).fetchall())
            groen_op_rij = 0
            for _, k in rijen:
                if k != "groen":
                    break
                groen_op_rij += 1
            sig = self.opslag.tx(lambda db, oid=oid, o=o: db.execute(
                "SELECT soort, aangemaakt, besproken FROM signalen WHERE onderwerp=? AND modus=? AND aangemaakt>=? "
                "ORDER BY aangemaakt DESC", (oid, o["modus"], nu - 30 * 86400)).fetchall())
            dagen = ", ".join(_dt.date.fromisoformat(d).strftime("%a") for d in w["late_avonden"]) or "geen"
            regels = "".join(f"<tr><td>{e(labels[k])}</td><td>{w['tellers'][k]}</td></tr>"
                             for k in GEDRAG if k != "leerpad_stap_af")
            regels += f"<tr><td>Laat op de avond</td><td>{len(w['late_avonden'])} ({e(dagen)})</td></tr>"
            strip = " ".join(e(k) for _, k in reversed(rijen)) or "nog geen weken"
            seintjes = "".join(
                f"<li>{e(self.teksten['soorten'][s_])} · {_dt.datetime.fromtimestamp(t_, self.tz).strftime('%a %d %b %H:%M')}"
                f"{' · besproken' if b_ else ''}</li>" for s_, t_, b_ in sig) or "<li>geen</li>"
            niveau = int((self.cfg.get("niveaus") or {}).get(oid, 1))
            test = " [TEST]" if o["modus"] == "test" else ""
            kop = "Mijn ladder" if rol == "kind" else e(o["naam"])
            kolommen.append(
                f"<section><h2>{kop}{test}</h2><p>Niveau {niveau}.</p><p>Deze week: {e(w['kleur'])}.</p>"
                f"<table>{regels}</table><p>Laatste weken: {strip}</p>"
                f"<p>Op weg naar niveau {niveau + 1}: {min(groen_op_rij, 4)} van 4 groene weken; de rest bespreek je aan tafel.</p>"
                f"<h3>{'Jouw seintjes' if rol == 'kind' else 'Veiligheidssignalen'} (30 dagen)</h3><ul>{seintjes}</ul>"
                f"<p><em>Seintjes tellen nooit mee voor de ladder.</em></p></section>")
        voet = ("<p>Wat papa ziet: precies dit. Wat niemand ziet: je gesprekken.</p>" if rol == "kind" else "")
        return ("<!doctype html><html lang=nl><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                "<title>Ladder</title>" + "".join(kolommen) + voet + "</html>")

    def besproken(self, sid: int) -> bool:
        nu = self.klok()
        return self.opslag.tx(lambda db: db.execute(
            "UPDATE signalen SET besproken=? WHERE id=? AND besproken IS NULL", (nu, sid)).rowcount == 1)

    def overzicht(self, rol: str, eigen: Optional[str], dagen: int = 7) -> Dict[str, Any]:
        """Counts only, schema-bound. A parent sees every subject with gedrag on; a child only his own.
        Safety signals are never in here (they have their own page)."""
        nu = self.klok()
        van = _dt.datetime.fromtimestamp(nu - dagen * 86400, self.tz).strftime("%Y-%m-%d")
        tot = _dt.datetime.fromtimestamp(nu, self.tz).strftime("%Y-%m-%d")
        grens = nu - dagen * 86400
        uit: Dict[str, Dict[str, Any]] = {}
        for oid, o in self.cfg["onderwerpen"].items():
            if not o.get("gedrag", False) or (rol == "kind" and oid != eigen):
                continue
            rijen = self.opslag.tx(lambda db: db.execute(
                "SELECT soort, COUNT(*) FROM gedrag WHERE onderwerp=? AND modus=? AND uur>=? AND status='geldig' GROUP BY soort",
                (oid, o["modus"], grens)).fetchall())
            tellers = {s: 0 for s in GEDRAG}
            tellers.update({s: int(n) for s, n in rijen})
            avonden = self.late_avonden(oid, van, tot)
            uit[oid] = {"gedrag": tellers, "late_avonden": avonden}
        return {"vanaf": van, "tot": tot, "onderwerpen": uit}


# --------------------------------------------------------------------------- ntfy


def ntfy_verstuur(server: str, topic: str, titel: str, prio: int, tekst: str) -> None:
    req = urllib.request.Request(
        server.rstrip("/") + "/" + topic, data=tekst.encode("utf-8"), method="POST",
        headers={"Title": titel, "Priority": str(prio)})
    with urllib.request.urlopen(req, timeout=10) as r:
        if r.status // 100 != 2:
            raise RuntimeError("ntfy status")


# --------------------------------------------------------------------------- HTTP


def maak_handler(dienst: Dienst):
    class H(BaseHTTPRequestHandler):
        server_version = "gezinsdienst"
        sys_version = ""

        def log_message(self, *a: Any) -> None:  # the default logger prints paths and addresses
            return

        def _json(self, code: int, obj: Dict[str, Any]) -> None:
            data = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _html(self, code: int, text: str) -> None:
            data = text.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", "default-src 'none'; form-action 'self'")
            self.send_header("X-Frame-Options", "DENY")
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> Any:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > MAX_BODY:
                raise ValueError("lengte")
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise ValueError("type")
            return json.loads(self.rfile.read(n).decode("utf-8"))

        def _onderwerp(self) -> Optional[str]:
            a = self.headers.get("Authorization") or ""
            return dienst.onderwerp_voor_token(a[7:] if a.startswith("Bearer ") else "")

        def _rol(self) -> Tuple[str, Optional[str]]:
            t = dienst.cfg["toegang"]
            return dienst.rol(self.headers.get(t["header_gebruiker"]) or "", self.headers.get(t["header_groepen"]) or "")

        def do_GET(self) -> None:
            if self.path == "/healthz":
                return self._json(200, {"ok": True})
            rol, eigen = self._rol()
            if self.path == "/":
                if rol != "ouder":
                    LOG.info(json.dumps({"event": "pagina", "status": 403}))
                    return self._html(403, "<p>Geen toegang.</p>")
                return self._html(200, dienst.pagina())
            if self.path == "/ladder":
                if rol == "geen":
                    return self._html(403, "<p>Geen toegang.</p>")
                return self._html(200, dienst.ladder_html(rol, eigen))
            if self.path.startswith("/v1/overzicht"):
                if rol == "geen":
                    return self._json(403, {"fout": "geen toegang"})
                return self._json(200, dienst.overzicht(rol, eigen))
            return self._json(404, {"fout": "niet gevonden"})

        def do_POST(self) -> None:
            if self.path in ("/v1/signaal", "/v1/gedrag", "/v1/gebruik"):
                oid = self._onderwerp()
                if not oid:
                    LOG.info(json.dumps({"event": self.path, "status": 401}))
                    return self._json(401, {"fout": "onbekend token"})
                try:
                    body = self._body()
                except Exception:
                    return self._json(400, {"fout": "ongeldige body"})
                if self.path == "/v1/signaal":
                    code, obj = dienst.signaal(oid, body, self.headers.get("Idempotency-Key"))
                elif self.path == "/v1/gedrag":
                    code, obj = dienst.gedrag(oid, body)
                else:
                    code, obj = dienst.gebruik(oid, body)
                LOG.info(json.dumps({"event": self.path, "status": code}))
                return self._json(code, obj)
            m = re.fullmatch(r"/(besproken|telt-niet)/(\d{1,9})", self.path)
            if m:
                rol, _ = self._rol()
                if rol != "ouder":
                    return self._html(403, "<p>Geen toegang.</p>")
                host = self.headers.get("Host") or ""
                origin = self.headers.get("Origin") or ""
                if not origin or origin.split("://", 1)[-1] != host:
                    return self._html(403, "<p>Geweigerd.</p>")
                if m.group(1) == "besproken":
                    dienst.besproken(int(m.group(2)))
                else:
                    dienst.telt_niet(int(m.group(2)))
                self.send_response(303)
                self.send_header("Location", "/" if m.group(1) == "besproken" else "/ladder")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            return self._json(404, {"fout": "niet gevonden"})

    return H


def achtergrond(dienst: Dienst, stop: threading.Event, interval: float = 30.0) -> None:
    laatst_opgeruimd = 0.0
    while not stop.wait(interval):
        try:
            dienst.deurbel_ronde()
            dienst.zondag_ronde()
            if time.time() - laatst_opgeruimd > 3600:
                dienst.opruimen()
                laatst_opgeruimd = time.time()
        except Exception as e:  # keep the loop alive; the error class only, never data
            LOG.error(json.dumps({"event": "achtergrond", "fout": type(e).__name__}))


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    try:
        cfg = laad_config(os.environ["GEZIN_CONFIG"])
        with open(os.environ["GEZIN_TEKSTEN"], "r", encoding="utf-8") as f:
            teksten = json.load(f)
        for k in ("signaal_zin", "soorten", "deurbel_titel", "deurbel_tekst", "deurbel_test_tekst", "wat_nu", "gedrag", "gedrag_zin"):
            if k not in teksten:
                raise ConfigFout(f"teksten mist '{k}'")
        opslag = Opslag(os.environ["GEZIN_DB"])
    except (KeyError, ConfigFout, OSError, ValueError) as e:
        LOG.error(json.dumps({"event": "start", "fout": f"{type(e).__name__}: {e}"}))
        return 2
    topics = {"live": os.environ.get("GEZIN_NTFY_TOPIC", ""), "test": os.environ.get("GEZIN_NTFY_TOPIC_TEST", "")}
    if topics["live"] and topics["live"] == topics["test"]:
        LOG.error(json.dumps({"event": "start", "fout": "live- en testtopic zijn gelijk"}))
        return 2
    if any(o["modus"] == "live" for o in cfg["onderwerpen"].values()) and not topics["live"]:
        LOG.error(json.dumps({"event": "start", "fout": "live-onderwerp zonder GEZIN_NTFY_TOPIC"}))
        return 2
    dienst = Dienst(cfg, opslag, teksten, topics={k: v for k, v in topics.items() if v})
    stop = threading.Event()
    threading.Thread(target=achtergrond, args=(dienst, stop), daemon=True).start()
    poort = int(os.environ.get("GEZIN_POORT", "8080"))
    srv = ThreadingHTTPServer((os.environ.get("GEZIN_ADRES", "0.0.0.0"), poort), maak_handler(dienst))
    LOG.info(json.dumps({"event": "start", "poort": poort}))
    try:
        srv.serve_forever()
    finally:
        stop.set()
    return 0


if __name__ == "__main__":
    sys.exit(main())
