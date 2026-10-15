#!/usr/bin/env python3
"""chg-2026-10-15-001 C3 test of huiswerk-refresh guard.py with SYNTHETIC packages in a scratch volume (non-prod).
   python3 -I hack/ops/chg-2026-10-15-001-guard-test.py <guard.py> <refresh.py> <vul-kennis-prive> <scratch-dir>
Cases: (1) good package + restart OK -> exit 0, new collections in place, 1 retired dir;
       (2) non-UTF-8 package -> exit 1 before swap, collections unchanged (sha equal);
       (3) good package + restart failure -> exit 1, previous collections restored, failed-* kept, restart retried.
Synthetic text only; prints PASS/FAIL per case."""
import hashlib, importlib.util, io, os, sys, tarfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

GUARD, REFRESH, FILLER, SCRATCH = sys.argv[1:5]
TODAY = datetime.now(ZoneInfo('Europe/Amsterdam')).date().isoformat()


def package(p2, p3):
    name = f'huiswerk-{TODAY}'
    files = {'huiswerk-profiel-2/huiswerk.md': p2, 'huiswerk-profiel-3/huiswerk.md': p3,
             'vul-kennis-prive.sh': b'# data only\n'}
    sums = ''.join(f'{hashlib.sha256(v).hexdigest()}  {k}\n' for k, v in sorted(files.items())).encode()
    files['SHA256SUMS'] = sums
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as t:
        def add(n, b):
            i = tarfile.TarInfo(n); i.size = len(b); t.addfile(i, io.BytesIO(b))
        add('huiswerk-latest', f'{name}\n{hashlib.sha256(sums).hexdigest()}\n'.encode())
        for k, v in files.items():
            add(f'{name}/{k}', v)
    return buf.getvalue()


def tree_sha(vol):
    h = hashlib.sha256()
    for c in ('huiswerk-profiel-2', 'huiswerk-profiel-3'):
        for f in sorted((vol / c).rglob('*')) if (vol / c).exists() else []:
            if f.is_file():
                h.update(str(f.relative_to(vol)).encode() + f.read_bytes())
    return h.hexdigest()[:12]


def run_case(label, data, restart_fails):
    os.environ['HUISWERK_REFRESH_PY'] = REFRESH
    spec = importlib.util.spec_from_file_location('guard', GUARD)
    guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
    real_load = guard.load_refresh
    calls = {'restart': 0}

    def load():
        r = real_load(REFRESH)
        real_checked = r.checked

        def checked(cmd, **kw):
            if cmd[0] == 'ssh':
                return data
            if cmd[:2] == ['sh', '/opt/huiswerk/vul-kennis-prive']:
                return real_checked(['sh', FILLER] + cmd[2:], **kw)
            raise RuntimeError('unexpected command')
        r.checked = checked

        def restart(ns):
            calls['restart'] += 1
            if restart_fails and calls['restart'] == 1:
                raise RuntimeError('kennisdienst rollout timeout')
        r.cluster_restart = restart
        return r
    guard.load_refresh = load
    vol = Path(os.environ['HUISWERK_VOLUME'])
    before = tree_sha(vol)
    retired_before = len([p for p in vol.iterdir() if p.name.startswith('.retired-')])
    rc = guard.main()
    after = tree_sha(vol)
    retired = len([p for p in vol.iterdir() if p.name.startswith('.retired-')]) - retired_before
    return rc, before, after, retired, calls['restart']


def main():
    vol = Path(SCRATCH) / 'vul'
    vol.mkdir(parents=True)
    (vol / 'zeevaart').mkdir(); (vol / 'zeevaart' / 'x.md').write_text('# synthetic\n')
    os.environ.update(HUISWERK_VOLUME=str(vol), HUISWERK_STATE=str(Path(SCRATCH) / 'state'),
                      HUISWERK_MINI_HOST='test@127.0.0.1')
    ok = True
    rc, b, a, r, n = run_case('good', package(b'# A\n## dag 1\nsynthetic a\n', b'# B\n## dag 1\nsynthetic b\n'), False)
    p = rc == 0 and b != a and r == 1 and n == 1
    ok &= p; print(f"case1 good: rc={rc} changed={b != a} retired+={r} restarts={n} -> {'PASS' if p else 'FAIL'}")
    good_sha = a
    rc, b, a, r, n = run_case('non-utf8', package(b'\xff\xfe\xfa bad', b'# B\n## x\nsynthetic\n'), False)
    p = rc == 1 and a == good_sha and r == 0 and n == 0
    ok &= p; print(f"case2 non-UTF-8: rc={rc} unchanged={a == good_sha} retired+={r} restarts={n} -> {'PASS' if p else 'FAIL'}")
    rc, b, a, r, n = run_case('restart-fail', package(b'# C\n## y\nsynthetic c\n', b'# D\n## y\nsynthetic d\n'), True)
    failed = sorted(x.name for d in vol.iterdir() if d.name.startswith('.retired-') for x in d.iterdir() if x.name.startswith('failed-'))
    p = rc == 1 and a == good_sha and n == 2 and failed == ['failed-huiswerk-profiel-2', 'failed-huiswerk-profiel-3']
    ok &= p; print(f"case3 restart failure: rc={rc} restored={a == good_sha} restarts={n} failed_kept={len(failed)} -> {'PASS' if p else 'FAIL'}")
    print('zeevaart untouched:', (vol / 'zeevaart' / 'x.md').read_text() == '# synthetic\n')
    print('ALL PASS' if ok else 'SOME FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
