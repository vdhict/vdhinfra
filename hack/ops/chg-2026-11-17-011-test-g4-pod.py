#!/usr/bin/env python3
"""Local test of hack/ops/chg-2026-11-17-011-g4-pod.py on a SYNTHETIC ledger dir with the real signal plugin CODE
(family-ai-cluster blob c95b02dc = 99fb4183) and synthetic settings. Proves G4 3a/3e mechanics without the cluster:
trip writes the shared off state (current month, billing 402 billing_error, person null) + one 'off' transition with no
person field; a second trip refuses; swap-prev archives the real off file by link and leaves a previous-month off file
(never an absent state, no delete); the pin guard refuses a non-pin module. Writes only under a fresh mkdtemp.
F2 (Argus 21-11): write commands run only as the service user (a test runner names its own uid via G4_SERVICE_UID; a
different uid -> refuse, nothing written); `seen` reads (an unreadable off file -> off_seen false); `state` reports
owner/mode per file; abort-archive refuses wrong fields / wrong ts / symlink / existing target / call_while_off, and on
the exact synthetic trip links it to cloud-off.aborted-g4-<tag>.json and drops only the cloud-off.json name.
F6 (inc-2026-11-21-001): import/trip write NO __pycache__ (even when run without -B), import/routes/transitions refuse
as a non-service uid, and root-owned counts `find -xdev -uid N` under plugins/.plugins.old/.plugins.new read-only.
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
           'FAMILY_CLOUD_ROUTE_FILE': os.path.join(root, 'route.jsonl'), 'HOME': root, 'G4_SERVICE_UID': str(os.getuid())}
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
    s, rc = run(env, 'seen'); ok('seen -> off_seen true (read as the service user)', rc == 0 and s.get('off_seen') is True and s.get('off_readable') is True)
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
    f2_tests(signal, month, prev)
    f6_tests(signal)
    n, good = len(RES), sum(RES)
    print('G4POD TESTS %d/%d passed' % (good, n))
    return 0 if good == n else 1


def off_doc(cur_month, ts, **over):
    d = dict(v=1, ts=ts, month=cur_month, kind='billing', status=402, type='billing_error', person=None)
    d.update(over)
    return d


def f2_tests(signal, month, prev):
    # --- privilege drop
    root, led, env, _ = setup(signal)
    s, rc = run(env, 'drop-check'); ok('F2 drop-check as the service user -> ok, uid reported', rc == 0 and s.get('drop') == 'ok' and s.get('uid') == os.getuid())
    bad = dict(env, G4_SERVICE_UID=str(os.getuid() + 4242))
    s, rc = run(bad, 'trip'); ok('F2 trip as a non-service uid (cannot drop) -> refused, nothing written',
                                 rc != 0 and 'service user' in json.dumps(s) and not os.path.exists(os.path.join(led, 'cloud-off.json')))
    s, rc = run(dict(env, G4_SERVICE_UID='0'), 'trip'); ok('F2 service uid 0 is refused', rc != 0 and 'uid 0' in json.dumps(s))
    s, rc = run(bad, 'seen'); ok('F2 seen as a non-service uid -> refused', rc != 0)
    s, rc = run(bad, 'abort-archive', '1', '20261121T064806Z'); ok('F2 abort-archive as a non-service uid -> refused', rc != 0 and 'service user' in json.dumps(s))
    # --- seen reads; state reports metadata
    s, rc = run(env, 'seen'); ok('F2 seen with no off file -> present false, seen false', rc == 0 and s['off_present'] is False and s['off_seen'] is False)
    s, rc = run(env, 'trip'); ok('F2 trip (setup for seen/state)', s == {'tripped': True})
    s, rc = run(env, 'seen'); ok('F2 seen readable -> off_seen true, off_readable true', rc == 0 and [s['off_seen'], s['off_present'], s['off_readable']] == [True, True, True])
    s, rc = run(env, 'state')
    f = s.get('files', {})
    ok('F2 state files: owner/mode/type for cloud-off.json, cloud-transitions.jsonl, month.json; no sticky/lock names',
       set(f) == {'cloud-off.json', 'cloud-transitions.jsonl', 'month.json'} and all(v.get('uid') == os.getuid() and v.get('type') == 'reg' for v in f.values())
       and f['cloud-transitions.jsonl']['mode'] == '600')
    off = os.path.join(led, 'cloud-off.json')
    os.chmod(off, 0)
    s, rc = run(env, 'seen'); ok('F2 seen on an unreadable off file -> present true, off_seen false (stat is not enough)', rc == 0 and s['off_present'] is True and s['off_seen'] is False)
    os.chmod(off, 0o644)
    # --- abort-archive refusals on a real trip
    ts = json.load(open(off))['ts']
    tag = '20261121T064806Z'
    arch = os.path.join(led, 'cloud-off.aborted-g4-%s.json' % tag)
    s, rc = run(env, 'abort-archive', repr(ts + 0.001), tag); ok('F2 abort-archive wrong ts -> refused', rc != 0 and 'expected trip' in json.dumps(s) and os.path.exists(off))
    s, rc = run(env, 'abort-archive', repr(ts), '20261121T0648Z'); ok('F2 abort-archive malformed tag -> refused', rc != 0 and os.path.exists(off))
    s, rc = run(env, 'abort-archive', repr(ts)); ok('F2 abort-archive missing tag -> refused', rc != 0 and os.path.exists(off))
    open(arch, 'w').write('{}')
    s, rc = run(env, 'abort-archive', repr(ts), tag); ok('F2 abort-archive existing target -> refused, nothing changed', rc != 0 and 'exists' in json.dumps(s) and os.path.exists(off) and open(arch).read() == '{}')
    os.rename(arch, os.path.join(root, 'moved-aside.json'))
    raw0 = open(off).read()
    for label, over in (('person set', {'person': 'x'}), ('kind', {'kind': 'unknown'}), ('status', {'status': 401}),
                        ('type', {'type': 'authentication_error'}), ('month', {'month': prev}), ('status as bool-ish', {'status': '402'}),
                        ('extra key', {'extra': 1})):
        open(off, 'w').write(json.dumps(off_doc(month, ts, **over)))
        s, rc = run(env, 'abort-archive', repr(ts), tag)
        ok('F2 abort-archive wrong fields (%s) -> refused, off file kept' % label, rc != 0 and os.path.exists(off) and not os.path.lexists(arch))
    open(off, 'w').write(raw0)
    real = os.path.join(root, 'real-off.json'); os.rename(off, real); os.symlink(real, off)
    s, rc = run(env, 'abort-archive', repr(ts), tag); ok('F2 abort-archive on a symlink -> refused, link kept', rc != 0 and 'regular' in json.dumps(s) and os.path.islink(off))
    os.rename(off, os.path.join(root, 'symlink-aside')); os.rename(real, off)
    hl = os.path.join(root, 'second-name.json'); os.link(off, hl)
    s, rc = run(env, 'abort-archive', repr(ts), tag); ok('F2 abort-archive on a file with a second hard link -> refused', rc != 0 and os.path.exists(off) and not os.path.lexists(arch))
    # the second name stays (no delete): move the linked inode aside and write a fresh single-link copy of the bytes
    os.rename(off, os.path.join(root, 'off-linked-original.json')); open(off, 'w').write(raw0)
    trans = os.path.join(led, 'cloud-transitions.jsonl')
    t_raw = open(trans).read()
    with open(trans, 'a') as fh:
        fh.write(json.dumps({'ts': ts + 5, 'to': 'call_while_off', 'calls_while_off': 1}) + '\n')
    s, rc = run(env, 'abort-archive', repr(ts), tag); ok('F2 abort-archive with a call_while_off since the trip -> refused', rc != 0 and 'call_while_off' in json.dumps(s) and os.path.exists(off))
    open(trans, 'w').write(t_raw)
    os.chmod(trans, 0)
    s, rc = run(env, 'abort-archive', repr(ts), tag); ok('F2 abort-archive with unreadable transitions -> refused', rc != 0 and 'transitions unreadable' in json.dumps(s) and os.path.exists(off))
    os.chmod(trans, 0o600)
    # --- the exact synthetic trip -> archived
    s, rc = run(env, 'abort-archive', repr(ts), tag)
    ok('F2 abort-archive exact synthetic trip -> aborted, archive name, off gone', rc == 0 and s.get('aborted') is True and s.get('archived_as') == 'cloud-off.aborted-g4-%s.json' % tag and s.get('off_now') is False)
    ok('F2 archive keeps the exact bytes; no new transition line; archive name not cloud-off.cleared*',
       open(arch).read() == raw0 and open(trans).read() == t_raw and not os.path.basename(arch).startswith('cloud-off.cleared'))
    s, rc = run(env, 'state'); ok('F2 state after abort: off false, off_files == [the aborted archive]', s['off'] is False and s['off_files'] == ['cloud-off.aborted-g4-%s.json' % tag])
    s, rc = run(env, 'abort-archive', repr(ts), tag); ok('F2 abort-archive a second time -> refused (no off file)', rc != 0 and 'no cloud-off.json' in json.dumps(s))
    s, rc = run(env, 'trip'); ok('F2 a new trip after the abort works again (off state is absent, not stuck)', s == {'tripped': True})
    # the real G4 synthetic stamp form used on the rerun day (ts with 3 decimals as JSON wrote it)
    r3, l3, e3, m3 = setup(signal)
    open(os.path.join(l3, 'cloud-off.json'), 'w').write(json.dumps(off_doc(m3, 1795243795.837)))
    open(os.path.join(l3, 'cloud-transitions.jsonl'), 'w').write('{"ts":1795243795.84,"to":"off","kind":"billing","status":402,"type":"billing_error","calls_while_off":0}\n')
    s, rc = run(e3, 'abort-archive', '1795243795.837', '20261121T064806Z'); ok('F2 abort-archive with the rerun-day arguments (1795243795.837) -> aborted', rc == 0 and s.get('aborted') is True)


def tree(top):
    """names + (uid, size, mtime_ns) of everything under top (lstat): proves a command wrote nothing"""
    out = {}
    for dirpath, dirs, files in os.walk(top):
        for n in dirs + files:
            p = os.path.join(dirpath, n); st = os.lstat(p)
            out[os.path.relpath(p, top)] = (st.st_uid, st.st_size, st.st_mtime_ns)
    return out


def pycache(top):
    return [d for d, _, f in os.walk(top) if os.path.basename(d) == '__pycache__' or any(x.endswith('.pyc') for x in f)]


def run_plain(env, *args):
    """like run(), but WITHOUT -B (and without -I's -E): the helper's own sys.dont_write_bytecode must hold"""
    p = subprocess.run([sys.executable, '-s', '-', *args], stdin=open(HELPER), capture_output=True, text=True,
                       env=dict(env, PYTHONDONTWRITEBYTECODE=''), cwd=env['HOME'])
    out = (p.stdout.strip() or p.stderr.strip()).splitlines()
    try:
        return json.loads(out[-1]), p.returncode
    except Exception:
        return {'raw': out[-1:] if out else []}, p.returncode


def f6_tests(signal):
    root, led, env, _ = setup(signal)
    plug = env['G4_PLUGIN_DIR']
    s, rc = run(env, 'import')
    ok('F6 import runs as the service user with bytecode off', rc == 0 and s.get('import') == 'ok' and s.get('as_uid') == os.getuid() and s.get('bytecode') == 'off')
    s, rc = run_plain(env, 'import')
    ok('F6 import WITHOUT -B still writes no __pycache__/.pyc in the plugin dir (helper sets dont_write_bytecode)', rc == 0 and s.get('import') == 'ok' and pycache(plug) == [])
    s, rc = run_plain(env, 'trip')
    ok('F6 trip WITHOUT -B: tripped, no __pycache__/.pyc anywhere in the test root', s == {'tripped': True} and pycache(root) == [])
    bad = dict(env, G4_SERVICE_UID=str(os.getuid() + 4242))
    s, rc = run(bad, 'import'); ok('F6 import as a non-service uid -> refused before the load, no __pycache__', rc != 0 and 'service user' in json.dumps(s) and pycache(plug) == [])
    s, rc = run(bad, 'routes', '0', '1'); ok('F6 routes as a non-service uid -> refused', rc != 0 and 'service user' in json.dumps(s))
    s, rc = run(bad, 'transitions', '0'); ok('F6 transitions as a non-service uid -> refused', rc != 0 and 'service user' in json.dumps(s))
    # root-owned on a synthetic /opt/data
    data = os.path.join(root, 'data')
    os.makedirs(os.path.join(data, 'plugins', 'model-providers', 'family-cloud', '__pycache__'))
    open(os.path.join(data, 'plugins', 'model-providers', 'family-cloud', '__init__.py'), 'w').write('x = 1\n')
    open(os.path.join(data, 'plugins', 'model-providers', 'family-cloud', '__pycache__', 'x.pyc'), 'w').write('')
    os.makedirs(os.path.join(data, '.plugins.old', 'a'))
    open(os.path.join(data, '.plugins.old', 'a', 'b.py'), 'w').write('')
    os.makedirs(os.path.join(data, 'memories')); open(os.path.join(data, 'memories', 'not-scanned.txt'), 'w').write('')
    outside = os.path.join(root, 'outside'); os.makedirs(outside); open(os.path.join(outside, 'o.txt'), 'w').write('')
    os.symlink(outside, os.path.join(data, 'plugins', 'link-out'))
    me = dict(env, G4_DATA_DIR=data, G4_ROOTCHECK_UID=str(os.getuid()))
    before = tree(data)
    s, rc = run(me, 'root-owned')
    # plugins: plugins, model-providers, family-cloud, __pycache__, __init__.py, x.pyc, link-out (lstat, not followed) = 7
    # .plugins.old: .plugins.old, a, b.py = 3; memories/ and the symlink target are not scanned
    ok('F6 root-owned counts every name under plugins + .plugins.old owned by the checked uid (7 + 3), symlink not followed, memories/ not scanned',
       rc == 0 and s.get('plugins_present') is True and s.get('root_owned') == 10 and s.get('per_root') == {'plugins': 7, '.plugins.old': 3}
       and s.get('errors') == 0 and len(s.get('first', [])) == 5 and not any('memories' in f or 'o.txt' in f for f in s['first']))
    ok('F6 root-owned wrote nothing (tree identical before/after)', tree(data) == before)
    s, rc = run(dict(env, G4_DATA_DIR=data), 'root-owned')
    ok('F6 root-owned default uid 0 on a runner-owned tree -> 0 root-owned, plugins present, no error',
       rc == 0 and s.get('root_owned') == 0 and s.get('plugins_present') is True and s.get('errors') == 0 and s.get('scanned') == 10)
    os.makedirs(os.path.join(data, '.plugins.new')); open(os.path.join(data, '.plugins.new', 'n.py'), 'w').write('')
    s, rc = run(me, 'root-owned'); ok('F6 root-owned also scans .plugins.new (seed-once rm -rf target)', s.get('per_root', {}).get('.plugins.new') == 2 and s.get('root_owned') == 12)
    locked = os.path.join(data, '.plugins.old', 'a'); os.chmod(locked, 0)
    s, rc = run(me, 'root-owned'); os.chmod(locked, 0o755)
    ok('F6 root-owned counts an unlistable dir as an error (driver fails closed)', rc == 0 and s.get('errors', 0) >= 1)
    empty = os.path.join(root, 'data-empty'); os.makedirs(empty)
    s, rc = run(dict(me, G4_DATA_DIR=empty), 'root-owned'); ok('F6 root-owned with no plugins dir -> plugins_present false', rc == 0 and s.get('plugins_present') is False and s.get('root_owned') == 0)
    s, rc = run(dict(me, G4_DATA_DIR=os.path.join(root, 'nope')), 'root-owned'); ok('F6 root-owned on a missing data dir -> error counted', s.get('errors') == 1)


if __name__ == '__main__':
    sys.exit(main())
