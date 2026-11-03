#!/bin/sh
# Health probe for the study-material reader on the Studio (chg-2026-11-03-007). launchd runs it every 5 min.
# Writes counts-only metrics to the node-exporter textfile dir; the aiops PrometheusRule alerts on them.
# Atomic like pka.prom: temp name without .prom, then mv. No body, token or page content is ever read or written.
TEXTFILE_DIR="${SM_TEXTFILE_DIR:-$HOME/.local/share/aiops/textfile}"
code=$(/usr/bin/curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:18769/gezond)
up=0; [ "$code" = 200 ] && up=1
tf="$TEXTFILE_DIR/.studiemateriaal.prom.tmp"
{
  echo '# HELP studiemateriaal_worker_up 1 when the reader on 127.0.0.1:18769 answers /gezond with 200.'
  echo '# TYPE studiemateriaal_worker_up gauge'
  echo "studiemateriaal_worker_up $up"
  echo '# HELP studiemateriaal_probe_last_run_timestamp_seconds End of the last probe run.'
  echo '# TYPE studiemateriaal_probe_last_run_timestamp_seconds gauge'
  echo "studiemateriaal_probe_last_run_timestamp_seconds $(date +%s)"
} >"$tf" && chmod 600 "$tf" && mv -f "$tf" "$TEXTFILE_DIR/studiemateriaal.prom"
