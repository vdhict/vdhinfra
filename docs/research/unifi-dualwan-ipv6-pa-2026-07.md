# UniFi dual-WAN IPv6 (both PA prefixes): NPTv6 + ULA on a UDM Pro Max

## Question
On a UDM Pro Max running UniFi Network 10.5.x with two Dutch ISPs delivering only PA prefixes via DHCPv6-PD (KPN /48, Ziggo /56) and no PI/BGP, can we run stable IPv6 on the main client VLAN using NPTv6 + a stable ULA — and is that native in 10.5, an on-box hack, or a bad idea?

## TL;DR
- **UniFi now has native GUI NAT66 and ULA** — not the old "IPv6 only on primary WAN, nothing else" story. NAT66 rules landed in the **Policy Table in Network 9.4.17**; multiple/**ULA "Additional IPs" per VLAN** in **10.0.160**; firewall rules can key on an **IPv6 Interface ID** (dynamic-prefix-proof) — all confirmed on live community pages, all present in 10.5. (UniFi calls it **NAT66**, and the GUI warns performance may be degraded, so treat it as stateful NAT66, not textbook stateless NPTv6.)
- **What is NOT solved natively: dual-WAN IPv6 *routing/failover*.** On failover, IPv6 traffic does not follow the surviving WAN; per-WAN IPv6 traffic rules do not work. A user re-confirmed this bug **~2 months ago (≈ May 2026)**: "3 years later and this is still the case."
- So a ULA-internal + NAT66-to-active-WAN design is buildable in the GUI for **addressing and inbound-rule stability**, but the **failover leg still needs an on-box script** to move the default route + NAT66 mapping to the surviving WAN. That script does **not survive UDM firmware auto-updates** without re-install.
- **Ziggo is the gating problem, not UniFi.** Ziggo is largely **DS-Lite / CGNAT**, and third-party-router DHCPv6-PD on the ConnectBox has a history of breaking. If Ziggo does not hand your UDM a routable PD, NPTv6-to-Ziggo is moot. **Verify Ziggo PD on the actual line before designing anything.**
- **Verdict: NPTv6+ULA on the UDM is worth it for internal-address stability, but full auto-healing dual-WAN v6 failover is a fragile scripted hack on this platform.** Recommended pragmatic target: ULA + NAT66 to KPN as the single IPv6 WAN; treat Ziggo as IPv4-only backup unless you confirm it delegates real IPv6.

## Primary focus: NPTv6 / NAT66 + ULA

### 1. Does Network 10.5 expose NPTv6 / NAT66 / prefix translation in the GUI?
**Yes — as "NAT66", inherited from 9.4/10.0; 10.5 itself added nothing new here.**
- **NAT66 in the Policy Table since Network 9.4.17.** A community user quotes the 9.4.17 notes: *"Added support for IPv6 NAT66 rules to the Policy Table."* Another user reports it working: *"setting the 'Translated IP Address' to a prefix and the clients get the new prefix"* — with the caveat *"the GUI warned me that the performance will be degraded"* (i.e. implemented as NAT66, likely stateful, not stateless NPTv6). [NPTv6 thread]
- **ULA is native since 10.0.160**: *"Added the Additional IPs option to the VLAN Network IPv6 Settings to add multiple IPv6 addresses, including ULA (Unique Local Address)."* The long-running ULA request thread is now marked **[RESOLVED]**. [NPTv6 thread] / [ULA thread]
- **Dynamic-prefix-proof firewall**: the NPTv6 thread author (5 months ago) confirms *"firewall policies now support the input of an IPv6 Interface ID, effectively solving the dynamic prefix change problem"* — inbound rules no longer break when the ISP shuffles the PD.
- **10.5.54 (RC) release notes contain no IPv6 / NAT66 / NPTv6 / dual-WAN items** — 10.5's headline is PPPoE RFC 4638, SafeOps, client observability. So capabilities are exactly the 9.4/10.0 set. [10.5.54 notes] / [Dong 10.5, released 2026-06-25]
- **Official help page** (help.ui.com "Configuring IPv6 in UniFi", cited by community as the NAT66 doc): **could not verify via fetch** — Cloudflare bot-challenge blocks both WebFetch (403) and headless render.

### 2. If you want *true* NPTv6-style failover, the realistic on-box path
UniFi's GUI NAT66 covers static/single-WAN ULA→GUA translation, but it does **not** re-point to a surviving WAN on failover. For that, the community pattern is an on-box daemon:
- **Mechanism** (repo `mattackerman808/ipv6-wan-failover`, README live-fetched): on failover it adds `ip -6 rule add from <dead_prefix> lookup <surviving_table>` **and** `ip6tables -t nat -A POSTROUTING -o <surviving_wan> -s <dead_prefix> -j MASQUERADE`. Note it uses **MASQUERADE, not NETMAP** — i.e. many-to-one source rewrite, all existing v6 sessions drop on switchover. Polls WAN tables every 1s; removes rules on recovery. No specific UDM model/firmware tested is stated.
- **Persistence across auto-update — the load-bearing problem.** The script body lives in `/data/…` which *"survives firmware updates"*, but the systemd unit in `/etc/systemd/system/` does **not**: *"After a UDM firmware update, re-copy the service file and re-enable it."* The common hardening is `udm-utilities` **udm-boot** (a `/data/on_boot.d/` runner installed as a persistent boot service) so `/data/on_boot.d/*.sh` re-applies rules every boot — **could not verify the udm-utilities pages via live fetch this run; cite before relying.** Our memory already notes **UDM firmware auto-upgrade is ON**, so any unit-file-only approach will silently die on the next UniFi OS bump.
- **What must switch on failover:** (a) the IPv6 default route to the surviving WAN, and (b) the active NAT66/masquerade source prefix. Both are scriptable on the UDM as above; neither is exposed as a GUI failover primitive today.

### 3. Does this deliver stable internal addressing + clean failover?
- **Internal addressing: yes.** Assign a fixed **ULA** (`fdxx::/48`) per VLAN via "Additional IPs"; internal DNS, firewall rules, and host-to-host traffic stay stable across any ISP PD change. This is the real win and is GUI-native.
- **Failover: partial, and not transparent.** Even with the script, MASQUERADE/NPTv6 failover is **stateful-session-breaking** — all live IPv6 flows reset when the WAN flips (community "waterside": NPTv6 failover *"would not be transparent … all existing sessions would be lost on failover"*). New connections recover once the route+NAT flip. Acceptable for a home VLAN; not seamless.
- Also note: if a **GUA is present on the LAN alongside the ULA, clients prefer the GUA** (RFC 6724), defeating the ULA-only routing intent. A clean ULA+NPTv6 design wants **ULA-only on the client VLAN** — which then makes you fully dependent on the NPTv6 mapping being correct.

### 4. Honest verdict
For a single-operator homelab: **use the native pieces, skip the fragile part.**
- ULA + GUI NAT66 to **one** WAN (KPN) = maintainable, GUI-native, upgrade-safe. Gives stable internal addressing and PD-change-proof inbound rules **today** on 10.5.
- Adding scripted NPTv6 **dual-WAN failover** = a genuine hack: an SSH-installed daemon that breaks on every auto-update unless wrapped in udm-boot, breaks all v6 sessions on switchover, and has no vendor support. High maintenance for a backup path that most homes can tolerate losing v6 on. **Not recommended as a long-term default.**

## Secondary sub-questions (original brief)
1. **IPv6 on both WANs at once?** You can *assign* a per-network IPv6 source WAN (WAN1/WAN2), so PD can be requested on both — but it is **one active LAN prefix at a time**, and routing does not honour the choice (see #2 below). [Dual-WAN thread]
2. **Failover behaviour:** **broken.** IPv4 fails over (NAT hides it); IPv6 keeps trying the dead WAN, no new address is allocated, and IPv6 traffic rules are ignored. Confirmed across UDM firmware 3.0.20 and RC 7.5.174, re-confirmed **≈2 months ago**. No RA-based clean renumber to the backup prefix happens automatically. [Dual-WAN thread]
3. **True PA multihoming (SADR/RFC 8028, advertise both prefixes):** **not supported** natively. UniFi is one-active-prefix-at-a-time; the dual-prefix + PBR model was "expected" for IPv6 but *"I haven't seen this actually implemented"*. NAT66/NPTv6 (§ above) is the only translation option, and only as GUI static NAT66 or an on-box script. [WAN-failover/NPTv6 thread]
4. **Community-recommended pattern (ranked for this case):**
   - a) **IPv6 on primary WAN only (KPN)** + ULA internal + GUI NAT66. GUI-native, upgrade-safe. *Recommended.*
   - b) **ULA + scripted NPTv6 dual-WAN failover.** Buildable, unsupported hack, breaks on auto-update, sessions drop on flip.
   - c) **Accept single-homed v6** (v6 down while on Ziggo backup). Zero maintenance.
   - d) BGP/PI multihoming — **out**, neither ISP offers it.
5. **ISP gotchas:**
   - **KPN:** delegates a **/48** via **DHCPv6-PD**, carried in **PPPoE on VLAN 6** (MTU 1492; 10.5 also supports RFC 4638 1500-byte PPPoE). Works on UDM with DHCPv6-PD + per-VLAN Prefix ID; the WAN interface may show no v6 address even when clients get GUAs (normal). Don't test with Safari (Private Relay masks v6). [KPN community] / [MikroTik KPN thread, 2024]
   - **Ziggo:** largely **DS-Lite / CGNAT** (shared IPv4). PD size **/56 or /60** depending on former-Ziggo vs former-UPC infra; original-Ziggo infra = dual-stack, former-UPC = DS-Lite only. Third-party-router DHCPv6-PD on the ConnectBox is historically flaky (broke late 2022; bridge-mode PD added later). **Confirm on the actual line that Ziggo delegates a routable PD to the UDM before assuming IPv6 backup is even possible.** [acropia 2021, live] / [synology-forum 2020, live]. Current vodafoneziggo community threads: **could not verify via fetch** (403 to WebFetch and headless).

