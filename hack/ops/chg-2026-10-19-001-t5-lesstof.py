#!/usr/bin/env python3
"""chg-2026-10-19-001 done criterion: one textbook question per boy through his OWN Hermes gateway (in-pod :8642,
local Studio model, his own KENNIS_TOKEN via the lesstof plugin). Runs on the Mini only.
   python3 -I hack/ops/chg-2026-10-19-001-t5-lesstof.py <n: 2|3> <topic: w21|ak2> <lesstof-pakket.tar.gz>
The reply, the hook context and the package text stay in this process's memory; ONLY counts/booleans are printed
(never the reply, the book text or homework). Afterwards the test session is deleted and the store counts are checked
to equal the counts before.
Measures:
  hook_direct  : the live plugin in the pod, own token -> context chars, fragments, header, distinctive-term hits
  turn         : HTTP status, seconds, reply chars
  lesstof_terms: distinctive terms of the target file (words >= 7 letters in the target file, in <= 2 of the other 23
                 package files, not in the question) found in the reply / total
  cites        : reply names a page number that occurs in the target file headings; reply names the section
  cross_boy    : unique words of the OTHER boy's current homework (not in own homework, not in the package) found
                 in the reply -> must be 0
"""
import json, re, subprocess, sys, tarfile
from pathlib import Path

N, TOPIC, TGZ = sys.argv[1], sys.argv[2], sys.argv[3]
assert N in ('2', '3') and TOPIC in ('w21', 'ak2')
OTHER = {'2': '3', '3': '2'}[N]
TARGET = {'w21': 'wiskunde-1.md', 'ak2': 'aardrijkskunde-2.md'}[TOPIC]
QUESTION = {'w21': 'Wat is het binnengebied van een cirkel? Leg het uit zoals in mijn wiskundeboek, paragraaf 2.1.',
            'ak2': 'Geef me oefenvragen over bewegende platen, aardrijkskunde hoofdstuk 2 paragraaf 2.'}[TOPIC]
SECTION = {'w21': r'\b2\.1\b', 'ak2': r'§\s*2\b|paragraaf 2\b'}[TOPIC]
PRIVE = Path.home() / 'family-ai-prive'

COUNTS = r'''
import os, sqlite3, json
c = sqlite3.connect("file:/opt/data/state.db?mode=ro", uri=True)
r = sqlite3.connect("file:/opt/data/response_store.db?mode=ro", uri=True)
print(json.dumps({"sessions": c.execute("select count(*) from sessions").fetchone()[0],
                  "messages": c.execute("select count(*) from messages").fetchone()[0],
                  "responses": r.execute("select count(*) from responses").fetchone()[0],
                  "conversations": r.execute("select count(*) from conversations").fetchone()[0],
                  "memory_files": sum(len(f) for _, _, f in os.walk("/opt/data/memories")),
                  "ids": [x[0] for x in c.execute("select id from sessions")]}))
'''
HOOK = r'''
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("lesstof", "/opt/data/plugins/lesstof/__init__.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
inst = json.load(open("/opt/data/plugins/lesstof/instellingen.json"))
v = m.Vooraf(os.environ["KENNIS_URL"], os.environ["KENNIS_TOKEN"], inst["collectie"])
r = v(user_message=sys.argv[1])
print(json.dumps({"collectie": inst["collectie"], "context": (r or {}).get("context", "")}))
'''
TURN = r'''
import os, json, sys, time, urllib.request
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
body = {"model": "hermes-agent-profiel-%s", "messages": [{"role": "user", "content": sys.argv[1]}], "stream": False}
req = urllib.request.Request("http://127.0.0.1:8642/v1/chat/completions", method="POST", data=json.dumps(body).encode(),
      headers={"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["API_SERVER_KEY"]})
t = time.time()
with op.open(req, timeout=300) as resp:
    d = json.load(resp)
    print(json.dumps({"status": resp.status, "secs": round(time.time() - t, 1), "text": d["choices"][0]["message"]["content"]}))
''' % N


def kexec(code, *args, timeout=360):
    return subprocess.run(['kubectl', '-n', 'family-ai', 'exec', f'deploy/hermes-profiel-{N}', '-c', 'app', '--',
                           'python3', '-c', code, *args], capture_output=True, text=True, timeout=timeout)


def words(text):
    return set(re.findall(r'[a-zà-ÿ]{7,}', text.lower()))


