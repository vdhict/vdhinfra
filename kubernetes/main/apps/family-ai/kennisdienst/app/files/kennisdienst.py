#!/usr/bin/env python3
"""kennisdienst: read-only retrieval over citable Markdown collections (hybrid BM25 + multilingual embeddings,
reciprocal-rank fusion, multilingual cross-encoder rerank). Stdlib HTTP; no outbound network at all.

Collections: $KENNIS_DATA/<collectie>/*.md, one file per article/regulation. Each '## ' section is one unit whose
heading is the exact reference ("MLC 2006, Standard A2.3, paragraph 5"). A file without '## ' is one unit ('# ').
Adding a collection (e.g. the boys' study material) = a new directory + a token entry in KENNIS_TOEGANG.

Access: KENNIS_TOEGANG is JSON {"<ENV_NAME_OF_TOKEN>": ["collectie", ...]}; each token value comes from that env
var (a k8s Secret). A request needs "Authorization: Bearer <token>" and may only search that token's collections.

  POST /v1/zoek   {"collectie": "zeevaart", "vraag": "...", "k": 6}  ->  {"fragmenten": [{verwijzing, tekst, score}]}
  GET  /gezond    200 once all indexes are built (readiness/liveness), no auth, counts only.

Env: KENNIS_DATA, KENNIS_EMBED_MODEL, KENNIS_RERANK_MODEL (local dirs, read-only PVC), KENNIS_TOEGANG,
     KENNIS_ADRES (default 0.0.0.0), KENNIS_POORT (default 8088).
"""
from __future__ import annotations

import hmac
import json
import math
import os
import re
import sys
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

KANDIDATEN, RRF_K, MAX_K, MAX_TEKST, MAX_BODY = 30, 60, 10, 2400, 8192
WOORD = re.compile(r"\w+", re.UNICODE)


def tokens(t: str) -> list:
    return [w for w in WOORD.findall(t.lower()) if len(w) > 1]


class BM25:
    def __init__(self, docs: list, k1: float = 1.5, b: float = 0.75):
        self.k1, self.b = k1, b
        self.tf = [Counter(d) for d in docs]
        self.len = [len(d) for d in docs]
        self.avg = sum(self.len) / max(len(docs), 1)
        df = Counter(w for d in docs for w in set(d))
        n = len(docs)
        self.idf = {w: math.log(1 + (n - f + 0.5) / (f + 0.5)) for w, f in df.items()}

    def scores(self, q: list) -> list:
        out = []
        for tf, ln in zip(self.tf, self.len):
            s = 0.0
            for w in q:
                f = tf.get(w)
                if f:
                    s += self.idf[w] * f * (self.k1 + 1) / (f + self.k1 * (1 - self.b + self.b * ln / self.avg))
            out.append(s)
        return out


def lees_units(map_: Path) -> list:
    units = []
    for f in sorted(map_.glob("*.md")):
        tekst = f.read_text(encoding="utf-8")
        titel = tekst.split("\n", 1)[0].lstrip("# ").strip()
        delen = re.split(r"(?m)^## ", tekst)
        if len(delen) == 1:
            body = "\n".join(r for r in tekst.split("\n")[1:] if not r.startswith("Bron: ")).strip()
            units.append({"verwijzing": titel, "tekst": body, "titel": titel})
            continue
        for d in delen[1:]:
            kop, _, body = d.partition("\n")
            units.append({"verwijzing": kop.strip(), "tekst": body.strip(), "titel": titel})
    return units


