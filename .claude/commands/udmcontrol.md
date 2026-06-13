---
description: Operate the UDM Pro Max (UniFi OS + Network controller) at 172.16.2.1 — static DNS, devices, clients, settings, traffic rules. Apply this whenever a task touches the UniFi controller; do not invent curl pipelines from scratch.
---

# /udmcontrol — UDM Pro engineer

You are operating a **production** UniFi UDM Pro Max. Treat it as the network's brainstem: when it stalls or crashes, the entire homelab (cluster, smart-home, cameras, internet for the household) is impaired. Bias toward read-only inspection; write operations need a reason.

## Footguns proven by past incidents

**`AAAA` records in `static-dns` are a known footgun.** The UniFi API accepts a POST of `record_type: AAAA`; the controller stores it; but the embedded DNS resolver (dnsmasq) does **not** consult the static-dns table for AAAA queries — it forwards them to the upstream resolver. **And** writing an AAAA record can trigger a controller crash (auto-recovered on 2026-05-13, scope unclear: full UniFi OS or just the Network module). Never write AAAA via `/proxy/network/v2/api/site/default/static-dns/`. If you need split-horizon AAAA, do it elsewhere (Pi-hole, AdGuard Home, or configure Cloudflare DNS).

**The UniFi controller and UDM firmware are closed-source.** API behavior can change silently across firmware releases. Before relying on an unusual endpoint, verify it still behaves as documented (see "On firmware updates" below).

## Where things live

- **Address**: `172.16.2.1` (HTTPS, self-signed cert — always use `curl -sk`)
- **Hardware/OS**: UDM Pro Max (UDMPROMAX), UniFi OS firmware
- **Dual WAN**: Ziggo (77.250.45.126) + KPN (86.80.222.126). KPN provides native IPv6 to clients.
- **API auth — pick the right key for the endpoint:**
  - **Local integration API key** (newer, REST-style): `~/Code/homelab-migration/config/unifi-api-key`. Header `X-API-KEY`. Authenticates the Network Integration API **and** — confirmed on our UniFi-OS UDM — the legacy private API directly (no cookie/CSRF needed; see Three-API model below).
  - **external-dns-unifi key**: `kubectl get secret -n network external-dns-unifi-secret -o jsonpath='{.data.api-key}' | base64 -d`. Used for the static-dns endpoint under `/proxy/network/v2/api/site/default/static-dns/`.
  - Both are X-API-KEY style; they often have different permission scopes — try the static-dns key first for DNS work.
- **Site ID** (integration API path param): `88f7af54-98f8-306a-a1c7-c9349722b1f6`. **The integration API uses this UUID; the legacy private API uses the literal `default`. Don't cross them.**

## Three-API model (read this before saying "read-only")

There is no single "UniFi API". Three surfaces, three capability levels:

| Surface | Base | Auth | Capability |
|---|---|---|---|
| **Site Manager** (cloud) | `https://api.ui.com` | UI cloud key | **Read-only.** Inventory/telemetry across sites. Don't reach for it for writes — that's the "UniFi is read-only" myth. |
| **Network Integration API** | `/proxy/network/integration/v1/...` | our `X-API-KEY` | **Read + write.** Device/client **actions** (reboot/adopt/locate/PoE cycle), CRUD on networks/WiFi/firewall-zones/DNS-policies. Documented, schema-stable. Prefer this where it covers the task. |
| **Legacy private API** | `/proxy/network/api/s/default/...` | our `X-API-KEY` **directly** | **Full UI surface** — everything the web UI does (per-device `rest/device`, BGP, some firewall ops). **CONFIRMED: our integration X-API-KEY authenticates against it with NO cookie/CSRF login on our UniFi-OS UDM.** The `/api/auth/login` cookie dance is no longer required for these writes. |

Decision rule: reach for the **Integration API** first (cleaner, documented). Drop to the **legacy private API** only for what Integration can't reach (per-AP radio table, BGP). Site Manager is reads only.

## Canonical endpoints

| Goal | Method | Path |
|---|---|---|
| List static DNS records | GET | `/proxy/network/v2/api/site/default/static-dns/` |
| Add a static DNS record (A or CNAME only) | POST | `/proxy/network/v2/api/site/default/static-dns/` body `{"key":"<fqdn>","value":"<ip-or-cname>","record_type":"A"\|"CNAME","enabled":true}` |
| Delete a static DNS record | DELETE | `/proxy/network/v2/api/site/default/static-dns/<_id>` |
| List devices | GET | `/proxy/network/integration/v1/sites/<site_id>/devices` |
| List clients | GET | `/proxy/network/integration/v1/sites/<site_id>/clients` |
| Device action (reboot/adopt/locate) | POST | `/proxy/network/integration/v1/sites/<site_id>/devices/<id>/actions` body `{"action":"RESTART"\|"ADOPT"\|"LOCATE"}` |
| PoE port cycle | POST | `/proxy/network/integration/v1/sites/<site_id>/devices/<id>/interfaces/ports/<idx>/actions` body `{"action":"POWER_CYCLE"}` |
| **Read** device state (radio_table, stats) | GET | `/proxy/network/api/s/default/stat/device` — use this for GET-after-write diffs |
| **Write** per-AP radio (channel/tx_power/min_rssi/min_rate) | PUT | `/proxy/network/api/s/default/rest/device/<_id>` (integration key, no cookie) — see radio_table rule below |

