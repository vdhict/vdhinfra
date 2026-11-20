#!/usr/bin/env python3
"""C1 check for chg-2026-11-17-011 (Argus condition 1): commit A's profiel-3 bundle == the bundle at <base> with exactly
ONE file changed, plugins/model-providers/family-cloud/__init__.py 82fafe60.. -> 99fb4183.. . Decrypts both versions
with sops through pipes into memory only (no plaintext file is written); prints names, sha256 prefixes and tar
metadata only. Also: commit A touches only that bundle file.

  chg-2026-11-17-011-c1check.py --repo <worktree> --base <ref> --commit <sha of A>
Last line "C1 OK base-tar <sha256> new-tar <sha256>" and rc 0, else "C1 RED: <reason>" and rc 1.
"""
import argparse
import base64
import hashlib
import io
import json
import subprocess
import sys
import tarfile

PATH = 'kubernetes/main/apps/family-ai/hermes/profiel-3/bundle.sops.yaml'
FILE = 'plugins/model-providers/family-cloud/__init__.py'
OLD, NEW = '82fafe60ce93a8173f600fb095fb47a2f63ae2ca370a2d301dc6a33b09b757ae', \
    '99fb4183deb1793c4cecf3e2abece50e4375b37962f44fa53c358bf581c37496'


def git(repo, *args):
    return subprocess.run(['git', '-C', repo] + list(args), check=True, capture_output=True).stdout


def decrypt(repo, ref):
    enc = git(repo, 'show', f'{ref}:{PATH}')
    p = subprocess.run(['sops', '-d', '--input-type', 'yaml', '--output-type', 'json', '/dev/stdin'],
                       input=enc, capture_output=True, cwd=repo)
    if p.returncode != 0:
        raise SystemExit('C1 RED: sops decrypt of %s failed' % ref)
    data = json.loads(p.stdout)['data']
    raw = base64.b64decode(data['bundle.tar.gz'])
    emb = base64.b64decode(data['bundle.tar.gz.sha256']).decode().split()[0]
    tar = tarfile.open(fileobj=io.BytesIO(raw))
    members = []
    for m in tar.getmembers():
        b = tar.extractfile(m).read() if m.isreg() else b''
        members.append((m.name, hashlib.sha256(b).hexdigest(), m.mode, m.uid, m.gid, m.type, b if m.name == 'SHA256SUMS' else None))
    return hashlib.sha256(raw).hexdigest(), emb, sorted(data), members, hashlib.sha256(enc).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--base', required=True)
    ap.add_argument('--commit', required=True)
    a = ap.parse_args()
    red = []
    files = git(a.repo, 'diff', '--name-only', f'{a.commit}^', a.commit).decode().split()
    print('commit A files:', files)
    if files != [PATH]:
        red.append('commit A touches more than the p3 bundle')
    bsha, bemb, bkeys, bm, benc = decrypt(a.repo, a.base)
    nsha, nemb, nkeys, nm, nenc = decrypt(a.repo, a.commit)
    print('base %s bundle.sops.yaml sha256 %s, bundle.tar.gz %s (embedded match %s)' % (a.base, benc, bsha, bsha == bemb))
    print('A    bundle.sops.yaml sha256 %s, bundle.tar.gz %s (embedded match %s)' % (nenc, nsha, nsha == nemb))
    if bsha != bemb or nsha != nemb:
        red.append('embedded bundle.tar.gz.sha256 mismatch')
    if bkeys != nkeys:
        red.append('Secret data keys differ')
    if [m[0] for m in bm] != [m[0] for m in nm]:
        red.append('member list or order differs')
    bd, nd = {m[0]: m for m in bm}, {m[0]: m for m in nm}
    differing = sorted(n for n in set(bd) | set(nd) if bd.get(n, (None,) * 6)[:6] != nd.get(n, (None,) * 6)[:6])
    for n in differing:
        print('DIFF %s %s -> %s meta %s -> %s' % (n, bd[n][1][:16], nd[n][1][:16], bd[n][2:6], nd[n][2:6]))
    if differing != ['SHA256SUMS', FILE]:
        red.append('differing members are not exactly SHA256SUMS + the family-cloud __init__.py')
    elif bd[FILE][1] != OLD or nd[FILE][1] != NEW or bd[FILE][2:6] != nd[FILE][2:6]:
        red.append('family-cloud __init__.py is not 82fafe60 -> 99fb4183 with equal metadata')
    else:
        parse = lambda b: {l.split()[1].lstrip('*'): l.split()[0] for l in b.decode().splitlines() if l.strip()}
        sb, sn = parse(bd['SHA256SUMS'][6]), parse(nd['SHA256SUMS'][6])
        sd = sorted(k for k in set(sb) | set(sn) if sb.get(k) != sn.get(k))
        print('SHA256SUMS lines differing:', sd)
        if sd != [FILE] or sn[FILE] != NEW:
            red.append('SHA256SUMS differs in more than the one line')
    if red:
        print('C1 RED: ' + '; '.join(red))
        return 1
    print('C1 OK base-tar %s new-tar %s' % (bsha, nsha))
    return 0


if __name__ == '__main__':
    sys.exit(main())