## Sources
Live-verified this run unless marked otherwise.
- Dual-WAN thread — community.ui.com, "Dual WAN IPv6 Failover and Traffic Routing UDM-Pro" (created 2023, last activity ≈2 months before 2026-07-01). Rendered via headless browser (React shell to WebFetch). https://community.ui.com/questions/Dual-WAN-IPv6-Failover-and-Traffic-Routing-UDM-Pro/8c46d2bb-9aba-422b-ad2d-c78d6a7d5bcb
- NPTv6 thread — community.ui.com, "[RESOLVED] UniFi Network | IPv6 NPTv6 Support" (activity 4 months ago). Headless-rendered. https://community.ui.com/questions/UniFi-Network-or-IPv6-NPTv6-Support/cffc0906-a308-4a98-99eb-cf468def42de
- ULA thread — community.ui.com, "[RESOLVED] UniFi Network | IPv6 ULA Support" (quotes 9.4.17 notes). Headless-rendered. https://community.ui.com/questions/UniFi-Network-or-IPv6-ULA-Support/60169bdf-864d-4f56-bc44-74de9bbdb911
- WAN-failover/NPTv6 concept thread — community.ui.com (2019). Headless-rendered. https://community.ui.com/questions/IPv6-WAN-failover-IPv6-to-IPv6-Network-Prefix-Translation-NPTv6/cf20dfd7-8353-4276-a737-f06217d3bd1f
- 10.5.54 release notes — community.ui.com (RC). Headless-rendered; no IPv6/NAT66 items. https://community.ui.com/releases/UniFi-Network-Application-10-5-54/fdfe1b15-091c-410b-9cb9-3de3acfc1255
- Dong Knows Tech, "UniFi Network 10.5 released" — 10.5 released 2026-06-25; no IPv6 changes. WebFetch OK. https://dongknows.com/unifi-network-10-5-released/
- On-box failover script — github.com/mattackerman808/ipv6-wan-failover, README raw-fetched. ip6tables MASQUERADE + `ip -6 rule`; `/data` persists, systemd unit does not. https://github.com/mattackerman808/ipv6-wan-failover
- KPN /48 DHCPv6-PD on UDM — community.kpn.com "IPv6 settings for Unifi Dream Machine". WebFetch OK. https://community.kpn.com/thuisnetwerk-72/ipv6-settings-for-unifi-dream-machine-606460
- KPN fiber DHCPv6-PD /48, VLAN 6, PPPoE — forum.mikrotik.com (finalized 2024-07-17). WebFetch OK. https://forum.mikrotik.com/t/help-needed-with-ipv6-on-dhcpv6-pd-kpn-fiber/177256
- Ziggo /56–/60, DS-Lite vs dual-stack, PD to third-party — notes.acropia.nl (2021). Headless-rendered. https://notes.acropia.nl/2021/05/ipv6-bij-ziggo/
- Ziggo DS-Lite = CGNAT shared IPv4 — synology-forum.nl (2020). WebFetch OK. https://www.synology-forum.nl/netwerk-algemeen/ziggo-ipv6-ds-lite-i-c-m-compal-connectbox/
- **Could not verify via fetch:** help.ui.com "Configuring IPv6 in UniFi" and "Static IPv6 and DHCPv6-PD" (Cloudflare bot challenge, 403 + challenge on headless); community.vodafoneziggo.nl threads (403); udm-utilities/udm-boot pages (not fetched this run).

