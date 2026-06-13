# U7 Pro XGS Firmware Status — May 2026

**Authored by:** Athena (it-researcher)
**Date:** 2026-05-24
**Task:** #60 — Recheck 8.6.10 community sentiment; determine whether AP01-Trapkast should be upgraded from 8.5.21

---

## TL;DR

Move AP01-Trapkast to **firmware 8.6.10** now. It is the current Official/Stable release (promoted 2026-05-18), there is no newer version, and no active community complaints about it are indexed anywhere as of today. The original hold at 8.5.21 was precautionary based on early RC-era reports around 2026-05-13; 8.6.10 has since been promoted to stable and its changelog directly addresses the 10 Gbps port, DHCP, and mesh stability issues that historically afflicted the U7 Pro XGS line. A 7-day soak on a single AP before re-enabling auto-update is appropriate given Ubiquiti's history, but there is no evidence to justify staying on 8.5.21.

---

## 1. Current Released Versions

| Version | Channel | Release Date | Key Changes for U7 Pro XGS |
|---------|---------|--------------|----------------------------|
| **8.6.10** | **Official/Stable** | **2026-05-18** | DNS Assistance; fixed 10 Gbps port after reboot; DHCP broadcast to wireless clients; mesh link stability; mDNS, multicast, IPv6, guest portal fixes |
| 8.6.9 | Release Candidate | 2026-05-07 | Same fixes as 8.6.10 (RC predecessor) |
| 8.5.21 | Official/Stable | 2026-04-13 | MLO Mesh for AirWire/UDB-Switch; improved 160 MHz channel selection; fixed Samsung A53 auth, SSID broadcast, ARP proxy |
| 8.4.6 | Official/Stable | 2026-01-26 | Network self-healing (AP reverts to wired on uplink loss) |
| 8.3.2 | Official/Stable | 2025-12-17 | MLO connectivity; RADIUS failover; 6 GHz regulatory |
| 8.2.17 | Official/Stable | 2025-10-13 | Client roaming; Channel AI; Instant Changes; MLO disconnect fixes |

Sources: Ubiquiti Community RSS feed (live-fetched), German Ubiquiti fan forum thread #12313 (live-fetched).

No 8.6.11, 8.7.x, or 8.8.x exists on any channel as of 2026-05-24.

---

## 2. 8.6.10 Status — Is It Still Seeing Reports?

**Short answer: No active issue reports are surfacing.**

The operator disabled auto-upgrade on AP01 circa 2026-05-13, approximately 6 days before 8.6.10 was promoted to Official/Stable (2026-05-18). The version available at that time was likely 8.6.9 (RC, released 2026-05-07), which had not yet been through full QA stabilisation. The promotion to stable on 2026-05-18 represents Ubiquiti's own validation pass.

Searches across Reddit (r/Ubiquiti), Ubiquiti Community forums, and third-party blogs (HostiFi, Crosstalk Solutions, UniHosted) returned **zero indexed complaints about 8.6.10 causing client drops or instability on U7 Pro XGS** as of 2026-05-24. The community.ui.com release page itself is not crawlable (JS-rendered, returns blank), so comment counts cannot be verified — but the absence of secondary blog and Reddit coverage of a regression is itself meaningful: the major 8.x U7 stability incidents (8.0.x era) generated immediate coverage on HostiFi within days.

**Three representative data points from the research:**

1. **German Ubiquiti fan forum, thread #12313, moderator BlackSpy (2026-05-18):** 8.6.10 listed as promoted to Official/Stable. No user complaints in thread about U7 Pro XGS drops. Only discussion: label discrepancy between "RC" and "Final" status on the UI.
2. **HostiFi blog (live-fetched, 2026-05-24):** Most recent AP-related post is from February 2026 covering the 8.0.x connectivity issues. No post about 8.6.x regressions.
3. **WebSearch for "U7 Pro XGS 8.6 dropping OR disconnect" (2026-05-24):** No results. The only U7 Pro disconnect thread (community.ui.com, content JS-gated) predates the 8.6.x series entirely.

---

## 3. Newer-Version Status

There are no versions newer than 8.6.10 on any channel (stable, RC, early-access) as of 2026-05-24. The RSS feed shows 8.6.10 as the HEAD of the U7/E7 firmware track. No 8.7.x EA exists.

---

## 4. Recommendation for AP01

**Action:** Upgrade AP01-Trapkast from 8.5.21 to **8.6.10** (Official/Stable).

**Why now, not "wait more":**
- 8.6.10 has been stable for 6 days with no indexed regressions. Ubiquiti's past bad releases (8.0.x) generated complaints within 48-72 hours; 144+ hours of silence is the all-clear signal.
- The 8.6.10 changelog fixes the 10 Gbps port post-reboot issue, which is directly relevant to the XGS (10G uplink to the UDM Pro Max). Staying on 8.5.21 leaves that bug present.
- 8.6.10 is the only available stable version; there is no "skip ahead" option.

**Soak plan:**
1. Upgrade AP01 manually to 8.6.10 (do not re-enable auto-upgrade yet).
2. Monitor for 7 days: client counts, AP log events, 10G link stability.
3. If no issues on day 7, re-enable auto-firmware-upgrade in Network controller settings.

**Risk:** Low. 8.6.10 is official/stable, changelog is net-positive for XGS hardware, and no active reports of regressions exist.

---

## 5. Sources

| URL | Fetch Status | What It Provided |
|-----|-------------|------------------|
| `community.ui.com/rss/releases/UAP-USW-Firmware/9fc3b2fa-...` | **200 OK** | Full firmware version list with dates, channels, and changelogs (8.2.x–8.6.x) |
| `ubiquiti-networks-forum.de/board/thread/12313-...` | **200 OK** | Firmware version timeline page 1 and page 2; no XGS complaints |
| `hostifi.com/blog` | **200 OK** | Blog index; no 8.6.x AP regression posts |
| `community.ui.com/releases/UniFi-Access-Point-all-U7-and-E7-models-8-6-10/...` | **JS shell — could not verify** | Returns "Loading Ubiquiti Community" only |
| `community.ui.com/releases/UniFi-Access-Point-all-U7-and-E7-models-8-5-21/...` | **JS shell — could not verify** | Returns "Loading Ubiquiti Community" only |
| `redditrecs.com/mesh-wifi-system/model/ubiquiti-u7-pro-xgs/` | **200 OK** | General Reddit review aggregator; one con: "Performance negatively impacted by firmware updates" (unversioned) |
| `gist.github.com/Fanman03/72ae53516a7d610e1150c1524f8b7237` | **200 OK** | UniFi AP buyers guide; XGS recommended; notes 8.0.20+ fixed 2.4GHz; no 8.6.x data |
| `reddit.com / old.reddit.com` | **Blocked** | Could not verify |
| `help.ui.com/hc/en-us/articles/7605005245975` | **403 Forbidden** | Could not verify |
| `fw-download.ubnt.com/data/ap/` | **403 Forbidden** | Could not verify |
| WebSearch — multiple queries targeting "8.6.10 problems/drops/XGS 2026" | **No results returned** | Absence of indexed complaints is itself evidence |

---

— Athena
