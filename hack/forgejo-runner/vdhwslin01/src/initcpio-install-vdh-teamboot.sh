#!/bin/bash
# mkinitcpio install hook "vdh-teamboot" (chg-2026-10-05-031).
# Installed as /etc/initcpio/install/vdh-teamboot and appended to HOOKS by
# /etc/mkinitcpio.conf.d/90-vdh-teamboot.conf, so it builds AFTER encryptssh.
# Build-time only (no runtime hook): it moves encryptssh's cryptsetup_shell to
# cryptsetup_shell.vdh-real and puts the team-boot wrapper in its place.

build() {
    if [[ ! -f "${BUILDROOT}/bin/cryptsetup_shell" ]]; then
        error "vdh-teamboot: /bin/cryptsetup_shell not in image; list vdh-teamboot AFTER encryptssh"
        return 1
    fi
    if [[ ! -f "${BUILDROOT}/bin/cryptsetup_shell.vdh-real" ]]; then
        mv "${BUILDROOT}/bin/cryptsetup_shell" "${BUILDROOT}/bin/cryptsetup_shell.vdh-real"
    fi
    install -m 0755 /usr/local/lib/vdh-runner/teamboot-shell "${BUILDROOT}/bin/cryptsetup_shell"
    # cat/cut/printf come from the busybox that the base hook installs.
    echo "vdh-teamboot: wrapped /bin/cryptsetup_shell"
}

help() {
    cat <<HELPEOF
Marks boots that were unlocked over the initramfs ssh server (encryptssh) as
team-started by writing /run/team-boot (started_by=team + boot_id). Used by
vdhwslin01's idle-poweroff. List it after encryptssh.
HELPEOF
}