— Athena

---

## Update 2026-07-08 — API/changelog re-check

Re-check of the four moving parts (changelog IPv6, Integration API surface, dual-WAN IPv6, Ziggo PD) against the "not supported" baseline above. Every figure below was live-fetched this run (community.ui.com and vodafoneziggo rendered with Playwright; specs pulled with curl).

**Bottom line: nothing changed versus the baseline.** No new dual-WAN IPv6, no PD/WAN-IPv6 UI, no official API surface for WAN IPv6. Only cosmetic movement (an "IPv6 Detection" dashboard banner).

### Version reality first
- **Latest STABLE = 10.4.57** (official channel; bundled UniFi OS Server 5.1.21). Its notes render publicly.
- **10.5.x (10.5.43 / .51 / .54 / .56) is EARLY ACCESS / beta only** — every 10.5 release-notes page returns *"This part of community is for Early Access Users"* + a login wall (verified on 10.5.43 and 10.5.56). Content **could not be verified** without an EA login.
- Implication for us: if our box reports **10.5.54 with auto-upgrade "stable"**, it is actually on the **Early Access channel**, not stable. Worth confirming the update channel in the console.
- ⚠️ A user comment on the official 10.4.57 notes (posted ~6 h before this fetch): *"Network Application 10.4.57 keeps crashing on my UDM-Pro causing the network to go down."* Anecdotal, single report — but relevant with auto-upgrade ON.

