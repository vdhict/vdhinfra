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
  - **Local integration API key** (newer, REST-style): `~/Code/homelab-migration/config/unifi-api-key`. Header `X-API-KEY`. Used by Site/Device/Client integration endpoints under `/proxy/network/integration/v1/...`.
  - **external-dns-unifi key**: `kubectl get secret -n network external-dns-unifi-secret -o jsonpath='{.data.api-key}' | base64 -d`. Used for the static-dns endpoint under `/proxy/network/v2/api/site/default/static-dns/`.
  - Both are X-API-KEY style; they often have different permission scopes — try the static-dns key first for DNS work.
- **Site ID** (integration API path param): `88f7af54-98f8-306a-a1c7-c9349722b1f6`

## Canonical endpoints

| Goal | Method | Path |
|---|---|---|
| List static DNS records | GET | `/proxy/network/v2/api/site/default/static-dns/` |
| Add a static DNS record (A or CNAME only) | POST | `/proxy/network/v2/api/site/default/static-dns/` body `{"key":"<fqdn>","value":"<ip-or-cname>","record_type":"A"\|"CNAME","enabled":true}` |
| Delete a static DNS record | DELETE | `/proxy/network/v2/api/site/default/static-dns/<_id>` |
| List devices | GET | `/proxy/network/integration/v1/sites/<site_id>/devices` |
| List clients | GET | `/proxy/network/integration/v1/sites/<site_id>/clients` |
| Login (legacy cookie API) | POST | `/api/auth/login` body `{"username":"...","password":"..."}` — only when integration API can't do it |

Most BGP/routing endpoints are still legacy cookie-API only.

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
- ❌ Use the legacy cookie API where the integration API works — cookie sessions accumulate and a stale CSRF token wastes a debugging hour.
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
