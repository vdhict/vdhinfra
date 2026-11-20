#!/usr/bin/env python3
"""G9 v2 go gate for chg-2026-11-17-011 (tsk-2026-10-17-005), Atlas's vdhinfra side of Argus C2 (verdict
argus-golive-g9g3-79df378-20261120T180406Z, conditions 2 + 3). Read-only, no network, python -I. Prints only verdict
lines, names and hash prefixes; never a bundle file's content, never the workspace id ("ok" only).

  chg-2026-11-17-011-g9gate.py --changes ops/changes.jsonl --evidence-dir ops/evidence/chg-2026-11-17-011 \
      --g4-event <ts> --cloud-bundle profiel-3=<bundle.tar.gz> --local-bundle profiel-1=<..> --local-bundle profiel-4=<..> \
      (--local-bundle profiel-2=<..> | --dormant-bundle profiel-2=<..> --dormant-ack <ts>) [--now <iso>]

Exactly one line "GATE GREEN (g1)" and rc 0 when every rule holds; otherwise "GATE RED: <reason>" and rc 1
(argument errors: rc 2). There is no path A (W2): for this change only (g1) exists (C2 e).

 a  The G4 event: exactly one change-log line on chg-2026-11-17-011 at --g4-event; event validated, actor infra-ops,
    top-level keys {actor, chg, event, payload, ts}; payload keys EXACTLY Argus Q1's set; tsk, step G4, g4 green;
    checks = exactly the six names, each JSON true; plugin/probe sha = the pins; plugin sha = the --cloud-bundle's
    family-cloud/__init__.py; p3_bundle_sha256 = sha256 of the --cloud-bundle (the go bundle is the one the canary ran
    on, not a dark one); the evidence file lies directly in --evidence-dir (realpath, no symlink) and its sha256 =
    evidence_sha256; no "person" anywhere in the line; no rolled_back on the chg at or after it; 0 <= age <= 24 h.
 b  The G1 pointer is exactly g1-evidence-pointer-20261118T162823Z.json, the ONLY g1-evidence-pointer-* file in the
    dir, a regular file (no symlink); org_monthly_limit_usd a finite number 0 < n <= 200 (ar-019); payment_method
    exactly "none" or "present (...". No billing_change event since 2026-11-18.
 c  Bundles by explicit role, all four profiles, each once. Cloud = profiel-3 only: family-cloud present, plugin =
    PIN_INIT, settings budget_usd finite 0 < n <= 99, price_confirmed true, workspace_id wrkspc_[A-Za-z0-9]+,
    endpoint the pinned API, no school_*_cloud keys (school mode off, C1). Local: no family-cloud member and no
    "family-cloud" in config.yaml.
    Dormant (profiel-2 only; Heph's proposal, NOT in Argus' text, refused unless Argus acknowledged it): live p2
    carries the PRE-signal family-cloud plugin (Argus Q3 B1, condition 4) and therefore fails the "local" rule.
    Dormant requires family-cloud/__init__.py == PRE_SIGNAL exactly (never the signal pin) AND --dormant-ack <ts>
    pointing at a qa_passed line by security-engineer on this chg with payload.dormant_p2 == "accepted". The driver
    separately proves p2 has no cloud CNP and cannot reach the API.
 d  --now only with GOLIVE_TEST=1 (tests). argparse: no hang on a dangling flag (rc 2).
"""
import argparse
import datetime as dt
import glob
import gzip
import hashlib
import io
import json
import math
import os
import re
import sys
import tarfile

CHG = 'chg-2026-11-17-011'
TSK = 'tsk-2026-10-17-005'
PIN_INIT = '99fb4183deb1793c4cecf3e2abece50e4375b37962f44fa53c358bf581c37496'
PIN_PROBE = 'f1d9aed6b482808cc72217803e603e2b58b4f581a2c7c362ba259f4fc2e6bba7'
PRE_SIGNAL = '82fafe60ce93a8173f600fb095fb47a2f63ae2ca370a2d301dc6a33b09b757ae'
POINTER = 'g1-evidence-pointer-20261118T162823Z.json'
BILLING_SINCE = '2026-11-18T00:00:00Z'
ENDPOINT = 'https://api.anthropic.com/v1'
FC = 'plugins/model-providers/family-cloud/'
PAYLOAD_KEYS = {'tsk', 'step', 'g4', 'evidence', 'evidence_sha256', 'plugin_sha256', 'probe_sha256',
                'p3_bundle_sha256', 'checks'}
