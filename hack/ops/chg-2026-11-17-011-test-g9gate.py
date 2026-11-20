#!/usr/bin/env python3
"""Tests for hack/ops/chg-2026-11-17-011-g9gate.py (Argus C2: one test per probe B1p..K5, H1, F1, plus the brief's
negatives). Synthetic inputs only: synthetic settings/config/SOUL; the two plugin files are the real CODE blobs from
family-ai-cluster (signal c95b02dc = 99fb4183, pre-signal af43b7c1 = 82fafe60) so the pins can match. Writes only
under a fresh mkdtemp in $TMPDIR (never removed here: no deletes, AGR-121).

  python3 -I hack/ops/chg-2026-11-17-011-test-g9gate.py        -> "TESTS n/n passed" and rc 0
"""
import copy
import datetime as dt
import gzip
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, 'chg-2026-11-17-011-g9gate.py')
FAC = os.environ.get('FAMILY_AI_CLUSTER', os.path.expanduser('~/Code/pka-wires/family-ai-cluster'))
CHG = 'chg-2026-11-17-011'
NOW = '2026-11-21T09:00:00Z'
G4TS = '2026-11-21T08:30:00Z'
ACKTS = '2026-11-20T21:00:00Z'
FC = 'plugins/model-providers/family-cloud/'


def blob(sha):
    return subprocess.run(['git', '-C', FAC, 'cat-file', 'blob', sha], check=True, capture_output=True).stdout


SIGNAL = blob('c95b02dc273ae4559c6e55c8e757f6e67ebd8710')
PRESIG = blob('af43b7c1d3433784a92c48a52de2bae6b83313e6')
SETTINGS = {'budget_usd': 99, 'price_confirmed': True, 'workspace_id': 'wrkspc_SYNTHETIC0',
            'endpoint': 'https://api.anthropic.com/v1', 'provider': 'anthropic'}


def tgz(files, link=None):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        if link:
            info = tarfile.TarInfo(link)
            info.type = tarfile.SYMTYPE
            info.linkname = '/etc/passwd'
            tar.addfile(info)
    return gzip.compress(buf.getvalue(), mtime=0)


def cloud_files(settings=None, init=SIGNAL, with_fc=True):
    f = {'config.yaml': b'model:\n  provider: family-cloud\n', 'SOUL.md': b'synthetic\n'}
    if with_fc:
        f[FC + '__init__.py'] = init
        f[FC + 'settings.json'] = json.dumps(settings if settings is not None else SETTINGS).encode()
    return f


def local_files():
    return {'config.yaml': b'model:\n  provider: custom\n', 'SOUL.md': b'synthetic\n', 'plugins/x/__init__.py': b'#\n'}


class Env:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix='g9gate-test-')
        self.ev = os.path.join(self.root, 'ops', 'evidence', CHG)
        os.makedirs(self.ev)
        self.bundles = {}
        self.pointer = {'chg': CHG, 'org_monthly_limit_usd': 200, 'payment_method': 'present (synthetic:1)'}
        self.evtext = b'synthetic g4 canary evidence\n'
        self.evname = 'g4-canary-20261121T082900Z.txt'
        self.cloud = tgz(cloud_files())
        self.p2 = tgz(cloud_files(init=PRESIG))
        self.extra_events = []
        self.event = None   # filled by build()

    def g4_event(self):
        return {'actor': 'infra-ops', 'chg': CHG, 'event': 'validated', 'ts': G4TS, 'payload': {
            'tsk': 'tsk-2026-10-17-005', 'step': 'G4', 'g4': 'green',
            'evidence': 'ops/evidence/%s/%s' % (CHG, self.evname),
            'evidence_sha256': hashlib.sha256(self.evtext).hexdigest(),
            'plugin_sha256': '99fb4183deb1793c4cecf3e2abece50e4375b37962f44fa53c358bf581c37496',
            'probe_sha256': 'f1d9aed6b482808cc72217803e603e2b58b4f581a2c7c362ba259f4fc2e6bba7',
            'p3_bundle_sha256': hashlib.sha256(self.cloud).hexdigest(),
            'checks': {k: True for k in ('off_visible_other_pod', 'turn_cloud_off', 'offgate_followed',
                                         'probe_same_month_200', 'probe_cleared_prev_month', 'alert_team_only')}}}

    def ack_event(self):
        return {'actor': 'security-engineer', 'chg': CHG, 'event': 'qa_passed', 'ts': ACKTS,
                'payload': {'category': 'security', 'dormant_p2': 'accepted'}}

    def build(self, event=None, raw_lines=None):
        w = lambda n, d: open(os.path.join(self.root, n), 'wb').write(d)
        w('p1.tgz', tgz(local_files())); w('p4.tgz', tgz(local_files()))
        w('p2.tgz', self.p2); w('p3.tgz', self.cloud)
        if self.pointer is not None:
            open(os.path.join(self.ev, 'g1-evidence-pointer-20261118T162823Z.json'), 'w').write(json.dumps(self.pointer))
        open(os.path.join(self.ev, self.evname), 'wb').write(self.evtext)
        ev = self.g4_event() if event is None else event
        lines = [json.dumps({'actor': 'infra-ops', 'chg': CHG, 'event': 'executed', 'ts': '2026-11-20T10:00:00Z', 'payload': {}}),
                 json.dumps(self.ack_event())]
        lines += [json.dumps(ev)] + [json.dumps(x) for x in self.extra_events] + (raw_lines or [])
        open(os.path.join(self.root, 'changes.jsonl'), 'w').write('\n'.join(lines) + '\n')
        return self

    def args(self, **over):
        r = self.root
        a = ['--changes', os.path.join(r, 'changes.jsonl'), '--evidence-dir', self.ev, '--g4-event', G4TS,
             '--cloud-bundle', 'profiel-3=' + os.path.join(r, 'p3.tgz'),
             '--local-bundle', 'profiel-1=' + os.path.join(r, 'p1.tgz'),
             '--local-bundle', 'profiel-4=' + os.path.join(r, 'p4.tgz'),
             '--dormant-bundle', 'profiel-2=' + os.path.join(r, 'p2.tgz'), '--dormant-ack', ACKTS, '--now', NOW]
        return over.get('replace', a)


