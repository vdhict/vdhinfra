#!/usr/bin/env python3
"""G5 cloud egress lock (chg-2026-11-17-011, tsk-2026-10-17-005; Argus G5, Q4, D-L1, D-L2, D-I1).

Runs every 2 minutes (CronJob family-cloud-lock). Reads the shared ledger directory READ-ONLY and keeps two deny-only
CiliumNetworkPolicies in step with it. Deny beats allow in Cilium, so these close the cloud egress whatever the
Flux-managed *-cloud allow CNPs say, and Flux never prunes or re-opens them (they are not in its inventory).

  OFFGATE (family-cloud-offgate): present while cloud-off.json exists or cannot be read (fail closed). Selects the
           cloud profiles only (hermes-profiel-2/3), NOT the probe, so the 07:05 probe can still clear a monthly trip
           (Argus Q4). Removed automatically once the off file is gone. => egress to the cloud is open only while on.
  LOCK     (family-cloud-lock): LATCHED. Selects the cloud profiles AND the probe. Created on any of
           T1 a transition line {"to":"call_while_off"} newer than the last reopen (keyed on lines, D-I1);
           T2 the ledger usd rising while off by more than (probe Jobs since the baseline) x PROBE_MAX_COST_USD (D-L1;
              the ledger reserves before a call, so this does not depend on the plugin's own detector);
           T3 more than MAX_PROBES_PER_DAY probe Jobs created in one UTC day (D-L2);
           T0 cloud-transitions.jsonl exists but cannot be read (any error but "absent"): T1 is blind then, so the
              lock closes and the run exits non-zero (Argus F-B/F3, 21-11: a root-owned file made this reader raise
              PermissionError and the job exit BEFORE any deny was ensured = fail open).
           Never removed by a trigger going away. Reopen = a logged manual step: set data.reopen_ack_ts of the state
           ConfigMap to the current epoch (kubectl patch); the next run removes the lock if no trigger is newer.
A lock CNP found without a "locked" record in the state ConfigMap (e.g. left by the fail-safe below when the state
could not be saved) is adopted as latched, so the normal reopen_ack_ts path can remove it.
Fail-safe: any unexpected error in a run tries ensure(OFFGATE) and ensure(LOCK) (and records the latch) before exit 1.
Nothing here reads "person", conversation text or the sticky stores. Output: one JSON line per run (Loki), fixed fields.
DRILL mode (LOCK_MODE=drill) uses the same code on a synthetic state dir (DRILL_SEED), drill names and the drill pod
selector; it never opens /cloud-spend. A seed value "__UNREADABLE__" writes that file with mode 000 (the job runs as
uid 10000, not root, so it cannot read it back): the drill for T0.
"""
import datetime as dt
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

NS = os.environ.get('POD_NAMESPACE', 'family-ai')
MODE = os.environ.get('LOCK_MODE', 'prod')
if MODE == 'drill':
    STATE_DIR = Path('/tmp/drill-state')
    OFFGATE, LOCK, STATE_CM = 'family-cloud-offgate-drill', 'family-cloud-lock-drill', 'family-cloud-lock-drill-state'
    OFFGATE_SEL = LOCK_SEL = ['family-cloud-drill']
    PROBE_LABEL = 'family-cloud-probe-drill'
else:
    STATE_DIR = Path(os.environ.get('LEDGER_DIR', '/cloud-spend'))
    OFFGATE, LOCK, STATE_CM = 'family-cloud-offgate', 'family-cloud-lock', 'family-cloud-lock-state'
    OFFGATE_SEL = ['hermes-profiel-2', 'hermes-profiel-3']
    LOCK_SEL = ['hermes-profiel-2', 'hermes-profiel-3', 'family-cloud-probe']
    PROBE_LABEL = 'family-cloud-probe'
