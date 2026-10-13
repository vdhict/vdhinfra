#!/bin/sh
# vdhwslin01 (chg-2026-10-05-031): one journal line per boot saying who started
# it. Installed as /usr/local/libexec/vdh-runner/teamboot-record.
bid="$(cat /proc/sys/kernel/random/boot_id)"
if grep -qx "boot_id=$bid" /run/team-boot 2>/dev/null && grep -qx 'started_by=team' /run/team-boot; then
  echo "started_by=team boot_id=$bid"
else
  echo "started_by=sander boot_id=$bid"
fi
