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


if __name__ == '__main__':
    sys.exit(main())
