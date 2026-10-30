"""chg-2026-10-20-010 W2c C1/C2 pre-check (Atlas 30-10, option 2): run IN the profiel-1 pod (stdin to its python), on
the LIVE webeerlijk + kennis plugin files, whether a question gets a pre-search context (then the turn stays on the
Studio by design) or not (then it may reach the cloud).
  argv: <none|web>=<question> ...   e.g.  none=Geef me een recept voor pannenkoeken.  web=Wat is het weer morgen in Rotterdam?
  none: webeerlijk injects nothing (no crisis, besluit None, no ZOEK_WEB) AND kennis injects nothing (3 runs, the
        live index via kennisdienst, read-only search)
  web:  webeerlijk would pre-search (besluit not None, or ZOEK_WEB without GEEN_WEB) -> a context on that turn
Prints one line per question (decision + context sizes only, never the context) and "ROUTES OK" iff every
expectation holds. Synthetic questions only."""
import importlib.util
import sys


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


w = load("w2c_webeerlijk", "/opt/data/plugins/webeerlijk/__init__.py")
k = load("w2c_kennis", "/opt/data/plugins/kennis/__init__.py")
hooks = {}


class Ctx:
    def register_hook(self, name, fn):
        hooks[name] = fn

    def __getattr__(self, n):
        return lambda *a, **kw: None


k.register(Ctx())
kh = hooks["pre_llm_call"]
ok = True
for arg in sys.argv[1:]:
    want, q = arg.split("=", 1)
    web = bool(w.is_crisis(q)) or w.besluit(q) is not None or (
        bool(w.ZOEK_WEB.search(q)) and not w.GEEN_WEB.search(q) and not w.URL_IN_VRAAG.search(q))
    kn = [len((kh(user_message=q, conversation_history=[{"role": "user", "content": q}], session_id="c010-routes-%d" % i,
                  turn_id="t") or {}).get("context") or "") for i in range(3)]
    if want == "none":
        good = not web and kn == [0, 0, 0]
    elif want == "web":
        good = web
    else:
        good = False
    ok = ok and good
    print("%s want=%s webeerlijk_presearch=%s kennis_ctx_chars=%s | %s" % ("ok " if good else "RED", want, web, kn, q))
print("ROUTES OK" if ok else "ROUTES RED")
sys.exit(0 if ok else 1)