def run(args, test_env=True, timeout=20):
    env = {'PATH': '/usr/bin:/bin'}
    if test_env:
        env['GOLIVE_TEST'] = '1'
    try:
        p = subprocess.run([sys.executable, '-I', GATE] + args, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 'HANG', -9
    return p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ('stderr:' + p.stderr[-200:]), p.returncode


RESULTS = []


def expect(name, out, want_green, want_in=None):
    line, rc = out
    green = (line == 'GATE GREEN (g1)' and rc == 0)
    ok = green if want_green else (not green and rc != 0 and line != 'HANG' and line.startswith('GATE RED'))
    if ok and want_in and want_in not in line:
        ok = False
    RESULTS.append(ok)
    print(('PASS ' if ok else 'FAIL ') + name + ' -> rc=%s %s' % (rc, line))


def mutated(fn):
    e = Env()
    ev = e.g4_event()
    fn(e, ev)
    e.build(event=ev)
    return e


def main():
    e = Env().build()
    expect('baseline synthetic GREEN', run(e.args()), True)

    # --- a: G4 event shape (Argus B1p, B2p, K5 + "any shape other than Argus' exact one")
    expect('B1p event type qa_failed', run(mutated(lambda e, v: v.update(event='qa_failed')).args()), False)
    expect('B1p actor mypka', run(mutated(lambda e, v: v.update(actor='mypka')).args()), False)
    expect('shape: extra payload key', run(mutated(lambda e, v: v['payload'].update(note='x')).args()), False)
    expect('shape: missing payload key', run(mutated(lambda e, v: v['payload'].pop('probe_sha256')).args()), False)
    expect('shape: extra top-level key', run(mutated(lambda e, v: v.update(extra=1)).args()), False)
    expect('shape: a 7th check', run(mutated(lambda e, v: v['payload']['checks'].update(more=True)).args()), False)
    expect('shape: a missing check', run(mutated(lambda e, v: v['payload']['checks'].pop('alert_team_only')).args()), False)
    expect('shape: check false', run(mutated(lambda e, v: v['payload']['checks'].update(turn_cloud_off=False)).args()), False)
    expect('shape: check "true" string', run(mutated(lambda e, v: v['payload']['checks'].update(turn_cloud_off='true')).args()), False)
    expect('shape: check 1 (int)', run(mutated(lambda e, v: v['payload']['checks'].update(turn_cloud_off=1)).args()), False)
    expect('shape: g4 "Green"', run(mutated(lambda e, v: v['payload'].update(g4='Green')).args()), False)
    expect('shape: step G3', run(mutated(lambda e, v: v['payload'].update(step='G3')).args()), False)
    expect('shape: tsk other', run(mutated(lambda e, v: v['payload'].update(tsk='tsk-2026-11-09-101')).args()), False)
    expect('shape: plugin sha != pin', run(mutated(lambda e, v: v['payload'].update(plugin_sha256='0' * 64)).args()), False)
    expect('shape: probe sha != pin', run(mutated(lambda e, v: v['payload'].update(probe_sha256='0' * 64)).args()), False)
    expect('shape: "person" in payload (R7)', run(mutated(lambda e, v: v['payload'].update(person=None)).args()), False, 'person')
    expect('K5 p3_bundle_sha = a dark bundle (not the go bundle)', run(mutated(lambda e, v: v['payload'].update(p3_bundle_sha256=hashlib.sha256(b'dark').hexdigest())).args()), False)
    expect('evidence sha mismatch', run(mutated(lambda e, v: v['payload'].update(evidence_sha256='1' * 64)).args()), False)
    expect('evidence path in another chg dir', run(mutated(lambda e, v: v['payload'].update(evidence='ops/evidence/chg-2026-10-20-010/' + e.evname)).args()), False)
    expect('evidence path with ../', run(mutated(lambda e, v: v['payload'].update(evidence='ops/evidence/%s/../%s/%s' % (CHG, CHG, e.evname))).args()), False)
    # symlinked evidence file (Argus A4 shape, on path B)
    e2 = Env(); outside = os.path.join(e2.root, 'outside.txt'); open(outside, 'wb').write(e2.evtext)
    e2.build(); os.rename(os.path.join(e2.ev, e2.evname), os.path.join(e2.root, 'moved-away.txt'))
    os.symlink(outside, os.path.join(e2.ev, e2.evname))
    expect('symlinked evidence file', run(e2.args()), False, 'symlink')
    e3 = Env().build(); a3 = e3.args(); a3[a3.index('--g4-event') + 1] = '2026-11-21T08:30:01Z'
    expect('--g4-event ts not the event', run(a3), False)
    a3b = [x for x in e3.args() if x not in ('--g4-event', G4TS)]
    expect('--g4-event missing', run(a3b), False)
    e4 = Env().build(); a4 = e4.args(); a4[a4.index('--now') + 1] = '2026-11-22T08:30:01Z'
    expect('stale: G4 event > 24 h old (--now)', run(a4), False, '24 h')
    a5 = e4.args(); a5[a5.index('--now') + 1] = '2026-11-21T08:29:59Z'
    expect('G4 event in the future', run(a5), False)
    e6 = Env(); e6.extra_events = [{'actor': 'infra-ops', 'chg': CHG, 'event': 'rolled_back', 'ts': '2026-11-21T08:40:00Z', 'payload': {}}]
    expect('B2p rolled_back after the G4 event', run(e6.build().args()), False)
    e7 = Env(); e7.extra_events = [dict(e7.g4_event())]
    expect('two lines at the G4 ts', run(e7.build().args()), False)
    e8 = Env(); e8.build(raw_lines=['{not json'])
    expect('corrupt changes line', run(e8.args()), False)

    # --- b: pointer (B3p, B4p, B5p + second pointer, symlink)
    e9 = Env().build(); open(os.path.join(e9.ev, 'g1-evidence-pointer-zzz.json'), 'w').write(json.dumps({'chg': CHG, 'org_monthly_limit_usd': None}))
    expect('B3p second pointer file', run(e9.args()), False, 'pointer')
    for name, val in (('B4p limit 5000', 5000), ('limit null', None), ('limit 0', 0), ('limit -1', -1), ('limit "200"', '200'),
                      ('limit true', True), ('limit 200.01', 200.01)):
        ex = Env(); ex.pointer['org_monthly_limit_usd'] = val
        expect(name, run(ex.build().args()), False)
    ex = Env(); ex.build(); p = os.path.join(ex.ev, 'g1-evidence-pointer-20261118T162823Z.json')
    text = open(p).read().replace('"org_monthly_limit_usd": 200', '"org_monthly_limit_usd": NaN')
    open(p, 'w').write(text)
    expect('limit NaN', run(ex.args()), False, 'finite')
    for name, val in (('B5p payment_method nonesuch', 'nonesuch'), ('payment_method present( (no space)', 'present(x)'), ('payment_method None', None)):
        ex = Env(); ex.pointer['payment_method'] = val
        expect(name, run(ex.build().args()), False)
    ex = Env(); ex.pointer['payment_method'] = 'none'
    expect('payment_method "none" GREEN', run(ex.build().args()), True)
    ex = Env(); ex.pointer = None; ex.build()
    real = os.path.join(ex.root, 'ptr.json'); open(real, 'w').write(json.dumps({'chg': CHG, 'org_monthly_limit_usd': 200, 'payment_method': 'none'}))
    os.symlink(real, os.path.join(ex.ev, 'g1-evidence-pointer-20261118T162823Z.json'))
    expect('pointer is a symlink', run(ex.args()), False)
    ex = Env(); ex.extra_events = [{'actor': 'infra-ops', 'chg': 'chg-2026-11-18-001', 'event': 'executed', 'ts': '2026-11-19T10:00:00Z', 'payload': {'billing_change': True}}]
    expect('billing_change since 2026-11-18', run(ex.build().args()), False)

    # --- c: bundles (K1, K2, K3/4, K5 settings, school, roles)
    def cloud_with(**kw):
        s = dict(SETTINGS); s.update(kw)
        ex = Env(); ex.cloud = tgz(cloud_files(settings=s)); return ex.build()
    expect('K5 price_confirmed false', run(cloud_with(price_confirmed=False).args()), False)
    expect('K5 workspace empty', run(cloud_with(workspace_id='').args()), False)
    expect('workspace with a dash', run(cloud_with(workspace_id='wrkspc_ab-cd').args()), False)
    expect('K3 budget NaN', run(cloud_with(budget_usd=float('nan')).args()), False)
    expect('K4 budget -5', run(cloud_with(budget_usd=-5).args()), False)
    expect('budget 200', run(cloud_with(budget_usd=200).args()), False)
    expect('budget true', run(cloud_with(budget_usd=True).args()), False)
    expect('endpoint other', run(cloud_with(endpoint='https://api.example.invalid/v1').args()), False)
    expect('school keys present (C1 school off)', run(cloud_with(school_context_cloud=['profiel-3']).args()), False)
    ex = Env(); ex.cloud = tgz(cloud_files(with_fc=False)); ex.build()
    expect('K1 cloud p3 bundle without family-cloud', run(ex.args()), False)
    ex = Env(); ex.cloud = tgz(cloud_files(init=PRESIG)); ex.build()
    expect('cloud p3 with the pre-signal plugin (live p3 today)', run(ex.args()), False)
    ex = Env(); ex.cloud = tgz(cloud_files(), link='plugins/evil'); ex.build()
    expect('bundle with a symlink member', run(ex.args()), False)
    ex = Env().build(); a = ex.args(); i = a.index('profiel-1=' + os.path.join(ex.root, 'p1.tgz'))
    a[i] = 'profiel-1=' + os.path.join(ex.root, 'p3.tgz')
    expect('K2 local p1 that carries family-cloud', run(a), False)
    ex = Env().build(); a = ex.args(); a[a.index('profiel-3=' + os.path.join(ex.root, 'p3.tgz'))] = 'profiel-1=' + os.path.join(ex.root, 'p3.tgz')
    expect('cloud role on profiel-1', run(a), False)
    ex = Env().build(); a = ex.args(); a[a.index('--dormant-bundle')] = '--local-bundle'
    a = a[:a.index('--dormant-ack')] + a[a.index('--dormant-ack') + 2:]
    expect('live-shape p2 (pre-signal family-cloud) as local -> RED', run(a), False, 'profiel-2 has family-cloud')
    a = ex.args(); a = a[:a.index('--dormant-ack')] + a[a.index('--dormant-ack') + 2:]
    expect('dormant p2 without the Argus ack', run(a), False, 'dormant-ack')
    ex = Env(); ex.build(); a = ex.args(); a[a.index('--dormant-ack') + 1] = '2026-11-20T10:00:00Z'
    expect('dormant ack pointing at a non-Argus line', run(a), False)
    ex = Env(); ex.p2 = tgz(cloud_files()); ex.build()
    expect('dormant p2 carrying the SIGNAL plugin', run(ex.args()), False)
    ex = Env().build(); a = ex.args(); i = a.index('--local-bundle', a.index('profiel-1=' + os.path.join(ex.root, 'p1.tgz')) - 1)
    a = a[:i] + a[i + 2:]
    expect('profiel-1 missing', run(a), False)
    ex = Env().build(); a = ex.args() + ['--local-bundle', 'profiel-1=' + os.path.join(ex.root, 'p1.tgz')]
    expect('profiel-1 twice', run(a), False)

    # --- d/e: --now, parsing, path A
    ex = Env().build()
    expect('--now without GOLIVE_TEST', run(ex.args(), test_env=False), False, 'test-only')
    a = ex.args(); a = a[a.index('--evidence-dir'):] + ['--changes']
    expect('H1 --changes given last (no hang)', run(a, timeout=10), False)
    expect('--w2-event (path A) refused', run(ex.args() + ['--w2-event', G4TS]), False)
    expect('F1 --now unparseable', run(ex.args()[:-1] + ['yesterday']), False)
    expect('abbreviated flag --chan refused', run(['--chan'] + ex.args()[1:]), False)

    n, ok = len(RESULTS), sum(RESULTS)
    print('TESTS %d/%d passed' % (ok, n))
    return 0 if ok == n else 1


if __name__ == '__main__':
    sys.exit(main())
