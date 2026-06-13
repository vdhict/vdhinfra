# UniFi DFS Channels: Disable or Keep?

**Researched by Athena — 2026-05-22**

---

## 1. TL;DR — Recommendation for This Network

**Leave DFS enabled on all radios, but pin each U7 Pro XGS to a fixed DFS channel rather than leaving it on Auto.**

The U7 Pro XGS has hardware Zero-Wait DFS ([Ubiquiti tech specs, live fetch 2026-05-22](https://techspecs.ui.com/unifi/wifi/u7-pro-xgs); confirmed by [Dong Knows Tech review, live fetch 2026-05-22](https://dongknows.com/ubiquiti-u7-pro-xgs-review/)). Zero-Wait DFS means the AP performs the Channel Availability Check (CAC) *in the background* on a secondary radio path and can switch to the new DFS channel instantly on radar detection — no 60-second silent period, no client disruption. The main downside of DFS (the sudden 30-60 second outage) is architecturally eliminated on this hardware. Disabling DFS would surrender 19 additional 5 GHz channels and make 80 MHz channel widths impossible in this regulatory domain — all cost, no gain. The Netherlands sits under ETSI EN 301 893; weather radar interference *does exist* (KNMI reports confirmed 5 GHz interference in NL since 2009), but with Zero-Wait DFS the AP handles it cleanly. If weather-radar channels 120/124/128 (10-minute CAC sub-band) cause repeated events, exclude *only those three* via Channel AI's channel plan rather than nuking all DFS.

---

## 2. Where the Setting Is

There are **two separate mechanisms** to control DFS in UniFi Network 9.x / 10.x. Both are per-network (not per-AP) unless overridden at the device level.

### A. Enable/Disable the DFS spectrum entirely

**UI path (confirmed via multiple sources):**
`Settings → WiFi → [select network] → Advanced → Radio Settings → Default WiFi Speeds`
- Select **Custom**
- Toggle **Extended 5 GHz Spectrum (DFS)**
- Click **Apply Changes**

By default, DFS is *disabled* in UniFi for new installations ([search snippet from help.ui.com confirmed by multiple independent sources]).
Enabling it adds channels 52–144 to the 5 GHz auto-selection pool.

Source: Search snippet from [Ubiquiti Help Center article on DFS Channels](https://help.ui.com/hc/en-us/articles/15510834696599-DFS-Channels) (page returned HTTP 403 — content confirmed via independent search snippets referencing the article); exact UI path corroborated by [UniHosted channel guide, live fetch 2026-05-22](https://www.unihosted.com/blog/manually-set-wifi-channels-on-unifi).

### B. Exclude specific channels from Channel AI selection

**UI path:**
`WiFi → Channel AI → Channel Plan`

This lets you block individual channels from automatic selection — e.g., exclude 120/124/128 while keeping the rest of UNII-2C available.
Source: [UniFi Channel AI help article](https://help.ui.com/hc/en-us/articles/37367741854743-UniFi-Channel-AI-and-Automated-WiFi-Optimization) (page returned HTTP 403 — confirmed via search snippet from the Ubiquiti help site).

### C. Per-AP manual override

Navigate to **Devices → [AP] → Settings → Radios**. Disable **Nightly Channel Optimization** and manually set a fixed channel. The AP then ignores Channel AI for that radio. This is per-device, overriding the network default.

> **API note:** The UniFi Network API field controlling the DFS toggle is `ht_mode` and `channel` in the `ap_group` or `wlanconf` objects. The extended spectrum flag is not a single boolean — it surfaces by whether channels 52–144 appear in the allowed channel list. No official public API docs were found live (help.ui.com 403'd); this is derived from community-confirmed API inspection.

---

## 3. Why DFS Exists (Non-Engineer Version)

The 5 GHz spectrum between 5.25–5.35 GHz and 5.47–5.725 GHz was originally allocated to radar systems — military, aviation surveillance, and weather services. When regulators opened these frequencies to Wi-Fi, they imposed a condition: Wi-Fi devices must *detect* incumbent radar and *immediately* yield. This is DFS. The AP listens for a radar pulse signature and, if found, vacates the channel within 10 seconds and stays off it for at least 30 minutes (ETSI EN 301 893 non-occupancy period). The Netherlands has two operational C-band weather radars (Herwijnen and Den Helder) whose interference with 5 GHz Wi-Fi was formally documented by EUMETNET starting 2009.

---

## 4. The Trade-off, Concretely

| Factor | DFS **enabled** (channels 36–48 + 52–144 + 149–165) | DFS **disabled** (channels 36–48 + 149–165 only) |
|---|---|---|
| **5 GHz channels available (20 MHz)** | ~25 | ~9 |
| **5 GHz channels available (80 MHz)** | 6 (incl. 4 DFS) | 2 (ch 42, ch 155) |
| **5 GHz channels available (160 MHz)** | 2–3 (all require DFS) | 0 |
| **Congestion in dense neighbourhood** | Much lower — 19 extra channels mean you can pick clean air | Higher — you compete on only 9 channels with every neighbour and IoT device |
| **Radar-triggered outage (conventional AP)** | 30–60 s silent, then channel change | None |
| **Radar-triggered outage (U7 Pro XGS Zero-Wait)** | **Effectively zero** — background CAC, seamless switch | n/a |
| **Old/IoT clients that ignore DFS channels** | Some won't probe DFS channels on initial scan (mitigated by band steering) | Not an issue |
| **Weather radar channels 120/124/128** | 10-minute CAC on radar detection (ETSI sub-band) | n/a |

Source for channel counts: [Evan McCann UniFi Advanced Wi-Fi Settings, live fetch 2026-05-22](https://evanmccann.net/blog/2021/11/unifi-advanced-wi-fi-settings); [purple.ai DFS guide, live fetch 2026-05-22](https://www.purple.ai/en-gb/guides/dfs-channels-what-they-are-and-when-to-avoid-them); EU channel list from [Wyebot DFS blog, live fetch 2026-05-22](https://wyebot.com/blogs/dynamic-frequency-selection-dfs-in-wi-fi-radar-detection-and-5-ghz-channel-behavior/).

Note: The 2AM `syswrapper.sh dfs-reset` cron behavior documented by [arrogantrabbit.com, live fetch 2026-05-22](https://blog.arrogantrabbit.com/hardware/Ubiquiti-DFS/) (conventional non-zero-wait APs) does not apply to the U7 Pro XGS, which handles recovery autonomously.

---

## 5. Local Environment Factors — What to Check Before Deciding

1. **Has radar detection actually fired?** Check: UniFi controller → `Network → WiFi → [AP] → Insights → Events`. Filter for "DFS" or "radar". If you see zero DFS events in 30 days, the question is largely moot for stability.

2. **What channel width is 5 GHz running?** If APs are on 80 MHz (common with U7 Pro XGS default), DFS is *already required* — only channels 42 and 155 are 80 MHz-capable without DFS; on 160 MHz there are *zero* non-DFS options. Disabling DFS forces a downgrade to smaller channels or auto-selection of crowded 80 MHz ch 42/155.

3. **Neighbourhood density?** Run WiFi scanner (e.g., WiFiman on mobile from the AP location). If you see 10+ networks on channels 36/40/44/48 and 149–161, DFS channels are almost certainly cleaner.

4. **Are 6 GHz clients in use?** U7 Pro XGS has a 2×2 6 GHz radio. The 6 GHz band (5.925–7.125 GHz) does **not** require DFS in the EU for indoor standard-power (SP) operation — it's a separate regulatory regime. Clients capable of 6 GHz (Wi-Fi 6E or Wi-Fi 7) should be band-steered there, removing them from the 5 GHz DFS question entirely.

5. **Weather radar sub-band:** Channels 120, 124, and 128 overlap with weather radar allocation in ETSI domain and carry a 10-minute CAC. If the controller's event log shows repeated hits specifically on these three channels, exclude them in Channel AI → Channel Plan. Keep the rest.

---

## 6. Recommendation for This Specific Network

Given: U7 Pro XGS (Zero-Wait DFS hardware), EU/ETSI domain, mixed home + IoT client base, operator preference for stability.

**Action: Enable DFS (Extended 5 GHz Spectrum), then pin each AP to a fixed 80 MHz DFS channel.**

Specifically:
- Enable DFS via `Settings → WiFi → Advanced → Radio Settings → Extended 5 GHz Spectrum (DFS)`.
- In `Channel AI → Channel Plan`, **exclude channels 120, 124, 128** (weather radar, 10-min CAC). Leave all other UNII-2A and UNII-2C channels eligible.
- Per AP, via `Devices → [AP] → Settings → Radios`, disable Nightly Channel Optimization and assign a fixed channel: choose from 100 (80 MHz) or 116 (80 MHz) depending on which is cleaner per WiFiman scan. This avoids the stability concern from Auto-channel switching without surrendering the spectrum.
- Let 6 GHz run on Auto — it has no DFS requirement and the band is near-empty in residential EU environments.
- Do **not** disable DFS globally. The 9 non-DFS channels at 5 GHz will be contested with every neighbour; losing 19 channels on Wi-Fi 7 hardware to avoid a problem the hardware already solves is a poor trade.

This matches the operator's preference (explicit control, no surprise regressions) while capturing the full spectrum advantage of the hardware purchased.

---

## 7. Sources (All Live-Fetched Unless Noted)

| Source | URL | Status | Used For |
|---|---|---|---|
| Ubiquiti Tech Specs — U7 Pro XGS | https://techspecs.ui.com/unifi/wifi/u7-pro-xgs | Live fetch — 200 OK | Zero-Wait DFS confirmation, channel widths |
| Dong Knows Tech — U7 Pro XGS Review | https://dongknows.com/ubiquiti-u7-pro-xgs-review/ | Live fetch — 200 OK | Zero-Wait DFS explanation and U7 Pro Max comparison |
| HostiFi — U7 Pro Max vs XGS | https://www.hostifi.com/blog/u7-pro-max-vs-u7-pro-xgs | Live fetch — 200 OK | Zero-Wait DFS as XGS-exclusive feature |
| arrogantrabbit.com — Ubiquiti DFS Handling | https://blog.arrogantrabbit.com/hardware/Ubiquiti-DFS/ | Live fetch — 200 OK | CAC timing, 2AM cron behavior, regulatory EN 301 893 |
| Evan McCann — UniFi Advanced Wi-Fi Settings | https://evanmccann.net/blog/2021/11/unifi-advanced-wi-fi-settings | Live fetch — 200 OK | Channel count math at 20/40/80/160 MHz |
| purple.ai — DFS Channels Guide | https://www.purple.ai/en-gb/guides/dfs-channels-what-they-are-and-when-to-avoid-them | Live fetch — 200 OK | When to avoid DFS, ETSI regulatory note, channel 120/124/128 CAC |
| Wyebot — DFS in Wi-Fi blog | https://wyebot.com/blogs/dynamic-frequency-selection-dfs-in-wi-fi-radar-detection-and-5-ghz-channel-behavior/ | Live fetch — 200 OK | CAC/non-occupancy timing, radar types |
| UniHosted — Setting Wi-Fi Channels | https://www.unihosted.com/blog/manually-set-wifi-channels-on-unifi | Live fetch — 200 OK | UI navigation path corroboration |
| EUMETNET — C-Band Radar/RLAN Recommendation | https://www.eumetnet.eu/wp-content/uploads/2017/01/OPERA_2008_12_Recommendation_RLAN.pdf | Search snippet only — PDF not fetched | NL 5 GHz radar interference history |
| Ubiquiti Help Center — DFS Channels | https://help.ui.com/hc/en-us/articles/15510834696599-DFS-Channels | **HTTP 403 — could not verify** | UI path cited from cross-source confirmation only |
| Ubiquiti Help Center — Channel AI | https://help.ui.com/hc/en-us/articles/37367741854743-UniFi-Channel-AI-and-Automated-WiFi-Optimization | **HTTP 403 — could not verify** | Channel Plan UI path cited from search snippets |

— Athena
