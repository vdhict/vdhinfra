# NanoStation AC Management Options

## Question
What is the best management strategy for two Ubiquiti NanoStation AC airMAX bridge devices (Achtertuin + Schuur) in a UniFi-first homelab, given that UniFi cannot manage airMAX?

## TL;DR

- **Recommend lightweight DIY over UISP** for two devices. UISP carries a 4 GB RAM / 16 GB SSD Linux VM requirement, demands a public IP and FQDN for Let's Encrypt to function correctly, and its Docker image is community-maintained (not Ubiquiti). That overhead is disproportionate to two static P2P bridge units with a combined change frequency near zero.
- **Concrete DIY stack**: SSH config pull via cron to Git (SCP `scp -O` from `/tmp/system.cfg`), SNMP scrape via prometheus/snmp_exporter using the `ubiquiti_airmax` module (OID `1.3.6.1.4.1.41112.1.4`), syslog UDP/514 forwarded to Loki via Promtail or your existing syslog receiver. Firmware updates remain manual via SSH one-liner — scripted but operator-triggered.
- **UniFi Network cannot manage airMAX**. Confirmed still separate product lines as of July 2024. No convergence announced.
- airOS 8.7.13 (June 7, 2024) is the current XC firmware for NanoStation AC. No documented REST API; all programmatic access goes through SSH + `/tmp/system.cfg` or SNMP.
- **Status quo (per-device web UI only)** is fine for day-zero but leaves zero visibility into signal quality, uptime, or config drift. The DIY stack costs ~2 hours to implement and gives you full observability.

## Current State of airMAX Management

**UniFi vs UISP are permanently separate.** UniFi manages switches, APs, cameras, and gateways. UISP manages airMAX, airFiber, LTU, EdgeMAX, UFiber, and UISP-branded ISP gear. The HostiFi comparison page (fetched 2026-05-26, dated July 2024) states explicitly: "If you need products from both sides, you need to operate two separate controllers." No announcement of merge exists.

**airOS 8.x firmware** is at 8.7.13 for XC-platform devices (NanoStation AC), released June 7, 2024 (fetched from `dl.ubnt.com/firmwares/XC-fw/v8.7.13/changelog.txt`, 2026-05-26). The changelog confirms this release includes memory optimisation for UISP management systems, meaning UISP is the official management path Ubiquiti assumes.

**No documented REST API.** There is no Ubiquiti-published HTTP API for airOS config push/pull. The community-discovered method is SSH to `/tmp/system.cfg` (key-value flat file). This is confirmed by the Nornir community and multiple Incredigeek guides, and is the basis for the `airos` PyPI package and the `euphdk/airos-config` GitHub tool. The Home Assistant airOS integration (v0.1.6, July 26, 2025) follows the same pattern: it wraps a browser-emulating library, not a REST API.

**Web UI is HTTPS with self-signed cert by default.** Community posts confirm devices present "insecure" browser warnings from a self-signed certificate. Custom cert replacement via SSH is documented but requires per-device manual steps.

## The Three Options

### Option 1: UISP Self-Hosted

**Who**: Ubiquiti's official ISP/WISP management platform. Designed for operators with dozens or hundreds of airMAX devices.

**Core pattern**: Install script runs on Ubuntu 22.04 / Debian 12 only (Linux-only, not macOS, not Windows). Fetches and manages its own Docker containers internally — in-app upgrades require pulling new Docker images, not a `helm upgrade`. The community Docker image (`nico640/docker-unms`, 910 MB, version 3.0.159 as of March 2026) is the only k8s-adjacent path, but Ubiquiti explicitly does not support it. Official requirements: 2-core 64-bit CPU with SSE 4.2, 4 GB RAM minimum, 16 GB SSD, Linux. A public IP + FQDN is strongly recommended for Let's Encrypt to work; without it, advanced features degrade. Port 443 (device connector), 80 (LE), 81 (suspension page), 8089 (local remote access) must be open.

**What it buys**: Multi-device firmware push, config history, signal monitoring, outage alerting, Google Maps topology view.

**What it sacrifices**: A full Linux VM or bare-metal host just for two devices; no official k8s path; macOS Docker Desktop is not supported (VirtualBox VM required); does not integrate into your existing Prometheus/Loki stack — it's a parallel island.

