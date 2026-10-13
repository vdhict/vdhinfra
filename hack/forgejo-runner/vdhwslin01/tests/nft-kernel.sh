#!/usr/bin/env bash
# Runs INSIDE a throwaway Arch container with CAP_NET_ADMIN in its OWN network
# namespace (nothing outside the pod is touched). Real kernel nftables:
#   K1  the final ruleset from provision.sh passes `nft -c` and loads
#   K2  nft-guard check passes on the REAL `nft list` output (the guard's
#       match strings are tested against real formatting, not a fixture)
#   K3  behaviour as uid runner vs root (envoy-internal stands in for
#       envoy-forge, the pod's cluster resolver for the host resolver)
#   K4  delete the table -> guard stops the runner; a flushed output chain
#       -> check fails (Argus F3/C4)
# Usage: bash tests/nft-kernel.sh <bundle-dir>
# shellcheck disable=SC1091,SC2034  # sources provision.sh to render; sets its globals
set -uo pipefail
B="${1:?bundle dir}"; cd "$B"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

pacman -Sy --noconfirm --needed nftables curl util-linux >/dev/null 2>&1
id runner >/dev/null 2>&1 || useradd --system runner
echo "# provision.sh sha256 $(sha256sum provision.sh | cut -d' ' -f1), kernel $(uname -r)"
ns="$(awk '$1=="nameserver"{print $2; exit}' /etc/resolv.conf)"

( . ./provision.sh; FORGE_HOST=forge.example.invalid; ENVOY_FORGE_IP=172.16.2.249; DNS_STUB=1; nft_ruleset ) > /root/final.nft
( . ./provision.sh; FORGE_HOST=forge.example.invalid; ENVOY_FORGE_IP=172.16.2.241; DNS_STUB=0; DNS_SERVERS=("$ns"); nft_ruleset ) > /root/behav.nft
if nft -c -f /root/final.nft; then ok "K1 nft -c accepts the final ruleset"; else bad "K1 nft -c final"; fi
grep -n 'elements = { 172.16.2.81' /root/final.nft | sed 's/^/    /'

if nft -f /root/behav.nft; then ok "K1 ruleset loads (pod netns only)"; else bad "K1 load"; fi
if sh src/nft-guard.sh check; then ok "K2 nft-guard check passes on the real nft listing"; else bad "K2 guard check on real listing"; nft list table inet vdh_runner; fi

t() { # t <runner|root> <allow|block> <url> [curl args]
  local who=$1 want=$2 url=$3 rc; shift 3
  if [ "$who" = runner ]; then runuser -u runner -- curl -sk -o /dev/null -m 5 "$@" "$url"; rc=$?
  else curl -sk -o /dev/null -m 5 "$@" "$url"; rc=$?; fi
  if { [ "$want" = allow ] && [ $rc -eq 0 ]; } || { [ "$want" = block ] && [ $rc -eq 28 ]; }; then ok "K3 $who $want $url (rc=$rc)"
  else bad "K3 $who $want $url (rc=$rc)"; fi
}
t runner block http://172.16.2.1/
t runner block https://172.16.2.237:8123/
t runner block http://127.0.0.1:22/
t runner allow https://172.16.2.241/ -H "Host: forge.example.invalid"
t runner allow https://1.1.1.1/
t runner allow https://deb.debian.org/
t runner block http://1.1.1.1:8080/
t root   allow http://172.16.2.1/

stub=/root/systemctl-stub; : > /root/systemctl.calls
# shellcheck disable=SC2016  # $* belongs to the stub, not to this shell
printf '#!/bin/sh\necho "$*" >> /root/systemctl.calls\n[ "$1" = is-active ] && exit 0\nexit 0\n' > "$stub"; chmod +x "$stub"
G() { VDH_GUARD_TEST=1 VDH_GUARD_NFT=nft VDH_GUARD_SYSTEMCTL="$stub" sh src/nft-guard.sh "$@"; }
G guard >/dev/null
if ! grep -q '^stop' /root/systemctl.calls; then ok "K4 guard leaves the runner alone while the table is intact"; else bad "K4 false stop"; fi
h="$(nft -a list chain inet vdh_runner output | awk '/counter packets [0-9]+ bytes [0-9]+ drop # handle/ && !/comment/ {print $NF}' | tail -1)"
nft delete rule inet vdh_runner output handle "$h"
if ! G check >/dev/null; then ok "K4 check fails when the final catch-all drop is deleted (handle $h)"; else bad "K4 missing catch-all passed"; fi
nft -f /root/behav.nft
if G check >/dev/null; then ok "K4 check passes again after reload"; else bad "K4 reload"; fi
nft flush chain inet vdh_runner output
if ! G check >/dev/null; then ok "K4 check fails after 'nft flush chain ... output'"; else bad "K4 flushed chain passed"; fi
nft delete table inet vdh_runner
G guard
if grep -qx 'stop forgejo-runner-vm.service' /root/systemctl.calls; then ok "K4 table deleted -> guard stops forgejo-runner-vm"; else bad "K4 no stop after delete"; fi
if ! G check >/dev/null; then ok "K4 ExecStartPre check refuses a start without the table"; else bad "K4 check passed without table"; fi

echo "RESULT: ${pass} passed, ${fail} failed"
(( fail == 0 ))
