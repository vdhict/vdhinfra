"""family-ai hermes log scrub (chg-2026-09-26-001, Mack addendum 3 point 5d).

Loaded by Python via PYTHONPATH=/opt/family-ai-py (as sitecustomize.py) in the hermes app
container. Hermes' web providers log search queries and full request URLs: the SearXNG
provider at INFO ("SearXNG search '<query>'"), and on any HTTP error at WARNING with the
exception text, which carries the full URL incl. ?q=<query>. WARNING reaches stdout -> Loki;
INFO reaches logs/agent.log on the PVC (backed up). Here, without touching the bundle:
  * the web-provider loggers and tools.web_tools are raised to WARNING (the INFO query
    lines are never emitted);
  * agent.turn_context is raised to WARNING (L12l): its INFO "conversation turn ..." line
    carries the first 80 characters of every user message (agent/turn_context.py:1052,
    hermes-agent v2026.9.24) into logs/agent.log. agent/turn_context_compaction.py:23
    logs under the same logger name, so its INFO lines (idle/preflight compression
    decisions: token counts, thresholds, session id; no user text) are suppressed too.
    WARNING lines from both files still reach the log;
  * tools.web_result_cache is raised to WARNING (L12l): on a cache hit it logs the search
    query (tools/web_result_cache.py:103, %r) and the extracted URL (:277) at INFO.
    The other INFO loggers were surveyed on all three profiles (agent.conversation_loop:
    model/token/latency counters; hermes_cli.model_catalog: fetch failures) and carry
    no user text;
  * a quoted value after query:/q: (any level, e.g. plugins/web/ddgs/provider.py:200
    "... for query: %r" at WARNING - ddgs is not an active backend here) becomes
    '[redacted]' (L12l, land-12f residual);
  * every log record, any logger/level: URLs are cut to scheme://host/[redacted] and
    q=/query=/search= values become [redacted]; exception tracebacks are reduced to the
    exception class name (httpx puts the URL into the exception text).
Shadows Debian's /usr/lib/python3.13/sitecustomize.py, whose only job (apport hook) is
chained below.
"""
import logging
import re

_URL = re.compile(r"""(?i)\b((?:https?|wss?)://[^/\s'"<>?#]+)[^\s'"<>]*""")
_QS = re.compile(r"""(?i)\b(q|query|search|srsearch|text|wd|p)=(?!['"])[^&\s'"<>]*""")
# a quoted bare value after query: / q: / query= (L12l): "for query: 'x'" -> "for query: '[redacted]'"
_QQ = re.compile(r"""(?i)\b(query|q)(\s*[:=]\s*)(['"])[^'"\n]*\3""")
_orig_factory = logging.getLogRecordFactory()


def _redact(text: str) -> str:
    text = _QQ.sub(r"\1\2\3[redacted]\3", _URL.sub(r"\1/[redacted]", text))
    return _QS.sub(r"\1=[redacted]", text)


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
# tools.web_tools logs "Web search via <backend>: '<query>'" at INFO (land-12e finding);
# agent.turn_context logs "conversation turn ... <user message preview>" at INFO (L12l);
# tools.web_result_cache logs "web_search cache hit: <query>" at INFO (L12l)
for _name in ("plugins.web.searxng.provider", "plugins.web.firecrawl.provider", "plugins.web._common",
              "tools.web_tools", "agent.turn_context", "tools.web_result_cache"):
    logging.getLogger(_name).setLevel(logging.WARNING)

try:  # Debian's sitecustomize, which this file shadows
    import apport_python_hook  # type: ignore
except ImportError:
    pass
else:
    apport_python_hook.install()
