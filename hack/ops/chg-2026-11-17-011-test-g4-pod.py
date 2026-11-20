#!/usr/bin/env python3
"""Local test of hack/ops/chg-2026-11-17-011-g4-pod.py on a SYNTHETIC ledger dir with the real signal plugin CODE
(family-ai-cluster blob c95b02dc = 99fb4183) and synthetic settings. Proves G4 3a/3e mechanics without the cluster:
trip writes the shared off state (current month, billing 402 billing_error, person null) + one 'off' transition with no
person field; a second trip refuses; swap-prev archives the real off file by link and leaves a previous-month off file
(never an absent state, no delete); the pin guard refuses a non-pin module. Writes only under a fresh mkdtemp.
  python3 -I hack/ops/chg-2026-11-17-011-test-g4-pod.py  -> "G4POD TESTS n/n passed", rc 0
"""
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, 'chg-2026-11-17-011-g4-pod.py')
FAC = os.environ.get('FAMILY_AI_CLUSTER', os.path.expanduser('~/Code/pka-wires/family-ai-cluster'))
RES = []


def blob(sha):
    return subprocess.run(['git', '-C', FAC, 'cat-file', 'blob', sha], check=True, capture_output=True).stdout


def setup(init):
    root = tempfile.mkdtemp(prefix='g4pod-test-')
    plug, led = os.path.join(root, 'plugin'), os.path.join(root, 'cloud-spend')
    os.makedirs(plug); os.makedirs(led)
    open(os.path.join(plug, '__init__.py'), 'wb').write(init)
    open(os.path.join(plug, 'settings.json'), 'w').write(json.dumps({'budget_usd': 99, 'price_confirmed': True, 'workspace_id': 'wrkspc_SYNTHETIC0'}))
    month = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m')
    open(os.path.join(led, 'month.json'), 'w').write(json.dumps({'month': month, 'usd': 0.5, 'input_tokens': 0, 'output_tokens': 0,
        'cache_read_tokens': 0, 'cache_write_tokens': 0, 'person_usd': {'profiel-1': 0, 'profiel-2': 0.1, 'profiel-3': 0.4}}))
    env = {'PATH': '/usr/bin:/bin', 'G4_PLUGIN_DIR': plug, 'CLOUD_SPEND_PATH': os.path.join(led, 'month.json'),
           'FAMILY_CLOUD_ROUTE_FILE': os.path.join(root, 'route.jsonl'), 'HOME': root}
    return root, led, env, month


def run(env, *args):
    p = subprocess.run([sys.executable, '-I', '-', *args], stdin=open(HELPER), capture_output=True, text=True, env=env, cwd=env['HOME'])
    out = (p.stdout.strip() or p.stderr.strip()).splitlines()
    try:
        return json.loads(out[-1]), p.returncode
    except Exception:
        return {'raw': out[-1:] if out else []}, p.returncode


def ok(name, cond):
    RES.append(bool(cond)); print(('PASS ' if cond else 'FAIL ') + name)


def main():
    signal, presig = blob('c95b02dc273ae4559c6e55c8e757f6e67ebd8710'), blob('af43b7c1d3433784a92c48a52de2bae6b83313e6')
    root, led, env, month = setup(signal)
    first = dt.datetime.now(dt.timezone.utc).replace(day=1); prev = (first - dt.timedelta(days=1)).strftime('%Y-%m')
    s, rc = run(env, 'state'); ok('state before: not off, ledger numbers read', rc == 0 and s['off'] is False and s['usd'] == 0.5 and s['p3_usd'] == 0.4)
    s, rc = run(env, 'import'); ok('import ok with the pin module', rc == 0 and s.get('import') == 'ok' and 'trip_cloud_off' in s['has'])
    s, rc = run(env, 'trip'); ok('3a trip -> tripped true', rc == 0 and s == {'tripped': True})
    s, rc = run(env, 'state')
    ok('3a off state: current month, billing 402 billing_error, person not set',
       [s['off'], s['off_month'], s['off_kind'], s['off_status'], s['off_type'], s['off_person_set']] == [True, month, 'billing', 402, 'billing_error', False])
    raw = open(os.path.join(led, 'cloud-transitions.jsonl')).read()
    ok('3a one off transition line, no "person" in it', raw.count('\n') == 1 and 'person' not in raw and '"to":"off"' in raw)
    s, rc = run(env, 'seen'); ok('seen -> off_seen true', s == {'off_seen': True})
    s, rc = run(env, 'trip'); ok('second trip refuses (off already present)', rc != 0 and 'already present' in json.dumps(s))
    s, rc = run(env, 'swap-prev', '20261121T083000Z'); ok('3e swap-prev -> archived + previous month', rc == 0 and s.get('swapped') is True and s.get('synthetic_month') == prev)
    s, rc = run(env, 'state')
    ok('3e state: off with the previous month; archive present; the real off file kept (link, no delete)',
       s['off'] is True and s['off_month'] == prev and 'cloud-off.cleared-g4-20261121T083000Z.json' in s['off_files']
       and json.load(open(os.path.join(led, 'cloud-off.cleared-g4-20261121T083000Z.json')))['month'] == month)
    s, rc = run(env, 'swap-prev', '20261121T083000Z'); ok('swap-prev refuses to overwrite an archive', rc != 0)
    s, rc = run(env, 'swap-prev', '../x'); ok('swap-prev refuses a non-stamp tag', rc != 0)
    s, rc = run(env, 'transitions', '0'); ok('transitions: [[off, billing]] only (swap writes none)', s == {'transitions': [['off', 'billing']]})
    open(env['FAMILY_CLOUD_ROUTE_FILE'], 'w').write('{"ts": 10, "route": "studio", "rule": "cloud_off", "id_class": "none"}\n{"ts": 99, "route": "cloud", "rule": "cloud_ok", "id_class": "msg_"}\n')
    s, rc = run(env, 'routes', '5', '20'); ok('routes window -> [[studio, cloud_off]] only', s == {'routes': [['studio', 'cloud_off']]})
    r2, l2, e2, _ = setup(presig)
    s, rc = run(e2, 'trip'); ok('pin guard: pre-signal module -> trip refused, nothing written', rc != 0 and 'not the pin' in json.dumps(s) and not os.path.exists(os.path.join(l2, 'cloud-off.json')))
    s, rc = run(e2, 'import'); ok('pin guard: import refused', rc != 0)
    n, good = len(RES), sum(RES)
    print('G4POD TESTS %d/%d passed' % (good, n))
    return 0 if good == n else 1


if __name__ == '__main__':
    sys.exit(main())
