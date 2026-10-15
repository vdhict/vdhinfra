#!/usr/bin/env python3
"""no-rm.py: PreToolUse on Bash. Refuses rm, unlink and find -delete (AGR-121).

Why: Sander, 2026-10-14: "Again I got to approve a bash with an rm built in". AGR-121 says temporary files stay in
scratch and what has to go is moved with `mv`. Golden task G5 counts these commands in yesterday's transcripts; on
2026-10-15 it was red with 32 hits (22 MacBook, 10 Mini). A rule in a document does not reach a shell, so this
hook stops the command itself and says what to do instead.

Detection is the same as G5 (`~/pka-larry-session/gouden/g5_scan.py`, function `destructive`): command position
only, quoted text and heredoc bodies are data. Keep both in step; tests: test-no-rm.sh next to this file.

Fail open: an unreadable event gives no output and exit 0. Only a clear hit gives a deny.
"""
import json
import re
import sys

REASON = (
    "AGR-121: geen rm, unlink of find -delete. Laat tijdelijk werk in scratch staan, of verplaats het met mv "
    "(bijvoorbeeld naar ~/scratch/weg-$(date +%F)/). Sander hoeft dan niets goed te keuren."
)


def destructive(command):
    lines = command.splitlines()
    clean = []
    pending = []
    for line in lines:
        if pending:
            tabs, delimiter = pending[0]
            if (line.lstrip('\t') if tabs else line) == delimiter:
                pending.pop(0)
            continue
        clean.append(line)
        for match in re.finditer(r"<<(-)?\s*['\"]?(\w+)['\"]?", line):
            pending.append((bool(match[1]), match[2]))
    command = '\n'.join(clean)
    command = re.sub(r"'(?:[^']*)'|\"(?:\\.|[^\"\\])*\"", '__quoted__', command)
    position = r'(?:^|[;|(`\n]|&&|\|\||\$\()\s*'
    xargs_flags = r'(?:(?:-[ILnPsdE]|--(?:max-args|max-procs|max-lines|replace|max-chars|delimiter|eof))\s+\S+\s+|-\S+\s+)*'
    wrappers = r'(?:(?:sudo|command|exec|then|do|else)\s+|xargs\s+' + xargs_flags + r')*'
    if re.search(position + wrappers + r'(?:rm|unlink)\b', command):
        return True
    return bool(re.search(position + wrappers + r'find\s+[^;|\n]*\s-delete\b', command))


def main():
    try:
        event = json.load(sys.stdin)
        command = event.get('tool_input', {}).get('command', '')
        if not isinstance(command, str) or not destructive(command):
            return 0
    except Exception:
        return 0
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': REASON,
    }}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
