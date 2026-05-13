# UDM Pro Max crash under poller load — root-cause research

## Question

Why is the UDM Pro Max (UDMPROMAX, UniFi OS 5.0.16, UniFi Network 10.2.93) crashing under poller load — and what do upstream changelogs and the community say about (a) version-specific instability, (b) the specific pollers we run (unpoller, kashalls/external-dns-unifi-webhook), and (c) safe polling cadence + auth patterns?

## TL;DR

- **There are no UI-published 10.2.93 / OS 5.0.16 changelog entries mentioning crash / OOM / watchdog fixes.** 10.2.93 (2026-03-12) is a feature release (Port Manager Time Machine, Device Supervisor, infrastructure topology). The first explicit "stability improvements" line in this branch is **10.2.97** (2026-03-18, post-date — *we are on the prior build*). The last branch with documented "improved application stability and memory usage" is **10.0.156 / 10.0.160** (Nov 2025). So we are running an in-between version that quietly accumulated regressions for which fixes shipped in 10.2.97 and 10.2.105.
- **unpoller is the prime suspect.** Upstream issue [unpoller #396](https://github.com/unpoller/unpoller/issues/396) documents exactly our symptom — *"polling causes UDM CPU spikes within seconds, API becomes unresponsive, times out"* — and it was closed *not planned*. DPI / events / anomalies / IDS / sites collection (which we had **all enabled**) is the well-known culprit. Issue [#316](https://github.com/unpoller/unpoller/issues/316) describes the same re-auth loop that produces 133 restarts in 22 days like we saw.
- **The "invalid character '<'" error from external-dns-unifi is HTML-on-401**, i.e. the controller served the login page instead of JSON. That is what UDM does when the integration API key is rejected, a session is invalidated mid-request, **or the controller is overloaded and the reverse proxy short-circuits to the UI**. It is a signal of stress, not a cause — but the webhook retries hard on it, which adds to the pile.
- **dnsmasq + AAAA-in-hosts is a real upstream class of bugs.** dnsmasq 2.86 ChangeLog explicitly fixed *"lose track of processes forked to handle TCP DNS connections under heavy load"* and 2.91 fixed a SIGSEGV in `order_qsort()`. UI does not publish the dnsmasq version shipped in 5.0.16. Our 2026-05-13 AAAA write → crash correlation is consistent with this class.
- **Recommendation:** Treat the integration API (`/proxy/network/integration/v1`) as the only safe scrape surface; never poll `/proxy/network/v2/api/...` faster than 5 min; keep AAAA out of static-dns; cap concurrent pollers at one; upgrade to 10.2.105 + OS 5.0.x latest before unsuspending unpoller. Re-enable external-dns-unifi only at `policy: upsert-only` and `interval: 5m`.

## What the world does

**unpoller (the InfluxDB/Prometheus exporter we run, GitHub `unpoller/unpoller`, v2.39.0).** Polls the *legacy* controller API and iterates per-device, per-port. With `SAVE_DPI`, `SAVE_EVENTS`, `SAVE_ANOMALIES`, `SAVE_IDS`, `SAVE_SITES`, `SAVE_ALARMS` all true (what we had), each scrape pulls multiple multi-MB JSON blobs. Upstream issue #396 (closed not-planned) reproduces our symptom; #316 reproduces our re-auth loop. Tradeoff: comprehensive Prometheus metrics — pays for it with heavy controller load.

**kashalls/external-dns-unifi-webhook v0.8.2.** Wraps the legacy `/proxy/network/v2/api/site/<site>/static-dns/` endpoint to read/write A/CNAME/TXT records. Auth: local integration key (recommended) or username/password (deprecated). No published rate-limit, polling cadence, or recovery semantics; README only mentions `SERVER_READ_TIMEOUT`/`SERVER_WRITE_TIMEOUT`. external-dns drives it on `policy: sync` at the default 1-minute reconcile, which means *every minute* the webhook lists every static-dns row and reconciles deltas. Under controller stress, listing returns HTML (the login page) and the webhook surfaces `invalid character '<' looking for beginning of value`.

**Ubiquiti integration API (`/proxy/network/integration/v1`).** Documented since [help.ui.com/hc/en-us/articles/30076656117655](https://help.ui.com/hc/en-us/articles/30076656117655-Getting-Started-with-the-Official-UniFi-API). Rate-limited (returns HTTP 429) and explicitly designed for programmatic polling — including a per-device `/statistics/latest` endpoint that replaces the heavy `/stat/device` loop. UI does not publish the per-minute quota number, but the contract is "429 on overrun, no controller stress". Auth is `X-API-KEY`, no session cookie, no re-auth loop. This is what our minimal `unifi-exporter` uses (`/stat/health`, 60s + jitter + exponential backoff).

**UniFi Network 10.x release branch (per community.ui.com RSS feed).** Pattern: 10.0.156 → 10.0.160 explicitly call out *"improved application stability and memory usage"*; 10.2.93 (our version) ships features only; **10.2.97** (six days later) ships *"stability improvements"*; 10.2.105 ships further bugfixes. Translation: 10.2.93 is a feature-train build that needed two follow-up patch builds to settle.

**dnsmasq (ships inside UniFi Network).** Public changelog records the relevant class of bugs we're worried about: 2.86 fixed lost child-process tracking under heavy TCP DNS load; 2.91 fixed a heap read causing SIGSEGV in answer sorting. UI does not document which dnsmasq is bundled in OS 5.0.16, so we cannot rule these out.

## Patterns that recur

**Shared across every credible report.**
- High poller cadence + DPI/events collection on UDM ≡ CPU spike → API timeout → re-auth loop → restart loop. Independent of cluster setup.
- The integration API (`/integration/v1`) is the supported surface; the legacy `/proxy/network/v2/api/...` surface is undocumented and *only* path for static-DNS + BGP + a few other things.
- "HTML instead of JSON" from the controller is **always** a signal — either auth, version skew, or overload. Never a transient.

**Only some reports share.**
- AAAA-record crashes: documented as a dnsmasq upstream class, not as a UniFi-published bug. Our 2026-05-13 incident is one anecdote, not a proven CVE.
- Memory leak that needs daily reboot: documented for UDM Pro (non-Max) at 1.9.x firmware vintage. No published report for UDMPROMAX on OS 5.0.x.

## Recommendation

**Three-step posture for *this homelab*, given a single operator and one controller:**

1. **Treat the integration API as the only steady-state scrape surface.** Keep `unifi-exporter` (`/stat/health`, 60s + jitter + backoff). Do not unsuspend `unpoller` as-is. If port-level metrics are needed, rewrite to call `/proxy/network/integration/v1/sites/{site}/devices/{deviceId}/statistics/latest`, 5-min interval, one device at a time.
2. **For static-DNS work, re-enable `external-dns-unifi` only after:** (a) bumping UDM to OS 5.0.x-latest + Network 10.2.105+; (b) changing the external-dns policy to `upsert-only` and the reconcile interval to ≥5 min; (c) keeping the existing AAAA-footgun guardrail (no record_type AAAA writes, ever).
3. **Treat any future "invalid character '<'" log line as a tripwire** — auto-scale the webhook to 0 on N consecutive failures rather than retrying. Surface to the operator immediately.

Ranked root-cause hypotheses:

| Rank | Hypothesis | Evidence strength |
|------|-----------|------------------|
| 1 | **unpoller scraping legacy `/proxy/network/v2/api/...` with DPI+events+IDS+anomalies enabled overloaded the controller**, triggered re-auth storm, cascaded into CPU saturation and Network app crash | **High.** unpoller #396 / #316 reproduce exact symptom. 133 restarts/22d matches the failure mode. Our own `UP_UNIFI_DEFAULT_SAVE_DPI/EVENTS/IDS/ANOMALIES=true` is the documented worst-case config. |
| 2 | **external-dns-unifi (kashalls webhook) hammering `/proxy/network/v2/api/.../static-dns/` every 60s under `policy: sync`** added persistent load and amplified the unpoller failure into full crash | **Medium.** The "HTML on 401" error pattern is correlated with overload, and `policy: sync` re-lists every minute. No upstream bug, but the load contribution is mechanically obvious. |
| 3 | **UniFi Network 10.2.93 + bundled dnsmasq carries a regression** that 10.2.97 quietly fixes; the 2026-05-13 AAAA write was a latent trigger | **Low-medium.** dnsmasq changelog shows the right *class* of bug; 10.2.97 ships unspecified "stability improvements" six days after 10.2.93. But no UI advisory names it. Treat as the long-tail explanation, not the primary cause. |

## Sources

- [UniFi Network Application releases RSS feed — community.ui.com](https://community.ui.com/rss/releases/UniFi-Network-Application/e6712595-81bb-4829-8e42-9e2630fabcfe) — accessed 2026-05-13; gives 10.2.93 (2026-03-12), 10.2.97 (2026-03-18 "stability improvements"), 10.2.105 (2026-03-30), 10.0.156/160 ("improved application stability and memory usage") dates and one-line summaries.
- [UniFi Network Application 10.2.93 release page (UI Community)](https://community.ui.com/releases/UniFi-Network-Application-10-2-93/6124ef35-ce93-47d9-8f9d-fa44ab02c587) — accessed 2026-05-13; features-only release, no stability bullets.
- [UniFi OS Dream Machines 5.0.16 release page](https://community.ui.com/releases/UniFi-OS-Dream-Machines-5-0-16/4b8a0a8b-f241-49a0-b0a3-c3de80d503ef) — accessed 2026-05-13; release dated 2026-03-22 (per Releasebot index).
- [Releasebot — Ubiquiti updates index](https://releasebot.io/updates/ubiquiti) — accessed 2026-05-13; cross-checks release dates when ui.com pages render via JS.
- [unpoller/unpoller #396 — "Polling Information Causes High CPU Usage on UDM"](https://github.com/unpoller/unpoller/issues/396) — accessed 2026-05-13; closed not-planned; matches our symptom exactly.
- [unpoller/unpoller #316 — "UDM Pro re-authentication loop"](https://github.com/unpoller/unpoller/issues/316) — accessed 2026-05-13; reproduces our 133-restart pattern.
- [kashalls/external-dns-unifi-webhook README + Issues](https://github.com/kashalls/external-dns-unifi-webhook) — accessed 2026-05-13; no documented polling cadence or rate-limit handling.
- [Getting Started with the Official UniFi API — help.ui.com](https://help.ui.com/hc/en-us/articles/30076656117655-Getting-Started-with-the-Official-UniFi-API) — accessed 2026-05-13; documents `X-API-KEY` integration auth and HTTP 429 rate-limit behavior.
- [Art-of-WiFi UniFi-API-client issue #194 — "Rate limiting?"](https://github.com/Art-of-WiFi/UniFi-API-client/issues/194) — accessed 2026-05-13; confirms UDM returns JSON `AUTHENTICATION_FAILED` and that no public rate limit number exists.
- [dnsmasq ChangeLog — thekelleys.org.uk](https://thekelleys.org.uk/dnsmasq/CHANGELOG) — accessed 2026-05-13; 2.86 ("lose track of processes forked to handle TCP DNS connections under heavy load"), 2.91 (SIGSEGV in order_qsort).
- [Internal memory: unifi-aaaa-static-dns-footgun](/Users/sheijden/.claude/projects/-Users-sheijden-Code-homelab-migration-vdhinfra/memory/feedback_unifi_aaaa_static_dns.md) — 2026-05-12 evidence that AAAA write was both ineffective (dnsmasq doesn't consult static-dns for AAAA) and time-correlated with a controller crash.
- [Internal memory: project_unifi_exporter_archived](/Users/sheijden/.claude/projects/-Users-sheijden-Code-homelab-migration-vdhinfra/memory/project_unifi_exporter_archived.md) — confirms `/stat/health` + 60s + jitter + backoff is the kind pattern we already validated; `/stat/device` is not.

— Athena
