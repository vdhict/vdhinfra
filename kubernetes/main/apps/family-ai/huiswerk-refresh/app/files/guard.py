#!/usr/bin/env python3
"""huiswerk-refresh guard (chg-2026-10-15-001, Argus C3). Wraps the reviewed refresh.py without changing it.

1. Pre-swap check: both huiswerk.md files must decode as UTF-8 and yield >= 1 kennisdienst unit
   (kennisdienst.lees_units turns any non-empty text into at least one unit; an undecodable file would crash it).
2. Auto-rollback: if anything fails AFTER the filler swapped the collections (kennisdienst rollout timeout or error),
   the new huiswerk-profiel-2/-3 directories move into the swap's .retired dir as failed-*, the previous ones move
   back from that same .retired dir, and kennisdienst is restarted once more. Nothing is deleted.
Output is content-free: fixed lines only. Any failure exits 1 (the Job fails -> alert).
"""
import importlib.util
import os
import sys
import time
from pathlib import Path

COLLECTIONS = ('huiswerk-profiel-2', 'huiswerk-profiel-3')


def load_refresh(path=os.environ.get('HUISWERK_REFRESH_PY', '/opt/huiswerk/refresh.py')):
    spec = importlib.util.spec_from_file_location('refresh', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def precheck(files):
    for name in COLLECTIONS:
        raw = files[name + '/huiswerk.md']
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            raise ValueError('package text is not UTF-8')
        if not text.strip():
            raise ValueError('package text yields no unit')


def newest_retired(volume, before):
    fresh = [p for p in volume.iterdir()
             if p.is_dir() and p.name.startswith('.retired-') and not p.name.startswith('.retired-staging-')
             and p.name not in before]
    if len(fresh) != 1:
        raise RuntimeError('cannot identify the swap snapshot')
    return fresh[0]


def restore(volume, retired):
    for name in COLLECTIONS:
        target = volume / name
        if target.exists():
            target.rename(retired / ('failed-' + name))
        previous = retired / name
        if previous.is_dir():
            previous.rename(target)


def wait_ready(refresh, namespace, seconds):
    """Extra wait after refresh.py's own 120 s rollout wait: kennisdienst (Recreate, embedding models) needs
    ~100-150 s to become Available after the old pod is gone (measured 2026-10-15). GET only."""
    service = Path('/var/run/secrets/kubernetes.io/serviceaccount')
    token = (service / 'token').read_text().strip()
    context = refresh.ssl.create_default_context(cafile=str(service / 'ca.crt'))
    opener = refresh.urllib.request.build_opener(refresh.NoRedirect(), refresh.urllib.request.HTTPSHandler(context=context))
    host = os.environ['KUBERNETES_SERVICE_HOST']
    if ':' in host:
        host = '[' + host + ']'
    port = os.environ.get('KUBERNETES_SERVICE_PORT_HTTPS', '443')
    url = f'https://{host}:{port}/apis/apps/v1/namespaces/{namespace}/deployments/kennisdienst'
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        request = refresh.urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
        with opener.open(request, timeout=20) as response:
            deployment = refresh.json.load(response)
        status = deployment.get('status', {})
        replicas = deployment.get('spec', {}).get('replicas', 1)
        if (status.get('observedGeneration', 0) >= deployment['metadata']['generation']
                and status.get('updatedReplicas', 0) == replicas
                and status.get('availableReplicas', 0) == replicas
                and status.get('replicas', 0) == replicas):
            return
        time.sleep(3)
    raise RuntimeError('kennisdienst rollout timeout')


def main():
    refresh = load_refresh()
    original_validate = refresh.validate

    def validate(data, today):
        files, want = original_validate(data, today)
        precheck(files)
        return files, want

    refresh.validate = validate
    original_restart = refresh.cluster_restart
    volume = Path(os.environ.get('HUISWERK_VOLUME', '/vul'))
    before = {p.name for p in volume.iterdir()} if volume.is_dir() else set()
    state = {'swapped': False}

    extra = int(os.environ.get('HUISWERK_EXTRA_ROLLOUT_SECONDS', '300'))

    def restart_and_wait(namespace):
        try:
            original_restart(namespace)
        except RuntimeError as error:
            if str(error) != 'kennisdienst rollout timeout':
                raise
            wait_ready(refresh, namespace, extra)

    def cluster_restart(namespace):
        state['swapped'] = True
        restart_and_wait(namespace)

    refresh.cluster_restart = cluster_restart
    try:
        refresh.run()
    except Exception:
        if not state['swapped']:
            print('FAIL: homework refresh before swap; previous collections untouched', file=sys.stderr)
            return 1
        try:
            restore(volume, newest_retired(volume, before))
        except Exception:
            print('FAIL: homework refresh after swap; AUTOMATIC RESTORE FAILED', file=sys.stderr)
            return 1
        try:
            restart_and_wait(os.environ.get('HUISWERK_NS', 'family-ai'))
            print('FAIL: homework refresh after swap; previous collections restored, kennisdienst restarted',
                  file=sys.stderr)
        except Exception:
            print('FAIL: homework refresh after swap; previous collections restored, kennisdienst NOT READY yet',
                  file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
