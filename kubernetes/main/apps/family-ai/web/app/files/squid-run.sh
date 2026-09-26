#!/bin/sh
# Start squid in the foreground-ish and rotate its access log once a day.
# logfile_rotate 6 => access.log + .0..5 = 7 days kept on the PVC.
set -eu
CONF=/etc/egress-proxy/squid.conf
squid -f "$CONF" -N -Y -C &
PID=$!
(
  while sleep 86400; do squid -f "$CONF" -k rotate || true; done
) &
wait "$PID"