### Q1 — Changelog 10.4.x → latest, IPv6 items
Live-read from the rendered **official 10.4.57** notes (cumulative for the 10.4 line):
- Improvement: **"Added an IPv6 Detection banner to the Dashboard."** (Requires UniFi OS 5.1.8+) — a cosmetic "you could enable IPv6" nudge. Not PD, not dual-WAN.
- Improvement: **"Improved validation for WireGuard IPv6 MTU and MSS settings."** — WireGuard VPN, not WAN.
- Bugfix: **"Fixed a gateway configuration error when entering an invalid IPv6 range in network settings."**
- **No** items on WAN DHCPv6-PD, dual-WAN IPv6, NAT66/NPTv6, per-VLAN ULA, or a prefix-delegation UI. (Those capabilities predate 10.4 — NAT66 in 9.4.17, ULA/Additional IPs in 10.0.160 per the sections above.)
- **10.5** (Dong Knows Tech, build 10.5.51, 2026-06-25): headline = **PPPoE 1500 MTU / RFC 4638**, SafeOps Data Plane Protection, dedicated update UI, SD-WAN underlay, Suricata 6→8. **Zero IPv6 items.**

**CHANGED vs baseline? No.** The only new IPv6 surface anywhere in 10.4→10.5 is a dashboard detection banner.

