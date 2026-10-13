#!/usr/bin/env bash
# Generates provision.sh (single self-contained file for Sander) from
# provision.in.sh + src/. Usage: ./build.sh [--check]
#   --check: exit 1 if provision.sh is not what build.sh would generate.
set -euo pipefail
cd "$(dirname "$0")"
# function name -> source file
payloads=(
  "vm_dispatch:src/vm-dispatch.sh"
  "vm_golden_build:src/vm-golden-build.sh"
  "idle_poweroff:src/idle-poweroff.sh"
  "teamboot_record:src/teamboot-record.sh"
  "teamboot_shell:src/teamboot-shell.sh"
  "initcpio_install_vdh_teamboot:src/initcpio-install-vdh-teamboot.sh"
  "forgejo_runner_vm_service:src/forgejo-runner-vm.service"
  "idle_poweroff_service:src/idle-poweroff.service"
  "idle_poweroff_timer:src/idle-poweroff.timer"
  "vdh_teamboot_record_service:src/vdh-teamboot-record.service"
  "vdh_runner_nft_service:src/vdh-runner-nft.service"
)
delim=VDH_PAYLOAD_EOF
gen() {
  local line entry fn src
  while IFS= read -r line; do
    if [[ "$line" == "# @@PAYLOADS@@" ]]; then
      for entry in "${payloads[@]}"; do
        fn="${entry%%:*}"; src="${entry#*:}"
        if grep -q "$delim" "$src"; then echo "build.sh: $src contains $delim" >&2; exit 1; fi
        echo "# --- from ${src} (sha256 $(shasum -a 256 "$src" 2>/dev/null | cut -c1-16 || sha256sum "$src" | cut -c1-16))"
        echo "payload_${fn}() {"
        echo "cat <<'${delim}'"
        cat "$src"
        echo "${delim}"
        echo "}"
      done
    else
      printf '%s\n' "$line"
    fi
  done < provision.in.sh
}
if [[ "${1:-}" == "--check" ]]; then
  if gen | cmp -s - provision.sh; then echo "provision.sh is in sync"; else echo "provision.sh is STALE: run ./build.sh" >&2; exit 1; fi
else
  gen > provision.sh.new
  chmod 0755 provision.sh.new
  mv -f provision.sh.new provision.sh
  echo "wrote provision.sh sha256 $(shasum -a 256 provision.sh 2>/dev/null | cut -d' ' -f1 || sha256sum provision.sh | cut -d' ' -f1)"
fi
