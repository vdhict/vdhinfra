#!/bin/sh
# vdh-teamboot: wrapper around encryptssh's /bin/cryptsetup_shell inside the
# initramfs (busybox ash, POSIX sh only). chg-2026-10-05-031, AGR-115.
#
# encryptssh makes /bin/cryptsetup_shell the LOGIN SHELL of root for the
# initramfs ssh server, so every ssh unlock (dropbear/tinyssh on 2222) runs
# through here, while a console unlock at the keyboard never does. A disk that
# was locked before and is open after this session therefore means: unlocked
# over ssh = a team-started boot. We record that in /run/team-boot, which
# switch_root carries into the booted system, where idle-poweroff reads it.
# Sander's own boots (console passphrase) never get the marker, so the box
# never powers off a boot he started.
#
# The real shell is delegated to unchanged; this wrapper never sees or stores
# the passphrase (cryptsetup reads it from the ssh session's stdin).
name="$(cat /.cryptname 2>/dev/null)"
was_open=0
if [ -n "$name" ] && [ -b "/dev/mapper/$name" ]; then
  was_open=1
fi

/bin/cryptsetup_shell.vdh-real "$@"
rc=$?

if [ "$was_open" = 0 ] && [ -n "$name" ] && [ -b "/dev/mapper/$name" ]; then
  bid="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  (
    umask 022
    printf 'started_by=team\nboot_id=%s\nvia=initramfs-ssh-unlock\nuptime_at_unlock=%s\n' \
      "$bid" "$up" > /run/team-boot
  )
  echo "vdh-teamboot: started_by=team boot_id=$bid"
fi
exit $rc