### Q2 — Integration API (developer.ui.com): any WAN-IPv6 / IA_PD / DHCPv6 surface?
- The public dev portal publishes only the **cloud "Site Manager API v1.0.0"**. Pulled its OpenAPI spec live (`/site-manager/v1.0.0/openapi.json`). Paths: `hosts`, `hosts/{id}`, `sites`, `devices`, `isp-metrics/{type}`, `isp-metrics/{type}/query`, `sd-wan-configs(+/{id}, /{id}/status)`, connector proxy. **`ipv6` / `prefix` / `dhcpv6` occurrences in the entire spec: 0.** ("internet" appears only inside ISP-metrics.) No per-WAN IPv6 address, no delegated prefix, no DHCPv6 client state.
- The **local Network Integration API** (X-API-KEY, `/v1`, documented in-app under Settings → Integrations; **no downloadable spec on the public portal** — Network/Protect/Mobility tabs resolve to no `/network/v1.0.0/*` path). Documented coverage per Art of WiFi: sites, devices, clients, **networks**, WiFi broadcasts, vouchers, firewall zones/policies, ACL rules, DNS policies. **No WAN / Internet resource → no per-WAN IPv6 surface.**

**CHANGED vs baseline? No.** Still no official surface for WAN IPv6 or delegated prefixes. We must still read WAN v6 indirectly via legacy `stat/device`.

### Q3 — Dual-WAN IPv6 native (load-balance/failover)?
- **Still not supported.** Most recent authoritative-ish datapoint: reply by user **bh3, "2 months ago" (≈ May 2026)** on the Dual-WAN thread, live-rendered: you *can* pick which WAN assigns v6 to a network, but *"even if you get the IPv6 address from WAN2, IPv6 traffic doesn't get routed via WAN2 … Setting a traffic route for IPv6 addresses doesn't help (i.e. traffic routes for IPv6 don't work)."* Closing line: *"3 years later and this is still the case. Any plans to fix this bug, @UI-Team?"* — **no UI-Team response** in the thread. No release note contradicts this.

**CHANGED vs baseline? No.** Dual-WAN IPv6 routing/failover remains broken; assign-only, no routing.

### Q4 — Ziggo (AS33915) DHCPv6-PD: routable prefix or CGNAT-only?
- **Line-dependent, unchanged.** Former-**Ziggo** (native dual-stack) areas delegate a routable **/56**; former-**UPC** areas are largely **DS-Lite / CGNAT** where a routable PD is often absent or flaky.
- Live-verified sources: **mtak EdgeRouter guide** — *"Ziggo will give you a `/56` prefix, and you want to split that up in `/64`s"* (native dual-stack, no DS-Lite; guide ~2021). **unifi-forum.nl** (Nov–Dec 2021) — Ziggo letter says **PD = /56**, modem in **bridge mode**; but results on UDM Pro were mixed (one user got a gateway address, another *"krijg ik geen IPv6 adres toegewezen"* = got no IPv6 at all).
- Recent **Feb 2025** vodafoneziggo community threads (search-listed: /56 fZiggo, /57 fUPC, bridge-mode for the full /56) **could NOT be verified** — the forum sits behind a Cloudflare *"Verify you are human"* challenge that blocks both WebFetch (403) and Playwright (challenge page). Treat the 2025 figures as unverified.

**CHANGED vs baseline? No.** Still: confirm on the actual line whether Ziggo hands the UDM a routable /56 before assuming an IPv6 backup path exists.

