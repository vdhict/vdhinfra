#!/usr/bin/env python3
"""chg-2026-11-17-011 local tests of the G5 lock (cloud_lock.py) and G6 alert (cloud_alert.py) jobs, Argus F3 (21-11).

Loads the two job scripts from kubernetes/main/apps/family-ai/cloud-cutover/app/files with a FAKE Kubernetes API (CNPs,
state ConfigMaps, probe Jobs) and a fake Alertmanager post, on a synthetic ledger dir under a fresh mkdtemp. No cluster,
no network, no family content. Proves:
  lock : an unreadable transitions log (mode 000, a directory) -> trigger transitions_unreadable, lock CNP + latch,
         job red (rc 3); latched after the file is readable again until reopen_ack_ts; any unexpected error -> the
         fail-safe ensures offgate + lock and records the latch before exit 1; an unrecorded lock CNP is adopted;
         the drill seed "__UNREADABLE__" drives the same path; the old T1/offgate behaviour is unchanged.
  alert: an unreadable transitions / probe-results file -> exactly ONE team warning FamilyCloudStateUnreadable per UTC
         day and file, cursor untouched, exit 1; a failed post is retried; once readable the held lines are alerted
         (nothing skipped); drill seed -> DrillFamilyCloudStateUnreadable (warning, drill=true); absent file -> silent.
  python3 -I hack/ops/chg-2026-11-17-011-test-cloud-guards.py  -> "CLOUD GUARD TESTS n/n passed", rc 0
"""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(HERE, '..', '..', 'kubernetes', 'main', 'apps', 'family-ai', 'cloud-cutover', 'app', 'files')
RES = []
NS = 'family-ai'


def ok(name, cond):
    RES.append(bool(cond)); print(('PASS ' if cond else 'FAIL ') + name)


class FakeAPI:
    def __init__(self, cms):
        self.cnps, self.cms, self.jobs, self.fail = {}, {k: dict(v) for k, v in cms.items()}, [], {}

    def __call__(self, method, path, body=None, content_type='application/json'):
        for (m, prefix), status in self.fail.items():
            if m == method and path.startswith(prefix):
                return status, {}
        cnp = f'/apis/cilium.io/v2/namespaces/{NS}/ciliumnetworkpolicies'
        cm = f'/api/v1/namespaces/{NS}/configmaps/'
        if path.startswith(cnp):
            name = path[len(cnp) + 1:]
            if method == 'GET':
                return (200, self.cnps[name]) if name in self.cnps else (404, {})
            if method == 'POST':
                self.cnps[body['metadata']['name']] = body; return 201, body
            if method == 'DELETE':
                return (200, {}) if self.cnps.pop(name, None) else (404, {})
        if path.startswith(cm):
            name = path[len(cm):]
            if name not in self.cms:
                return 404, {}
            if method == 'GET':
                return 200, {'data': dict(self.cms[name])}
            if method == 'PATCH':
                self.cms[name].update(body['data']); return 200, {}
        if '/jobs?' in path and method == 'GET':
            stamp = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            return 200, {'items': [{'metadata': {'creationTimestamp': stamp(t)}} for t in self.jobs]}
        return 500, {}


