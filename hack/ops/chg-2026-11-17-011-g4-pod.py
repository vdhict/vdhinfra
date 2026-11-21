# chg-2026-11-17-011 G4 helper, run INSIDE a hermes pod from stdin (never stored in the pod):
#   kubectl exec -i <pod> -c app -- /opt/hermes/.venv/bin/python -I - <cmd> [args] < hack/ops/chg-2026-11-17-011-g4-pod.py
# Prints ONE JSON line of fixed fields: numbers, flags, file names, sha256 prefixes. Never conversation text, never a
# "person" value, never the sticky stores, never the workspace id or a key. Commands:
#   state            ledger month/usd (+ p2/p3 person_usd numbers), off file present + its month/kind/status/type,
#                    "off_person_set" (bool only), cloud-off* names, deployed plugin + settings sha256, settings flags
#                    + "files": uid/gid/mode/type per cloud-* file and month.json (metadata only, lstat)
#   seen             AS UID 10000: open + parse cloud-off.json (for the OTHER pod: is the shared off state there AND
#                    readable by the service user?) -> off_present (lstat), off_readable, off_seen (= readable)
#   drop-check       AS UID 10000: proves the privilege drop works in this pod (uid/gid/groups, root not regainable);
#                    no file is opened
#   import           load the deployed family-cloud module (the probe's loader) -> import ok + sha
#   trip             AS UID 10000. Argus G4 3a: trip_cloud_off(ledger, 'billing', 402, 'billing_error') with the
#                    DEPLOYED module (sha must be the pin), no person -> {"tripped": bool}
#   swap-prev <tag>  AS UID 10000. Argus G4 3e: mv cloud-off.json -> cloud-off.cleared-g4-<tag>.json (no delete, refuses
#                    to overwrite), then a synthetic off file for the PREVIOUS UTC month (same fields as the plugin)
#   abort-archive <expected_off_ts> <tag>
#                    AS UID 10000. Argus F2/R1: undo an aborted G4 3a trip. Refuses unless cloud-off.json is a regular
#                    file owned by 10000 whose fields are EXACTLY the synthetic trip (v 1, billing / 402 / billing_error,
#                    person null, month == current UTC month, ts == expected_off_ts) and the transitions since that ts
#                    hold no call_while_off. Then hard-links it to cloud-off.aborted-g4-<tag>.json (refuses if that name
#                    exists) and unlinks only the cloud-off.json name. The bytes stay; no transition line is written.
# Write commands drop to the service user (uid/gid 10000, the user s6-setuidgid runs hermes as) BEFORE any open or
# module load: `kubectl exec` bypasses s6 and runs as root, and a root-owned shared file is unreadable for the lock and
# alert jobs (Argus F-A, 21-11). The container keeps CAP_SETUID/CAP_SETGID for s6, so a plain setgroups/setgid/setuid
# works; the drop is verified (euid/egid/groups == 10000, setuid(0) must fail) or the command refuses.
#   routes <t0> <t1> route records (route, rule) with t0 <= ts <= t1 from the plugin's route file
#   transitions <t0> 'to' (+ kind) of cloud-transitions.jsonl lines with ts >= t0 (no other field)
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import stat
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
TRANS = DIR / 'cloud-transitions.jsonl'
SERVICE_ID = 10000
# Local tests only: a non-root test runner cannot setuid, so it names its own uid as the "service user". Never 0.
EXPECT_ID = int(os.environ.get('G4_SERVICE_UID', SERVICE_ID))
TAG_RE = re.compile(r'^[0-9]{8}T[0-9]{6}Z$')
SYNTHETIC_KEYS = ['kind', 'month', 'person', 'status', 'ts', 'type', 'v']


def refuse(message):
    raise SystemExit(json.dumps({'error': message}))


def drop_to_service():
    """Become uid/gid EXPECT_ID before any open or load. Root drops (setgroups, setgid, setuid); a non-root caller must
    already be EXPECT_ID. Verified afterwards, and regaining root must fail. Refuses otherwise (nothing written)."""
    if EXPECT_ID == 0:
        refuse('service uid 0 is not allowed')
    if os.geteuid() == 0:
        try:
            os.setgroups([EXPECT_ID]); os.setgid(EXPECT_ID); os.setuid(EXPECT_ID)
        except OSError as error:
            refuse(f'privilege drop failed ({type(error).__name__})')
        try:
            os.setuid(0)
            refuse('privilege drop not permanent (setuid(0) succeeded)')
        except PermissionError:
            pass
    if os.environ.get('G4_SERVICE_UID'):    # local test runner: its own uid; its gid is whatever the OS gave it
        ok = [os.getuid(), os.geteuid()] == [EXPECT_ID] * 2
    else:                                   # in the pod: uid, gid and the supplementary groups are all 10000
        ok = [os.getuid(), os.geteuid(), os.getgid(), os.getegid()] == [EXPECT_ID] * 4 and set(os.getgroups()) <= {EXPECT_ID}
    if not ok:
        refuse(f'not running as the service user {EXPECT_ID} after the drop')
    os.umask(0o022)
    return {'uid': os.geteuid(), 'gid': os.getegid(), 'groups': sorted(os.getgroups())}


def meta(path):
    """uid/gid/mode/type of one name (lstat, metadata only, never the content)."""
    st = os.lstat(path)
    kind = 'reg' if stat.S_ISREG(st.st_mode) else 'lnk' if stat.S_ISLNK(st.st_mode) else 'dir' if stat.S_ISDIR(st.st_mode) else 'other'
    return {'uid': st.st_uid, 'gid': st.st_gid, 'mode': '%o' % stat.S_IMODE(st.st_mode), 'type': kind}


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
    files = {}
    for name in sorted(n for n in os.listdir(DIR) if n.startswith('cloud-') or n == LEDGER.name):
        try:
            files[name] = meta(DIR / name)
        except OSError as error:
            files[name] = {'error': type(error).__name__}
    out['files'] = files
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


