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