PROBE_MAX_COST_USD = 0.0001          # = family-cloud PROBE_MAX_COST_USD at b7b3a96
MAX_PROBES_PER_DAY = int(os.environ.get('MAX_PROBES_PER_DAY', '2'))
EPSILON = 1e-9
PRIVATE = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10']   # Studio 172.16.2.200 stays reachable
SA = Path('/var/run/secrets/kubernetes.io/serviceaccount')
API = 'https://%s:%s' % (os.environ.get('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc'),
                          os.environ.get('KUBERNETES_SERVICE_PORT', '443'))   # by IP: no DNS rule needed


# --- Kubernetes API (urllib, SA token) -------------------------------------------------------------------------------
def api(method, path, body=None, content_type='application/json'):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + (SA / 'token').read_text().strip())
    req.add_header('Accept', 'application/json')
    if data is not None:
        req.add_header('Content-Type', content_type)
    ctx = ssl.create_default_context(cafile=str(SA / 'ca.crt'))
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return resp.status, json.loads(resp.read() or b'{}')
    except urllib.error.HTTPError as error:
        return error.code, {}


def cnp_path(name=None):
    base = f'/apis/cilium.io/v2/namespaces/{NS}/ciliumnetworkpolicies'
    return base if name is None else f'{base}/{name}'


def deny_cnp(name, instances, reason, extra):
    return {
        'apiVersion': 'cilium.io/v2', 'kind': 'CiliumNetworkPolicy',
        'metadata': {'name': name, 'namespace': NS,
                     'labels': {'app.kubernetes.io/part-of': 'family-ai', 'app.kubernetes.io/managed-by': 'family-cloud-lock'},
                     'annotations': dict({'family-cloud/reason': reason,
                                          'family-cloud/since': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                                          'family-cloud/change': 'chg-2026-11-17-011'}, **extra)},
        'spec': {
            'endpointSelector': {'matchExpressions': [
                {'key': 'app.kubernetes.io/instance', 'operator': 'In', 'values': list(instances)}]},
            'enableDefaultDeny': {'egress': False, 'ingress': False},
            'egressDeny': [{'toCIDRSet': [{'cidr': '0.0.0.0/0', 'except': list(PRIVATE)}]}],
        },
    }


def ensure(name, instances, reason, extra=None):
    status, _ = api('GET', cnp_path(name))
    if status == 200:
        return 'present'
    status, _ = api('POST', cnp_path(), deny_cnp(name, instances, reason, extra or {}))
    if status not in (200, 201, 409):
        raise RuntimeError(f'create {name}: HTTP {status}')
    return 'created'


def remove(name):
    status, _ = api('DELETE', cnp_path(name))
    if status not in (200, 202, 404):
        raise RuntimeError(f'delete {name}: HTTP {status}')
    return 'removed' if status != 404 else 'absent'


def load_state():
    status, cm = api('GET', f'/api/v1/namespaces/{NS}/configmaps/{STATE_CM}')
    if status != 200:
        raise RuntimeError(f'state configmap {STATE_CM}: HTTP {status}')
    data = cm.get('data') or {}
    try:
        state = json.loads(data.get('state.json') or '{}')
    except ValueError:
        state = {}
    try:
        ack = float(data.get('reopen_ack_ts') or 0)   # the manual, logged reopen (own key, set with kubectl patch)
    except ValueError:
        ack = 0.0
    return state, ack


def save_state(state):
    body = {'data': {'state.json': json.dumps(state, sort_keys=True, separators=(',', ':'))}}
    status, _ = api('PATCH', f'/api/v1/namespaces/{NS}/configmaps/{STATE_CM}', body, 'application/merge-patch+json')
    if status != 200:
        raise RuntimeError(f'save state: HTTP {status}')


def probe_jobs():
    """Creation epochs of the probe Jobs (CronJob runs and manual runs from it carry the label)."""
    sel = urllib.parse.quote(f'app.kubernetes.io/name={PROBE_LABEL}')
    status, jobs = api('GET', f'/apis/batch/v1/namespaces/{NS}/jobs?labelSelector={sel}')
    if status != 200:
        raise RuntimeError(f'list jobs: HTTP {status}')
    out = []
    for job in jobs.get('items', []):
        stamp = job['metadata']['creationTimestamp']
        out.append(dt.datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp())
    return out


