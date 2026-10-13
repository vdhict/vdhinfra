#!/usr/bin/env bash
# Unit tests for src/nft-guard.sh (Argus F3/C4) with stub nft/systemctl.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SUT="${here}/../src/nft-guard.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX")"
trap 'find "${T:?}" -delete' EXIT
pass=0; fail=0

GOOD='table inet vdh_runner {
	chain input {
		type filter hook input priority filter - 10; policy accept;
		tcp dport { 22, 2222 } ip saddr @ssh_allow_v4 accept
	}
	chain output {
		type filter hook output priority filter - 10; policy accept;
		meta skuid != "runner" accept
		meta nfproto ipv6 counter packets 0 bytes 0 drop
		ip daddr @nonpublic_v4 counter packets 0 bytes 0 drop comment "no RFC1918/LAN"
		tcp dport { 80, 443 } accept
		counter packets 0 bytes 0 drop
	}
}'

setup() { # setup <name> <nft-listing|MISSING> <active|inactive>
  local d="$T/$1"; mkdir -p "$d"
  if [[ "$2" == MISSING ]]; then printf '#!/bin/sh\nexit 1\n' > "$d/nft"
  else printf '%s\n' "$2" > "$d/listing"; printf '#!/bin/sh\ncat "%s/listing"\n' "$d" > "$d/nft"; fi
  cat > "$d/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$d/calls"
[ "\$1" = is-active ] && { [ "$3" = active ]; exit \$?; }
exit 0
STUB
  chmod +x "$d/nft" "$d/systemctl"; echo "$d"
}
run() { local d="$1"; shift; VDH_GUARD_TEST=1 VDH_GUARD_NFT="$d/nft" VDH_GUARD_SYSTEMCTL="$d/systemctl" sh "$SUT" "$@"; }
t() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

d="$(setup good "$GOOD" active)"
t "check passes with the full table" "run '$d' check"
run "$d" guard >/dev/null
t "guard leaves a running runner alone when the table is fine" "! grep -q stop '$d/calls' 2>/dev/null"

d="$(setup gone MISSING active)"
t "check fails when the table is gone" "! run '$d' check >/dev/null"
out="$(run "$d" guard)"
t "guard STOPS the runner when the table is gone" "grep -qx 'stop forgejo-runner-vm.service' '$d/calls'"
if [[ "$out" == *STOPPED* ]]; then pass=$((pass+1)); echo "ok   guard says why"; else fail=$((fail+1)); echo "FAIL guard says why: $out"; fi

d="$(setup flushed "table inet vdh_runner {
	chain input {
		type filter hook input priority filter - 10; policy accept;
	}
	chain output {
		type filter hook output priority filter - 10; policy accept;
	}
}" active)"
t "check fails on a flushed (empty-chain) table" "! run '$d' check >/dev/null"
run "$d" guard >/dev/null
t "guard stops the runner on a flushed table" "grep -qx 'stop forgejo-runner-vm.service' '$d/calls'"

d="$(setup noipv6 "${GOOD//meta nfproto ipv6/meta nfproto ipv4}" active)"
t "check fails when the IPv6 drop is missing" "! run '$d' check >/dev/null"

d="$(setup nocatchall "${GOOD//		counter packets 0 bytes 0 drop
/}" active)"
t "check fails when the final catch-all drop is gone" "! run '$d' check >/dev/null"

d="$(setup already "MISSING" inactive)"
run "$d" guard >/dev/null
t "guard does not call stop when the runner is already stopped" "! grep -q '^stop' '$d/calls'"

d="$(setup seam "$GOOD" active)"
t "test seam inert without VDH_GUARD_TEST=1 (real nft absent/denied -> check fails)" "! VDH_GUARD_NFT='$d/nft' VDH_GUARD_SYSTEMCTL='$d/systemctl' sh '$SUT' check >/dev/null 2>&1"

echo "nft-guard tests: ${pass} passed, ${fail} failed"
(( fail == 0 ))
