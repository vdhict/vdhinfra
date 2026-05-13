# UDM Pro Max state snapshot — 2026-05-13 13:25 UTC

Change ticket: `chg-2026-05-13-020`. Context: support Athena's investigation of inc-2026-05-13-003 (UDM crashes under polling load). All probes read-only, one at a time, ≥2 s gaps.

## Reachability
- HTTP `GET https://172.16.2.1/`: `http=200`, `t=0.030 s` — UniFi OS web server responsive.
- DNS `dig @172.16.2.1 hass.bluejungle.net +short`: `172.16.2.243`, rc=0 — embedded resolver answering.

## Versions
- Firmware (UniFi OS): not exposed by integration `/info`; only the Network application version is returned.
- Controller / Network App (`/proxy/network/integration/v1/info`): `10.3.58`.
- Drift from memory (`reference_unifi.md` records 5.0.16 / 10.2.93): **YES** on Network app — memory was at 10.2.93, current is 10.3.58. UniFi OS firmware not re-confirmed in this probe (kept quiet; one read endpoint is enough).
- Action item (out of scope here): the udmcontrol "firmware/controller updates" checklist needs to run before any next write — Network app jumped a minor version, schema/auth scope may have shifted.

## Load indicators
- Uptime: integration `/info` does not expose uptime; legacy `/api/.../stat/health` skipped (would require cookie session = write). Not collected.
- Response-time anomaly worth flagging: same UDM answered `GET /` in 30 ms but `GET /proxy/network/integration/v1/info` in **4.86 s** on first call (second integration call to `/sites/<id>/devices` finished in 123 ms). The Network application is slow to wake on the first integration-API request even when the OS-level web server is instant. Consistent with a Network module under stress or recently restarted.

## Poller status (confirmed quiet)
- `external-dns-unifi` (network ns): replicas=0/0, HR `spec.suspend=true`.
- `unifi-exporter` (observability ns): replicas=0/0 at the Deployment level (no HelmRelease — raw manifest, scaled to zero in Git); Flux Kustomization itself is `Applied=True` so it will not get re-scaled by drift.
- `unpoller` (observability ns): replicas=0/0, HR `spec.suspend=true`. Flux Kustomization is `Ready=False` ("HelmRelease status: Failed") — cosmetic; the workload is not running.
- HA UniFi integration (`config_entries/get unifi`): `state=not_loaded`, `disabled_by=user`, entry id `01JE19FZATZPVCZWB626NXPJXS`, title "VDH FemFlex". Confirmed disabled.
- `cluster-health` `collect.sh`: line 50 reads `# run_collector network    python3 /scripts/collect_network.py` — commented out. Confirmed.

## Sample device payload (one device, redacted)
From `/proxy/network/integration/v1/sites/<site_id>/devices?limit=1`:

- Model: `USW 16 PoE`
- Firmware: `7.4.1`
- State: `ONLINE`
- `firmwareUpdatable: false`
- Features: `switching`; interfaces: `ports`
- totalCount across the site: **12 devices**

Payload shape is the expected v1 integration schema; no surprise fields.

## Observations
1. **The Network application version drifted (10.2.93 → 10.3.58) without it being recorded in memory.** Per udmcontrol footgun rules, this alone is reason to re-walk the changelog before any future write. May also be relevant to Athena: 10.3.x is a different code path than the version we last validated against, and the crash on the 2026-05-13 AAAA write happened **on this newer version** — not on the version the memory captured.
2. **Cold-start latency on the integration API (4.86 s for a 30-byte response) while the OS-level HTTP was 30 ms** suggests the Network module is currently lightly loaded but slow to spin up handlers — consistent with a recent restart / watchdog recovery and consistent with the crash hypothesis (Network app under poll pressure).
3. **All pollers are confirmed quiet.** Nothing in the cluster is currently hitting the UDM API at any cadence. If the UDM still struggles in the next hour, the cause is not us.

## What I did NOT do (and why)
- **Did not call `/proxy/network/v2/api/site/default/static-dns/`** — we already know it has been flaky from the controller's perspective and Athena is researching exactly that surface; another GET there would add noise to her timeline without new information.
- **Did not pull `/api/s/default/stat/health` (legacy cookie API for uptime/load)** — requires creating a session (POST `/api/auth/login`), which violates the "no writes" constraint. The integration `/info` does not surface uptime.
- **Did not iterate devices** — sampled one with `limit=1`. The brief asked for a single snapshot to confirm reachability and payload shape; iterating would risk being misread as resuming polling.
- **Did not retry any probe.** Everything returned 200 first try, but the policy stands.
- **Did not SSH the UDM** for events. Out of scope ("don't try to scrape SSH").

— Iris
