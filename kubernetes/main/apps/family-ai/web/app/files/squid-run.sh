#!/bin/sh
# Start squid in the foreground-ish and rotate its access log once a day.
# logfile_rotate 6 => access.log + .0..5 = 7 days kept on the PVC.
set -eu
CONF=/etc/egress-proxy/squid.conf
# squid's own stderr can carry URLs too: append it to cache.log on the PVC,
# so the pod's stdout/stderr (-> Loki) only ever see the two lines below.
squid -f "$CONF" -k parse >/dev/null 2>&1 || { echo "egress-proxy: squid.conf does not parse (details in cache.log on the PVC)"; squid -f "$CONF" -k parse >>/var/log/squid/cache.log 2>&1; exit 1; }
echo "egress-proxy: starting squid"
squid -f "$CONF" -N -Y -C -d 0 2>>/var/log/squid/cache.log &
PID=$!
(
  while sleep 86400; do squid -f "$CONF" -k rotate >/dev/null 2>&1 || true; done
) &
wait "$PID"