CHECK_KEYS = {'off_visible_other_pod', 'turn_cloud_off', 'offgate_followed', 'probe_same_month_200',
              'probe_cleared_prev_month', 'alert_team_only'}
EVIDENCE_RE = re.compile(r'ops/evidence/chg-2026-11-17-011/(g4-canary-[0-9]{8}T[0-9]{6}Z\.txt)')
TS_RE = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z')
HEX64 = re.compile(r'[0-9a-f]{64}')
WORKSPACE_RE = re.compile(r'wrkspc_[A-Za-z0-9]+')


class Red(Exception):
    pass


def need(cond, why):
    if not cond:
        raise Red(why)


def is_num(v):
    return type(v) in (int, float) and math.isfinite(v)


def parse_ts(s):
    need(isinstance(s, str) and TS_RE.fullmatch(s), 'timestamp not YYYY-MM-DDTHH:MM:SSZ')
    return dt.datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def regular_file_in(directory, name):
    """Path of `name` directly in `directory`: not a symlink, a regular file, realpath parent == realpath dir."""
    need('/' not in name and name not in ('', '.', '..'), f'{name}: not a plain file name')
    path = os.path.join(directory, name)
    need(os.path.lexists(path), f'{name}: missing')
    need(not os.path.islink(path), f'{name}: is a symlink')
    need(os.path.isfile(path), f'{name}: not a regular file')
    need(os.path.dirname(os.path.realpath(path)) == os.path.realpath(directory), f'{name}: not directly in the dir')
    return path


def read_changes(path):
    events = []
    with open(path, 'rb') as handle:
        for n, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                raise Red(f'changes line {n} is not JSON')
            need(isinstance(e, dict), f'changes line {n} is not an object')
            events.append((raw, e))
    return events


def bundle(path):
    """(sha256 of the tar.gz bytes, {member name: bytes}) - regular files only, no links, no absolute/.. paths."""
    with open(path, 'rb') as handle:
        raw = handle.read()
    need(len(raw) > 0, f'{path}: empty bundle')
    try:
        tar = tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw)), mode='r:')
        members = {}
        for m in tar.getmembers():
            name = m.name[2:] if m.name.startswith('./') else m.name
            need(not name.startswith('/') and '..' not in name.split('/'), 'bundle member path refused')
            if m.isdir():
                continue
            need(m.isreg(), 'bundle member that is not a regular file')
            need(name not in members, 'duplicate bundle member')
            members[name] = tar.extractfile(m).read()
    except Red:
        raise
    except Exception as error:
        raise Red(f'bundle unreadable ({type(error).__name__})')
    return hashlib.sha256(raw).hexdigest(), members


def check_cloud(members):
    init, sett = members.get(FC + '__init__.py'), members.get(FC + 'settings.json')
    need(init is not None and sett is not None, 'cloud bundle profiel-3 has no family-cloud plugin')
    need(hashlib.sha256(init).hexdigest() == PIN_INIT, 'cloud bundle family-cloud/__init__.py != pin 99fb4183')
    try:
        s = json.loads(sett)
    except ValueError:
        raise Red('cloud settings.json not JSON')
    need(isinstance(s, dict), 'cloud settings.json not an object')
    need(is_num(s.get('budget_usd')) and 0 < s['budget_usd'] <= 99, 'cloud budget_usd not a finite number in (0, 99]')
    need(s.get('price_confirmed') is True, 'cloud price_confirmed is not true')
    need(isinstance(s.get('workspace_id'), str) and WORKSPACE_RE.fullmatch(s['workspace_id']), 'cloud workspace_id not ok')
    need(s.get('endpoint') == ENDPOINT, 'cloud endpoint is not the pinned API')
    need(not any(k in s for k in ('school_context_cloud', 'school_attachments_cloud')), 'school mode keys present (C1: off)')
    return 'cloud profiel-3: plugin 99fb4183, budget_usd %s, price_confirmed true, workspace ok' % s['budget_usd']


def check_local(name, members):
    need(not any(m.startswith(FC) or '/family-cloud/' in m for m in members), f'local bundle {name} has family-cloud')
    need(b'family-cloud' not in members.get('config.yaml', b''), f'local bundle {name} config names family-cloud')
    return f'local {name}: no family-cloud'


