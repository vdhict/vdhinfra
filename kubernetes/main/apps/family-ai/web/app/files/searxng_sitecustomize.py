"""family-ai searxng log redaction (chg-2026-09-26-001, F-LOG).

Loaded automatically by Python (PYTHONPATH -> this file as sitecustomize.py) before
SearXNG starts. SearXNG logs failed engine requests as full URLs, which carry the search
query (q=...) - and stdout goes to Loki. Every log record is rewritten here, whatever its
logger or level: any URL is cut down to scheme://host/..., and exception tracebacks
(httpx errors embed the URL too) are replaced by the exception class name only.
land-12g: the Brave API key (read once from the rendered settings.yml) and any
X-Subscription-Token header value are redacted too.
"""
import logging
import re

_URL = re.compile(r"""(?i)\b((?:https?|wss?)://[^/\s'"<>?#]+)[^\s'"<>]*""")
_QS = re.compile(r"""(?i)\b(q|query|search|text|wd|p)=[^&\s'"<>]*""")
_TOKEN = re.compile(r"""(?i)(x-subscription-token['"]?\s*[:=,]\s*['"]?)[^\s'",}]+""")
_orig_factory = logging.getLogRecordFactory()


def _secrets() -> list:
    try:
        with open("/etc/searxng/settings.yml", encoding="utf-8") as f:
            vals = re.findall(r"""(?m)^\s*api_key:\s*['"]?([^'"\s]+)""", f.read())
        return [v for v in vals if len(v) >= 8]
    except OSError:
        return []


_SECRETS = _secrets()


def _redact(text: str) -> str:
    for secret in _SECRETS:
        text = text.replace(secret, "[redacted-key]")
    text = _TOKEN.sub(r"\1[redacted]", text)
    return _QS.sub(r"\1=[redacted]", _URL.sub(r"\1/[redacted]", text))


def _factory(*args, **kwargs):
    record = _orig_factory(*args, **kwargs)
    try:
        msg = record.getMessage()
    except Exception:  # never break logging
        msg = str(record.msg)
    if record.exc_info and record.exc_info[0] is not None:
        msg += f" [{record.exc_info[0].__name__}]"
    record.msg, record.args = _redact(msg), ()
    record.exc_info, record.exc_text, record.stack_info = None, None, None
    return record


logging.setLogRecordFactory(_factory)
# engine request failures are WARNING in searx.network / searx.engines: not needed at all
for _name in ("searx.network", "searx.engines", "searx.search", "httpx", "httpcore", "curl_cffi"):
    logging.getLogger(_name).setLevel(logging.ERROR)


# --- Brave API quota line (land-12h) ------------------------------------------
# ONE log line per Brave API call, e.g.
#   family-ai quota: braveapi ts=2026-09-27T08:00:00Z calls=3 status=200 remaining_month=1994
# remaining_month = the LAST value of Brave's own X-RateLimit-Remaining header
# ("<per-second>, <per-month>"), digits only. calls = count since pod start.
# No query, no URL, no key. Brave-side remaining is authoritative; count in
# Loki: {namespace="family-ai"} |= "family-ai quota: braveapi".
# Engines are loaded with load_module (no import hook possible), so this wraps
# OnlineProcessor._send_http_request right after that module is imported.
# Re-check on every searxng image bump (the method name/signature is internal).
import datetime as _dt
import importlib.abc as _iabc
import importlib.machinery as _imach
import sys as _sys
import threading as _th

_QUOTA_MODULE = "searx.search.processors.online"
_quota_log = logging.getLogger("family_ai.quota")
_quota_lock = _th.Lock()
_quota_calls = 0


def _quota_line(status: str, remaining: str) -> None:
    global _quota_calls
    with _quota_lock:
        _quota_calls += 1
        n = _quota_calls
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    _quota_log.warning("family-ai quota: braveapi ts=%s calls=%d status=%s remaining_month=%s", ts, n, status, remaining)


def _remaining(headers) -> str:
    try:
        raw = headers.get("X-RateLimit-Remaining") or ""
    except Exception:
        return "unknown"
    last = raw.split(",")[-1].strip()
    return last if last.isdigit() else "unknown"


def _patch_online(module) -> None:
    cls = getattr(module, "OnlineProcessor", None)
    orig = getattr(cls, "_send_http_request", None)
    if orig is None or getattr(orig, "_family_ai_quota", False):
        _quota_log.warning("family-ai quota: hook NOT installed (OnlineProcessor._send_http_request missing)")
        return

    def _send_http_request(self, params):
        if getattr(getattr(self, "engine", None), "name", None) != "braveapi":
            return orig(self, params)
        try:
            resp = orig(self, params)
        except Exception:
            _quota_line("error", "unknown")  # HTTP 4xx/5xx raise before returning
            raise
        _quota_line(str(getattr(resp, "status_code", "")), _remaining(getattr(resp, "headers", {})))
        return resp

    _send_http_request._family_ai_quota = True
    cls._send_http_request = _send_http_request


class _QuotaFinder(_iabc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname != _QUOTA_MODULE:
            return None
        spec = _imach.PathFinder.find_spec(fullname, path)
        if spec is None or spec.loader is None:
            return spec
        loader_exec = spec.loader.exec_module

        def exec_module(module):
            loader_exec(module)
            try:
                _patch_online(module)
            except Exception as exc:  # never break searxng
                _quota_log.warning("family-ai quota: hook failed [%s]", type(exc).__name__)

        spec.loader.exec_module = exec_module
        return spec


_sys.meta_path.insert(0, _QuotaFinder())