class Collectie:
    def __init__(self, naam: str, map_: Path, embed, rerank):
        self.naam, self.embed, self.rerank = naam, embed, rerank
        self.units = lees_units(map_)
        if not self.units:
            raise SystemExit(f"collectie {naam}: geen units in {map_}")
        teksten = [self._index_tekst(u) for u in self.units]
        self.bm25 = BM25([tokens(t) for t in teksten])
        self.vec = embed.encode(teksten, batch_size=32, normalize_embeddings=True, convert_to_numpy=True)

    @staticmethod
    def _index_tekst(u: dict) -> str:
        kop = u["verwijzing"] if u["verwijzing"].startswith(u["titel"]) else u["titel"] + " — " + u["verwijzing"]
        return kop + "\n" + u["tekst"]

    def zoek(self, vraag: str, k: int) -> list:
        bm = self.bm25.scores(tokens(vraag))
        qv = self.embed.encode([vraag], normalize_embeddings=True, convert_to_numpy=True)[0]
        dense = (self.vec @ qv).tolist()
        rrf: dict = {}
        for lijst in (bm, dense):
            volgorde = sorted(range(len(lijst)), key=lambda i: -lijst[i])[:KANDIDATEN]
            for rang, i in enumerate(volgorde):
                if lijst is bm and bm[i] <= 0:
                    break
                rrf[i] = rrf.get(i, 0.0) + 1.0 / (RRF_K + rang + 1)
        kand = sorted(rrf, key=lambda i: -rrf[i])[:KANDIDATEN]
        paren = [(vraag, self._index_tekst(self.units[i])[:2000]) for i in kand]
        sc = self.rerank.predict(paren, batch_size=16).tolist() if paren else []
        beste = sorted(zip(kand, sc), key=lambda x: -x[1])[:k]
        return [{"verwijzing": self.units[i]["verwijzing"], "tekst": self.units[i]["tekst"][:MAX_TEKST],
                 "score": round(float(s), 3)} for i, s in beste]


class Dienst:
    def __init__(self):
        from sentence_transformers import CrossEncoder, SentenceTransformer
        data = Path(os.environ["KENNIS_DATA"])
        embed = SentenceTransformer(os.environ["KENNIS_EMBED_MODEL"], device="cpu")
        rerank = CrossEncoder(os.environ["KENNIS_RERANK_MODEL"], device="cpu", max_length=512)
        self.collecties = {d.name: Collectie(d.name, d, embed, rerank) for d in sorted(data.iterdir()) if d.is_dir()}
        self.toegang = []   # [(token bytes, set(collecties))]
        for env, cols in json.loads(os.environ.get("KENNIS_TOEGANG", "{}")).items():
            tok = os.environ.get(env, "")
            if len(tok) < 24:
                raise SystemExit(f"token {env} ontbreekt of is te kort")
            onbekend = set(cols) - set(self.collecties)
            if onbekend:
                raise SystemExit(f"token {env}: onbekende collecties {sorted(onbekend)}")
            self.toegang.append((tok.encode(), set(cols)))
        self.slot = threading.Lock()   # the models are not re-entrant-safe on CPU; queries are short

    def mag(self, kop: str) -> set:
        if not kop.startswith("Bearer "):
            return set()
        gegeven = kop[7:].strip().encode()
        mag: set = set()
        for tok, cols in self.toegang:
            if hmac.compare_digest(tok, gegeven):
                mag |= cols
        return mag


DIENST: Dienst | None = None


class H(BaseHTTPRequestHandler):
    server_version = "kennisdienst"

    def log_message(self, fmt, *a):   # no query text in logs: status line only
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {a[1] if len(a) > 1 else ''}\n")

    def _j(self, code: int, obj) -> None:
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/gezond":
            return self._j(200, {"ok": True, "collecties": {n: len(c.units) for n, c in DIENST.collecties.items()}})
        self._j(404, {"fout": "onbekend pad"})

    def do_POST(self):
        if self.path != "/v1/zoek":
            return self._j(404, {"fout": "onbekend pad"})
        mag = DIENST.mag(self.headers.get("Authorization", ""))
        if not mag:
            return self._j(401, {"fout": "geen toegang"})
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            return self._j(413, {"fout": "verzoek te groot of leeg"})
        try:
            body = json.loads(self.rfile.read(n))
            col, vraag = body["collectie"], str(body["vraag"]).strip()
            k = max(1, min(int(body.get("k", 6)), MAX_K))
        except (ValueError, KeyError, TypeError):
            return self._j(400, {"fout": "verwacht {collectie, vraag, k?}"})
        if col not in mag:
            return self._j(403, {"fout": "geen toegang tot deze collectie"})
        if not vraag or len(vraag) > 1000:
            return self._j(400, {"fout": "vraag leeg of te lang"})
        with DIENST.slot:
            fr = DIENST.collecties[col].zoek(vraag, k)
        self._j(200, {"collectie": col, "fragmenten": fr})


def main() -> None:
    global DIENST
    DIENST = Dienst()
    sys.stderr.write("klaar: " + json.dumps({n: len(c.units) for n, c in DIENST.collecties.items()}) + "\n")
    ThreadingHTTPServer((os.environ.get("KENNIS_ADRES", "0.0.0.0"), int(os.environ.get("KENNIS_POORT", "8088"))),
                        H).serve_forever()


if __name__ == "__main__":
    main()
