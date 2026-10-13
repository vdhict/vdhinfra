#!/usr/bin/env bash
# Re-pins the wrapper/drop-in/provision hashes inside install-window.sh from
# the actual files (run after any edit). Usage: ./pin.sh [--check]
set -euo pipefail
cd "$(dirname "$0")"
w="$(shasum -a 256 vdh-provision-tonight | cut -d' ' -f1)"
d="$(shasum -a 256 90-agent-provision | cut -d' ' -f1)"
p="$(shasum -a 256 ../provision.sh | cut -d' ' -f1)"
grep -q "PROV_SHA256=${p}" vdh-provision-tonight || { echo "wrapper pins a different provision.sh than ../provision.sh (${p})"; exit 1; }
new="$(sed -e "s/^WRAP_SHA256=.*/WRAP_SHA256=${w}/" -e "s/^DROPIN_SHA256=.*/DROPIN_SHA256=${d}/" -e "s/^PROV_SHA256=.*/PROV_SHA256=${p}/" install-window.sh)"
if [[ "${1:-}" == --check ]]; then
  if [[ "$new" == "$(cat install-window.sh)" ]]; then echo "install-window.sh pins in sync"; else echo "install-window.sh pins STALE: run ./pin.sh"; exit 1; fi
else
  printf '%s\n' "$new" > install-window.sh.new && chmod 0755 install-window.sh.new && mv -f install-window.sh.new install-window.sh
  echo "pinned wrapper ${w} drop-in ${d} provision ${p}"
fi