# --- Ledger directory (read-only) ------------------------------------------------------------------------------------
def off_info():
    """(off, off_ts): off True when cloud-off.json exists or cannot be stat'ed (fail closed). Only ts is read."""
    path = STATE_DIR / 'cloud-off.json'
    try:
        path.stat()
    except FileNotFoundError:
        return False, None
    except Exception:
        return True, None
    try:
        return True, float(json.loads(path.read_text())['ts'])
    except Exception:
        return True, None


def ledger():
    """(month, usd) of month.json, or (None, None) when unreadable."""
    try:
        data = json.loads((STATE_DIR / 'month.json').read_text())
        return str(data['month']), float(data['usd'])
    except Exception:
        return None, None


def call_while_off_lines(after_ts):
    """(hits, error): ts of every {"to":"call_while_off"} transition line newer than after_ts (only 'to' and 'ts' are
    read), and None or the error class name when the file exists but cannot be read (fail closed: T0). An absent file
    is not an error (no transition yet). A call_while_off line with an unparseable ts counts as a hit."""
    hits = []
    try:
        with (STATE_DIR / 'cloud-transitions.jsonl').open() as handle:
            for raw in handle:
                try:
                    line = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(line, dict) and line.get('to') == 'call_while_off':
                    try:
                        ts = float(line.get('ts', 0))
                    except (TypeError, ValueError):
                        ts = float('inf')
                    if ts > after_ts:
                        hits.append(ts)
    except FileNotFoundError:
        return [], None
    except Exception as error:
        return hits, type(error).__name__
    return hits, None


def seed_drill():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    seed = json.loads(os.environ.get('DRILL_SEED', '{}'))
    now = time.time()
    for name, content in seed.items():
        if '/' in name or name.startswith('.'):
            continue
        try:
            os.chmod(STATE_DIR / name, 0o600)      # a previous __UNREADABLE__ seed in the same dir (local tests)
        except FileNotFoundError:
            pass
        if content == '__UNREADABLE__':
            (STATE_DIR / name).write_text('')
            os.chmod(STATE_DIR / name, 0)
            continue
        text = content if isinstance(content, str) else json.dumps(content)
        (STATE_DIR / name).write_text(text.replace('"__NOW_MINUS_600__"', str(now - 600)).replace('"__NOW_MINUS_300__"', str(now - 300)))


