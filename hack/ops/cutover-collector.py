#!/usr/bin/env python3
"""cutover-collector: copy real cloud-cutover job actions from Loki into the change log.

chg-2026-11-17-011 / tsk-2026-10-17-005. Stdlib only.

Reads the JSON result lines of the family-ai cloud-cutover jobs (family-cloud-lock G5, family-cloud-alert G6,
family-cloud-probe G7) from Loki and appends ONE `executed` event per real action via ./ops/ops:
  lock_closed / lock_reopened  (family-cloud-lock: CNP created / removed; heartbeat present/absent is skipped)
  probe_called / probe_refused (family-cloud-probe result line)
  alert_sent                   (family-cloud-alert changelog line)
Drill pods (app *-drill, mode != prod, drill label) are never logged. Payload keys are a fixed whitelist; no free
text and no `person` field is ever copied. Idempotent: cursor = last processed ns timestamp, advanced per event.
First run without a cursor sets the cursor to now (no backfill).
"""
import datetime as dt
import glob
import json
import os
import subprocess
import sys
import urllib.parse
from pathlib import Path

CHG = 'chg-2026-11-17-011'
TSK = 'tsk-2026-10-17-005'
REPO = Path(os.environ.get('CUTOVER_REPO', '/Users/sheijden/Code/homelab-migration/vdhinfra'))
STATE = Path(os.environ.get('CUTOVER_STATE', str(Path.home() / '.local/state/cutover-collector')))
CURSOR = STATE / 'cursor'
STAMP = STATE / 'last-success'
QUERY = '{namespace="family-ai",app=~"family-cloud-(lock|alert|probe)"}'
LOKI = '/api/v1/namespaces/observability/services/loki:3100/proxy/loki/api/v1/query_range'
LIMIT = 5000
LOCK_TARGETS = ('family-cloud-lock', 'family-cloud-offgate')
LOCK_ACTIONS = {'created': 'lock_closed', 'removed': 'lock_reopened'}
REFUSED_CLASSES_PREFIX = ('pin_mismatch', 'bundle_', 'budget_over_cap', 'prepare_', 'no_result_line')
SAFE = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.')


def safe(value, n=40):
    if value is None:
        return None
    s = str(value)[:n]
    return s if s and set(s) <= SAFE else None


def kubectl():
    found = sorted(glob.glob(str(Path.home() / '.local/share/mise/installs/aqua-kubernetes-kubernetes-kubectl/*/kubectl')))
    return found[-1] if found else 'kubectl'


def loki(start_ns):
    q = urllib.parse.urlencode({'query': QUERY, 'limit': LIMIT, 'direction': 'forward', 'start': start_ns})
    out = subprocess.run([kubectl(), 'get', '--raw', f'{LOKI}?{q}'], capture_output=True, text=True, timeout=60)
    if out.returncode:
        raise RuntimeError('loki query failed: ' + out.stderr.strip()[:200])
    entries = []
    for stream in json.loads(out.stdout)['data']['result']:
        app = stream['stream'].get('app', '')
        for ns, line in stream['values']:
            entries.append((int(ns), app, line))
    entries.sort()
    return entries


def iso(ns):
    return dt.datetime.fromtimestamp(ns / 1e9, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def classify(app, line):
    """Return a list of whitelisted payload dicts (without tsk/ts) for real actions in this log line."""
    try:
        obj = json.loads(line)
    except ValueError:
        return []
    if not isinstance(obj, dict):
        return []
    found = []
    if app == 'family-cloud-lock' and isinstance(obj.get('family_cloud_lock'), dict):
        body = obj['family_cloud_lock']
        if body.get('mode') != 'prod':
            return []
        triggers = [t.get('t') for t in body.get('triggers') or [] if isinstance(t, dict)]
        trig = safe(triggers[0]) if triggers else None
        for target, result in sorted((body.get('actions') or {}).items()):
            if target in LOCK_TARGETS and result in LOCK_ACTIONS:
                item = {'job': 'lock', 'action': LOCK_ACTIONS[result], 'target': target}
                if trig:
                    item['trigger'] = trig
                found.append(item)
    elif app == 'family-cloud-alert' and isinstance(obj.get('changelog'), dict):
        body = obj['changelog']
        labels = body.get('labels') or {}
        if body.get('chg') == CHG and not (isinstance(labels, dict) and labels.get('drill')):
            name = safe(body.get('alert'), 60)
            if name and not name.startswith('Drill'):
                item = {'job': 'alert', 'action': 'alert_sent', 'alertname': name}
                sev = safe(body.get('severity'), 12)
                if sev:
                    item['severity'] = sev
                found.append(item)
    elif app == 'family-cloud-probe' and isinstance(obj.get('probe_run'), dict):
        body = obj['probe_run']
        result = safe(body.get('result'), 40)
        cls = safe(body.get('class'), 40)
        if result:
            refused = result == 'error' and cls and cls.startswith(REFUSED_CLASSES_PREFIX)
            item = {'job': 'probe', 'action': 'probe_refused' if refused else 'probe_called', 'result': result}
            if cls:
                item['class'] = cls
            if isinstance(body.get('status'), int):
                item['status'] = body['status']
            found.append(item)
    return found


def emit(payload):
    cmd = ['./ops/ops', 'change', 'event', CHG, 'executed', '--actor', 'infra-ops',
           '--payload-json', json.dumps(payload, separators=(',', ':'), sort_keys=True)]
    out = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=60)
    if out.returncode:
        raise RuntimeError('ops change event failed: ' + (out.stderr or out.stdout).strip()[:200])


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    now_ns = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1e9)
    if not CURSOR.exists():
        CURSOR.write_text(str(now_ns) + '\n')
        STAMP.write_text(iso(now_ns) + '\n')
        print(json.dumps({'cutover_collector': 'cursor initialised', 'cursor': now_ns}))
        return 0
    cursor = int(CURSOR.read_text().strip())
    events = 0
    newest = cursor
    for ns, app, line in loki(cursor + 1):
        if ns <= cursor:
            continue
        for item in classify(app, line):
            item.update({'tsk': TSK, 'ts': iso(ns), 'loki_ns': ns})
            emit(item)
            events += 1
        newest = ns
        CURSOR.write_text(str(newest) + '\n')   # per entry: a failure later never replays what is already logged
    STAMP.write_text(iso(now_ns) + '\n')
    print(json.dumps({'cutover_collector': 'ok', 'events': events, 'cursor': newest}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'cutover_collector': 'error', 'class': type(error).__name__, 'detail': str(error)[:200]}))
        sys.exit(1)
