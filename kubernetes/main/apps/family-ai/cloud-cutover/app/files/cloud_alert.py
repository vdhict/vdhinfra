#!/usr/bin/env python3
"""G6 + C4 family-cloud transition alerts (chg-2026-11-17-011, tsk-2026-10-17-005; Argus G6, C4, D-F1, S-F5, S-F7, G7).

Runs every 5 minutes (CronJob family-cloud-alert). Reads the shared ledger directory READ-ONLY:
  cloud-transitions.jsonl  (only ts, to, kind, status, type, month, calls_while_off are read; "person" never is)
  cloud-off.json           (only ts, kind, status, type)
  cloud-probe-results.jsonl (written by the G7 wrapper)
and posts one Alertmanager alert per new transition. Routing is by labels (alertmanager-secret, chg-2026-11-20-021):
  severity=warning  -> team topic pka-team (p3 by day, p1 silent at night);
  severity=critical -> the owner (HA by day only via component=aiops-*, ntfy). Used for ONE thing only: a same_month_200
                       whose CURRENT off file is a billing trip (D-F1): type billing_error, or kind billing with status
                       400/402/429. 401/403 (key or permission) and repeated_unknown stay team items (manual reopen).
                       Day only: a money item found 23:00-07:00 is held and posted at the first run after 07:00.
                       MONEY_TO_OWNER=false (default) sends it as a team warning FamilyCloudMoneyCandidate instead, until
                       Atlas has checked the first real one against the grant's renewal day (Argus D-F1) and flips it in Git.
Dedupe: same_month_200 repeats daily for one off episode; one item per (off ts, month). Other lines: one per line.
First run: the cursor starts at "now"; history is never alerted. Per alert one JSON "changelog" line on stdout (Loki),
fixed fields only; Atlas's host-side collector turns those into ops/changes.jsonl lines.
Also: G7 probe result error (or ledger_unreadable, pin mismatch) on two UTC days running -> one team warning per day.
Fail closed on the inputs (Argus F-B/F3, 21-11): a transitions or probe-results file that exists but cannot be read (any
error but "absent") posts ONE team warning FamilyCloudStateUnreadable per UTC day and file (deduped in the state
ConfigMap), keeps the cursor where it is (nothing is skipped; the lines are alerted once the file is readable again) and
exits 1, so the job shows red. It never exits silently.
DRILL mode (ALERT_MODE=drill): synthetic state dir from DRILL_SEED, drill state ConfigMap, every alert is forced to
severity=warning with alertname Drill*, label drill=true and would_severity, so a drill never reaches the owner.
A seed value "__UNREADABLE__" writes that file with mode 000 (the job runs as uid 10000): the drill for the above.
"""
import datetime as dt
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

NS = os.environ.get('POD_NAMESPACE', 'family-ai')
MODE = os.environ.get('ALERT_MODE', 'prod')
DRILL = MODE == 'drill'
STATE_DIR = Path('/tmp/drill-state') if DRILL else Path(os.environ.get('LEDGER_DIR', '/cloud-spend'))
STATE_CM = 'family-cloud-alert-drill-state' if DRILL else 'family-cloud-alert-state'
MONEY_TO_OWNER = os.environ.get('MONEY_TO_OWNER', 'false') == 'true'
AM_HOST = os.environ.get('AM_HOST', 'alertmanager-operated.observability.svc.cluster.local')
AM_PORT = int(os.environ.get('AM_PORT', '9093'))
ALERT_HOURS = float(os.environ.get('ALERT_HOURS', '11'))   # < repeat_interval 12h: one firing push per item
LOCAL = ZoneInfo('Europe/Amsterdam')
OK_PROBE = ('not_off', 'cleared', 'refused', 'no_budget', 'same_month_200')
LINE_FIELDS = ('ts', 'to', 'kind', 'status', 'type', 'month', 'calls_while_off')
SA = Path('/var/run/secrets/kubernetes.io/serviceaccount')
API = 'https://%s:%s' % (os.environ.get('KUBERNETES_SERVICE_HOST', 'kubernetes.default.svc'),
                          os.environ.get('KUBERNETES_SERVICE_PORT', '443'))   # by IP: no DNS rule needed