**Where it runs in this environment**: Not on k8s (the self-managed Docker containers break Flux's reconciliation model and the install script expects systemd). Not on the Mac Mini without a Linux VM layer. Not on the UDM Pro — the UDM Pro can host one additional UniFi application (Network is already there); UISP is not in the UniFi OS application catalogue.

**Verdict for 2 devices**: Overbuilt. The marginal benefit over DIY is firmware push to N devices simultaneously — irrelevant at N=2.

---

### Option 2: Lightweight DIY (recommended)

**Who**: Any operator running existing Prometheus + Loki infrastructure who wants observability without a new management plane.

**Core pattern**: Three independent pieces, each independently useful:

1. **Config backup to Git**: Cron job runs `scp -O ubnt@<host>:/tmp/system.cfg ./configs/<hostname>.cfg && git commit -m "config backup"` for each device. Use `scp -O` (legacy SCP protocol — SFTP is not supported by airOS). The `/tmp/system.cfg` flat-file is the canonical config source. Confirmed approach from Incredigeek and community posts. Apply changes by pushing a modified cfg back via SCP and running `/usr/etc/rc.d/rc.softrestart save` via SSH.

2. **SNMP scraping**: Enable SNMP on each device (web UI > Services, or set `snmp.community` in `/tmp/system.cfg` via SSH). Use prometheus/snmp_exporter with the built-in `ubiquiti_airmax` module (OID `1.3.6.1.4.1.41112.1.4`) — this is in the upstream `generator.yml` (fetched from github.com/prometheus/snmp_exporter, 2026-05-26). Add a scrape target per device in your existing snmp_exporter config. Zabbix also has an official airOS SNMP template for reference. Known quirk: NanoStation devices report ifSpeed=0 for VLAN/wireless interfaces — use signal-quality OIDs from the airMAX MIB, not ifSpeed, for link health.

3. **Syslog to Loki**: airOS supports UDP syslog to a remote host on port 514 (configurable via web UI Services > System Log). Feed into your existing Promtail syslog receiver or an rsyslog relay in front of Promtail (the standard architecture documented by Alexandre de Verteuil, 2022, still current approach).

4. **Firmware updates (semi-automated, operator-triggered)**: `ssh ubnt@<host> "curl -k -o /tmp/fwupdate.bin <firmware-url> && ubntbox fwupdate.real -m /tmp/fwupdate.bin"`. The device reboots automatically after flashing. Confirmed method from Incredigeek (fetched 2026-05-26). UISP could push to both simultaneously, but two devices makes this a 2-minute manual task per release — current firmware is 8.7.13 from June 2024, so update frequency is low.

**What it buys**: Full integration into existing Grafana/Loki observability stack, config history in Git, zero new services to operate.

**What it sacrifices**: No map view, no billing/outage management (irrelevant for a homelab). Firmware push requires two SSH invocations instead of one UISP click.

---

### Option 3: Status Quo (per-device web UI only)

**Who**: Valid starting point for a single operator who never needs to look at the devices.

**Core pattern**: Log in to 172.16.3.43 and 172.16.3.74 via browser (HTTPS, accept self-signed cert) when needed. No automation, no observability.

**What it buys**: Zero setup cost.

**What it sacrifices**: No signal quality visibility in Grafana, no config drift detection, firmware updates require remembering to check manually, no syslog in Loki. For a P2P bridge you never touch, this is survivable — until a wireless issue causes unexplained latency and you have no historical signal data to diagnose it.

---

### Option 4 (reference only): Third-party NMS

LibreNMS has a native `Airos.php` module (fetched from github.com/librenms/librenms, 2026-05-26) that discovers airMAX wireless metrics (RSSI, CCQ, TX/RX power, noise floor, capacity) using UBNT-AirMAX-MIB OIDs. Zabbix has an official airOS SNMP template (Zabbix 5.0 through 7.4, fetched from zabbix.com, 2026-05-26). Both are viable if you already run LibreNMS or Zabbix — but adding either to this homelab solely for two devices duplicates what prometheus/snmp_exporter + Grafana already does.

## Recommendation

Implement the lightweight DIY stack on the existing Prometheus + Loki infrastructure. Estimated setup time: ~2 hours.

**Concrete next steps** (for Hephaestus/Sibyl to execute):

1. Enable SNMP on both devices (web UI, or via SSH cfg edit). Community string `public` is fine for a private LAN segment.
2. Add `ubiquiti_airmax` module to your snmp_exporter config and add scrape targets for `172.16.3.43` and `172.16.3.74`. Build a Grafana panel with signal strength (RSSI), noise floor, TX/RX rate, and CCQ from the airMAX MIB.
3. Configure syslog forwarding on each device to your Loki/Promtail syslog receiver (UDP 514).
4. Add a daily cron job on the Mac Mini that SCPs `/tmp/system.cfg` from each device and commits to a `configs/airmax/` subdirectory in this repo (or a separate ops repo).
5. Leave firmware as manual-with-script: keep the SSH one-liner in a runbook. Next firmware event is likely months away.

Do not deploy UISP. Do not add a management VM for two static bridge units.

## Sources

| Source | URL | Fetch status | Date |
|---|---|---|---|
| HostiFi: UniFi vs UISP | https://www.hostifi.com/blog/ubiquiti-unifi-vs-uisp | Live, fetched 2026-05-26 |
| HostiFi: UISP installation requirements | https://www.hostifi.com/blog/how-to-install-uisp-controller-on-ubuntu | Live, fetched 2026-05-26 |
| Nico640/docker-unms (Docker Hub) | https://hub.docker.com/r/nico640/docker-unms | Live, fetched 2026-05-26 (v3.0.159, 910 MB, March 2026) |
| Nico640/docker-unms (GitHub) | https://github.com/Nico640/docker-unms | Live, fetched 2026-05-26 (last release 3.0.159, March 1 2026) |
| airOS XC firmware changelog v8.7.13 | https://dl.ubnt.com/firmwares/XC-fw/v8.7.13/changelog.txt | Live, fetched 2026-05-26 (released June 7, 2024) |
| airOS SNMP guide (Incredigeek) | https://www.incredigeek.com/home/configure-airos-snmp-settings-over-ssh/ | Live, fetched 2026-05-26 |
| airOS firmware via SSH (Incredigeek) | https://www.incredigeek.com/home/upgrade-firmware-on-ubiquiti-airmax-equipment-from-the-command-linessh/ | Live, fetched 2026-05-26 |
| Prometheus snmp_exporter generator.yml | https://github.com/prometheus/snmp_exporter/blob/main/generator/generator.yml | Live, fetched 2026-05-26 |
| Zabbix Ubiquiti airOS integration | https://www.zabbix.com/integrations/ubiquiti | Live, fetched 2026-05-26 |
| LibreNMS Airos.php | https://github.com/librenms/librenms/blob/master/LibreNMS/OS/Airos.php | Live, fetched 2026-05-26 |
| euphdk/airos-config | https://github.com/euphdk/airos-config | Live, fetched 2026-05-26 |
| Warbel: custom TLS on airOS | https://blog.warbel.net/index.php/2022/07/08/configuring-ubiquiti-powerbeam-with-custom-tls-certificates/ | Live, fetched 2026-05-26 (implies HTTPS+self-signed default) |
| Logmanager airOS 5 syslog | https://doc.logmanager.com/latest/log-source-devices/ubiquiti-networks-airos-5/ | Live, fetched 2026-05-26 (UDP/514 only) |
| HA airOS integration | https://www.home-assistant.io/integrations/airos/ | Live (partial), fetched 2026-05-26 |
| CoMPaTech hAirOS (GitHub) | https://github.com/CoMPaTech/hAirOS | Live, fetched 2026-05-26 (v0.1.6, July 26, 2025) |
| UISP help centre (first setup) | https://help.uisp.com/hc/en-us/articles/22591008678039 | HTTP 403 — could not verify |
| UISP help centre (add devices) | https://help.uisp.com/hc/en-us/articles/22590956342295 | HTTP 403 — could not verify |
| UISP help centre (firmware mgmt) | https://help.uisp.com/hc/en-us/articles/22590880030871 | HTTP 403 — could not verify |
| UISP k8s Helm chart community | https://community.ui.com/questions/K8s-Helm-Chart-for-UISP/514e08e6-afc4-49ce-b3a0-e451b6945cb3 | JS-rendered, could not verify |

— Athena
