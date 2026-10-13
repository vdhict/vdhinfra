# AIOps step 1: alert delivery and the dead man's switch

Change: chg-2026-10-12-009. Owner: observability-engineer (Sibyl).

## Where alerts go

Alertmanager (`kubernetes/main/apps/observability/kube-prometheus-stack/app/alertmanager-secret.yaml`):

| Match | Receiver | When |
|---|---|---|
| `alertname=InfoInhibitor` | `null` | always |
| `alertname=Watchdog` | `null` (the dead man's switch source; read over the LAN, see below) | always |
| `component=mypka-wires` | `ntfy-day` / `ntfy-night`, never HA | day / night |
| `severity=critical` | `ha-critical` (HA webhook, unchanged) | always; `component=aiops-*` and `vikunja-sync` by day only |
| `severity=critical` | `ntfy-critical`, priority 4 | 07:00-23:00 Europe/Amsterdam |
| `severity=warning` | `ntfy-day`, priority 3 | 07:00-23:00 |
| warning or critical | `ntfy-night`, priority 1, title `[night] ...` | 23:00-07:00 |
| anything else (info) | `ntfy-low`, priority 1 | always |

Priority 1 (min) means no sound and no vibration on ntfy clients. At 07:00 the
CronJob `observability/aiops-morning-summary` reads the night's `[night]`
messages back from the topic and posts one summary (priority 3, or 2 on a
quiet night).

Repeat intervals: 24h for warning and info, 12h for critical.

The ntfy server is the public relay `https://ntfy.sh` (the same one family-ai
uses). Its anonymous quota is **250 messages/day per public IP**, and the KPN
address is shared by the Mini, the MacBook (pka-alert) and the cluster. Until
2026-10-13 a second "heartbeat" topic carried `hb cluster` / `hb <mac>` every
~5 min (~470/day from the KPN address alone); that exhausted the quota and
pka-alert pushes got 429 (Mack, AGR-078). The heartbeat topic is retired. Only
the alert topic remains (subscribe to it). It is secret and lives in:

- the cluster: SOPS secret `kube-prometheus-stack/app/alertmanager-ntfy.sops.yaml`
  (full receiver URLs, read by Alertmanager through `url_file`);
- each Mac: `~/.config/aiops/ntfy.env` (mode 600), never in Git.

## The dead man's switch: on the LAN, ntfy only for a real loss

| Watched | Signal | Watched by | Alert (ntfy) |
|---|---|---|---|
| cluster (Prometheus + Alertmanager) | the ACTIVE `Watchdog` alert in Alertmanager, read with `GET https://alertmanager.<domain>/api/v2/alerts` through envoy-internal (HTTPRoute `alertmanager-heartbeat`: that one GET path only) | `aiops-mac-agent` on the Mini and the Studio, every 5 min | `heartbeat lost: cluster` ONCE after 15 min (3 failed runs), `heartbeat back: cluster` once |
| vdhmini01 (172.16.2.201) | node_exporter scrape `up{job="mac-node"}` | the cluster | `MacNodeDown` (15 min) |
| vdhllmsrv01, the Studio (172.16.2.200) | same | the cluster | `MacNodeDown` (15 min) |
| the agent itself | `mac_aiops_agent_last_run_timestamp_seconds` | the cluster | `MacAgentStale` (> 30 min + 15 min) |

Watchdog fires permanently in Prometheus and is re-sent to Alertmanager every
minute; Alertmanager drops it a few minutes after the last re-send. So an
active Watchdog proves that Prometheus evaluates rules and that Alertmanager
receives them. Its route is `null`, so it costs no ntfy messages.

The Macs no longer watch each other: if the cluster is down, the cluster loss
is the alert that matters. A Mac that cannot reach the LAN endpoint counts
the cluster as down; it only notifies after 15 minutes, and only once.

## Mac half (launchd, per user, no sudo)

Installed by `hack/aiops/mac/install.sh <lan-ip>`:

| launchd label | What |
|---|---|
| `com.vdhict.aiops-node-exporter` | Homebrew node_exporter on `127.0.0.1:9100` only, textfile dir `~/.local/share/aiops/textfile` |
| `com.vdhict.aiops-node-exporter-lan` | launchd owns `<lan-ip>:9100` and hands each connection to `/usr/bin/nc 127.0.0.1 9100` |
| `com.vdhict.aiops-mac-agent` | `~/bin/aiops-mac-agent` every 5 min: LAN cluster check, crash metrics |

Firewall note: the Studio runs the macOS application firewall. It allows
launchd and Apple-signed binaries, and would block (or prompt for) the
ad-hoc-signed Homebrew node_exporter. The launchd-socket pattern needs no
firewall exception and no sudo, and node_exporter never listens on the LAN.
The Mini has the firewall off; it uses the same pattern for uniformity.
These are LaunchAgents: they run while the user session is logged in, like
every other agent on these hosts.

Crash counter (textfile metrics): `mac_diagnostic_reports_24h{kind}` and
`mac_diagnostic_report_last_timestamp_seconds{kind}` for kind = crash, jetsam,
panic, resource, from `/Library/Logs/DiagnosticReports` and
`~/Library/Logs/DiagnosticReports`. Also `mac_aiops_peer_heartbeat_up{peer="cluster"}`
(1 = Watchdog seen over the LAN) and `mac_aiops_agent_last_run_timestamp_seconds`.

`~/.config/aiops/ntfy.env` needs `NTFY_SERVER`, `NTFY_ALERT_TOPIC` and
`AIOPS_AM_URL=https://alertmanager.<domain>`. `NTFY_HB_TOPIC` is unused.

## Cluster half

`kubernetes/main/apps/observability/aiops/`: ScrapeConfig `mac-node`,
`aiops-exporter` (token register + Renovate via the GitHub API), the morning
summary CronJob, and PrometheusRule `aiops`. TCP probes of the Macs (ssh) and
the NAS (5001, 2049) are in `blackbox-exporter/app/probe.yaml`.

## Testing on a Mac

    AIOPS_DRY_NOTIFY=1 ~/bin/aiops-mac-agent; cat ~/.local/state/aiops/lan-cluster
    curl -s http://<lan-ip>:9100/metrics | grep ^mac_
