#!/usr/bin/env python3
"""G7 wrapper around the wire's bin/cloud-probe (chg-2026-11-17-011, tsk-2026-10-17-005; Argus G3/G7, D-L4).

Runs ONCE per Job (CronJob family-cloud-probe, backoffLimit 0, restartPolicy Never). Before any cloud call:
  1. the profile bundle (Secret family-ai-hermes-profiel-bundle-3) passes the same sha256 check as seed-once.sh;
  2. ONLY plugins/model-providers/family-cloud/__init__.py and settings.json are taken out of it (exact member names,
     regular files only) into an emptyDir;
  3. __init__.py and /probe/cloud-probe must equal the pinned wire blobs (PIN_INIT_SHA256 / PIN_PROBE_SHA256): G3 on the
     probe job, fail-closed (no call on a mismatch);
  4. settings.json budget_usd must be a number <= MAX_BUDGET_USD (Argus C2: rendered 99).
Then it runs cloud-probe against the real shared ledger and reads its JSON result line (never the exit code alone):
  not_off | cleared | refused | no_budget | same_month_200 -> exit 0 (the state machine worked; refused is the normal
  end-of-month state, so no KubeJobFailed noise); error | ledger_unreadable | anything else -> exit 4 (Job Failed).
Every run appends one line to <ledger dir>/cloud-probe-results.jsonl: {ts, day, result, status, class}. Fixed fields
only, no text, no person; the alert job reads it ("error two days running" -> team alert).
"""
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import time
from pathlib import Path

BUNDLE = Path(os.environ.get('PROBE_BUNDLE_DIR', '/bundle'))
PLUGIN_DIR = Path(os.environ.get('PROBE_PLUGIN_DIR', '/plugin'))
PROBE = Path(os.environ.get('PROBE_BIN', '/probe/cloud-probe'))
STATE = Path(os.environ.get('PROBE_STATE', '/cloud-spend/month.json'))
PIN_INIT = os.environ['PIN_INIT_SHA256']
PIN_PROBE = os.environ['PIN_PROBE_SHA256']
MAX_BUDGET = float(os.environ.get('MAX_BUDGET_USD', '99'))
PYTHON = os.environ.get('PROBE_PYTHON', '/opt/hermes/.venv/bin/python')
MEMBERS = {'plugins/model-providers/family-cloud/__init__.py': '__init__.py',
           'plugins/model-providers/family-cloud/settings.json': 'settings.json'}
OK_RESULTS = ('not_off', 'cleared', 'refused', 'no_budget', 'same_month_200')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def record(result):
    line = {'ts': round(time.time(), 3), 'day': time.strftime('%Y-%m-%d', time.gmtime()),
            'result': str(result.get('result', 'error'))[:40]}
    for key in ('status', 'class'):
        if isinstance(result.get(key), (int, str)):
            line[key] = result[key] if isinstance(result[key], int) else str(result[key])[:40]
    try:
        fd = os.open(STATE.parent / 'cloud-probe-results.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
        try:
            os.write(fd, (json.dumps(line, separators=(',', ':')) + '\n').encode())
        finally:
            os.close(fd)
    except Exception as error:   # the result line on stdout still carries it
        print(json.dumps({'warning': 'results file not written', 'class': type(error).__name__}))
    return line


def refuse(cls):
    line = record({'result': 'error', 'class': cls})
    print(json.dumps({'probe_run': line}, sort_keys=True))
    return 4


def prepare():
    want = (BUNDLE / 'bundle.tar.gz.sha256').read_text().split()[0]
    if sha256(BUNDLE / 'bundle.tar.gz') != want:
        return 'bundle_sha_mismatch'
    PLUGIN_DIR.mkdir(parents=True, exist_ok=True)
    found = set()
    with tarfile.open(BUNDLE / 'bundle.tar.gz', 'r:gz') as tar:
        for member in tar.getmembers():
            name = member.name[2:] if member.name.startswith('./') else member.name
            if name not in MEMBERS:
                continue
            if not member.isreg() or name in found:
                return 'bundle_member_refused'
            data = tar.extractfile(member).read()
            (PLUGIN_DIR / MEMBERS[name]).write_bytes(data)
            found.add(name)
    if found != set(MEMBERS):
        return 'bundle_member_missing'
    if sha256(PLUGIN_DIR / '__init__.py') != PIN_INIT:
        return 'pin_mismatch_plugin'
    if sha256(PROBE) != PIN_PROBE:
        return 'pin_mismatch_probe'
    budget = json.loads((PLUGIN_DIR / 'settings.json').read_text()).get('budget_usd')
    if type(budget) not in (int, float) or not 0 < budget <= MAX_BUDGET:
        return 'budget_over_cap'
    return None


def main():
    try:
        problem = prepare()
    except Exception as error:
        problem = 'prepare_' + type(error).__name__
    if problem:
        return refuse(problem)
    print(json.dumps({'probe_run': 'pins ok', 'plugin_sha256': PIN_INIT[:16], 'probe_sha256': PIN_PROBE[:16]}))
    if os.environ.get('PROBE_CHECK_ONLY') == '1':   # drill: everything up to the call, no call
        print(json.dumps({'probe_run': 'check only, no call'}))
        return 0
    proc = subprocess.run([PYTHON, '-I', str(PROBE), '--plugin-dir', str(PLUGIN_DIR), '--state', str(STATE)],
                          capture_output=True, text=True, timeout=120, env=dict(os.environ))
    result = None
    for line in reversed(proc.stdout.strip().splitlines()):
        try:
            candidate = json.loads(line)
        except ValueError:
            continue
        if isinstance(candidate, dict) and 'result' in candidate:
            result = candidate
            break
    if proc.stderr:   # class names only; cloud-probe never prints the key, keep stderr out of the log anyway
        print(json.dumps({'probe_stderr_lines': len(proc.stderr.splitlines())}))
    if result is None:
        return refuse('no_result_line_exit_%d' % proc.returncode)
    line = record(result)
    print(json.dumps({'probe_run': line, 'probe_exit': proc.returncode}, sort_keys=True))
    return 0 if line['result'] in OK_RESULTS else 4


if __name__ == '__main__':
    sys.exit(main())
