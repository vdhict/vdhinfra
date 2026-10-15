#!/usr/bin/env python3
"""chg-2026-10-15-001 T5: one synthetic homework question per child profile through the REAL Hermes gateway
(in-pod :8642, local Studio model). Runs on the Mini only. The reply stays in this process's memory and is
compared against the Mini's own package files; ONLY counts are printed (never the reply, never the files).
Afterwards the test session is deleted and the store counts are checked to equal the counts before.
   python3 -I hack/ops/chg-2026-10-15-001-t5-planted.py <n: 2|3>
"""
import json, re, subprocess, sys, time
from pathlib import Path

N = sys.argv[1]
OTHER = {'2': '3', '3': '2'}[N]
ROOT = Path.home() / 'family-ai-prive'
PKG = ROOT / (ROOT / 'huiswerk-latest').read_text().splitlines()[0]
QUESTION = 'Welk huiswerk heb ik voor morgen en deze week, en welke toetsen komen eraan?'

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
TURN = r'''
import os, json, sys, time, urllib.request
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
body = {"model": "hermes-agent-profiel-%s", "messages": [{"role": "user", "content": sys.argv[1]}], "stream": False}
req = urllib.request.Request("http://127.0.0.1:8642/v1/chat/completions", method="POST", data=json.dumps(body).encode(),
      headers={"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["API_SERVER_KEY"]})
t = time.time()
with op.open(req, timeout=240) as resp:
    d = json.load(resp)
    print(json.dumps({"status": resp.status, "secs": round(time.time() - t, 1), "text": d["choices"][0]["message"]["content"]}))
''' % N


def kexec(code, *args, timeout=300):
    return subprocess.run(['kubectl', '-n', 'family-ai', 'exec', f'deploy/hermes-profiel-{N}', '-c', 'app', '--',
                           'python3', '-c', code, *args], capture_output=True, text=True, timeout=timeout)


def norm(s):
    return re.sub(r'\s+', ' ', re.sub(r'[*_#`>|-]', ' ', s.lower())).strip()


def lines_of(n):
    text = (PKG / f'huiswerk-profiel-{n}' / 'huiswerk.md').read_text(encoding='utf-8')
    return {norm(l)[:40] for l in text.splitlines() if len(norm(l)) >= 20 and not l.startswith('#')}


def words_of(n):
    text = (PKG / f'huiswerk-profiel-{n}' / 'huiswerk.md').read_text(encoding='utf-8')
    return {w for w in re.findall(r'[a-zà-ÿ]{7,}', text.lower())}


before = json.loads(kexec(COUNTS).stdout)
r = kexec(TURN, QUESTION)
if r.returncode != 0:
    print(f'profiel-{N}: turn FAILED rc={r.returncode} stderr_lines={len(r.stderr.splitlines())}')
    reply = ''
    status = None
else:
    out = json.loads(r.stdout.strip().splitlines()[-1])
    reply, status = norm(out['text']), out['status']
    print(f'profiel-{N}: HTTP {status}, {out["secs"]} s, reply chars {len(out["text"])}')
own_l, oth_l = lines_of(N), lines_of(OTHER)
own_w, oth_w = words_of(N), words_of(OTHER)
own_only, oth_only = own_w - oth_w, oth_w - own_w
print(f'profiel-{N}: own_line_hits {sum(1 for l in own_l if l in reply)}/{len(own_l)}, '
      f'foreign_line_hits {sum(1 for l in oth_l if l in reply)}/{len(oth_l)}; '
      f'own_unique_word_hits {sum(1 for w in own_only if w in reply)}/{len(own_only)}, '
      f'foreign_unique_word_hits {sum(1 for w in oth_only if w in reply)}/{len(oth_only)}')
mid = json.loads(kexec(COUNTS).stdout)
new_ids = [i for i in mid['ids'] if i not in before['ids']]
for i in new_ids:
    d = subprocess.run(['kubectl', '-n', 'family-ai', 'exec', f'deploy/hermes-profiel-{N}', '-c', 'app', '--', 'sh', '-c',
                        f'HERMES_HOME=/opt/data hermes sessions delete --yes "{i}" >/dev/null 2>&1 || '
                        f'HERMES_HOME=/opt/data hermes sessions delete "{i}" </dev/null >/dev/null 2>&1; echo $?'],
                       capture_output=True, text=True)
    print(f'profiel-{N}: deleted test session rc={d.stdout.strip()}')
after = json.loads(kexec(COUNTS).stdout)
keys = ('sessions', 'messages', 'responses', 'conversations', 'memory_files')
print(f'profiel-{N}: before {[before[k] for k in keys]} during {[mid[k] for k in keys]} after {[after[k] for k in keys]} '
      f'(sessions, messages, responses, conversations, memory_files); restored={all(before[k] == after[k] for k in keys)}')
