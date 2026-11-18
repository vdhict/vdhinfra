# Patch copy for Atlas. The source of this file is the vdhinfra repo (kubernetes/main/apps/family-ai/web/app/files/web_extract.py).
"""web-extract: minimal page fetcher for the family-ai Hermes agents (chg-2026-09-26-001).

Hermes v2026.9.24 has NO local page fetcher: web_extract only talks to Firecrawl-style
back-ends (firecrawl/tavily/exa/parallel/keenable). This service implements the small part
of Firecrawl's scrape API that Hermes' firecrawl provider uses with FIRECRAWL_API_URL
(self-hosted): POST /v2/scrape (and /v1/scrape) {"url": ..., "formats": [...]} ->
{"success": true, "data": {"markdown": text, "metadata": {"title", "sourceURL", "statusCode"}}}.

Every fetch goes through the logging egress proxy (which denies all private/LAN/cluster
ranges); this pod has no other egress (CNP). Stdlib only. Logs counts and status codes,
never URLs or content (the proxy log holds the host).
"""
import base64
import hashlib
import html.parser
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# EGRESS_PROXY_BASE = "http://egress-proxy.family-ai.svc.cluster.local"; each profile has
# its own squid port (3131..3134) so the proxy log records WHICH profile fetched.
PROXY_BASE = os.environ["EGRESS_PROXY_BASE"].rstrip("/")
PROFILE_PORTS = {"profiel-1": 3131, "profiel-2": 3132, "profiel-3": 3133, "profiel-4": 3134}
MAX_URL = int(os.environ.get("MAX_URL_CHARS", "512"))       # caps data smuggling in URLs
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(2 * 1024 * 1024)))
MAX_CHARS = int(os.environ.get("MAX_CHARS", "60000"))
RATE_PER_MIN = int(os.environ.get("RATE_PER_MIN", "30"))
TIMEOUT = float(os.environ.get("FETCH_TIMEOUT", "20"))
UA = "Mozilla/5.0 (compatible; family-ai-fetch/1.0)"

OPENERS = {
    prof: urllib.request.build_opener(urllib.request.ProxyHandler(
        {"http": f"{PROXY_BASE}:{port}", "https": f"{PROXY_BASE}:{port}"}))
    for prof, port in PROFILE_PORTS.items()}
_lock = threading.Lock()
_windows = {prof: [] for prof in PROFILE_PORTS}


def rate_ok(prof: str) -> bool:
    """Per-profile budget, so one person cannot use up another's."""
    now = time.time()
    with _lock:
        w = _windows[prof]
        while w and now - w[0] > 60:
            w.pop(0)
        if len(w) >= RATE_PER_MIN:
            return False
        w.append(now)
        return True


def profile_of(headers) -> str:
    """Hermes' Firecrawl SDK sends FIRECRAWL_API_KEY as a bearer token; each hermes-profiel-N
    has FIRECRAWL_API_KEY=profiel-N. NOT a secret - it only selects the proxy port (log
    attribution). Unknown or missing -> refused (fail closed)."""
    auth = headers.get("Authorization") or ""
    tok = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
    return tok if tok in PROFILE_PORTS else ""


class Text(html.parser.HTMLParser):
    SKIP = {"script", "style", "noscript", "template", "svg", "iframe", "head", "nav", "footer", "form"}
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "pre"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.skip, self.title, self._in_title = [], 0, "", False

    def handle_starttag(self, tag, attrs):
        if tag == "title":
            self._in_title = True
        if tag in self.SKIP:
            self.skip += 1
        elif tag in self.BLOCK:
            self.out.append("\n")
        if tag in ("h1", "h2", "h3") and not self.skip:
            self.out.append("#" * int(tag[1]) + " ")

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag in self.SKIP and self.skip:
            self.skip -= 1
        elif tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        elif not self.skip:
            self.out.append(data)

    def text(self):
        t = re.sub(r"[ \t\r\f\v]+", " ", "".join(self.out))
        return re.sub(r"\n\s*\n+", "\n\n", t).strip()


