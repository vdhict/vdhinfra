#!/usr/bin/env bash
# chg-2026-10-20-010 offline tests of hack/ops/chg-2026-10-20-010-pin-probe.py (Argus C3).
#
#   bash hack/ops/chg-2026-10-20-010-test-pin-probe.sh [<scratch-dir>]
#
# A fake Hermes tree (4 pinned modules) and a fake plugin with the same contract as family-cloud (literal
# PINNED_MODULES / PINNED_SOURCES / PINNED_IMAGE, runtime_pinned() requiring every pinned module loaded).
# Plus, when present, the real v0.22.5 toolchain with the real ported plugin. No cluster, no network.
# Deletes nothing (AGR-121). Exit 0 iff all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PROBE="$HERE/chg-2026-10-20-010-pin-probe.py"
B="${1:-$(mktemp -d "${TMPDIR:-/tmp}/c010-pin-probe-XXXXXX")}"; mkdir -p "$B"
PASS=0; FAIL=0; t() { local n="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "PASS  $n"; else FAIL=$((FAIL+1)); echo "FAIL  $n"; fi; }
IMG="docker.io/nousresearch/hermes-agent:vTEST@sha256:$(printf '0%.0s' $(seq 1 64))"
DEFMODS='PINNED_MODULES = {"hermes_cli": "hermes_cli/__init__.py", "agent.chat_completion_helpers": "agent/chat_completion_helpers.py", "gateway.platforms.api_server": "gateway/platforms/api_server.py", "gateway.run_turn_runner": "gateway/run_turn_runner.py"}'
mkroot() { # $1 dir: fake hermes tree + plugin; $2 = optional plugin variant
  local R="$1/root" P="$1/plugin.py"; mkdir -p "$R/hermes_cli" "$R/agent" "$R/gateway/platforms"
  : > "$R/agent/__init__.py"; : > "$R/gateway/__init__.py"; : > "$R/gateway/platforms/__init__.py"
  printf '__version__ = "9.9.9"\n__release_date__ = "2026.1.1"\n' > "$R/hermes_cli/__init__.py"
  echo 'X = 1' > "$R/agent/chat_completion_helpers.py"; echo 'X = 2' > "$R/gateway/platforms/api_server.py"; echo 'X = 3' > "$R/gateway/run_turn_runner.py"
  local h; h() { shasum -a 256 "$R/$1" | cut -d' ' -f1; }
  cat > "$P" <<EOF
import hashlib, os, sys
from pathlib import Path
PINNED_IMAGE = "$IMG"
PINNED_SOURCES = {"hermes_cli/__init__.py": "$(h hermes_cli/__init__.py)", "agent/chat_completion_helpers.py": "$(h agent/chat_completion_helpers.py)",
                  "gateway/platforms/api_server.py": "$(h gateway/platforms/api_server.py)", "gateway/run_turn_runner.py": "$(h gateway/run_turn_runner.py)"}
${2:-$DEFMODS}
def runtime_pinned():
    if os.environ.get("HERMES_IMAGE") != PINNED_IMAGE or "HERMES_INSTALL_ROOT" in os.environ: return False
    cli = sys.modules.get("hermes_cli")
    if cli is None: return False
    root = Path(cli.__file__).resolve().parent.parent
    for name, rel in PINNED_MODULES.items():
        m = sys.modules.get(name)
        if m is None or Path(m.__file__).resolve() != (root / rel).resolve(): return False
    return all(hashlib.sha256((root / r).read_bytes()).hexdigest() == d for r, d in PINNED_SOURCES.items())
EOF
}
probe() { # $1 dir ; rest = env assignments ; sets OUT, RC
  local d="$1"; shift
  OUT=$(env -u HERMES_INSTALL_ROOT -u HERMES_PLUGIN_HOST_PROCESS HERMES_IMAGE="$IMG" "$@" PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -c "$(cat "$PROBE")" "$d/plugin.py" "$d/root" 2>&1); RC=$?; }
has() { grep -q -- "$1" <<< "$OUT"; }

mkroot "$B/a"; probe "$B/a"
t "P1 all 4 PINNED_MODULES read from the plugin, imported, runtime_pinned True -> rc 0" bash -c "[ $RC = 0 ] && grep -q '\"imported\": 4' <<< '$OUT' && grep -q 'gateway.run_turn_runner' <<< '$OUT' && grep -q '\"runtime_pinned\": true' <<< '$OUT'"
probe "$B/a" C010_PROBE_SKIP=gateway.run_turn_runner
t "P2 a probe that misses one module refuses with a clear reason" bash -c "[ $RC = 1 ] && grep -q 'pinned modules not loaded in the probe: gateway.run_turn_runner' <<< '$OUT'"
mkroot "$B/b"; mv "$B/b/root/gateway/run_turn_runner.py" "$B/b/run_turn_runner.py.moved"; probe "$B/b"
t "P3 a pinned module that cannot be imported refuses with its name" bash -c "[ $RC = 1 ] && grep -q 'cannot import pinned module gateway.run_turn_runner' <<< '$OUT'"
mkroot "$B/c" 'PINNED_MODULES = dict(hermes_cli="hermes_cli/__init__.py")'; probe "$B/c"
t "P4 PINNED_MODULES not a literal dict -> refuse (never executes plugin code to find it)" bash -c "[ $RC = 1 ] && grep -q 'no literal PINNED_MODULES dict' <<< '$OUT'"
mkroot "$B/d" '# no PINNED_MODULES here'; probe "$B/d"
t "P5 plugin without PINNED_MODULES -> refuse" bash -c "[ $RC = 1 ] && grep -q 'no literal PINNED_MODULES dict' <<< '$OUT'"
mkroot "$B/e"; probe "$B/e" HERMES_IMAGE=docker.io/other:1
t "P6 HERMES_IMAGE not the pin -> refuse, runtime_pinned false" bash -c "[ $RC = 1 ] && grep -q 'not pinned: runtime_pinned, image_env_is_pin' <<< '$OUT'"
mkroot "$B/f"; probe "$B/f" HERMES_INSTALL_ROOT=/x
t "P7 HERMES_INSTALL_ROOT set -> refuse" bash -c "[ $RC = 1 ] && grep -q 'install_root_unset' <<< '$OUT'"
mkroot "$B/g"; probe "$B/g" HERMES_PLUGIN_HOST_PROCESS=1
t "P8 HERMES_PLUGIN_HOST_PROCESS=1 -> refuse" bash -c "[ $RC = 1 ] && grep -q 'plugin_host_unset' <<< '$OUT'"
mkroot "$B/h"; echo '# changed' >> "$B/h/root/agent/chat_completion_helpers.py"; probe "$B/h"
t "P9 one pinned source byte changed -> refuse (pins 3/4)" bash -c "[ $RC = 1 ] && grep -q 'pins 3/4' <<< '$OUT'"
mkroot "$B/i"; printf 'PINNED_MODULES["agent.extra"] = "agent/chat_completion_helpers.py"\n' >> "$B/i/plugin.py"; probe "$B/i"
t "P10 plugin mutates PINNED_MODULES after the literal (K2) -> refuse: loaded list differs from the source literal" bash -c "[ $RC = 1 ] && grep -q 'PINNED_MODULES after load differs from its source literal' <<< '$OUT'"
T=~/Code/pka-wires/_toolchains/hermes-agent-v0.22.5; PL="${C010_REAL_PLUGIN:-}"
if [ -x "$T/.venv/bin/python" ] && [ -n "$PL" ] && [ -f "$PL" ]; then
  PIN=$(/usr/bin/python3 -I -c 'import re,sys; s=open(sys.argv[1]).read(); m=re.search(r"PINNED_IMAGE = \(\"([^\"]+)\"\s*\n\s*\"([^\"]+)\"\)", s); print(m.group(1)+m.group(2))' "$PL")
  OUT=$(env -u HERMES_INSTALL_ROOT HERMES_IMAGE="$PIN" PYTHONDONTWRITEBYTECODE=1 "$T/.venv/bin/python" -c "$(cat "$PROBE")" "$PL" "$T" 2>&1); RC=$?
  t "R1 real v0.22.5 toolchain + real ported plugin: 4 modules, 24/24 pins, runtime_pinned True" bash -c "[ $RC = 0 ] && grep -q '\"pins_ok\": 24' <<< '$OUT' && grep -q '\"imported\": 4' <<< '$OUT'"
  OUT=$(env -u HERMES_INSTALL_ROOT HERMES_IMAGE="$PIN" C010_PROBE_SKIP=gateway.run_turn_runner PYTHONDONTWRITEBYTECODE=1 "$T/.venv/bin/python" -c "$(cat "$PROBE")" "$PL" "$T" 2>&1); RC=$?
  t "R2 real tree, probe missing gateway.run_turn_runner (the 11:46Z bug) -> refuse with reason" bash -c "[ $RC = 1 ] && grep -q 'not loaded in the probe: gateway.run_turn_runner' <<< '$OUT'"
else echo "SKIP  R1/R2 (set C010_REAL_PLUGIN=<family-cloud __init__.py> and have the v0.22.5 toolchain)"; fi
echo "RESULT $PASS/$((PASS+FAIL)) PASS (scratch $B)"; [ $FAIL = 0 ]
