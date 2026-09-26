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
import html.parser
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROXY = os.environ["EGRESS_PROXY"]
MAX_URL = int(os.environ.get("MAX_URL_CHARS", "512"))       # caps data smuggling in URLs
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(2 * 1024 * 1024)))
MAX_CHARS = int(os.environ.get("MAX_CHARS", "60000"))
RATE_PER_MIN = int(os.environ.get("RATE_PER_MIN", "30"))
TIMEOUT = float(os.environ.get("FETCH_TIMEOUT", "20"))
UA = "Mozilla/5.0 (compatible; family-ai-fetch/1.0)"

opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
_lock = threading.Lock()
_window = []


def rate_ok() -> bool:
    now = time.time()
    with _lock:
        while _window and now - _window[0] > 60:
            _window.pop(0)
        if len(_window) >= RATE_PER_MIN:
            return False
        _window.append(now)
        return True


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


def fetch(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,text/plain;q=0.9,*/*;q=0.1"})
    try:
        r = opener.open(req, timeout=TIMEOUT)
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


class H(BaseHTTPRequestHandler):
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

    def do_POST(self):
        if self.path not in ("/v2/scrape", "/v1/scrape"):
            return self._send(404, {"success": False, "error": "not found"})
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 65536)) or b"{}")
            url = str(body.get("url", ""))
        except Exception:
            return self._send(400, {"success": False, "error": "bad request"})
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https") or not u.hostname or len(url) > MAX_URL or u.username or u.password:
            print(json.dumps({"event": "scrape", "status": "rejected"}), flush=True)
            return self._send(400, {"success": False, "error": f"only plain http(s) URLs up to {MAX_URL} chars"})
        if not rate_ok():
            print(json.dumps({"event": "scrape", "status": 429}), flush=True)
            return self._send(429, {"success": False, "error": "rate limit"})
        try:
            code, final, title, text = fetch(url)
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