def abort_archive(args):
    """Argus F2 / rerun R1: retire the off file of an ABORTED synthetic G4 trip under an archive name. Every check runs
    as the service user before the one write (a hard link), then only the cloud-off.json name is unlinked."""
    if len(args) != 2:
        refuse('usage: abort-archive <expected_off_ts> <tag>')
    try:
        expected = float(args[0])
    except ValueError:
        refuse('expected_off_ts must be a number')
    tag = args[1]
    if not TAG_RE.match(tag):
        refuse('tag must be a UTC stamp YYYYMMDDTHHMMSSZ')
    name = f'cloud-off.aborted-g4-{tag}.json'
    if name.startswith('cloud-off.cleared') or name == OFF.name:
        refuse('archive name not allowed')
    target = DIR / name
    drop_to_service()
    try:
        st = os.lstat(OFF)
    except FileNotFoundError:
        refuse('abort refused: no cloud-off.json')
    if not stat.S_ISREG(st.st_mode):
        refuse('abort refused: cloud-off.json is not a regular file')
    if st.st_uid != EXPECT_ID or st.st_nlink != 1:
        refuse('abort refused: cloud-off.json not owned by the service user or already linked elsewhere')
    if os.path.lexists(target):
        refuse('abort refused: archive name exists')
    try:
        fd = os.open(OFF, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            if os.fstat(fd).st_ino != st.st_ino:
                refuse('abort refused: cloud-off.json changed while checking')
            raw = b''
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                raw += chunk
        finally:
            os.close(fd)
        data = json.loads(raw)
    except SystemExit:
        raise
    except Exception as error:
        refuse(f'abort refused: cloud-off.json unreadable ({type(error).__name__})')
    month = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m')
    if not isinstance(data, dict) or sorted(data) != SYNTHETIC_KEYS:
        refuse('abort refused: off file keys are not the synthetic trip')
    if [data['v'], data['kind'], data['status'], data['type'], data['person'], data['month']] != [1, 'billing', 402, 'billing_error', None, month]:
        refuse('abort refused: off file fields are not the synthetic trip of this month')
    if isinstance(data['status'], bool) or isinstance(data['v'], bool) or not isinstance(data['ts'], (int, float)) or isinstance(data['ts'], bool):
        refuse('abort refused: off file field types')
    if float(data['ts']) != expected:
        refuse('abort refused: off ts is not the expected trip')
    try:
        lines = TRANS.read_text().splitlines()
    except Exception as error:
        refuse(f'abort refused: transitions unreadable ({type(error).__name__})')
    for raw_line in lines:
        try:
            rec = json.loads(raw_line)
        except ValueError:
            refuse('abort refused: a transitions line does not parse')
        if isinstance(rec, dict) and rec.get('to') == 'call_while_off':
            try:
                after = float(rec.get('ts', 0)) >= expected
            except (TypeError, ValueError):
                after = True                     # an unparseable time counts as "since the trip" (fail closed)
            if after:
                refuse('abort refused: call_while_off since the trip')
    os.link(OFF, target, follow_symlinks=False)          # FileExistsError if it appeared meanwhile: nothing changed
    if os.lstat(target).st_ino != st.st_ino or os.lstat(OFF).st_ino != st.st_ino:
        refuse('abort stopped after the link: inode mismatch (both names kept, nothing unlinked)')
    os.unlink(OFF)                                       # only the cloud-off.json name; the bytes live on as the archive
    return {'aborted': True, 'archived_as': name, 'off_now': os.path.lexists(OFF), 'archive_sha16': sha(target)[:16]}


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ''
    if cmd == 'state':
        print(json.dumps(state(), sort_keys=True))
    elif cmd == 'seen':
        who = drop_to_service()
        present = os.path.lexists(OFF); readable = False
        if present:
            try:
                readable = isinstance(json.loads(OFF.read_text()).get('ts'), (int, float))
            except Exception:
                readable = False
        print(json.dumps({'off_seen': readable, 'off_present': present, 'off_readable': readable, 'as_uid': who['uid']}))
    elif cmd == 'drop-check':
        who = drop_to_service()
        print(json.dumps(dict(who, drop='ok')))
    elif cmd == 'import':
        m = load()
        print(json.dumps({'import': 'ok', 'has': [n for n in ('trip_cloud_off', 'run_probe', 'Router', 'log_route') if hasattr(m, n)]}))
    elif cmd == 'trip':
        drop_to_service()
        if os.path.lexists(OFF):
            raise SystemExit(json.dumps({'error': 'off file already present: refusing to trip'}))
        m = load()
        print(json.dumps({'tripped': bool(m.trip_cloud_off(str(LEDGER), 'billing', 402, 'billing_error'))}))
    elif cmd == 'swap-prev':
        tag = argv[2] if len(argv) > 2 else ''
        if not TAG_RE.match(tag):
            refuse('tag must be a UTC stamp YYYYMMDDTHHMMSSZ')
        drop_to_service()
        target = DIR / f'cloud-off.cleared-g4-{tag}.json'
        if os.path.lexists(target) or not os.path.isfile(OFF) or os.path.islink(OFF):
            refuse('swap refused (target exists or no regular off file)')
        if os.lstat(OFF).st_uid != EXPECT_ID:
            refuse('swap refused (off file not owned by the service user)')
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
    elif cmd == 'abort-archive':
        print(json.dumps(abort_archive(argv[2:])))
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