def check_dormant(name, members, events, ack_ts):
    need(name == 'profiel-2', 'dormant role is for profiel-2 only')
    need(ack_ts is not None, 'profiel-2 carries family-cloud; dormant role needs --dormant-ack (Argus)')
    acks = [e for _, e in events if e.get('chg') == CHG and e.get('ts') == ack_ts]
    need(len(acks) == 1, 'dormant ack: not exactly one change-log line at --dormant-ack')
    a = acks[0]
    need(a.get('event') == 'qa_passed' and a.get('actor') == 'security-engineer'
         and isinstance(a.get('payload'), dict) and a['payload'].get('dormant_p2') == 'accepted',
         'dormant ack is not a security-engineer qa_passed with dormant_p2 accepted')
    init = members.get(FC + '__init__.py')
    need(init is not None, 'dormant profiel-2 without family-cloud: use --local-bundle')
    sha = hashlib.sha256(init).hexdigest()
    need(sha != PIN_INIT, 'dormant profiel-2 carries the SIGNAL plugin: it is a cloud bundle, refused')
    need(sha == PRE_SIGNAL, 'dormant profiel-2 family-cloud is not the known pre-signal 82fafe60')
    return 'dormant profiel-2: pre-signal 82fafe60 (acknowledged %s)' % ack_ts


def role_args(values, role):
    out = []
    for v in values or []:
        name, sep, path = v.partition('=')
        need(sep == '=' and re.fullmatch(r'profiel-[1-4]', name) and path, f'--{role}-bundle must be profiel-N=<path>')
        out.append((name, role, path))
    return out


