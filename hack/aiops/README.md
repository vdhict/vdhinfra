# AIOps step 1: alert delivery and the dead man's switch

Change: chg-2026-10-12-009. Owner: observability-engineer (Sibyl).

## Where alerts go

Alertmanager (`kubernetes/main/apps/observability/kube-prometheus-stack/app/alertmanager-secret.yaml`):

| Match | Receiver | When |
|---|---|---|
| `alertname=InfoInhibitor` | `null` (the only null route) | always |
| `alertname=Watchdog` | `heartbeat` -> ntfy heartbeat topic, `hb cluster` every ~5 min | always |
| `severity=critical` | `ha-critical` (HA webhook, unchanged) | always; `component=aiops-*` and `vikunja-sync` by day only |
| `severity=critical` | `ntfy-critical`, priority 4 | 07:00-23:00 Europe/Amsterdam |
| `severity=warning` | `ntfy-day`, priority 3 | 07:00-23:00 |
| warning or critical | `ntfy-night`, priority 1, title `[night] ...` | 23:00-07:00 |
| anything else (info) | `ntfy-low`, priority 1 | always |

Priority 1 (min) means no sound and no vibration on ntfy clients. At 07:00 the
CronJob `observability/aiops-morning-summary` reads the night's `[night]`
messages back from the topic and posts one summary (priority 3, or 2 on a
quiet night).

The ntfy server is the public relay `https://ntfy.sh` (the same one family-ai
uses), with two dedicated random topics: an alert topic (subscribe to this one)
and a heartbeat topic (machine traffic only, do not subscribe). The topics are
secret. They live in:

- the cluster: SOPS secret `kube-prometheus-stack/app/alertmanager-ntfy.sops.yaml`
  (full receiver URLs, read by Alertmanager through `url_file`);
- each Mac: `~/.config/aiops/ntfy.env` (mode 600), never in Git.

## The dead man's switch: three parties, each watched by the other two

| Watched | Heartbeat | Watched by | Alert |
|---|---|---|---|
| cluster (Prometheus + Alertmanager) | Watchdog -> `hb cluster` on the heartbeat topic every ~5 min | the Mini and the Studio, `aiops-mac-agent` every 5 min | `heartbeat lost: cluster` after 15 min silence |
| vdhmini01 (172.16.2.201) | agent publishes `hb vdhmini01` every 5 min; node_exporter | the Studio (ntfy) and the cluster (scrape) | `heartbeat lost: vdhmini01`; `MacHostDown` |
| vdhllmsrv01, the Studio (172.16.2.200) | agent publishes `hb vdhllmsrv01`; node_exporter | the Mini (ntfy) and the cluster (scrape) | `heartbeat lost: vdhllmsrv01`; `MacHostDown` |

If ntfy.sh itself cannot be reached, the agents conclude nothing and send
nothing (the cluster still alerts on the Macs through Prometheus, but its
notification also goes through ntfy).

## Mac half (launchd, per user, no sudo)

Installed by `hack/aiops/mac/install.sh <lan-ip>`:

| launchd label | What |
|---|---|
| `com.vdhict.aiops-node-exporter` | Homebrew node_exporter on `127.0.0.1:9100` only, textfile dir `~/.local/share/aiops/textfile` |
| `com.vdhict.aiops-node-exporter-lan` | launchd owns `<lan-ip>:9100` and hands each connection to `/usr/bin/nc 127.0.0.1 9100` |
| `com.vdhict.aiops-mac-agent` | `~/bin/aiops-mac-agent` every 5 min: heartbeat, peer check, crash metrics |

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
`~/Library/Logs/DiagnosticReports`. Also `mac_aiops_peer_heartbeat_up{peer}`.

## Cluster half

`kubernetes/main/apps/observability/aiops/`: ScrapeConfig `mac-node`,
`aiops-exporter` (token register + Renovate via the GitHub API), the morning
summary CronJob, and PrometheusRule `aiops`. TCP probes of the Macs (ssh) and
the NAS (5001, 2049) are in `blackbox-exporter/app/probe.yaml`.

## Testing on a Mac

    ~/bin/aiops-mac-agent; cat ~/.local/state/aiops/peer-*
    curl -s http://<lan-ip>:9100/metrics | grep ^mac_