### Sources (all live-fetched 2026-07-08)
- Official 10.4.57 notes (Improvements + Bugfixes, incl. "IPv6 Detection banner"; crash comment) — community.ui.com, Playwright-rendered (full-page). https://community.ui.com/releases/UniFi-Network-Application-10-4-57/92694b29-fd78-4d52-906a-3211136610e2
- 10.5.43 / 10.5.56 notes = **Early Access login wall** ("This part of community is for Early Access Users"), Playwright-rendered. https://community.ui.com/releases/UniFi-Network-Application-10-5-56/33533eca-865e-449a-9573-4d95bf57319e
- Version list (10.4.46/55/57, 10.5.43/51/54/56; 10.4.57 = official) — goofball222/unifi CHANGELOG raw. https://raw.githubusercontent.com/goofball222/unifi/main/CHANGELOG.md
- 10.5 = build 10.5.51, 2026-06-25, PPPoE RFC 4638, no IPv6 — Dong Knows Tech, WebFetch OK. https://dongknows.com/unifi-network-10-5-released/
- Site Manager API OpenAPI spec (0× ipv6/prefix/dhcpv6; path list) — curl. https://developer.ui.com/site-manager/v1.0.0/openapi.json
- Dev portal (Site Manager selected; Network/Protect/Mobility tabs, no published Network spec) — developer.ui.com, Playwright-rendered. https://developer.ui.com/
- Network Integration API coverage list (no WAN/Internet resource) — Art of WiFi, WebFetch OK. https://artofwifi.net/unifi-api
- Dual-WAN IPv6 still broken, bh3 reply "2 months ago" — community.ui.com, Playwright-rendered. https://community.ui.com/questions/Dual-WAN-IPv6-Failover-and-Traffic-Routing-UDM-Pro/8c46d2bb-9aba-422b-ad2d-c78d6a7d5bcb
- Ziggo /56 native dual-stack — mtak EdgeRouter guide, WebFetch OK (content ~2021). https://mtak.github.io/Ziggo-Edgerouter/
- Ziggo PD /56 + bridge mode on UDM Pro (mixed results) — unifi-forum.nl, Nov–Dec 2021, WebFetch OK. https://unifi-forum.nl/onderwerpen/bericht-ontvangen-over-ziggo-modem-in-bridge-mode-ipv6.2654/
- **Could not verify:** community.vodafoneziggo.nl 2025 threads (Cloudflare human-challenge on WebFetch + Playwright); help.ui.com IPv6 docs (Cloudflare, per prior section); 10.5.x EA-gated notes.

— Athena

---

## GUI runbook research 2026-07-08 (chg-002)

Goal: hand the user an exact GUI runbook for (A) a static ULA + SLAAC on CLIENT-VLAN and (B) NAT66 egress via the KPN WAN GUA, on UniFi Network 10.5.54 (UDM Pro Max, UniFi OS).

**Evidence method this run.** help.ui.com sits behind a Cloudflare "Verify you are human" Turnstile challenge that blocks WebFetch (403) *and* Playwright headless (I rendered the challenge page itself — screenshot `/private/tmp/.../ipv6doc.png`, confirms the interactive checkbox, no article content). Workaround: fetched the **Internet Archive Wayback snapshots** of the two official articles with `curl --compressed` and stripped tags. Both are Zendesk server-rendered HTML, so the snapshot text is the real article body. Snapshot dates noted per source.

### Task A — per-network IPv6 (ULA + SLAAC). Exact labels, verbatim from the official doc

Rendered source: "Configuring IPv6 in UniFi", **Wayback snapshot 2026-06-06** of `help.ui.com/hc/.../36378535649687`. Section "IPv6 Local (LAN) Configuration".

The per-network editor exposes an **"Interface Type"** selector with these options (verbatim):
- **Prefix Delegation** — "Automatically assigns a unique /64 subnet to each VLAN using the prefix received from the ISP. This is available for WANs configured with either SLAAC or DHCPv6."
- **Static** — "Assigns a fixed IPv6 address and subnet to the VLAN interface. **This method is only available for those with a static IPv6 WAN configuration provided by the ISP.** Use this option if you need to configure Unique Local Addresses (ULA) as your primary IP address, then you can use NAT66 to translate it."

