# UniFi Network API Access & Capabilities (2026-06)

## Question
For our UDM Pro Max on UniFi Network 10.4.57, driven by an agent using an integration **X-API-KEY**: what does the official Network Integration API expose today (incl. config writes), how do the legacy local-controller endpoints authenticate (cookie+CSRF vs the same API key), what changed in Network 10.x, and what should we use to reliably drive device/radio/firewall writes and ingest events?

## TL;DR
- There are **three distinct APIs**. Don't conflate them: **Site Manager API** (cloud, `api.ui.com/v1`, **read-only today**), **Network Integration API** (local, `/proxy/network/integration/v1`, **read + write**), and the **legacy private API** (`/proxy/network/api/s/<site>/…`, full UI surface).
- The "API key is currently read-only" warning everyone quotes is about the **Site Manager (cloud) API only**. The **local Network Integration API supports writes** — Create/Update/Delete/Patch on networks, WiFi, firewall zones/policies, ACL rules, and device/port actions, all with `X-API-KEY`. This is documented for v10.3.58 (our 10.4.57 is newer).
- The contradiction is resolved: **the integration `X-API-KEY` does authenticate against the legacy `/proxy/network/api/s/<site>/…` endpoints on UniFi OS** — no cookie/CSRF needed. Our successful `rest/device` write is expected behaviour, not a fluke. Cookie+CSRF is only required for self-hosted (non-UniFi-OS) controllers, which we are not.
- **10.x removed `/stat/event` and IDS/IPS endpoints** (confirmed by our own prod incident + upstream) and enforces **429 + `Retry-After`** on the integration API. There is no restoration in 10.4.x. Event/alarm ingestion via the old poller path is dead; use a slow, scoped poll instead.
- **Recommendation:** keep the single integration `X-API-KEY`, use the **integration v1 endpoints** as primary (typed, supported, write-capable), fall back to **legacy `/proxy/network/api/s/default/…` with the same key** only for what v1 doesn't cover (radio channel/tx-power on `rest/device`, BGP/routing). Honour `Retry-After`, poll ≤ once/5 min, never call `stat/event`.

## The three APIs

| | Site Manager API | Network Integration API | Legacy private API |
|---|---|---|---|
| Base URL | `https://api.ui.com/v1` (cloud) | `https://172.16.2.1/proxy/network/integration/v1` (local) | `https://172.16.2.1/proxy/network/api/s/<site>` (local) |
| Auth | `X-API-KEY` (UI account key) | `X-API-KEY` (Network-app key) | `X-API-KEY` **on UniFi OS** (or cookie+CSRF on self-hosted) |
| Site identifier | host/site UUID | **site UUID** (`88f7af54-…`) | **short name** (`default`) |
| Writes? | **No (read-only today)** | **Yes** | Yes (full UI surface) |
| Documented? | Yes (`developer.ui.com/site-manager`) | Yes (`developer.ui.com/network`) | No (reverse-engineered) |
| Stability | stable v1 | versioned per Network app (v10.3.58 doc) | changes between Network versions |

### 1. Site Manager API (cloud) — read-only
`developer.ui.com` landing (v1.0.0, live 2026-06-13): *"The API key is currently read-only. When write endpoints become available, you'll be able to enable write access as needed… A manual update will be required."* Endpoints are cloud-scoped: List Hosts, List Sites, List Devices, ISP Metrics, SD-WAN configs. Rate limit: **100 req/min (EA), 10,000 req/min (v1 stable)**, `429` + `Retry-After` on overage. Not what we drive the UDM with; useful only for multi-site/ISP-metrics read.

### 2. Network Integration API (local) — read **and write**
`developer.ui.com/network`, default doc version **v10.3.58** (live 2026-06-13). *"Each UniFi Application has its own API endpoints running locally on each site."* Auth is the Network-app `X-API-KEY` (Settings → API Keys, generated via Site Manager). Local base path confirmed from the rendered cURL examples: requests target `…/proxy/network/integration/v1/…`. Documented endpoint families and their **HTTP verbs** (captured from the rendered endpoint pages):

- **UniFi Devices**: List Adopted Devices, **Adopt Devices**, **Execute Port Action** (`POST /v1/sites/{siteId}/devices/{deviceId}/interfaces/ports/{portIdx}/actions`), **Execute Adopted Device Action**, Get Details, **Remove (Unadopt) Device**, Latest Statistics, Pending Adoption.
- **Networks**: Get / **Create** / **Update** (`PUT /v1/sites/{siteId}/networks/{networkId}`) / **Delete** / References.
- **WiFi Broadcasts**: Get / **Create** / **Update** / **Delete** / page.
- **Firewall**: List/Get/**Create**/**Update**/**Delete**/**Patch** Zones and Policies, plus **Reorder** policy ordering.
- **Access Control (ACL Rules)**: Get/**Create**/**Update**/**Delete**/Reorder.
- **Switching** (switch stacks, MCLAG), **DNS Policies**, **Traffic Matching Lists**, **Clients** (incl. Execute Connected Client Action), Hotspot **vouchers** (Create/Delete), Application Info (`GET /v1/info`).