def main():
    if MODE == 'drill':
        seed_drill()
    now = time.time()
    state, ack = load_state()
    off, off_ts = off_info()
    month, usd = ledger()
    if month is None:
        off = True   # an unreadable ledger is treated as off for the gate (the plugin refuses the cloud then too)
    today = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')
    jobs = probe_jobs()
    day_start = dt.datetime.strptime(today, '%Y-%m-%d').replace(tzinfo=dt.timezone.utc).timestamp()
    probes_today = sum(1 for t in jobs if t >= day_start)
    triggers = []

    # T0 + T1: call_while_off lines newer than the last reopen; an unreadable transitions log closes (T0).
    cwo, unreadable = call_while_off_lines(ack)
    if unreadable:
        triggers.append({'t': 'transitions_unreadable', 'class': unreadable})
    if cwo:
        triggers.append({'t': 'call_while_off', 'n': len(cwo), 'last_ts': max(cwo)})

    # T2: ledger rise while off. Baseline = ledger usd when this off episode was first seen (per month); an
    # acknowledged reopen re-baselines, so the rise that caused the lock does not re-lock by itself.
    ack_pending = bool(state.get('locked')) and ack > float(state['locked'].get('ts', 0))
    if off and usd is not None:
        key = f'{off_ts}|{month}'
        base = state.get('baseline') or {}
        if base.get('key') != key or ack_pending:
            state['baseline'] = base = {'key': key, 'usd': usd, 'since': now}
        probes_since = sum(1 for t in jobs if t >= float(base['since']) - 60)
        allowed = float(base['usd']) + probes_since * PROBE_MAX_COST_USD + EPSILON
        if usd > allowed:
            triggers.append({'t': 'ledger_rise_while_off', 'usd': round(usd, 6), 'allowed': round(allowed, 6)})
    elif not off:
        state.pop('baseline', None)

    # T3: more than MAX_PROBES_PER_DAY probe Jobs this UTC day (only those created after the last reopen count).
    probes_after_ack = sum(1 for t in jobs if t >= day_start and t > ack)
    if probes_after_ack > MAX_PROBES_PER_DAY:
        triggers.append({'t': 'probe_runs_per_day', 'n': probes_after_ack, 'max': MAX_PROBES_PER_DAY})

    actions = {}
    if triggers:
        first = triggers[0]['t']
        actions[LOCK] = ensure(LOCK, LOCK_SEL, first, {'family-cloud/triggers': json.dumps(triggers, separators=(',', ':'))})
        state['locked'] = {'ts': state.get('locked', {}).get('ts', now), 'triggers': triggers}
    elif ack_pending:
        actions[LOCK] = remove(LOCK)     # reopen: acknowledged after the lock and no trigger since the ack
        state['reopened'] = {'ts': now, 'ack': ack}
        state.pop('locked', None)
    elif state.get('locked'):
        actions[LOCK] = ensure(LOCK, LOCK_SEL, 'latched', {})   # latched until acknowledged, even if removed by hand
    elif exists(LOCK):
        # a lock CNP without a record (the fail-safe could not save state): adopt it as latched; reopen as usual
        state['locked'] = {'ts': now, 'triggers': [{'t': 'adopted_unrecorded_lock'}]}
        actions[LOCK] = 'adopted'
    if off:
        actions[OFFGATE] = ensure(OFFGATE, OFFGATE_SEL, 'cloud-off', {})
    else:
        actions[OFFGATE] = remove(OFFGATE)
    state['last_run'] = {'ts': now, 'off': off, 'probes_today': probes_today}
    save_state(state)
    print(json.dumps({'family_cloud_lock': {'mode': MODE, 'off': off, 'probes_today': probes_today,
                                            'triggers': triggers, 'actions': actions}}, sort_keys=True))
    return 3 if unreadable else 0    # closed, but the job must show red: the state needs a person (Argus F3)


def exists(name):
    status, _ = api('GET', cnp_path(name))
    if status not in (200, 404):
        raise RuntimeError(f'get {name}: HTTP {status}')
    return status == 200


def failsafe(error):
    """Argus F3: an unexpected error must not leave the egress open. Best effort, each step on its own: ensure the
    offgate and the lock, then record the latch so the usual reopen_ack_ts path applies. Never raises."""
    done = {}
    for name, sel in ((OFFGATE, OFFGATE_SEL), (LOCK, LOCK_SEL)):
        try:
            done[name] = ensure(name, sel, 'lock_error', {'family-cloud/error': type(error).__name__})
        except Exception as inner:
            done[name] = 'failed:' + type(inner).__name__
    try:
        state, _ = load_state()
        if not state.get('locked'):
            state['locked'] = {'ts': time.time(), 'triggers': [{'t': 'lock_error', 'class': type(error).__name__}]}
            save_state(state)
        done['state'] = 'latched'
    except Exception as inner:
        done['state'] = 'failed:' + type(inner).__name__
    return done


def run():
    try:
        return main()
    except Exception as error:
        done = failsafe(error)
        print(json.dumps({'family_cloud_lock': {'mode': MODE, 'error': type(error).__name__, 'detail': str(error)[:200],
                                                'failsafe': done}}, sort_keys=True))
        return 1


if __name__ == '__main__':
    sys.exit(run())