def fetch(url: str, prof: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,text/plain;q=0.9,*/*;q=0.1"})
    try:
        r = OPENERS[prof].open(req, timeout=TIMEOUT)
        code, final = r.status, r.geturl()
    except urllib.error.HTTPError as e:
        r, code, final = e, e.code, url
    ctype = (r.headers.get("Content-Type") or "").lower()
    body = r.read(MAX_BYTES + 1)[:MAX_BYTES]
    charset = (re.search(r"charset=([\w-]+)", ctype) or [None, "utf-8"])[1]
    raw = body.decode(charset, errors="replace")
    if "html" in ctype or raw.lstrip()[:15].lower().startswith(("<!doctype", "<html")):
        p = Text(); p.feed(raw); text, title = p.text(), p.title.strip()
    elif ctype.startswith("text/") or "json" in ctype or "xml" in ctype:
        text, title = raw, ""
    else:
        text, title = "", ""
        code = 415 if code < 400 else code
    return code, final, title, text[:MAX_CHARS]


RAW_MAX = 25 * 1024 * 1024
RAW_TIMEOUT = 60
RAW_TYPES = {"application/pdf", "text/html", "text/plain"}
_raw_window = []
_raw_slot = threading.Semaphore(1)
RAW_STEP = 5   # a single socket operation never waits longer, so a worker ends within RAW_STEP s of the deadline


class RawHold:
    """The one /v2/raw slot is released only when every holder is done: the upstream worker (it really stopped) and
    the request handler (the response is written). Codex review 18 Nov, point 2."""
    def __init__(self, holders):
        self.left, self.lock = holders, threading.Lock()

    def release(self):
        with self.lock:
            self.left -= 1
            last = self.left == 0
        if last:
            _raw_slot.release()


class RawError(ValueError):
    def __init__(self, key, status=400):
        self.key, self.status = key, status


def check_raw_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        if (len(url) <= MAX_URL and parsed.scheme == "https" and parsed.hostname
                and parsed.username is None and parsed.password is None
                and not any(c.isspace() or ord(c) < 32 for c in url)):
            return
    except (TypeError, ValueError, AttributeError):
        pass
    raise RawError("url")


def raw_remaining(deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise RawError("tijd", 504)
    return left


def raw_step(deadline):
    return min(raw_remaining(deadline), RAW_STEP)


class RawRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_302(self, req, fp, code, msg, headers):
        # Close without draining the redirect body. It has no bearing on the next request.
        fp.close()
        location = headers.get("Location") or headers.get("URI")
        hops = getattr(req, "raw_hops", 0)
        if not location or hops >= 3:
            raise RawError("url")
        try:
            url = urllib.parse.urljoin(req.full_url, location)
        except ValueError:
            raise RawError("url") from None
        check_raw_url(url)
        redirect = self.redirect_request(req, fp, code, msg, headers, url)
        redirect.raw_hops = hops + 1
        redirect.raw_deadline = req.raw_deadline
        return self.parent.open(redirect, timeout=raw_step(redirect.raw_deadline))

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


class RawProxy(urllib.request.ProxyHandler):
    def proxy_open(self, req, proxy, type):
        # Always tunnel through the profile proxy, including hosts covered by NO_PROXY.
        req.set_proxy(urllib.parse.urlsplit(proxy).netloc, "http")
        return None


RAW_OPENER = urllib.request.build_opener(RawProxy(
    {"https": f"{PROXY_BASE}:{PROFILE_PORTS['profiel-1']}"}), RawRedirect())


def raw_rate_ok():
    now = time.monotonic()
    with _lock:
        while _raw_window and now - _raw_window[0] >= 60:
            _raw_window.pop(0)
        if len(_raw_window) >= 5:
            return False
        _raw_window.append(now)
        return True


def fetch_raw(url, hold=None):
    deadline = time.monotonic() + RAW_TIMEOUT

    def read():
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
        req.raw_deadline = deadline
        with RAW_OPENER.open(req, timeout=raw_step(deadline)) as response:
            end_url = response.geturl()
            check_raw_url(end_url)
            if response.status != 200:
                raise RawError("document", 502)
            kind = response.headers.get("Content-Type", "").partition(";")[0].strip().lower()
            if kind not in RAW_TYPES:
                raise RawError("type", 415)
            if int(response.headers.get("Content-Length", "0")) > RAW_MAX:
                raise RawError("grootte", 413)
            body = bytearray()
            while True:
                raw_remaining(deadline)
                chunk = response.read1(min(65536, RAW_MAX + 1 - len(body)))
                raw_remaining(deadline)
                if not chunk:
                    break
                body.extend(chunk)
                if len(body) > RAW_MAX:
                    raise RawError("grootte", 413)
            return {"content_type": kind, "eind_url": end_url, "sha256": hashlib.sha256(body).hexdigest(),
                    "data": base64.b64encode(body).decode("ascii"),
                    "opgehaald_op": datetime.now(timezone.utc).isoformat()}

    # urllib's socket timeout alone cannot bound DNS, redirect handling or slow headers.
    result = []

    def work():
        try:
            result.append(read())
        except RawError as exc:
            result.append(exc)
        except TimeoutError:
            result.append(RawError("tijd", 504))
        except urllib.error.URLError as exc:
            if isinstance(exc, urllib.error.HTTPError):
                exc.close()
            result.append(RawError("tijd", 504) if isinstance(exc.reason, TimeoutError)
                          else RawError("document", 502))
        except Exception:
            result.append(RawError("document", 502))
        finally:
            if hold:
                hold.release()

    worker = threading.Thread(target=work, daemon=True)
    try:
        worker.start()
    except BaseException:
        if hold:
            hold.release()
        raise
    worker.join(max(0, deadline - time.monotonic()))
    if not result:
        raise RawError("tijd", 504)
    if isinstance(result[0], RawError):
        raise result[0]
    return result[0]


class H(BaseHTTPRequestHandler):
    timeout = 30  # socket timeout per request: a client that stalls mid-upload frees its slot
    def log_message(self, *a):  # no URLs in logs
        pass

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True})
        return self._send(404, {"success": False, "error": "not found"})

    def _raw(self):
        def send(status, obj):
            print(json.dumps({"event": "raw", "status": status}), flush=True)
            return self._send(status, obj)

        try:
            prof = profile_of(self.headers)
            if not prof:
                raise RawError("document", 401)
            if prof != "profiel-1":
                raise RawError("document", 403)
            if self.headers.get("Authorization") != "Bearer profiel-1":
                raise RawError("document", 401)
            try:
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length <= 65536:
                    raise ValueError()
                url = json.loads(self.rfile.read(length))["url"]
            except (ValueError, KeyError, TypeError):
                raise RawError("url") from None
            check_raw_url(url)
            # C3: one /v2/raw at a time. One 25 MiB answer peaks at ~155 MiB against a 256Mi limit. The slot is
            # held until the response is written and the upstream worker has stopped; the rate limit is charged
            # only to a request that got the slot.
            if not _raw_slot.acquire(blocking=False):
                raise RawError("document", 429)
            hold = RawHold(2)
            try:
                if not raw_rate_ok():
                    hold.release()   # the worker never starts
                    hold.release()
                    hold = None
                    raise RawError("document", 429)
                try:
                    data = fetch_raw(url, hold)
                except RawError as exc:
                    return send(exc.status, {"success": False, "error": exc.key})
                return send(200, {"success": True, "data": data})
            finally:
                if hold:
                    hold.release()
        except RawError as exc:
            return send(exc.status, {"success": False, "error": exc.key})

    def do_POST(self):
        if self.path == "/v2/raw":
            return self._raw()
        if self.path not in ("/v2/scrape", "/v1/scrape"):
            return self._send(404, {"success": False, "error": "not found"})
        prof = profile_of(self.headers)
        if not prof:
            print(json.dumps({"event": "scrape", "status": 401}), flush=True)
            return self._send(401, {"success": False, "error": "unknown caller"})
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 65536)) or b"{}")
            url = str(body.get("url", ""))
        except Exception:
            return self._send(400, {"success": False, "error": "bad request"})
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https") or not u.hostname or len(url) > MAX_URL or u.username or u.password:
            print(json.dumps({"event": "scrape", "status": "rejected"}), flush=True)
            return self._send(400, {"success": False, "error": f"only plain http(s) URLs up to {MAX_URL} chars"})
        if not rate_ok(prof):
            print(json.dumps({"event": "scrape", "status": 429}), flush=True)
            return self._send(429, {"success": False, "error": "rate limit"})
        try:
            code, final, title, text = fetch(url, prof)
        except Exception as e:  # proxy denial (403) and network errors land here
            print(json.dumps({"event": "scrape", "status": "error", "kind": type(e).__name__}), flush=True)
            return self._send(502, {"success": False, "error": "fetch failed or blocked by policy"})
        print(json.dumps({"event": "scrape", "status": code, "chars": len(text)}), flush=True)
        if code >= 400:
            return self._send(502, {"success": False, "error": f"upstream status {code}"})
        return self._send(200, {"success": True, "data": {"markdown": text,
                                "metadata": {"title": title, "sourceURL": final, "statusCode": code}}})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), H).serve_forever()