So device/port actions, full network/WiFi/firewall/ACL CRUD are first-class here. **Note:** radio channel / tx-power / per-radio config is **not** exposed as a typed integration endpoint yet — that still lives on the legacy `rest/device` object.

Two connection modes documented: **Local** (direct to controller, the path above) and **Remote** (cloud-proxied: `https://api.ui.com/v1/connector/consoles/{consoleId}/proxy/network/integration/v1/…`). We use Local.

### 3. Legacy private API — full surface, same key works
The endpoints the UI itself uses: `rest/device`, `rest/wlanconf`, `rest/networkconf`, `rest/firewallrule`, `rest/firewallgroup`, `stat/*`, `cmd/*` (`cmd/stamgr`, `cmd/devmgr`), `list/*`, `stat/event`, `list/alarm`. On UniFi OS these are all under `/proxy/network/api/s/<site>/…` with `<site>` = the **short name** `default` (not the UUID). Coverage is broad but the surface can change between Network versions and is undocumented.

**Auth — the resolved contradiction:** Our earlier note said device writes need a cookie+CSRF session. That is **only true on self-hosted (non-UniFi-OS) Network Application**. On a UniFi OS console (our UDM Pro Max), the **integration `X-API-KEY` authenticates against legacy endpoints too** — community-tested on UDR-7 / UniFi OS 4.x / Network 10.x: *"The API key works on both the Integration API and the legacy private API — no session cookie needed."* That matches our successful `rest/device` write. The cookie+CSRF flow (`POST /api/auth/login`, then read the `TOKEN` cookie JWT, base64-decode its payload, send the `csrfToken` field as `x-csrf-token` on writes — exactly what the art-of-wifi PHP client v1.1.101 does) is the **fallback for non-UniFi-OS**, and that client has **no API-key mode at all**.

