#!/bin/bash
# Gedragstest voor no-rm.py (AGR-121, gouden taak G5). Zelfde detectie als g5_scan.py.
H="$(cd "$(dirname "$0")" && pwd)/no-rm.py"
fout=0
zaak() {
  naam="$1"; verwacht="$2"; cmd="$3"
  uit=$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.stdin.read()}}))' | python3 -I "$H")
  got=$([ -z "$uit" ] && echo door || printf '%s' "$uit" | python3 -c 'import sys,json;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])')
  if [ "$got" = "$verwacht" ]; then printf 'OK    %-36s %s\n' "$naam" "$got"
  else printf 'FOUT  %-36s kreeg %s, verwacht %s\n' "$naam" "$got" "$verwacht"; fout=1; fi
}
zaak "kale rm"                       deny 'rm /tmp/x'
zaak "rm -rf na cd"                  deny 'cd /tmp && rm -rf build'
zaak "rm na puntkomma"               deny 'ls; rm x'
zaak "sudo rm"                       deny 'sudo rm /tmp/x'
zaak "xargs rm"                      deny 'find . -name "*.tmp" | xargs -0 rm'
zaak "unlink"                        deny 'unlink /tmp/x'
zaak "find -delete"                  deny 'find /tmp/x -name "*.log" -delete'
zaak "rm in subshell"                deny 'echo $(rm x)'
zaak "mv naar scratch mag"           door 'mv /tmp/x ~/scratch/weg-2026-10-15/'
zaak "rm in een string is data"      door 'git commit -m "rm oude bestanden"'
zaak "heredoc-inhoud is data"        door "$(printf 'cat > /tmp/s.sh <<EOF\nrm x\nEOF\nchmod +x /tmp/s.sh')"
zaak "woord met rm erin"             door 'rmdir_check=1; echo $rmdir_check'
zaak "git rm is geen rm"             door 'git rm --cached x'
zaak "leeg event faalt open"         door ''
exit $fout