with tarfile.open(TGZ) as t:
    files = {m.name.split('/', 1)[1]: t.extractfile(m).read().decode('utf-8')
             for m in t.getmembers() if m.isfile() and m.name.startswith(f'lesstof-profiel-{N}/')}
target = files[TARGET]
others = [words(v) for k, v in files.items() if k != TARGET]
qwords = words(QUESTION)
distinct = {w for w in words(target) if sum(w in o for o in others) <= 2 and w not in qwords}
pages = set(re.findall(r'(?im)^##?.*?\bblz\.?\s*(\d+)', target)) | set(re.findall(r'(?im)^##?.*?\bblz\.?\s*\d+\s*[-–]\s*(\d+)', target))
pkg_words = set().union(*[words(v) for v in files.values()])


def hits(text):
    low = text.lower()
    return sum(1 for w in distinct if w in low)


def cites(text):
    named = set(re.findall(r'(?i)\b(?:blz\.?|bladzijde|pagina|p\.)\s*(\d+)', text))
    return len(named & pages), bool(re.search(SECTION, text, re.I))


def homework_words(n):
    pkg = PRIVE / (PRIVE / 'huiswerk-latest').read_text().splitlines()[0]
    return words((pkg / f'huiswerk-profiel-{n}' / 'huiswerk.md').read_text(encoding='utf-8'))


own_hw, oth_hw = homework_words(N), homework_words(OTHER)
foreign_only = oth_hw - own_hw - pkg_words

h = kexec(HOOK, QUESTION)
if h.returncode != 0:
    print(f'profiel-{N} {TOPIC}: hook_direct FAILED rc={h.returncode}')
    ok_hook = False
else:
    d = json.loads(h.stdout.strip().splitlines()[-1])
    ctx = d['context']
    ok_hook = d['collectie'] == f'lesstof-profiel-{N}' and hits(ctx) > 0
    print(f'profiel-{N} {TOPIC}: hook_direct collectie_own={d["collectie"] == f"lesstof-profiel-{N}"}, context chars '
          f'{len(ctx)}, header {ctx.startswith("LESSTOF UIT ZIJN EIGEN SCHOOLBOEK")}, fragments '
          f'{ctx.count(chr(10) + chr(10)) + 1 if ctx else 0}, lesstof_terms {hits(ctx)}/{len(distinct)}, '
          f'cross_boy {sum(1 for w in foreign_only if w in ctx.lower())}')

before = json.loads(kexec(COUNTS).stdout)
r = kexec(TURN, QUESTION)
reply, status = '', None
if r.returncode != 0:
    print(f'profiel-{N} {TOPIC}: turn FAILED rc={r.returncode} stderr_lines={len(r.stderr.splitlines())}')
else:
    out = json.loads(r.stdout.strip().splitlines()[-1])
    reply, status = out['text'], out['status']
    page_hits, section = cites(reply)
    cross = sum(1 for w in foreign_only if w in reply.lower())
    print(f'profiel-{N} {TOPIC}: HTTP {status}, {out["secs"]} s, reply chars {len(reply)}; lesstof_terms '
          f'{hits(reply)}/{len(distinct)}; cites page_of_target {page_hits} section {section}; cross_boy {cross}/{len(foreign_only)}')
mid = json.loads(kexec(COUNTS).stdout)
new_ids = [i for i in mid['ids'] if i not in before['ids']]
for i in new_ids:
    d = subprocess.run(['kubectl', '-n', 'family-ai', 'exec', f'deploy/hermes-profiel-{N}', '-c', 'app', '--', 'sh', '-c',
                        f'HERMES_HOME=/opt/data hermes sessions delete --yes "{i}" >/dev/null 2>&1 || '
                        f'HERMES_HOME=/opt/data hermes sessions delete "{i}" </dev/null >/dev/null 2>&1; echo $?'],
                       capture_output=True, text=True)
    print(f'profiel-{N} {TOPIC}: deleted test session rc={d.stdout.strip()}')
after = json.loads(kexec(COUNTS).stdout)
keys = ('sessions', 'messages', 'responses', 'conversations', 'memory_files')
restored = all(before[k] == after[k] for k in keys)
print(f'profiel-{N} {TOPIC}: store before {[before[k] for k in keys]} after {[after[k] for k in keys]}; restored={restored}')
passed = (ok_hook and status == 200 and hits(reply) > 0
          and sum(1 for w in foreign_only if w in reply.lower()) == 0)
print(f'profiel-{N} {TOPIC}: {"PASS" if passed else "FAIL"}')
sys.exit(0 if passed else 1)