## UniFi Network 10.x changes (confirmed)
- `/api/s/<site>/stat/event` returns **404** ("Events endpoint removed, Network 10.x+"). IDS/IPS/anomalies endpoints are **gone/moved**. Confirmed in our own prod incident on 10.3.58 and upstream (unpoller #1013). **No restoration in 10.4.x.**
- Integration API enforces **429 + `Retry-After: 60s`** under load; aggressive pollers (unpoller v3.1.2 with `SAVE_EVENTS/IDS/ANOMALIES`) crashed our UDM.
- Telemetry was consolidated server-side; there is **no back-compat shim**. Treat event/alarm history as not reliably pollable on 10.x.

## Auth & rate-limit best practices
- **One Network-app `X-API-KEY`** covers integration + legacy on our UniFi OS box. Keep it the only auth path; no password/cookie plumbing needed for us. (Key file already at `config/unifi-api-key`.)
- Keys are issued via **Site Manager → Settings → API Keys** (unifi.ui.com), shown once, account-scoped. There is no per-endpoint scope/permission selector documented today — the key is effectively full-access on the local controller, so guard it like a root credential.
- **Use the right site id per API**: integration v1 → site **UUID** `88f7af54-98f8-306a-a1c7-c9349722b1f6`; legacy → short name **`default`**. Mixing them is a common 404 cause.
- **Rate etiquette**: honour `Retry-After` on 429; poll read endpoints ≤ once/5 min; never call `stat/event`/IDS; deploy new pollers one at a time and watch UDM API latency (cold-start >4 s = back off). Writes are cheap individually but serialise them.
- For the cookie path (only if we ever hit a non-UniFi-OS controller): `POST /api/auth/login`, capture `TOKEN` cookie, decode JWT payload → `csrfToken` → send as `x-csrf-token` header on every POST/PUT/DELETE.

## Recommendations for our setup
1. **Make integration v1 the primary write path.** We can now do, with the existing key: adopt/forget devices, port actions (PoE cycle, port enable/disable), create/update/delete networks + WiFi + firewall zones/policies + ACL rules + DNS policies. Migrate any agent logic that currently scripts these via legacy `rest/*` onto typed v1 endpoints — they're supported and won't shift between versions.
2. **Keep legacy `rest/device` (with the same key) only for radio/channel/tx-power and BGP/routing**, which v1 doesn't expose yet. This is the correct home for the "Keuken ch6 / 2.4 min-rate" class of change. Verify-before-report still applies: GET the object back and diff after every write (UniFi silently drops fields).
3. **Stop trying to ingest events/alarms via the API.** `stat/event` is 404 on 10.x. For network observability, drive HA/Prometheus off the integration **statistics** endpoints (device latest-statistics, `/v1/info`, client overview) on a ≥5-min cadence, plus syslog/SNMP-trap export from the UDM if event history is genuinely needed. Document this as a known 10.x limitation, not a bug to chase.
4. **Adopt a small typed wrapper** that (a) injects `X-API-KEY`, (b) auto-selects UUID vs `default` per endpoint family, (c) centralises `Retry-After` back-off, (d) refuses `stat/event`/IDS calls. This removes the two recurring footguns (wrong site id, 429 storms) in one place.
5. **New capabilities we're not using that are now safe:** programmatic firewall-policy + ACL management, DNS policy management, voucher issuance, and structured port actions — all via supported v1 endpoints with our current key. Good candidates for agent-driven changes once routed through the change-log + QA gate.

## Open / unverified
- **`help.ui.com` "Getting Started" article: could not verify** — Cloudflare bot-protection blocked both WebFetch (403) and headless render. Facts above come from `developer.ui.com` (the actual API spec) instead.
- The "API key works on legacy endpoints, no cookie" claim is **community-tested on UDR-7**, not in Ubiquiti's official docs; it matches our own prod observation on the UDM Pro Max, but Ubiquiti does not formally document legacy-endpoint auth. Treat as "verified by our own write + one corroborating community source", not "officially guaranteed".
- Network Integration API doc is published at **v10.3.58**; we run **10.4.57**. No 10.4.x-specific doc page found — assume ≥ the documented surface; verify any new endpoint against the live controller before relying on it.

## Sources
- UniFi Site Manager API — Getting Started, auth, read-only note, rate limits. `https://developer.ui.com/` (v1.0.0) — rendered live 2026-06-13.
- UniFi Network Integration API — endpoint list, verbs, local/remote base paths, cURL examples. `https://developer.ui.com/network` and `/network/v10.3.58/{gettingstarted,executeportaction,updatenetwork,getinfo,connectorget}` — rendered live 2026-06-13.
- Art of WiFi, "UniFi API Authentication: Local Admin vs API Key vs Site Manager" (posted 2026-04-12) — three auth methods; API key needs UniFi OS console/server; local-admin works on all. `https://artofwifi.net/blog/unifi-api-authentication-local-admin-vs-api-key-vs-site-manager` — fetched live 2026-06-13.
- Art of WiFi, "UniFi APIs: A Practical Guide" — legacy vs official API; official API on **Network App 10.1.84+**; no announced deprecation of internal API. `https://artofwifi.net/unifi-api` — fetched live 2026-06-13.
- Art-of-WiFi/UniFi-API-client `src/Client.php` v1.1.101 — login `/api/auth/login` (UniFi OS) vs `/api/login`; `create_x_csrf_token_header()` decodes `TOKEN` JWT → `csrfToken`; `/proxy/network` prefix; legacy paths `rest/device`, `rest/wlanconf`, `rest/networkconf`, `rest/firewallrule`, `rest/firewallgroup`, `stat/event`, `stat/ips/event`, `list/alarm`; **no API-key mode**. `https://raw.githubusercontent.com/Art-of-WiFi/UniFi-API-client/master/src/Client.php` — downloaded + grepped live 2026-06-13.
- trtmn/agent-skills `unifi-api/SKILL.md` — *"API key works on both the Integration API and the legacy private API — no session cookie needed on UDR-7"*; legacy prefix `/proxy/network/api/s/{site}`; tested UDR-7 / UniFi OS 4.x / Network 10.x. `https://raw.githubusercontent.com/trtmn/agent-skills/main/unifi-api/SKILL.md` — fetched live 2026-06-13.
- Internal: `[memory:unifi-v10-poller-breakage]` (stat/event 404, IDS gone, 429 on 10.3.58, upstream unpoller #1013/#1014) and `[memory:unifi-access]` (local base path, site UUID, key file, 10.4.57). Verified against prod by Iris 2026-05-13.

— Athena

---

## Additional / newer capabilities (researched 2026-06-13)

**Scope:** newer UniFi Network / UniFi OS API features beyond the prior section, framed as "what could we use that we aren't". Doc version is still **v10.3.58** (no 10.4.x doc page exists; we run 10.4.57, assume ≥ documented surface). Every path below was rendered live from `developer.ui.com` (React shell — rendered via headless Chromium, not WebFetch) or corroborated against a cited live page.

### Big-ticket findings (read these first)

**1. UniFi Alarm Manager → custom webhook = the dead-`stat/event` replacement.** *(yes — this is the one to adopt for observability.)*
What: a built-in event engine that fires on real-time Network events (device offline/online, client connect, etc.) and runs an **action** — including a **Webhook (GET or POST to a custom URL)**, plus push/email. Available in **UniFi Network 9.3+** (so present on our 10.4.57) per the live Ubiquiti help article. Configured in-app (Network → Alarm Manager): Trigger + Scope (devices/clients/VLANs/system-wide) + Action; supports schedules and "ignore repeated actions". This is **push, not poll** — it sidesteps the 429/`stat/event`-404 problem entirely. We can point a webhook at an HA webhook trigger or a small Prometheus-pushgateway/Alertmanager receiver. Setup is GUI-only (no documented API to *create* alarms), but the runtime path is a plain outbound HTTP POST we fully control. **Verdict: yes — best available answer to "how do we get network events on 10.x".**

**2. ISP Metrics API (Site Manager, cloud).** *(maybe — useful for WAN/uptime dashboards.)*
What: `GET /v1/isp-metrics/{type}` on the cloud Site Manager API — WAN/ISP performance (5-minute intervals retained ≥24 h; 1-hour intervals ≥30 d). Read-only, account-scoped key. Gives us latency/throughput/uptime history without touching the local controller or any removed endpoint. We already poll `/stat/health` for WAN bandwidth via the revived unifi-exporter; this is a cleaner, supported, cloud-side source for *trend* data (not real-time). **Verdict: maybe — nice for a "WAN over 30 days" Grafana panel; redundant for live bandwidth.**

**3. Local DNS records via integration `dns/policies` CRUD.** *(maybe — could replace the external-dns UniFi webhook path.)*
What: `POST/GET/PUT/DELETE /v1/sites/{siteId}/dns/policies` — manage **local DNS records** of type `A_RECORD / AAAA_RECORD / CNAME / MX / TXT / SRV / FORWARD_DOMAIN` (fields: `type, enabled, domain, ipv4Address, ttlSeconds`). **Important correction:** despite the "DNS Policies" name this is **local DNS record management, not content filtering / DNS Shield** — there is no category/malware/ad-block field. This is directly adjacent to our current setup, where external-dns writes per-hostname A records to the UDM via the kashalls webhook (`[memory:external-dns-unifi]`). A typed, supported CRUD endpoint *could* host a future custom DNS-record reconciler — but the kashalls webhook already works, so this is an option, not a need. **Verdict: maybe — keep in pocket as the supported successor if the webhook breaks.**

### Device & client control (integration v1 — write-capable, our key works)
- **Port action `POWER_CYCLE`** — `POST /v1/sites/{siteId}/devices/{deviceId}/interfaces/ports/{portIdx}/actions`, body `{"action":"POWER_CYCLE"}`. PoE-cycle a port programmatically (e.g. reboot a stuck AP/camera). **Verdict: yes — genuinely useful, low-risk, supported.**
- **Device action `RESTART`** — `POST /v1/sites/{siteId}/devices/{deviceId}/actions`, body `{"action":"RESTART"}`. Reboot an adopted device (AP/switch). **Verdict: yes — useful for runbooks.**
- **Client action** — `POST /v1/sites/{siteId}/clients/{clientId}/actions` (block/reconnect class actions; enum not fully rendered). **Verdict: maybe — block/unblock a client by API; minor for single-operator.**
- **Adopt / Remove device** — `POST .../devices` adopt, `DELETE` to unadopt. **Verdict: no — we adopt by hand, 30-component static estate.**

### Networking config (integration v1)
- **WiFi blackout scheduling** — `createwifibroadcast`/`updatewifibroadcast` expose `blackoutScheduleConfiguration` (scheduled SSID on/off windows) plus `mloEnabled` (Wi-Fi 7 MLO), `bandSteeringEnabled`, `bssTransitionEnabled`, `clientIsolationEnabled`, `arpProxyEnabled`. So **WiFi scheduling IS on the integration API** (as a per-SSID blackout schedule), contrary to my earlier assumption it wasn't exposed. **Verdict: maybe — could schedule a guest/IoT SSID off overnight.**
- **Firewall zones & policies, ACL rules, traffic-matching lists, DNS policies** — full CRUD + reorder (already noted in the prior section). **Verdict: maybe — powerful but high-risk; route through change-log + Argus.**
- **DPI catalogue** — `GET /v1/dpi/applications` and `/v1/dpi/application-categories` (reference data for building traffic-matching lists). **Verdict: maybe — only if we start writing traffic-matching rules.**
- **RADIUS profiles** — `GET /v1/sites/{siteId}/radius/profiles` (read-only). **Verdict: no — no RADIUS in our homelab.**

### VPN & WAN (integration v1 — READ-ONLY today)
- **VPN servers** — `GET /v1/sites/{siteId}/vpn/servers` (no create/update/delete slugs exist). 
- **Site-to-site VPN tunnels** — `GET /v1/sites/{siteId}/vpn/site-to-site-tunnels` (read-only).
- **WANs overview** — `GET /v1/sites/{siteId}/wans` (read-only WAN inventory/status).
- **Verdict: no (for now)** — all three are **read-only**; you cannot create/configure a VPN via the API yet. Single-site homelab has no site-to-site need. Worth re-checking when write verbs appear.

### Legacy private API "v2" endpoints (answer to "any /proxy/network/v2 worth using")
The integration API has **no v2**; "v2" lives on the legacy private surface at `…/proxy/network/v2/api/site/{site}/…`. The one consistently useful family is **Traffic Rules** — `GET/POST v2/api/site/{site}/trafficrules`, `PUT/DELETE v2/api/site/{site}/trafficrules/{id}/` (PUT returns 201) — because traffic rules/routes are **not** in the integration API at all. **Port profiles** and **routing** remain on legacy v1 (`rest/portconf`, `rest/routing`). **Verdict: maybe** — only reach for legacy v2 `trafficrules` if we actually need traffic-rule automation; everything else we want is on integration v1.

### UniFi OS-level / other apps
- **Alarm Manager** spans Network + Protect + Access (same engine) — covered above.
- **UniFi Identity Enterprise Event Hooks** (JSON HTTP POST of workspace events) and **UniFi Protect custom webhooks** exist but are **out of scope** — we run neither Identity nor Protect. **Verdict: no.**
- No documented UniFi OS API for **console backups / multi-site / identity** that applies to a single-site, single-console homelab. **Verdict: no.**

### Honest uncertainty
- All integration paths are from the **v10.3.58** doc; we run **10.4.57** — assume ≥ this surface, verify any specific endpoint against the live controller before relying on it.
- Alarm Manager's *runtime* webhook is well documented; there is **no documented API to programmatically create alarms** — assume GUI-only configuration.
- `community.ui.com` traffic-rules thread is JS-rendered and did **not** load via WebFetch (**could not verify** from that source); the `v2/api/site/{site}/trafficrules` path is corroborated from the live `ubntwiki.com` API page instead.
- Client-action and several enum value lists were not fully rendered in the doc text capture; verbs/paths are confirmed, exact enum members for client actions are **not fully verified**.

### Sources (2026-06-13 additions)
- UniFi Network Integration API endpoint index + per-endpoint method/path/schema (port `POWER_CYCLE`, device `RESTART`, WiFi `blackoutScheduleConfiguration`/`mloEnabled`, `dns/policies` record types, `vpn/servers`, `vpn/site-to-site-tunnels`, `wans`, `dpi/applications`, `radius/profiles`). `https://developer.ui.com/network` + `/network/v10.3.58/{executeportaction,executeadopteddeviceaction,executeconnectedclientaction,createwifibroadcast,creatednspolicy,getvpnserverpage,getsitetositevpntunnelpage,getwansoverviewpage,getdpiapplications,getradiusprofileoverviewpage}` — rendered live in headless Chromium 2026-06-13.
- UniFi Site Manager API — ISP Metrics endpoint, intervals/retention. `https://developer.ui.com/site-manager/v1.0.0/getispmetrics` — rendered live 2026-06-13.
- Ubiquiti Help Center, "UniFi Alarm Manager — Customize Alerts, Integrations, and Automations Across UniFi" — Alarm Manager in **Network 9.3+**; action types incl. **Webhook (GET/POST to custom URL)**; Trigger/Scope/Action model. `https://help.ui.com/hc/en-us/articles/27721287753239-...` — rendered live in headless Chromium 2026-06-13 (WebFetch was Cloudflare-blocked; headless render succeeded).
- Ubiquiti Community Wiki (ubntwiki), UniFi Controller API — legacy `v2/api/site/{site}/trafficrules` (GET/POST/PUT/DELETE), `rest/portconf` (port profiles), `rest/routing`. `https://ubntwiki.com/products/software/unifi-controller/api` — fetched live 2026-06-13.

— Athena
