"""family-ai hermes log scrub (chg-2026-09-26-001, Mack addendum 3 point 5d).

Loaded by Python via PYTHONPATH=/opt/family-ai-py (as sitecustomize.py) in the hermes app
container. Hermes' web providers log search queries and full request URLs: the SearXNG
provider at INFO ("SearXNG search '<query>'"), and on any HTTP error at WARNING with the
exception text, which carries the full URL incl. ?q=<query>. WARNING reaches stdout -> Loki;
INFO reaches logs/agent.log on the PVC (backed up). Here, without touching the bundle:
  * the web-provider loggers are raised to WARNING (the INFO query lines are never emitted);
  * every log record, any logger/level: URLs are cut to scheme://host/[redacted] and
    q=/query=/search= values become [redacted]; exception tracebacks are reduced to the
    exception class name (httpx puts the URL into the exception text).
Shadows Debian's /usr/lib/python3.13/sitecustomize.py, whose only job (apport hook) is
chained below.
"""
import logging
import re

_URL = re.compile(r"""(?i)\b((?:https?|wss?)://[^/\s'"<>?#]+)[^\s'"<>]*""")
_QS = re.compile(r"""(?i)\b(q|query|search|srsearch|text|wd|p)=[^&\s'"<>]*""")
_orig_factory = logging.getLogRecordFactory()


def _redact(text: str) -> str:
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
for _name in ("plugins.web.searxng.provider", "plugins.web.firecrawl.provider", "plugins.web._common"):
    logging.getLogger(_name).setLevel(logging.WARNING)

try:  # Debian's sitecustomize, which this file shadows
    import apport_python_hook  # type: ignore
except ImportError:
    pass
else:
    apport_python_hook.install()