def gate(a, now):
    lines = []
    events = read_changes(a.changes)
    evdir = a.evidence_dir
    need(os.path.isdir(evdir) and not os.path.islink(evdir.rstrip('/')), 'evidence dir missing or a symlink')
    need(os.path.realpath(evdir).endswith('/ops/evidence/' + CHG), 'evidence dir is not ops/evidence/' + CHG)

    # b: pointer, exact file and the only one; billing_change since 2026-11-18
    found = sorted(os.path.basename(p) for p in glob.glob(os.path.join(evdir, 'g1-evidence-pointer-*')))
    need(found == [POINTER], 'G1 pointer: not exactly the one file %s (found %d)' % (POINTER, len(found)))
    try:
        ptr = json.loads(open(regular_file_in(evdir, POINTER), 'rb').read())
    except Red:
        raise
    except Exception:
        raise Red('G1 pointer unreadable')
    need(isinstance(ptr, dict) and ptr.get('chg') == CHG, 'G1 pointer is not for ' + CHG)
    lim = ptr.get('org_monthly_limit_usd')
    need(is_num(lim) and 0 < lim <= 200, 'G1 org_monthly_limit_usd not a finite number in (0, 200]')
    pm = ptr.get('payment_method')
    need(isinstance(pm, str) and (pm == 'none' or pm.startswith('present (')), 'G1 payment_method not "none" / "present ("')
    lines.append(f'g1 pointer: limit {lim}, payment_method ok')
    bc = [e.get('ts') for _, e in events if isinstance(e.get('payload'), dict)
          and e['payload'].get('billing_change') is True and str(e.get('ts', '')) >= BILLING_SINCE]
    need(not bc, 'billing_change event since 2026-11-18')

    # c: bundles by role
    specs = role_args(a.cloud_bundle, 'cloud') + role_args(a.local_bundle, 'local') + role_args(a.dormant_bundle, 'dormant')
    names = [n for n, _, _ in specs]
    need(len(names) == len(set(names)), 'a profile is given more than once')
    need(set(names) == {'profiel-1', 'profiel-2', 'profiel-3', 'profiel-4'}, 'not exactly profiel-1..4 given')
    need([n for n, r, _ in specs if r == 'cloud'] == ['profiel-3'], 'the cloud role must be profiel-3 only')
    cloud_sha = None
    for name, role, path in specs:
        sha, members = bundle(path)
        if role == 'cloud':
            lines.append(check_cloud(members))
            cloud_sha = sha
        elif role == 'local':
            lines.append(check_local(name, members))
        else:
            lines.append(check_dormant(name, members, events, a.dormant_ack))
    if a.dormant_ack is not None:
        need('profiel-2' in [n for n, r, _ in specs if r == 'dormant'], '--dormant-ack without a dormant bundle')

    # a: the G4 event
    need(a.g4_event is not None, '--g4-event missing')
    g4ts = parse_ts(a.g4_event)
    at = [(raw, e) for raw, e in events if e.get('chg') == CHG and e.get('ts') == a.g4_event]
    need(len(at) == 1, 'not exactly one change-log line on %s at --g4-event (%d)' % (CHG, len(at)))
    raw, e = at[0]
    need(b'person' not in raw.lower(), 'G4 event carries "person"')
    need(set(e) == {'actor', 'chg', 'event', 'payload', 'ts'}, 'G4 event top-level keys are not the ops shape')
    need(e['event'] == 'validated' and e['actor'] == 'infra-ops', 'G4 event is not validated by infra-ops')
    p = e['payload']
    need(isinstance(p, dict) and set(p) == PAYLOAD_KEYS, 'G4 payload keys are not exactly Argus Q1 shape')
    need(p['tsk'] == TSK and p['step'] == 'G4' and p['g4'] == 'green', 'G4 payload tsk/step/g4 not exact')
    need(isinstance(p['checks'], dict) and set(p['checks']) == CHECK_KEYS, 'G4 checks are not exactly the six')
    need(all(v is True for v in p['checks'].values()), 'G4 check not JSON true')
    need(p['plugin_sha256'] == PIN_INIT and p['probe_sha256'] == PIN_PROBE, 'G4 plugin/probe sha != pins')
    need(isinstance(p['p3_bundle_sha256'], str) and HEX64.fullmatch(p['p3_bundle_sha256']), 'G4 p3_bundle_sha256 not hex')
    need(p['p3_bundle_sha256'] == cloud_sha, 'G4 p3_bundle_sha256 != the cloud bundle given (not the canary bundle)')
    need(isinstance(p['evidence'], str), 'G4 evidence not a string')
    m = EVIDENCE_RE.fullmatch(p['evidence'])
    need(m is not None, 'G4 evidence path not ops/evidence/%s/g4-canary-<UTC>.txt' % CHG)
    need(isinstance(p['evidence_sha256'], str) and HEX64.fullmatch(p['evidence_sha256']), 'G4 evidence_sha256 not hex')
    path = regular_file_in(evdir, m.group(1))
    need(hashlib.sha256(open(path, 'rb').read()).hexdigest() == p['evidence_sha256'], 'G4 evidence sha256 mismatch')
    age = (now - g4ts).total_seconds()
    need(age >= 0, 'G4 event lies in the future')
    need(age <= 86400, 'G4 event older than 24 h')
    later = [x.get('ts') for _, x in events if x.get('chg') == CHG and x.get('event') == 'rolled_back'
             and str(x.get('ts', '')) >= a.g4_event]
    need(not later, 'rolled_back on the chg at or after the G4 event')
    lines.append('g4 event %s: shape exact, evidence ok, age %ds' % (a.g4_event, int(age)))
    return lines


class Parser(argparse.ArgumentParser):
    def error(self, message):
        print('GATE RED: arguments: ' + message)
        sys.exit(2)


def main(argv=None):
    ap = Parser(allow_abbrev=False, description='G9 v2 gate, chg-2026-11-17-011 (path B / g1 only)')
    ap.add_argument('--changes', required=True)
    ap.add_argument('--evidence-dir', required=True)
    ap.add_argument('--g4-event')
    ap.add_argument('--cloud-bundle', action='append')
    ap.add_argument('--local-bundle', action='append')
    ap.add_argument('--dormant-bundle', action='append')
    ap.add_argument('--dormant-ack')
    ap.add_argument('--now')
    a = ap.parse_args(argv)
    try:
        if a.now is not None:
            need(os.environ.get('GOLIVE_TEST') == '1', '--now is test-only (GOLIVE_TEST=1)')
            now = parse_ts(a.now)
        else:
            now = dt.datetime.now(dt.timezone.utc)
        for line in gate(a, now):
            print(line)
    except Red as red:
        print('GATE RED: %s' % red)
        return 1
    except Exception as error:   # anything unforeseen is RED, never green
        print('GATE RED: unexpected %s' % type(error).__name__)
        return 1
    print('GATE GREEN (g1)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