Under an **"Advanced"** block (below Interface Type):
- **Auto** — "recommended for most setups".
- **Additional IPs** — "Allows you to specify other IP addresses on the VLAN interface, in addition to the Gateway IP already configured. This can be used to configure Unique Local Addresses (ULA) as your **secondary IP address** so clients can use multiple IPs simultaneously."
- **Client Address Assignment** — "Determines how clients receive IPv6 addresses, either via **SLAAC** or **DHCPv6**. SLAAC is generally recommended… If DHCPv6 is ever required, you can also enable **Allow SLAAC**."
- **Router Advertisement (RA)** — toggle; "inform clients that an IPv6 router is present… SLAAC, discover the default gateway…".
- **RA Priority** — "High > Medium > Low".

**Key finding / tension the user must resolve in the console.** The doc gives *two* ULA paths, and they differ in whether the ULA is the *only* v6 on the VLAN:
- **ULA as PRIMARY (true egress-only, ULA is the only prefix):** `Interface Type = Static`. BUT the same doc says Static "is only available for those with a static IPv6 WAN configuration." Our KPN WAN is **DHCPv6-PD, not static** → Static may be greyed out / unavailable. **Could not verify** whether the UDM lets you pick Static interface type on a LAN while the WAN is DHCPv6-PD (no console access; help page is Cloudflare-blocked; not stated in the doc).
- **ULA as SECONDARY (ULA alongside the PD GUA):** `Advanced → Additional IPs`, add the ULA. Works with any WAN incl. PD. But this is **not egress-only** — clients also get a real KPN GUA and, per RFC 6724, prefer the GUA (routes natively, defeats the NAT66-to-KPN intent).

So "egress-only ULA" as specified requires the **Static** path; if the console refuses Static on a PD WAN, the design must fall back to Additional-IPs (ULA + GUA coexist) or to suppressing PD on that VLAN. This is a live-console decision, not resolvable from docs.

**Exact field for typing the prefix — partially verified.** For the **Additional IPs** path, the prefix is entered in the **"Additional IPs"** field (verbatim label). For the **Static** path the doc only describes the *WAN* static fields ("IPv6 address, gateway, and prefix"); the exact LAN-interface field label for the ULA/subnet under Static — **could not verify exact label** (not shown in the rendered doc; likely the interface Gateway IP/Subnet field, but unconfirmed).

Top-level click path **Settings → Networks → [network] → (IPv6 section)** is the standard UniFi location and is stated as "Settings > Networks > [Select Network] > IPv6" in the same help article's summary; the field labels above are the verbatim contents of that section.

### Task B — NAT66 is an EXPLICIT Policy Table rule, not an auto per-network toggle

Rendered sources: "Configuring IPv6 in UniFi" (Wayback 2026-06-06) + "DNAT, SNAT, and Masquerading in UniFi" (**Wayback snapshot 2025-09-11**, `help.ui.com/hc/.../16437942532759`).

**Model: explicit rule (answers B-Q1/Q2).** The IPv6 doc's NAT66 section says verbatim: "To configure NAT66: 1. Assign a Unique Local Address (ULA) as a primary IP … or secondary IP … to local clients. 2. **Navigate to Settings > Policy Table > Create New Policy > NAT.** 3. **Specify IPv6 as your IP Version.** 4. Configure your NAT rule…". There is **no** per-network "NAT6"/"Masquerade" toggle — you build a standalone Policy-Table NAT rule.