def api(method, path, body=None, content_type='application/json'):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + (SA / 'token').read_text().strip())
    if data is not None:
        req.add_header('Content-Type', content_type)
    ctx = ssl.create_default_context(cafile=str(SA / 'ca.crt'))
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return resp.status, json.loads(resp.read() or b'{}')
    except urllib.error.HTTPError as error:
        return error.code, {}


def load_state():
    status, cm = api('GET', f'/api/v1/namespaces/{NS}/configmaps/{STATE_CM}')
    if status != 200:
        raise RuntimeError(f'state configmap {STATE_CM}: HTTP {status}')
    try:
        return json.loads((cm.get('data') or {}).get('state.json') or '{}')
    except ValueError:
        return {}


def save_state(state):
    body = {'data': {'state.json': json.dumps(state, sort_keys=True, separators=(',', ':'))}}
    status, _ = api('PATCH', f'/api/v1/namespaces/{NS}/configmaps/{STATE_CM}', body, 'application/merge-patch+json')
    if status != 200:
        raise RuntimeError(f'save state: HTTP {status}')


def clean(record, fields):
    """Copy only the allowed scalar fields; never 'person', never text."""
    out = {}
    for key in fields:
        value = record.get(key)
        if isinstance(value, bool) or value is None:
            continue
        if isinstance(value, (int, float)):
            out[key] = value
        elif isinstance(value, str):
            out[key] = value[:40]
    return out


class Unreadable(Exception):
    """A state file exists but cannot be read (anything but FileNotFoundError)."""
    def __init__(self, name, error):
        super().__init__(f'{name}: {type(error).__name__}')
        self.name, self.cls = name, type(error).__name__


def read_lines(name):
    """All JSON-object lines of one state file; [] when the file is absent; raises Unreadable on any other error.
    Read fully before anything is alerted, so a read error half-way never posts a partial set."""
    out = []
    try:
        with (STATE_DIR / name).open() as handle:
            for raw in handle:
                try:
                    line = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(line, dict):
                    out.append(line)
    except FileNotFoundError:
        return []
    except Exception as error:
        raise Unreadable(name, error) from None
    return out


def current_off():
    try:
        return clean(json.loads((STATE_DIR / 'cloud-off.json').read_text()), ('ts', 'kind', 'status', 'type'))
    except Exception:
        return None


def is_money(off):
    """D-F1: a billing trip, not a key/permission trip and not repeated_unknown."""
    if not off or off.get('kind') != 'billing':
        return False
    return off.get('type') == 'billing_error' or off.get('status') in (400, 402, 429)


def _newer(off, ts):
    try:
        return float(off.get('ts')) > ts
    except (TypeError, ValueError):
        return False


def episode_off(transitions, ts):
    """F7-b: cloud-off.json can be gone (driver swap) before this run sees a same_month_200 line. Rebuild the off state
    from the newest earlier 'off' transition that is not itself a same_month_200 (the trip that opened the episode).
    An 'on' transition closes the episode: no trip is then known (None -> NotMoney, never a false money alert).
    The ts keeps its original type so the dedupe key equals the one built from the off file."""
    rows = []
    for raw in transitions:
        line = clean(raw, LINE_FIELDS)
        try:
            lts = float(line.get('ts', 0))
        except (TypeError, ValueError):
            continue
        if lts <= ts:
            rows.append((lts, line))
    best = None
    for _, line in sorted(rows, key=lambda r: r[0]):
        if line.get('to') == 'on':
            best = None
        elif line.get('to') == 'off' and line.get('kind') != 'same_month_200':
            best = {'ts': line.get('ts'), **{k: line[k] for k in ('kind', 'status', 'type') if k in line}}
    return best


def daytime(now):
    hour = dt.datetime.fromtimestamp(now, LOCAL).hour
    return 7 <= hour < 23


def am_targets():
    try:
        return sorted({info[4][0] for info in socket.getaddrinfo(AM_HOST, AM_PORT, socket.AF_INET, socket.SOCK_STREAM)})
    except OSError:
        return []


def post(alerts):
    """POST to every Alertmanager replica (alerts are not gossiped). True if at least one accepted."""
    if not alerts:
        return True
    body = json.dumps(alerts).encode()
    accepted = 0
    for ip in am_targets():
        req = urllib.request.Request(f'http://{ip}:{AM_PORT}/api/v2/alerts', data=body, method='POST')
        req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                accepted += resp.status == 200
        except Exception:
            pass
    return accepted > 0


