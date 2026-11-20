# chg-2026-11-17-011 G4 helper, run INSIDE a hermes pod from stdin (never stored in the pod):
#   kubectl exec -i <pod> -c app -- /opt/hermes/.venv/bin/python -I - <cmd> [args] < hack/ops/chg-2026-11-17-011-g4-pod.py
# Prints ONE JSON line of fixed fields: numbers, flags, file names, sha256 prefixes. Never conversation text, never a
# "person" value, never the sticky stores, never the workspace id or a key. Commands:
#   state            ledger month/usd (+ p2/p3 person_usd numbers), off file present + its month/kind/status/type,
#                    "off_person_set" (bool only), cloud-off* names, deployed plugin + settings sha256, settings flags
#   seen             stat of cloud-off.json only (for the OTHER pod: is the shared off state visible there?)
#   import           load the deployed family-cloud module (the probe's loader) -> import ok + sha
#   trip             Argus G4 3a: trip_cloud_off(ledger, 'billing', 402, 'billing_error') with the DEPLOYED module
#                    (sha must be the pin), no person -> {"tripped": bool}
#   swap-prev <tag>  Argus G4 3e: mv cloud-off.json -> cloud-off.cleared-g4-<tag>.json (no delete, refuses to overwrite),
#                    then a synthetic off file for the PREVIOUS UTC month (create-if-absent, same fields as the plugin)
#   routes <t0> <t1> route records (route, rule) with t0 <= ts <= t1 from the plugin's route file
#   transitions <t0> 'to' (+ kind) of cloud-transitions.jsonl lines with ts >= t0 (no other field)
import datetime as dt
import hashlib
import importlib.util
import json
import os
import sys
import time
import types
from pathlib import Path

PIN = '99fb4183deb1793c4cecf3e2abece50e4375b37962f44fa53c358bf581c37496'
PLUGIN = Path(os.environ.get('G4_PLUGIN_DIR', '/opt/data/plugins/model-providers/family-cloud'))   # env: local tests only
LEDGER = Path(os.environ.get('CLOUD_SPEND_PATH', '/cloud-spend/month.json'))
DIR = LEDGER.parent
OFF = DIR / 'cloud-off.json'
ROUTES = Path(os.environ.get('FAMILY_CLOUD_ROUTE_FILE', '/opt/data/family-cloud-route.jsonl'))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load():
    if sha(PLUGIN / '__init__.py') != PIN:
        raise SystemExit(json.dumps({'error': 'deployed plugin is not the pin'}))
    try:
        import providers  # noqa: F401
    except ImportError:
        prov = types.ModuleType('providers'); prov.register_provider = lambda profile: None
        base = types.ModuleType('providers.base')
        base.ProviderProfile = type('ProviderProfile', (), {'__init__': lambda self, **kw: self.__dict__.update(kw)})
        sys.modules.setdefault('providers', prov); sys.modules.setdefault('providers.base', base)
    spec = importlib.util.spec_from_file_location('family_cloud_g4', PLUGIN / '__init__.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def state():
    out = {}
    try:
        d = json.loads(LEDGER.read_text())
        out.update(month=str(d['month']), usd=float(d['usd']), ledger_keys=sorted(d),
                   p2_usd=float((d.get('person_usd') or {}).get('profiel-2', 0)),
                   p3_usd=float((d.get('person_usd') or {}).get('profiel-3', 0)))
    except Exception as error:
        out.update(ledger_error=type(error).__name__)
    out['off'] = os.path.lexists(OFF)
    if out['off']:
        try:
            o = json.loads(OFF.read_text())
            out.update(off_month=o.get('month'), off_kind=o.get('kind'), off_status=o.get('status'),
                       off_type=o.get('type'), off_ts=o.get('ts'), off_person_set=o.get('person') is not None)
        except Exception as error:
            out.update(off_error=type(error).__name__)
    out['off_files'] = sorted(n for n in os.listdir(DIR) if n.startswith('cloud-off'))
    if PLUGIN.is_dir():
        out['plugin_sha'] = sha(PLUGIN / '__init__.py')
        try:
            s = json.loads((PLUGIN / 'settings.json').read_text())
            out.update(settings_sha=sha(PLUGIN / 'settings.json')[:16], budget_usd=s.get('budget_usd'),
                       price_confirmed=s.get('price_confirmed') is True,
                       workspace_ok=isinstance(s.get('workspace_id'), str) and s['workspace_id'].startswith('wrkspc_'),
                       school_keys=sorted(k for k in s if k.startswith('school_')))
        except Exception as error:
            out.update(settings_error=type(error).__name__)
    return out


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ''
    if cmd == 'state':
        print(json.dumps(state(), sort_keys=True))
    elif cmd == 'seen':
        try:
            OFF.stat(); seen = True
        except FileNotFoundError:
            seen = False
        print(json.dumps({'off_seen': seen}))
    elif cmd == 'import':
        m = load()
        print(json.dumps({'import': 'ok', 'has': [n for n in ('trip_cloud_off', 'run_probe', 'Router', 'log_route') if hasattr(m, n)]}))
    elif cmd == 'trip':
        if os.path.lexists(OFF):
            raise SystemExit(json.dumps({'error': 'off file already present: refusing to trip'}))
        m = load()
        print(json.dumps({'tripped': bool(m.trip_cloud_off(str(LEDGER), 'billing', 402, 'billing_error'))}))
    elif cmd == 'swap-prev':
        tag = argv[2]
        if not tag.replace('T', '').replace('Z', '').isdigit():
            raise SystemExit(json.dumps({'error': 'tag must be a UTC stamp'}))
        target = DIR / f'cloud-off.cleared-g4-{tag}.json'
        if os.path.lexists(target) or not os.path.isfile(OFF) or os.path.islink(OFF):
            raise SystemExit(json.dumps({'error': 'swap refused (target exists or no regular off file)'}))
        first = dt.datetime.now(dt.timezone.utc).replace(day=1)
        prev = (first - dt.timedelta(days=1)).strftime('%Y-%m')
        os.link(OFF, target)            # keep the real off file under its archive name first ...
        temp = DIR / f'cloud-off.json.g4.{os.getpid()}.new'
        with temp.open('x') as f:
            json.dump(dict(v=1, ts=round(time.time(), 3), month=prev, kind='billing', status=402, type='billing_error',
                           person=None), f)
            f.flush(); os.fsync(f.fileno())
        os.replace(temp, OFF)           # ... then replace it in one step: the state is never "absent" in between
        print(json.dumps({'swapped': True, 'archived_as': target.name, 'synthetic_month': prev}))
    elif cmd == 'routes':
        t0, t1 = float(argv[2]), float(argv[3])
        recs = []
        for path in (Path(str(ROUTES) + '.1'), ROUTES):
            try:
                for raw in path.read_text().splitlines():
                    try:
                        r = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and t0 <= float(r.get('ts', 0)) <= t1:
                        recs.append([str(r.get('route'))[:12], str(r.get('rule'))[:40]])
            except FileNotFoundError:
                pass
        print(json.dumps({'routes': recs}))
    elif cmd == 'transitions':
        t0 = float(argv[2]); out = []
        try:
            for raw in (DIR / 'cloud-transitions.jsonl').read_text().splitlines():
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(r, dict) and float(r.get('ts', 0)) >= t0:
                    out.append([str(r.get('to'))[:20], str(r.get('kind'))[:20]])
        except FileNotFoundError:
            pass
        print(json.dumps({'transitions': out}))
    else:
        raise SystemExit(json.dumps({'error': 'unknown command'}))


main(sys.argv)