def load(script, env):
    for k, v in env.items():
        os.environ[k] = v
    spec = importlib.util.spec_from_file_location(f'{script}_{len(RES)}_{time.monotonic_ns()}', os.path.join(FILES, script))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def call(fn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn()
    lines = [json.loads(x) for x in buf.getvalue().splitlines() if x.strip()]
    return rc, lines


def month():
    return dt.datetime.now(dt.timezone.utc).strftime('%Y-%m')


def write(d, name, obj):
    path = os.path.join(d, name)
    with open(path, 'w') as fh:
        fh.write(obj if isinstance(obj, str) else json.dumps(obj))
    return path


# ------------------------------------------------------------------------------------------------------ lock
def lock_env(d, mode='prod'):
    m = load('cloud_lock.py', {'LOCK_MODE': mode, 'LEDGER_DIR': d, 'POD_NAMESPACE': NS})
    api = FakeAPI({m.STATE_CM: {'state.json': '{}'}})
    m.api = api
    if mode == 'drill':
        m.STATE_DIR = type(m.STATE_DIR)(d)
    return m, api


def lock_run(m):
    rc, lines = call(m.run)
    return rc, lines[-1]['family_cloud_lock']


def lock_state(m, api):
    return json.loads(api.cms[m.STATE_CM]['state.json'] or '{}')


def lock_tests():
    d = tempfile.mkdtemp(prefix='c011-lock-')
    write(d, 'month.json', {'month': month(), 'usd': 0.5})
    m, api = lock_env(d)
    rc, o = lock_run(m)
    ok('lock: no off file, no transitions file -> rc 0, triggers [], offgate absent, no lock',
       rc == 0 and o['triggers'] == [] and o['actions'].get(m.OFFGATE) == 'absent' and m.LOCK not in api.cnps)
    off_ts = time.time() - 600
    write(d, 'cloud-off.json', {'v': 1, 'ts': off_ts, 'month': month(), 'kind': 'billing', 'status': 402, 'type': 'billing_error', 'person': None})
    trans = write(d, 'cloud-transitions.jsonl', json.dumps({'ts': off_ts + 0.1, 'to': 'off', 'kind': 'billing'}) + '\n')
    rc, o = lock_run(m)
    ok('lock: off + readable transitions (no call_while_off) -> rc 0, offgate created, no trigger, no lock',
       rc == 0 and o['off'] is True and o['triggers'] == [] and m.OFFGATE in api.cnps and m.LOCK not in api.cnps)
    os.chmod(trans, 0)
    rc, o = lock_run(m)
    st = lock_state(m, api)
    ok('lock: transitions mode 000 -> trigger transitions_unreadable (PermissionError), lock CNP created, rc 3',
       rc == 3 and o['triggers'][0] == {'t': 'transitions_unreadable', 'class': 'PermissionError'} and m.LOCK in api.cnps
       and api.cnps[m.LOCK]['metadata']['annotations']['family-cloud/reason'] == 'transitions_unreadable')
    ok('lock: the unreadable run latched (state.locked) and kept the offgate', st.get('locked', {}).get('triggers', [{}])[0].get('t') == 'transitions_unreadable' and m.OFFGATE in api.cnps)
    lock_spec = api.cnps[m.LOCK]['spec']
    ok('lock: the lock CNP is deny-only for p2/p3 + probe, private ranges excepted (Studio reachable)',
       lock_spec['endpointSelector']['matchExpressions'][0]['values'] == ['hermes-profiel-2', 'hermes-profiel-3', 'family-cloud-probe']
       and lock_spec['egressDeny'][0]['toCIDRSet'][0]['except'] == m.PRIVATE and 'egress' not in lock_spec)
    os.chmod(trans, 0o600)
    rc, o = lock_run(m)
    ok('lock: readable again, no ack -> still latched (lock present), rc 0', rc == 0 and o['triggers'] == [] and o['actions'].get(m.LOCK) == 'present' and m.LOCK in api.cnps)
    api.cms[m.STATE_CM]['reopen_ack_ts'] = str(time.time() + 1)
    time.sleep(0.01)
    rc, o = lock_run(m)
    ok('lock: reopen_ack_ts after the latch -> lock removed (offgate stays while off)', rc == 0 and o['actions'].get(m.LOCK) == 'removed' and m.LOCK not in api.cnps and m.OFFGATE in api.cnps)
    # a directory where the log should be
    d2 = tempfile.mkdtemp(prefix='c011-lock-dir-')
    write(d2, 'month.json', {'month': month(), 'usd': 0.5}); os.mkdir(os.path.join(d2, 'cloud-transitions.jsonl'))
    m2, api2 = lock_env(d2)
    rc, o = lock_run(m2)
    ok('lock: transitions is a directory -> transitions_unreadable (IsADirectoryError), lock, rc 3, offgate absent (not off)',
       rc == 3 and o['triggers'][0]['class'] == 'IsADirectoryError' and m2.LOCK in api2.cnps and m2.OFFGATE not in api2.cnps)
    # T1 regression + an unparseable ts counts
    d3 = tempfile.mkdtemp(prefix='c011-lock-t1-')
    write(d3, 'month.json', {'month': month(), 'usd': 0.5})
    write(d3, 'cloud-transitions.jsonl', json.dumps({'ts': time.time(), 'to': 'call_while_off', 'calls_while_off': 1}) + '\n'
          + json.dumps({'ts': 'x', 'to': 'call_while_off'}) + '\nnot json\n')
    m3, api3 = lock_env(d3)
    rc, o = lock_run(m3)
    ok('lock: T1 call_while_off lines (one with an unparseable ts) -> n 2, lock, rc 0',
       rc == 0 and len(o['triggers']) == 1 and o['triggers'][0]['t'] == 'call_while_off' and o['triggers'][0]['n'] == 2 and m3.LOCK in api3.cnps)
    # fail-safe on an unexpected error
    d4 = tempfile.mkdtemp(prefix='c011-lock-fs-')
    write(d4, 'month.json', {'month': month(), 'usd': 0.5})
    m4, api4 = lock_env(d4)
    api4.fail[('GET', f'/apis/batch/v1/namespaces/{NS}/jobs')] = 500
    rc, o = lock_run(m4)
    ok('lock: unexpected error (jobs API 500) -> rc 1, fail-safe created offgate + lock, latch recorded',
       rc == 1 and o['error'] == 'RuntimeError' and o['failsafe'] == {m4.OFFGATE: 'created', m4.LOCK: 'created', 'state': 'latched'}
       and m4.OFFGATE in api4.cnps and m4.LOCK in api4.cnps and lock_state(m4, api4)['locked']['triggers'][0]['t'] == 'lock_error')
    api4.fail.clear()
    rc, o = lock_run(m4)
    ok('lock: after the fail-safe, healthy run -> lock stays latched, offgate removed (not off), rc 0',
       rc == 0 and o['actions'].get(m4.LOCK) == 'present' and m4.LOCK in api4.cnps and m4.OFFGATE not in api4.cnps)
    d5 = tempfile.mkdtemp(prefix='c011-lock-fs2-')
    write(d5, 'month.json', {'month': month(), 'usd': 0.5})
    m5, api5 = lock_env(d5)
    api5.fail[('GET', f'/api/v1/namespaces/{NS}/configmaps/')] = 503
    api5.fail[('POST', f'/apis/cilium.io/v2/namespaces/{NS}/ciliumnetworkpolicies')] = 403
    rc, o = lock_run(m5)
    ok('lock: fail-safe that cannot write anything -> rc 1, reports each failure, never raises',
       rc == 1 and o['failsafe'][m5.OFFGATE].startswith('failed:') and o['failsafe'][m5.LOCK].startswith('failed:') and o['failsafe']['state'].startswith('failed:'))
    # adoption of an unrecorded lock CNP
    api5.fail.clear()
    api5.cnps[m5.LOCK] = m5.deny_cnp(m5.LOCK, m5.LOCK_SEL, 'lock_error', {})
    rc, o = lock_run(m5)
    ok('lock: a lock CNP without a state record is adopted as latched (not removed), rc 0',
       rc == 0 and o['actions'].get(m5.LOCK) == 'adopted' and m5.LOCK in api5.cnps and lock_state(m5, api5)['locked']['triggers'][0]['t'] == 'adopted_unrecorded_lock')
    api5.cms[m5.STATE_CM]['reopen_ack_ts'] = str(time.time() + 1)
    rc, o = lock_run(m5)
    ok('lock: the adopted lock reopens via reopen_ack_ts', rc == 0 and o['actions'].get(m5.LOCK) == 'removed' and m5.LOCK not in api5.cnps)
    # drill seed
    d6 = tempfile.mkdtemp(prefix='c011-lock-drill-')
    seed = {'month.json': {'month': month(), 'usd': 1.0},
            'cloud-off.json': {'v': 1, 'ts': '__NOW_MINUS_600__', 'month': month(), 'kind': 'billing', 'status': 402, 'type': 'billing_error', 'person': None},
            'cloud-transitions.jsonl': '__UNREADABLE__'}
    os.environ['DRILL_SEED'] = json.dumps(seed)
    m6, api6 = lock_env(d6, 'drill')
    rc, o = lock_run(m6)
    ok('lock DRILL: seed __UNREADABLE__ -> transitions_unreadable, lock-drill + offgate-drill, rc 3, prod names untouched',
       rc == 3 and o['mode'] == 'drill' and o['triggers'][0]['t'] == 'transitions_unreadable'
       and set(api6.cnps) == {'family-cloud-lock-drill', 'family-cloud-offgate-drill'})
    rc, o = lock_run(m6)
    ok('lock DRILL: a second run re-seeds the same dir (mode 000 file rewritten) -> still rc 3', rc == 3 and o['triggers'][0]['t'] == 'transitions_unreadable')
    os.environ.pop('DRILL_SEED', None)


# ------------------------------------------------------------------------------------------------------ alert
def alert_env(d, mode='prod', cursor=None):
    m = load('cloud_alert.py', {'ALERT_MODE': mode, 'LEDGER_DIR': d, 'POD_NAMESPACE': NS, 'MONEY_TO_OWNER': 'false'})
    st = {} if cursor is None else {'cursor_ts': cursor}
    api = FakeAPI({m.STATE_CM: {'state.json': json.dumps(st)}})
    m.api = api
    posted = []
    m.AM_UP = True

    def post(alerts):
        if not m.AM_UP:
            return False
        posted.extend(alerts); return True
    m.post = post
    if mode == 'drill':
        m.STATE_DIR = type(m.STATE_DIR)(d)
    return m, api, posted


def alert_run(m):
    return call(m.main)


def alert_tests():
    d = tempfile.mkdtemp(prefix='c011-alert-')
    t0 = time.time() - 900
    off_line = json.dumps({'ts': time.time() - 300, 'to': 'off', 'kind': 'billing', 'status': 402, 'type': 'billing_error'}) + '\n'
    trans = write(d, 'cloud-transitions.jsonl', off_line)
    os.chmod(trans, 0)
    m, api, posted = alert_env(d, cursor=t0)
    rc, lines = alert_run(m)
    st = json.loads(api.cms[m.STATE_CM]['state.json'])
    ok('alert: transitions mode 000 -> rc 1, exactly ONE FamilyCloudStateUnreadable, severity warning, team component',
       rc == 1 and [a['labels']['alertname'] for a in posted] == ['FamilyCloudStateUnreadable']
       and posted[0]['labels']['severity'] == 'warning' and posted[0]['labels']['component'] == 'aiops-family-cloud'
       and posted[0]['labels']['file'] == 'cloud-transitions.jsonl' and posted[0]['labels']['class'] == 'PermissionError')
    ok('alert: unreadable run keeps the cursor (nothing skipped) and logs a changelog line', float(st['cursor_ts']) == t0
       and any('changelog' in x and x['changelog']['alert'] == 'FamilyCloudStateUnreadable' for x in lines)
       and lines[-1]['family_cloud_alert']['error'] == 'state_unreadable')
    ok('alert: no "person" anywhere in the output or the alert', 'person' not in json.dumps(lines) + json.dumps(posted))
    rc, lines = alert_run(m)
    ok('alert: second unreadable run the same UTC day -> rc 1, deduped (0 posted)', rc == 1 and len(posted) == 1 and lines[-1]['family_cloud_alert']['deduped'] is True)
    real_time = m.time
    m.time = types.SimpleNamespace(time=lambda: real_time.time() + 86400)
    rc, lines = alert_run(m)
    m.time = real_time
    ok('alert: still unreadable the next UTC day -> one new warning, rc 1', rc == 1 and len(posted) == 2)
    os.chmod(trans, 0o600)
    rc, lines = alert_run(m)
    st = json.loads(api.cms[m.STATE_CM]['state.json'])
    ok('alert: readable again -> the held off line is alerted now (FamilyCloudOff), rc 0, unreadable state cleared',
       rc == 0 and posted[-1]['labels']['alertname'] == 'FamilyCloudOff' and 'unreadable' not in st and float(st['cursor_ts']) > t0)
    # failed post is retried
    d2 = tempfile.mkdtemp(prefix='c011-alert-am-')
    os.mkdir(os.path.join(d2, 'cloud-transitions.jsonl'))
    m2, api2, posted2 = alert_env(d2, cursor=t0)
    m2.AM_UP = False
    rc, lines = alert_run(m2)
    ok('alert: unreadable (directory) + Alertmanager down -> rc 1, nothing recorded', rc == 1 and posted2 == [] and 'unreadable' not in json.loads(api2.cms[m2.STATE_CM]['state.json']))
    m2.AM_UP = True
    rc, lines = alert_run(m2)
    ok('alert: next run with Alertmanager up -> the warning is posted (IsADirectoryError), rc 1',
       rc == 1 and len(posted2) == 1 and posted2[0]['labels']['class'] == 'IsADirectoryError')
    # probe results unreadable
    d3 = tempfile.mkdtemp(prefix='c011-alert-pr-')
    write(d3, 'cloud-transitions.jsonl', '')
    pr = write(d3, 'cloud-probe-results.jsonl', '{"day":"2026-11-20","result":"error"}\n'); os.chmod(pr, 0)
    m3, api3, posted3 = alert_env(d3, cursor=t0)
    rc, lines = alert_run(m3)
    ok('alert: probe-results unreadable -> FamilyCloudStateUnreadable file=cloud-probe-results.jsonl, rc 1',
       rc == 1 and len(posted3) == 1 and posted3[0]['labels']['file'] == 'cloud-probe-results.jsonl')
    # absent file stays silent
    d4 = tempfile.mkdtemp(prefix='c011-alert-none-')
    m4, api4, posted4 = alert_env(d4, cursor=t0)
    rc, lines = alert_run(m4)
    ok('alert: absent transitions + probe files -> rc 0, nothing posted', rc == 0 and posted4 == [])
    # regression: readable off + same_month_200 money candidate (team)
    d5 = tempfile.mkdtemp(prefix='c011-alert-ok-')
    off_ts = time.time() - 600
    write(d5, 'cloud-off.json', {'v': 1, 'ts': off_ts, 'month': month(), 'kind': 'billing', 'status': 402, 'type': 'billing_error', 'person': 'p'})
    write(d5, 'cloud-transitions.jsonl', off_line + json.dumps({'ts': time.time() - 60, 'to': 'off', 'kind': 'same_month_200', 'status': 200, 'month': month()}) + '\n')
    m5, api5, posted5 = alert_env(d5, cursor=t0)
    rc, lines = alert_run(m5)
    ok('alert regression: off + same_month_200 -> FamilyCloudOff + FamilyCloudMoneyCandidate, both warning, rc 0',
       rc == 0 and [a['labels']['alertname'] for a in posted5] == ['FamilyCloudOff', 'FamilyCloudMoneyCandidate']
       and {a['labels']['severity'] for a in posted5} == {'warning'} and 'person' not in json.dumps(posted5))
    # drill
    d6 = tempfile.mkdtemp(prefix='c011-alert-drill-')
    os.environ['DRILL_SEED'] = json.dumps({'cloud-transitions.jsonl': '__UNREADABLE__'})
    m6, api6, posted6 = alert_env(d6, 'drill')
    rc, lines = alert_run(m6)
    lab = posted6[0]['labels'] if posted6 else {}
    ok('alert DRILL: seed __UNREADABLE__ -> DrillFamilyCloudStateUnreadable, severity warning, drill true, would warning, rc 1',
       rc == 1 and len(posted6) == 1 and lab.get('alertname') == 'DrillFamilyCloudStateUnreadable' and lab.get('severity') == 'warning'
       and lab.get('drill') == 'true' and lab.get('would_severity') == 'warning')
    os.environ.pop('DRILL_SEED', None)


def race_tests():
    """F7 (Argus 22-11, go RED at G4): the alert job classifies a same_month_200 line by the CURRENT cloud-off.json. The driver's
    3e moved that file away inside the same */5 window as 3d, so ONE alert run that saw both lines gave NotMoney instead of
    MoneyCandidate. The first case documents the race (cloud_alert.py is NOT changed in this rerun, F7-b); the second is the
    sequence the fixed driver enforces: an alert run between 3d and 3e -> MoneyCandidate."""
    t0 = time.time() - 900
    base = time.time() - 300

    def lines(*objs):
        return ''.join(json.dumps(o) + '\n' for o in objs)
    off_bill = {'ts': base, 'to': 'off', 'kind': 'billing', 'status': 402, 'type': 'billing_error'}
    off_sm = {'ts': base + 10, 'to': 'off', 'kind': 'same_month_200', 'status': 200, 'month': month()}
    on_probe = {'ts': base + 20, 'to': 'on', 'kind': 'probe'}
    off_file = {'v': 1, 'ts': base, 'month': month(), 'kind': 'billing', 'status': 402, 'type': 'billing_error'}

    def names(posted):
        return [a['labels']['alertname'] for a in posted]
    # race: the off file is gone (3e swap) before the single alert run that sees off/billing, off/same_month_200 and on/probe
    d = tempfile.mkdtemp(prefix='c011-alert-race-')
    write(d, 'cloud-transitions.jsonl', lines(off_bill, off_sm, on_probe))
    m, api, posted = alert_env(d, cursor=t0)
    rc, _ = alert_run(m)
    ok('race F7: off file already moved + ONE alert run over off/billing, off/same_month_200, on/probe -> NotMoney (documents the race)',
       rc == 0 and names(posted) == ['FamilyCloudOff', 'FamilyCloudSameMonth200NotMoney', 'FamilyCloudOn']
       and 'FamilyCloudMoneyCandidate' not in names(posted))
    # fixed sequence: off file present at the first alert run (after 3d), then moved, then the on/probe line
    d2 = tempfile.mkdtemp(prefix='c011-alert-seq-')
    write(d2, 'cloud-off.json', off_file)
    write(d2, 'cloud-transitions.jsonl', lines(off_bill, off_sm))
    m2, api2, posted2 = alert_env(d2, cursor=t0)
    rc1, _ = alert_run(m2)
    ok('race F7: an alert run between 3d and 3e (off file present) -> FamilyCloudOff + FamilyCloudMoneyCandidate, no NotMoney',
       rc1 == 0 and names(posted2) == ['FamilyCloudOff', 'FamilyCloudMoneyCandidate'])
    os.rename(os.path.join(d2, 'cloud-off.json'), os.path.join(d2, 'cloud-off.cleared-g4-T.json'))
    write(d2, 'cloud-transitions.jsonl', lines(off_bill, off_sm, on_probe))
    rc2, _ = alert_run(m2)
    ok('race F7: the later run after the off file moved adds only FamilyCloudOn; set == [MoneyCandidate, Off, On], all warning',
       rc2 == 0 and sorted(names(posted2)) == ['FamilyCloudMoneyCandidate', 'FamilyCloudOff', 'FamilyCloudOn']
       and {a['labels']['severity'] for a in posted2} == {'warning'})


def main():
    if os.geteuid() == 0:
        print('run as a normal user: mode 000 does not stop root'); return 2
    lock_tests()
    alert_tests()
    race_tests()
    n, good = len(RES), sum(RES)
    print('CLOUD GUARD TESTS %d/%d passed' % (good, n))
    return 0 if good == n else 1


if __name__ == '__main__':
    sys.exit(main())