def alert(name, severity, summary, labels, now):
    ends = dt.datetime.fromtimestamp(now + ALERT_HOURS * 3600, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    lab = {'alertname': name, 'severity': severity, 'namespace': NS, 'component': 'aiops-family-cloud'}
    lab.update({k: str(v) for k, v in labels.items()})
    if DRILL:
        lab['would_severity'] = severity
        lab.update(alertname='Drill' + name, severity='warning', drill='true')
        summary = 'DRILL (synthetic, ignore): ' + summary
    return {'labels': lab, 'annotations': {'summary': summary}, 'endsAt': ends}


def seed_drill():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    now = time.time()
    for name, content in json.loads(os.environ.get('DRILL_SEED', '{}')).items():
        if '/' in name or name.startswith('.'):
            continue
        text = content if isinstance(content, str) else json.dumps(content)
        try:
            os.chmod(STATE_DIR / name, 0o600)      # a previous __UNREADABLE__ seed in the same dir (local tests)
        except FileNotFoundError:
            pass
        if content == '__UNREADABLE__':
            (STATE_DIR / name).write_text('')
            os.chmod(STATE_DIR / name, 0)
            continue
        for minus in (900, 600, 300, 120, 60):
            text = text.replace(f'"__NOW_MINUS_{minus}__"', str(now - minus))
        (STATE_DIR / name).write_text(text)


def main():
    if DRILL:
        seed_drill()
    now = time.time()
    state = load_state()
    if 'cursor_ts' not in state:
        state['cursor_ts'] = 0 if DRILL else now   # prod: never alert history
        if not DRILL:
            save_state(state)
            print(json.dumps({'family_cloud_alert': {'mode': MODE, 'bootstrap': True}}))
            return 0
    cursor = float(state['cursor_ts'])
    keys = state.setdefault('dedupe', [])
    pending = state.setdefault('pending_money', [])
    off_file = current_off()
    off = off_file
    out, log = [], []
    newest = cursor

    try:
        transitions = read_lines('cloud-transitions.jsonl')
        probe_results = read_lines('cloud-probe-results.jsonl')
    except Unreadable as error:
        return unreadable(state, error, now)
    if state.pop('unreadable', None) is not None:
        log.append({'unreadable': 'recovered'})

    for raw in transitions:
        line = clean(raw, LINE_FIELDS)
        ts = float(line.get('ts', 0))
        if ts <= cursor:
            continue
        newest = max(newest, ts)
        to, kind = line.get('to'), line.get('kind')
        lab = {k: line[k] for k in ('kind', 'status', 'type') if k in line}
        if to == 'off' and kind == 'same_month_200':
            # R-1: the transitions are the record of the episode this line belongs to; the off file only holds the
            # NEWEST trip (a backlog off->on->off moves it past this line), so it is a fallback, and only when it is
            # not newer than the line.
            off = episode_off(transitions, ts)
            if off is None and off_file and not _newer(off_file, ts):
                off = off_file
            key = f"{(off or {}).get('ts')}|{line.get('month')}"
            if key in keys:
                log.append({'line': 'same_month_200', 'deduped': True})
                continue
            keys.append(key)
            okind = {f'off_{k}': off[k] for k in ('kind', 'status', 'type') if off and k in off}
            if is_money(off):
                summary = ('family-cloud: a paid 200 in the SAME month as a billing cut-off: money appeared '
                           '(card, bought credit or auto-reload). Cloud stays off. Check the console.')
                if MONEY_TO_OWNER:
                    item = alert('FamilyCloudMoneyReopen', 'critical', summary, okind, now)
                    if daytime(now) or DRILL:
                        out.append(item)
                    else:
                        pending.append(item)
                        log.append({'line': 'same_month_200', 'money': True, 'held_until_day': True})
                else:
                    out.append(alert('FamilyCloudMoneyCandidate', 'warning',
                                     summary + ' Team: check against the grant renewal day before the owner route '
                                     'is switched on (MONEY_TO_OWNER).', okind, now))
            else:
                out.append(alert('FamilyCloudSameMonth200NotMoney', 'warning',
                                 'family-cloud: 200 in the same month, but the off state is a key/permission or '
                                 'repeated_unknown trip (not money). Manual, logged reopen per runbook.', okind, now))
        elif to == 'off':
            what = 'key or billing' if kind == 'billing' else 'repeated unknown 4xx'
            out.append(alert('FamilyCloudOff', 'warning', f'family-cloud switched OFF ({what}); turns go to the Studio.',
                             lab, now))
        elif to == 'on':
            out.append(alert('FamilyCloudOn', 'warning', 'family-cloud switched ON again by the daily probe.', lab, now))
        elif to == 'call_while_off':
            out.append(alert('FamilyCloudCallWhileOff', 'warning',
                             'family-cloud: a cloud call went out while OFF; the G5 lock closes the egress.',
                             {'calls_while_off': line.get('calls_while_off', '')}, now))

    # G7: probe result error on two UTC days running.
    per_day = {}
    for raw in probe_results:
        line = clean(raw, ('ts', 'day', 'result', 'class'))
        if 'day' in line:
            per_day[line['day']] = line
    days = sorted(per_day)[-2:]
    if (len(days) == 2 and all(per_day[d].get('result') not in OK_PROBE for d in days)
            and state.get('probe_err_day') != days[-1]):
        d0 = dt.date.fromisoformat(days[0])
        if dt.date.fromisoformat(days[1]) - d0 == dt.timedelta(days=1):
            state['probe_err_day'] = days[-1]
            out.append(alert('FamilyCloudProbeError2d', 'warning', 'family-cloud probe failed two days running.',
                             {'probe_class': per_day[days[-1]].get('class', per_day[days[-1]].get('result'))}, now))

    if pending and (daytime(now) or DRILL):
        out.extend(pending)
        state['pending_money'] = pending = []

    if not post(out):
        raise RuntimeError('no Alertmanager replica accepted the alerts')
    state['cursor_ts'] = newest
    state['dedupe'] = keys[-50:]
    save_state(state)
    for item in out:
        print(json.dumps({'changelog': {'chg': 'chg-2026-11-17-011', 'alert': item['labels']['alertname'],
                                        'severity': item['labels']['severity'],
                                        'labels': {k: v for k, v in item['labels'].items()
                                                   if k in ('kind', 'status', 'type', 'off_kind', 'off_status',
                                                            'off_type', 'would_severity', 'drill')}}},
                         sort_keys=True))
    print(json.dumps({'family_cloud_alert': {'mode': MODE, 'posted': len(out), 'pending_money': len(pending),
                                             'notes': log, 'money_to_owner': MONEY_TO_OWNER}}, sort_keys=True))
    return 0


def unreadable(state, error, now):
    """Argus F3: one team warning per UTC day and file, the cursor untouched, exit 1. A failed post is not recorded,
    so the next run tries again."""
    day = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime('%Y-%m-%d')
    seen = state.get('unreadable') or {}
    key = f'{error.name}|{day}'
    posted = 0
    if key not in (seen.get('keys') or []):
        item = alert('FamilyCloudStateUnreadable', 'warning',
                     f'family-cloud: {error.name} exists but cannot be read ({error.cls}). The G5 call_while_off check '
                     'and the transition alerts are blind; the lock job closes the egress. Check owner/mode on '
                     '/cloud-spend (must be 10000).', {'file': error.name, 'class': error.cls}, now)
        if post([item]):
            posted = 1
            state['unreadable'] = {'keys': ((seen.get('keys') or []) + [key])[-10:], 'since': seen.get('since', now)}
            try:
                save_state(state)
            except Exception:
                pass
            print(json.dumps({'changelog': {'chg': 'chg-2026-11-17-011', 'alert': item['labels']['alertname'],
                                            'severity': item['labels']['severity'],
                                            'labels': {k: v for k, v in item['labels'].items()
                                                       if k in ('file', 'class', 'would_severity', 'drill')}}},
                             sort_keys=True))
    print(json.dumps({'family_cloud_alert': {'mode': MODE, 'error': 'state_unreadable', 'file': error.name,
                                             'class': error.cls, 'posted': posted, 'deduped': posted == 0 and key in (seen.get('keys') or []),
                                             'money_to_owner': MONEY_TO_OWNER}}, sort_keys=True))
    return 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'family_cloud_alert': {'mode': MODE, 'error': type(error).__name__, 'detail': str(error)[:200]}}))
        sys.exit(1)