**Per-AP radio writes (CONFIRMED).** `PUT .../rest/device/<_id>` with the integration `X-API-KEY` writes channel / tx_power / min_rssi / min_rate. You must send the **entire `radio_table` array**, mutating only the target field — partial bodies get dropped. Proven: chg-2026-06-13-001 (`min_rssi -78`) and chg-2026-06-13-004 (channel 60→36→60). This **retires the old "channel writes need a legacy `/api/auth/login` cookie" guidance** — it's false on our UDM; the integration key authenticates `rest/device` directly.

**Read-back footgun.** `GET .../rest/device/<_id>` **404s — it is write-only.** Read device state back via `GET .../stat/device` for every GET-after-write diff. Silent-drop watch: `min-rate` only persisted once `minrate_setting_preference=manual` was also set in the same PUT; `min_rssi` and `channel` persisted without an extra preference flag. Always diff field-by-field against intent.

BGP/routing remain on the legacy private API (same key, `rest/...` / `set/setting/...`).

## Read-only patterns (prefer these)

```bash
# Pull static-dns key from the cluster, no copy/paste of secrets
API_KEY=$(kubectl get secret -n network external-dns-unifi-secret -o jsonpath='{.data.api-key}' | base64 -d)

# List a focused subset (don't dump 60+ records to context)
curl -sk -H "X-API-KEY: $API_KEY" \
  https://172.16.2.1/proxy/network/v2/api/site/default/static-dns/ \
  | jq '.[] | select(.key|test("hass|keuken"))'

# Check controller reachability + service alive (does NOT consume sessions)
curl -sk -o /dev/null -w 'http=%{http_code} t=%{time_total}\n' --max-time 5 https://172.16.2.1/
```

## Anti-patterns — DO NOT do these

- ❌ POST/PUT an `AAAA` record to `static-dns/` (see top of file).
- ❌ Loop many POSTs in tight succession. UniFi Network apply cycles can stall; rate-limit yourself to one write every 1–2 s.
- ❌ Open a `/api/auth/login` cookie session for writes our integration key already authenticates (per-AP radio, most legacy `rest/...`). Cookie sessions + stale CSRF tokens waste a debugging hour; use the X-API-KEY against the legacy private API directly (see Three-API model).
- ❌ `GET .../rest/device/<_id>` to read device state — it 404s. Read via `stat/device`.
- ❌ Send a partial `radio_table` on a `rest/device` PUT — dropped fields. Send the full array.
- ❌ Hardcode the UDM IP elsewhere. Always reference `172.16.2.1` so this file owns the truth.
- ❌ Take action via the UDM during peak household usage (movies, calls) without warning the user. A crash of the network module = TV buffering, calls dropping.

## On firmware / controller updates

When the UDM firmware or the UniFi Network application is updated (visible signals: UI banner, `device.version` field changes, behavior changes in API responses, the user mentioning an update) **before relying on any non-trivial endpoint**:

1. Pull the running version: `curl -sk -H "X-API-KEY: $KEY" https://172.16.2.1/proxy/network/integration/v1/info` (or scan one device for its `.version`).
2. Check the [UniFi Network Application changelog](https://community.ui.com/releases?os=network-application) for entries since the previous-known version. Look in particular for: API removals/renames, DNS handling, auth scope changes, response schema changes.
3. Check the [UniFi OS changelog](https://community.ui.com/releases?os=unifi-os) for the same span.
4. Record any cluster-relevant change in a `reference_unifi_<version>.md` memory pointer from `MEMORY.md`. Include: old behavior, new behavior, how to detect, mitigation.
5. If you discover the new behavior breaks an existing helmrelease/external-dns config, surface that to the user before continuing — don't silently work around it.

You can't proactively monitor UniFi releases from this skill, but **any session that touches the UDM API for the first time after a noticed version bump must do steps 1–4 before write operations**.

### Network 10.x — what changed (CONFIRMED)

- **`stat/event` and `stat/alarm` are gone (404).** Polling for network events no longer works. For events/alarms use the **Alarm Manager → custom webhook** (push) instead — configure an alarm that POSTs to a downstream collector rather than polling the controller. (Background on the poller breakage: `reference_unifi_v10_poller_breakage` memory.)
- **Integration API now rate-limits.** Expect `429` with `Retry-After`; pace writes (one every 1–2 s already in our anti-patterns) and back off on `Retry-After` rather than retry-spamming.

### Further reference

- Full API map, key-vs-surface matrix, and the auth-confirmation evidence: `docs/research/unifi-api-access-2026-06.md`.
- Quick path lookup: `reference_unifi_api_paths` memory.

## Sensitive operations

Confirm with the user before:
- Restarting the controller, the UDM (`systemctl restart unifi`), or rebooting the appliance.
- Changing firewall rules, traffic rules, port forwards, VLANs/networks.
- Adopting/forgetting devices, changing AP/switch settings.
- DHCP scope, lease, or reservation changes.
- Any `POST/PUT/DELETE` to `/proxy/network/v2/api/site/default/` outside of `static-dns/` for A/CNAME records.

## When the UDM looks unhappy

- `curl https://172.16.2.1/ -> http=503/502/504` or `http=000`: controller down — wait 30–60 s for watchdog auto-recover before touching anything.
- DNS resolution stops: `dig @172.16.2.1 google.com` no answer → the resolver inside the Network app died (often a Network-only crash, UniFi OS host still fine).
- external-dns-unifi webhook logs `invalid character '<' looking for beginning of value` → UniFi returned an HTML error page instead of JSON, usually a 401/redirect → API key invalid or scope changed; do not retry-spam.

When in doubt: read, don't write. The household's internet and the cluster are downstream of this device.
