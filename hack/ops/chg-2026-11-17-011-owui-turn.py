# chg-2026-11-17-011 synthetic turn on profiel-3, run INSIDE the open-webui pod from stdin:
#   kubectl exec -i <owui pod> -c app -- sh -c 'cd /app/backend && python3 - <tag>' < hack/ops/chg-2026-11-17-011-owui-turn.py
# Same mechanics as the reviewed land-3 canary (hack/ops/chg-2026-10-20-010-canary-probe.py): a temporary local account
# g4-canary-<rand>@acceptatie.invalid in group owui-profiel-3, ONE public synthetic question, the account deleted at the
# end (also on failure). Prints only HTTP code, answer LENGTH, seconds, TURNSTART/TURNEND epochs and RESULT. The answer
# is never printed or stored. No family content: the question is fixed and public.
import json, os, secrets, sys, time, urllib.error, urllib.request

TAG = sys.argv[1] if len(sys.argv) > 1 else 'turn'
GROUP, MODEL = 'owui-profiel-3', 'hermes-agent-profiel-3'
QUESTION = 'Hoeveel poten heeft een spin? Antwoord kort.'
U = 'http://127.0.0.1:8080'
fails = []


def ok(c, m):
    print(('PASS ' if c else 'FAIL ') + m, flush=True)
    if not c:
        fails.append(m)


def req(method, path, body=None, tok=None, timeout=300):
    h = {'Content-Type': 'application/json'} if body is not None else {}
    if tok:
        h['Authorization'] = 'Bearer ' + tok
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(urllib.request.Request(U + path, method=method, headers=h, data=data), timeout=timeout) as x:
        b = x.read()
        try:
            return json.loads(b or b'null')
        except ValueError:
            return None


admin = req('POST', '/api/v1/auths/signin', {'email': os.environ['WEBUI_ADMIN_EMAIL'], 'password': os.environ['WEBUI_ADMIN_PASSWORD']})['token']
email = f'g4-canary-{secrets.token_hex(4)}@acceptatie.invalid'
uid = None
try:
    pw = secrets.token_urlsafe(24)
    uid = req('POST', '/api/v1/auths/add', {'name': 'G4 canary', 'email': email, 'password': pw, 'role': 'user'}, admin)['id']
    gid = [g['id'] for g in req('GET', '/api/v1/groups/', tok=admin) if g['name'] == GROUP][0]
    req('POST', f'/api/v1/groups/id/{gid}/users/add', {'user_ids': [uid]}, admin)
    tok = req('POST', '/api/v1/auths/signin', {'email': email, 'password': pw})['token']
    pw = None
    print('TURNSTART', round(time.time(), 3), flush=True)
    t = time.time()
    try:
        r = req('POST', '/api/chat/completions', {'model': MODEL, 'stream': False,
                                                  'messages': [{'role': 'user', 'content': QUESTION}]}, tok, timeout=300)
        n = len(((r.get('choices') or [{}])[0].get('message') or {}).get('content') or '')
        code = 200
    except urllib.error.HTTPError as e:
        code, n = e.code, 0
    r = None
    print('TURNEND', round(time.time(), 3), flush=True)
    ok(code == 200 and n > 0, f'{TAG}: turn http={code} chars={n} secs={time.time() - t:.1f}')
except Exception as e:
    ok(False, 'run aborted: ' + type(e).__name__ + (f' {e.code}' if isinstance(e, urllib.error.HTTPError) else ''))
finally:
    if uid:
        try:
            req('DELETE', f'/api/v1/users/{uid}', tok=admin)
        except Exception:
            pass
    left = [x for x in (req('GET', '/api/v1/users/all', tok=admin) or {}).get('users', []) if x.get('email') == email]
    ok(not left, 'synthetic account deleted')
print('RESULT', 'GREEN' if not fails else 'RED')
sys.exit(1 if fails else 0)
