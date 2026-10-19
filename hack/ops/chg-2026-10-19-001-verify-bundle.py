#!/usr/bin/env python3
"""chg-2026-10-19-001: verify an encrypted Hermes bundle against the derived delivery and the live baseline.
   sops -d <bundle.sops.yaml> | python3 -I hack/ops/chg-2026-10-19-001-verify-bundle.py <n> <derived-root> <live-hashes>
<live-hashes> = `sha256sum` lines of SOUL.md, config.yaml, plugins/** captured from the running pod before the change.
Everything stays in memory; prints counts and sha256 prefixes only.
Pass = bundle members == derived profiel-<n> byte for byte; vs live: ONLY plugins/lesstof/* added and config.yaml
differs by exactly the one '    - "lesstof"' line (live config also carries Hermes' runtime '_config_version' line).
"""
import base64, hashlib, io, re, sys, tarfile
from pathlib import Path

n, derived, live_file = sys.argv[1], Path(sys.argv[2]) / f'profiel-{sys.argv[1]}', Path(sys.argv[3])
doc = sys.stdin.read()
b64 = re.search(r'^ +bundle\.tar\.gz: (\S+)$', doc, re.M).group(1)
raw = base64.b64decode(b64)
outer = hashlib.sha256(raw).hexdigest()
want_outer = base64.b64decode(re.search(r'^ +bundle\.tar\.gz\.sha256: (\S+)$', doc, re.M).group(1)).decode().split()[0]
fails = []
if outer != want_outer:
    fails.append('outer sha mismatch')
members = {}
with tarfile.open(fileobj=io.BytesIO(raw)) as t:
    for m in t.getmembers():
        if not (m.isfile() or m.isdir()):
            fails.append('non-regular member')
        if m.isfile():
            members[m.name.removeprefix('./')] = t.extractfile(m).read()
members.pop('SHA256SUMS', None)
dfiles = {str(p.relative_to(derived)): p.read_bytes() for p in derived.rglob('*') if p.is_file()}
if members != dfiles:
    fails.append(f'bundle != derived ({len(set(members) ^ set(dfiles))} name diffs)')
live = {}
for line in live_file.read_text().splitlines():
    h, name = line.split(None, 1)
    live[name.strip()] = h
bh = {k: hashlib.sha256(v).hexdigest() for k, v in members.items()}
added = sorted(set(bh) - set(live))
removed = sorted(set(live) - set(bh))
changed = sorted(k for k in set(bh) & set(live) if bh[k] != live[k])
if added != [f'plugins/lesstof/{f}' for f in ('__init__.py', 'instellingen.json', 'plugin.yaml')]:
    fails.append(f'unexpected added set {added}')
if removed:
    fails.append(f'removed {removed}')
if changed != ['config.yaml']:
    fails.append(f'unexpected changed set {changed}')
cfg = members['config.yaml'].decode().split('\n')
cfg_live_equiv = [l for l in cfg if l != '    - "lesstof"']
cfg_live_equiv = '\n'.join(cfg_live_equiv).rstrip('\n') + '\n_config_version: 46\n'
cfg_diff_ok = hashlib.sha256(cfg_live_equiv.encode()).hexdigest() == live['config.yaml'] \
    or hashlib.sha256('\n'.join(l for l in cfg if l != '    - "lesstof"').encode()).hexdigest() == live['config.yaml']
if not cfg_diff_ok:
    fails.append('config.yaml differs from live by more than the lesstof line (+ runtime _config_version)')
for bad in (b'family-cloud', b'anthropic', b'owui_bijlagen', b'bijlage'):
    if any(bad in v.lower() for v in members.values()):
        fails.append(f'forbidden marker in bundle: {bad.decode()}')
print(f'profiel-{n}: bundle sha256 {outer[:12]}, {len(members)} files; added {len(added)}, changed {changed}, '
      f'unchanged {len(set(bh) & set(live)) - len(changed)}; {"PASS" if not fails else "FAIL: " + "; ".join(fails)}')
sys.exit(1 if fails else 0)
