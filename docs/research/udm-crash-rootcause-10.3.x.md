# UDM Pro Max crash under poller load — 10.3.x re-research

**Supersedes the 10.2.x focus of [udm-crash-rootcause.md](./udm-crash-rootcause.md) (chg-2026-05-13-019).** The previous doc targeted UniFi Network 10.2.93; Iris verified actual controller is **10.3.58 / UniFi OS 5.0.16**. Re-scoped to the 10.3.x branch.

## Question

On UniFi Network 10.3.x specifically (we are on **10.3.58**, firmware auto-upgrade enabled): what known issues from the 10.3.x release notes / community / GitHub explain a UDM Pro Max crashing under polling load, and is there a fix-version we should wait for?

## TL;DR

- **The 10.3.x branch has only TWO shipped versions: 10.3.55 (official 2026-04-20) and 10.3.58 (beta 2026-04-22, official 2026-05-07). The earlier 10.3.47 / 10.3.52 only existed in beta. We are running the latest in-branch build.** Neither 10.3.55 nor 10.3.58 mentions crash, OOM, watchdog, dnsmasq, rate-limit, or reverse-proxy fixes — only generic "improved overall application stability and resiliency" (10.3.55) and "improved resiliency for applying Orchestrations" (10.3.58). **There is no specific 10.3.x advisory that names our symptom.**
- **There is no 10.4.x release.** No newer 10.3.x in beta either. So **there is no fix-version on the horizon to wait for** — auto-upgrade will not save us.
- **The 10.x controller has changed API behavior in a way that breaks legacy pollers.** [unpoller #1013](https://github.com/unpoller/unpoller/issues/1013) (filed 2026-05-10 by a *different* user also on **10.3.58**) reproduces our symptom: integration API returns **HTTP 429 with `Retry-After: 60s`** under unpoller's load; legacy endpoints `/stat/event` and IDS/IPS return **404 ("Events endpoint removed (Network 10.x+)")**. Their poller went into a re-auth + retry storm exactly like ours did. unpoller [PR #1014](https://github.com/unpoller/unpoller/pulls/1014) (merged 2026-05-12) caches scrapes from a background pool to stop the hammering — but this is a **client-side mitigation, not a controller fix**.
- **The "invalid character '<'" pattern from the kashalls webhook is still consistent with overload-triggered HTML-on-error from the legacy `/proxy/network/v2/api/.../static-dns/` endpoint.** No kashalls GitHub issues since Feb 2026 mention 10.3.x specifically — only Renovate dashboards. Silence is also a data point: this webhook is not heavily exercised, our use-case is not in the head of the distribution.
- **dnsmasq angle: no 10.3.x release-note entry mentions dnsmasq, DNS, or static-dns handling.** Our 2026-05-13 AAAA-write incident has no upstream corroboration in the 10.3.x changelog. Posture from previous doc unchanged: keep the AAAA-footgun guardrail, but don't treat dnsmasq as the primary explanation.
- **Updated posture (changes the previous doc).** Previous doc assumed waiting for 10.2.105/10.2.97 would help. **That is wrong** — we are on a different branch and 10.3.x has no patch-level fix queued. **Poller scope reduction is now mandatory, not optional.** Keep `unifi-exporter` (integration API, `/stat/health`, 60s + jitter + backoff). Do not unsuspend `unpoller`. Re-enable `external-dns-unifi` only at `policy: upsert-only`, interval ≥5 min, AAAA-filter on.

## What the 10.3.x changelog actually says

Pulled from the UniFi Community releases RSS feed and individual release pages; cross-checked against goofball222/unifi changelog mirror and unifi-forum.nl. All dates accessed 2026-05-13.

| Version | Released | Status | Stability-relevant bullets |
|---|---|---|---|
| 10.3.47 | 2026-04-10 | Beta only, never promoted | Initial 10.3 branch cut; no advisory |
| 10.3.52 | 2026-04-15 | Beta only, never promoted | None published |
| **10.3.55** | 2026-04-16 beta / **2026-04-20 official** | Official | "**Improved overall application stability and resiliency.**" Plus feature: Identity Firewall. Fixes: packet captures failing, security-posture-default-after-upgrade, View All Flows empty page, WiFi Broadcast save failure, VPN uptime stats missing, ISP Speed Test schedule misplacement, channel-width mismatch on AP adopt, Layer-3 networks over-creation on switches |
| **10.3.58** | 2026-04-22 beta / **2026-05-07 official** | **Official (current)** | "Improved resiliency for applying Orchestrations." Fixes: Firewall Policy ordering with Blueprints, DNS Assistance enabled on IoT WiFi, port-number display errors, IKEv2 settings save, port-marked-down-with-active-connections |
| 10.4.x | — | **Does not exist** | n/a |

**The "DNS Assistance" bullet in 10.3.58 is the closest thing to a DNS-pathway fix and refers to a UI toggle for IoT broadcast networks, not dnsmasq behavior on static-dns records.** Nothing in either 10.3.x release mentions integration-API rate-limiting, watchdog, OOM, reverse-proxy, or static-dns handling.

Sources: [UniFi Network Application releases RSS feed](https://community.ui.com/rss/releases/UniFi-Network-Application/e6712595-81bb-4829-8e42-9e2630fabcfe), [goofball222/unifi CHANGELOG](https://github.com/goofball222/unifi/blob/main/CHANGELOG.md), [10.3.58 community release page](https://community.ui.com/releases/UniFi-Network-Application-10-3-58/449387c9-4187-44bd-ad47-02da91688dfc), [10.3.55 community release page](https://community.ui.com/releases/UniFi-Network-Application-10-3-55/cf38dace-ce91-4e4a-8ab7-a1d2db30aa55) — all accessed 2026-05-13.

## What the community/GitHub says (10.3.x specifically)

- **unpoller [#1013 "Prometheus endpoint blocking on retry loop"](https://github.com/unpoller/unpoller/issues/1013)** — opened **2026-05-10**, closed 2026-05-12. Reporter is on **UniFi Network 10.3.58** (Remote API mode, all save_* flags true — same config family as ours). Symptoms reproduced verbatim:
  - `unifi.GetClients(...): 429 too many requests (retry after 1m0s)`
  - `integration page /proxy/network/integration/v1/sites?offset=0&limit=200: request failed: 429 too many requests`
  - `IDS/IPS endpoint removed (Network 10.x+): no replacement available`
  - `Events endpoint removed (Network 10.x+): use save_syslog instead`
  - `[ERROR] updateWeb panic recovered: runtime error: invalid memory address or nil pointer dereference`
  - Response times wandering from 7s → 76s; Prometheus `/metrics` stalling during 429 backoff loops.
- **unpoller [PR #1014](https://github.com/unpoller/unpoller/pulls/1014)** — merged **2026-05-12**. Adds background-poll cache + `singleflight` request coalescing so scrapes don't multiply upstream load during 429 backoff. *This is the patch path we'd need if we ever bring unpoller back.* It is a client mitigation; the controller is still rate-limiting.
- **kashalls/external-dns-unifi-webhook issues since 2026-02-01** — only `Renovate Dashboard` and `Dependency Dashboard` items. Zero user-reported issues about 10.3.x crashes, rate-limiting, or HTML-on-error. The webhook is low-volume; absence of reports here is "not enough users hitting our path" not "the path is fine."
- **Community.ui.com threads searched** (10.3-specific + crash/CPU): all results are pre-10.3 era (UDM Pro Protect crashes on older builds, generic high-CPU under DPI). **No 10.3.x-tagged crash thread surfaced.**

## The 10.x API surface change (this is the new finding)

The 10.x Network app has **removed legacy endpoints**. unpoller #1013 logs confirm:

- `GET /proxy/network/api/s/<site>/stat/event` → **404** (removed, "use save_syslog instead")
- IDS/IPS legacy path → **404** (removed, "no replacement available")
- Integration API `/proxy/network/integration/v1/sites` → **HTTP 429 with `Retry-After: 60s`** under load

This is a substantive behavior change versus 10.0.x / 10.2.x. **It explains why our `unpoller` config with `SAVE_EVENTS=true` and `SAVE_IDS=true` caused a re-auth storm on 10.3.x specifically — the controller is rejecting calls those flags emit and bouncing the poller into a 429 backoff loop while the poller still synchronously hammers `/metrics`.** PR #1014 confirms the client-side problem; the controller-side rate limit is what we trip.

This **partially supersedes Hypothesis 1 in the previous doc**: the cause is not "10.2.93 ships a regression"; it's "10.x dropped legacy endpoints and added aggressive 429s on the integration API, and unpoller v3.1.2 (pre-#1014) cannot survive that." Same mechanism, different root-cause attribution.

## Ranked hypotheses, updated

| Rank | Hypothesis | Evidence | Δ vs previous doc |
|---|---|---|---|
| 1 | **10.x controller's new API behavior (429 rate-limit on integration v1 + removed legacy `/stat/event` and IDS/IPS) plus unpoller v3.1.2 synchronous `/metrics` blocking, multiplied by our `SAVE_EVENTS/SAVE_IDS/SAVE_ANOMALIES=true` config, drove the UDM into a re-auth storm + CPU saturation + Network app crash.** | **High.** [unpoller #1013](https://github.com/unpoller/unpoller/issues/1013) reproduces our exact symptom on 10.3.58 with the same save_* config family. Our 133 restarts in 22 days matches the failure mode. [PR #1014](https://github.com/unpoller/unpoller/pulls/1014) is the upstream acknowledgement. | **Replaces** previous Hypothesis 1. Reattributes from "10.2.93 ships a regression" to "10.x removed/throttled the surface unpoller v3.1.2 calls." Mechanism unchanged. |
| 2 | **kashalls/external-dns-unifi-webhook under `policy: sync` adds steady load on `/proxy/network/v2/api/.../static-dns/`, amplifying #1 into full crash.** | **Medium.** "HTML on 401" pattern still consistent. No 10.3.x-specific GitHub issue exists, but absence-of-reports is "few operators on this path," not "path is safe." | **Unchanged.** |
| 3 | **dnsmasq bundled in OS 5.0.16 carries an upstream class of bug; 2026-05-13 AAAA-write was a latent trigger.** | **Low.** Zero 10.3.x release-note entries on dnsmasq. Our incident remains anecdotal. | **Weaker.** Previous doc gave this "low-medium" partly hoping 10.2.97 was a quiet dnsmasq bump; 10.3.x release notes give no signal. Demote to "low." Keep AAAA guardrail because the operational footgun is real even if the crash linkage isn't. |
| 4 | **Memory leak / OOM in Network app independent of poller load.** | **Low.** No 10.3.x community report surfaced. Older UDM Pro memory-leak threads are pre-10.x. | **New, but low.** Worth noting as alternative null-hypothesis if pollers stay off and crashes persist. |

## Fix-version posture

**There is no fix-version to wait for.** 10.3.58 is the latest 10.3.x; no 10.3.6x or 10.4.x exists in stable, beta, or RC. Auto-upgrade will not deliver a controller-side fix in any predictable window. If UI ships a 10.3.6x with explicit "fixed integration API 429 storms" or "fixed legacy stat/event 404 cascade," that would change the picture — until then, the only safe action is on our side.

**Recommendation (changes from the previous doc):**

1. **Poller scope reduction is mandatory.** Keep `unpoller` suspended. Keep `unifi-exporter` (`/stat/health` integration call, 60s + jitter + backoff) — this surface is the only one with documented 429 behavior the client handles cleanly.
2. **If unpoller is ever revived**, it must be at unpoller `>= post-#1014` (next release after v3.1.2), with `SAVE_EVENTS=false`, `SAVE_IDS=false`, `SAVE_ANOMALIES=false`, `SAVE_ALARMS=false` (these endpoints are gone in 10.x anyway), `prometheus.interval >= 60s`, and scrape interval ≥60s on Prometheus side.
3. **`external-dns-unifi`**: re-enable only at `policy: upsert-only`, interval ≥5 min, AAAA filter on, retry budget capped (auto-scale to 0 on N consecutive `invalid character '<'` errors). Unchanged from previous doc.
4. **Watch [UniFi Network Application releases RSS](https://community.ui.com/rss/releases/UniFi-Network-Application/e6712595-81bb-4829-8e42-9e2630fabcfe) for 10.3.6x or 10.4.x.** If a release explicitly mentions integration API rate limiting, retry tuning, or "stat/event compatibility," re-test cautiously with unpoller off.

## Sources

- [UniFi Network Application releases RSS feed — community.ui.com](https://community.ui.com/rss/releases/UniFi-Network-Application/e6712595-81bb-4829-8e42-9e2630fabcfe) — accessed 2026-05-13; full 10.3.x history (only 10.3.55 + 10.3.58 official).
- [UniFi Network Application 10.3.58 release page](https://community.ui.com/releases/UniFi-Network-Application-10-3-58/449387c9-4187-44bd-ad47-02da91688dfc) — accessed 2026-05-13; 2026-05-07 official.
- [UniFi Network Application 10.3.55 release page](https://community.ui.com/releases/UniFi-Network-Application-10-3-55/cf38dace-ce91-4e4a-8ab7-a1d2db30aa55) — accessed 2026-05-13; 2026-04-20 official.
- [goofball222/unifi CHANGELOG.md](https://github.com/goofball222/unifi/blob/main/CHANGELOG.md) — accessed 2026-05-13; mirrors UI release dates: 10.3.47 (2026-04-10 beta), 10.3.52 (2026-04-15 beta), 10.3.55 (2026-04-16 beta → 2026-04-20 official), 10.3.58 (2026-04-22 beta → 2026-05-07 official).
- [unpoller #1013 — "Prometheus endpoint blocking on retry loop"](https://github.com/unpoller/unpoller/issues/1013) — accessed 2026-05-13; **reporter on 10.3.58**, matches our symptom exactly. Logs show 429s, removed legacy endpoints, `updateWeb panic recovered`.
- [unpoller PR #1014 — "fix(prometheus): serve scrapes from cached background poll"](https://github.com/unpoller/unpoller/pull/1014) — merged 2026-05-12; client-side mitigation for #1013.
- [unpoller issue list 2026-Q2](https://github.com/unpoller/unpoller/issues?q=is%3Aissue+created%3A%3E%3D2026-02-01) — accessed 2026-05-13; surveyed for 10.3.x-tagged reports; #1013 is the only direct hit.
- [kashalls/external-dns-unifi-webhook issue list since 2026-02-01](https://github.com/kashalls/external-dns-unifi-webhook/issues?q=is%3Aissue+created%3A%3E%3D2026-02-01) — accessed 2026-05-13; only Renovate/Dependency Dashboard items, zero user-reported 10.3.x issues.
- [Releasebot — Ubiquiti updates index](https://releasebot.io/updates/ubiquiti) — accessed 2026-05-13; cross-check for newer 10.3.x or 10.4.x; **none exists**.
- Previous doc: [udm-crash-rootcause.md](./udm-crash-rootcause.md) (chg-2026-05-13-019) — superseded for the 10.x branch; mechanism-level findings still apply.

— Athena