**Rule fields, verbatim (Masquerade NAT):**
- Path (Network 9.4+): **Settings > Policy Table > Create New Policy > NAT**. (Network 9.3 legacy: "Settings > Policy Engine > NAT > Create New".) We are on 10.5 → use the Policy Table path.
- **IP Version = IPv6** (this is the NAT66 switch).
- Rule type: **Masquerade** — "the default behavior of UniFi NAT… a form of Source NAT (SNAT) that **dynamically adapts to the outbound interface's current IP address**, making it ideal for connections where the public IP may change frequently." (Exactly our case: KPN's delegated GUA can renumber.)
- **Select Interface** — "Traffic exiting your network will be translated as it exits **this** interface." → this is where you **pin the exit WAN**.
- (Optional) Translated Port; **Protocol**.
- **Specify Source & Destination** — tunable as **Any / Network(s) / IP(s) and Port(s) / Object(s)**. Set Source = CLIENT-VLAN network (or the ULA prefix as IP(s)/Object).
- **Click Add.**

Note: the two other rule types on the same screen are **Src. NAT** (static translated IP — needs a fixed GUA we don't have) and **Dest. NAT**. Masquerade is correct because KPN's GUA is dynamic.

NAT66 landing release: parent sections above cite a community quote of the **9.4.17** notes ("Added support for IPv6 NAT66 rules to the Policy Table"); the masquerading doc dates the Policy-Table NAT UI to **Network 9.4** and the IPv6 doc notes NAT66 requires **UniFi OS 4.4+**. All present in 10.5.

### WAN binding under dual-WAN (answers the BCP38 question)

**Yes, binding matters and it IS controllable** — the Masquerade rule's **"Select Interface"** field is the exit-WAN selector. Pin it to the **KPN WAN**. Because UniFi's dual-WAN **IPv6 routing/failover is broken** (established in the sections above, community-re-confirmed ≈May 2026: v6 does not follow the surviving WAN and v6 traffic-routes are ignored), IPv6 egresses whichever WAN currently holds the v6 default route — which, in the KPN-only-IPv6 design, is KPN. Pinning the masquerade to the KPN interface means: if a v6 flow ever *did* try to leave via Ziggo, it would **not** match the KPN-bound rule, would exit with its untranslated ULA source, and be **dropped by BCP38** — i.e. it fails closed, not silently leaking. This is the intended safety behaviour. There is **no** GUI primitive that makes NAT66 follow a failover to Ziggo (would require the on-box script discussed above).

### Could-not-verify list (this run)
- **help.ui.com live pages** — Cloudflare Turnstile blocks WebFetch (403) and Playwright headless (rendered the challenge, not the article). All Task A/B labels above come from **Wayback snapshots** (2026-06-06 IPv6 article; 2025-09-11 NAT article), not the live 10.5.54 console. Labels can differ slightly on an RC/EA build.
- **Whether `Interface Type = Static` is selectable on a LAN while the KPN WAN is DHCPv6-PD** — doc says Static needs a static WAN; not testable without the console.
- **Exact LAN field label for entering the ULA prefix under the Static interface type** — doc shows only WAN-static field names; LAN-static field label unconfirmed.
- **The exact in-editor position/heading of the IPv6 block within the network editor on 10.5.54** — top-level path (Settings → Networks → [network]) is standard; section labels are verbatim from the article body.
- **10.5.54 RC-specific label changes** — 10.5 notes are EA-gated (prior section); assume 10.4/9.4 labels unless the console shows otherwise.

### Sources (this run)
- "Configuring IPv6 in UniFi" — Wayback snapshot **2026-06-06**, curl `--compressed` + tag-strip (live help.ui.com = Cloudflare 403 + Turnstile). Original: https://help.ui.com/hc/en-us/articles/36378535649687-Configuring-IPv6-in-UniFi ; snapshot: http://web.archive.org/web/20260606191924id_/https://help.ui.com/hc/en-us/articles/36378535649687-Configuring-IPv6-in-UniFi
- "DNAT, SNAT, and Masquerading in UniFi" — Wayback snapshot **2025-09-11**, same method. Original: https://help.ui.com/hc/en-us/articles/16437942532759-DNAT-SNAT-and-Masquerading-in-UniFi ; snapshot: http://web.archive.org/web/20250911124854id_/https://help.ui.com/hc/en-us/articles/16437942532759-DNAT-SNAT-and-Masquerading-in-UniFi
- help.ui.com live Cloudflare challenge — Playwright screenshot `/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/eda6873c-.../scratchpad/ipv6doc.png` (this run, 2026-07-08).
- Dual-WAN IPv6 routing/failover still broken — see "Update 2026-07-08" section above (community.ui.com, Playwright-rendered).

— Athena
