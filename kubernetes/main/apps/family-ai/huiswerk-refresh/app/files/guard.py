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

    def cluster_restart(namespace):
        state['swapped'] = True
        original_restart(namespace)

    refresh.cluster_restart = cluster_restart
    try:
        refresh.run()
    except Exception:
        if not state['swapped']:
            print('FAIL: homework refresh before swap; previous collections untouched', file=sys.stderr)
            return 1
        try:
            restore(volume, newest_retired(volume, before))
            original_restart(os.environ.get('HUISWERK_NS', 'family-ai'))
            print('FAIL: homework refresh after swap; previous collections restored, kennisdienst restarted',
                  file=sys.stderr)
        except Exception:
            print('FAIL: homework refresh after swap; AUTOMATIC RESTORE FAILED', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
