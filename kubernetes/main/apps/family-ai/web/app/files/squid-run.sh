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
# Brave API quota counter (land-12g): after each rotation, count the
# established tunnels to api.search.brave.com in the log that was just closed
# (access.log.0), per UTC day, and append "YYYY-MM-DD<TAB>n" to
# brave-calls.tsv on the PVC. Host + date + count only - never a query.
# Month total = sum of that month's rows + the same awk over the live
# access.log. (Each API call is one tunnel unless curl reuses a warm one, so
# this is a lower bound; Brave's dashboard is authoritative.)
BRAVE_TSV=/var/log/squid/brave-calls.tsv
(
  while sleep 86400; do
    squid -f "$CONF" -k rotate >/dev/null 2>&1 || true
    sleep 10
    awk '$2 == "search" && $3 == "api.search.brave.com:443" && $4 == "200" { c[substr($1, 1, 10)]++ }
         END { for (d in c) printf "%s\t%d\n", d, c[d] }' /var/log/squid/access.log.0 >>"$BRAVE_TSV" 2>/dev/null || true
  done
) &
wait "$PID"
