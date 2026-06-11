# Ceph OSD SSD Replacement — NL Pricing Gut-Check (2026-06)

## Question
What do enterprise SATA SSD replacements for the worn Ceph OSDs (PLP, ≥1 DWPD, TLC,
DRAM, ~960 GB 2.5") cost in NL right now, and what is the premium over a cheap
consumer Crucial BX500 1 TB baseline?

## TL;DR
- Engineering verdict stands: **BX500 is wrong for Ceph** — confirmed DRAM-less, 3D
  NAND, no PLP. Cheap (~€149) but unsuitable for a write-amplified Ceph OSD.
- **SSD market is squeezed in June 2026.** Enterprise SATA at NL *consumer* retailers
  (Megekko, Alternate) is almost entirely **out of stock**; the live in-stock prices
  come from B2B server resellers and are high.
- **Best verified in-stock new enterprise drive: Samsung PM893 960 GB at Creo Server,
  €659.45 incl. VAT, 5 in stock.** Kingston DC600M 960 GB is €675–700 incl. VAT.
- **Could not verify a single used/refurb enterprise price live** — every used PM883/PM893
  listing I found (ServerZaak) was out of stock with no price shown. The "value play"
  is currently unavailable to verify.
- Replacing **just osd.2** (1 drive) = **~€660 (PM893, new)** vs **~€150 (BX500)** →
  a **~€510 premium** for PLP + endurance + DRAM. Doing it right is ~4.4× the BX500.

## Drive comparison (all prices LIVE-fetched this run; see Sources for fetch dates)

| Drive | Exact SKU | Cap | PLP | Endurance (DWPD / TBW) | DRAM | NAND | Price EUR (incl. VAT) | Condition | Source (fetch 2026-06-10/11) |
|---|---|---|---|---|---|---|---|---|---|
| Samsung PM893 | MZ7L3960HCJR-00A07 | 960 GB | Yes¹ | 1.0 DWPD¹ (~1752 TBW vendor-spec, not live-verified) | Yes¹ | V-NAND TLC | **€659.45** (5 in stock) | New | Creo Server |
| Samsung PM893 | MZ7L3960HCJR-00A07 | 960 GB | Yes¹ | as above | Yes¹ | V-NAND TLC | €819.50 (10+ stock) | New (bulk) | DectDirect |
| Kingston DC600M | SEDC600M/960G | 960 GB | **Yes** (on-board PLP caps, live-confirmed) | ~1 DWPD mixed-use (TBW not live-verified) | Yes² | 3D TLC | €675.17 (ARP) / €699.75 (DectDirect) | New | ARP / DectDirect |
| Micron 5400 PRO | MTFDDAK960TGA-1BC1 | 960 GB | Yes² | ~1.5 DWPD read-intensive (not live-verified) | Yes² | 3D TLC | €843.00 **excl.** VAT (≈€1020 incl.; ~2 wk lead) | New | Future Store |
| Samsung PM883 (used) | MZ7LH960HAJR | 960 GB | Yes² | ~1.3 DWPD (vendor) | Yes² | TLC | **could not verify** (out of stock, no price) | Used | ServerZaak |
| **Crucial BX500** | CT1000BX500SSD1 | 1 TB | **No** | low (~360 TBW class, consumer) | **No** (DRAM-less) | 3D NAND TLC | **€149.90** (Azerty) / €149.00 (bol.com) | New | Azerty / bol.com |

¹ PM893 line: "1.0 DWPD" and 5-yr warranty confirmed live on Samsung's PM893 page;
PLP/DRAM are standard PM893 datacenter features (page itself thin on per-SKU detail).
² PLP/DRAM for DC600M / Micron / PM883 are the published datacenter-class features for
these families; the DC600M's on-board PLP was the only one I could read on a live
*price* page (DectDirect). TBW/DWPD per-SKU numbers were NOT fetched live this run —
the manufacturer datasheet PDFs returned 403, so treat them as vendor-published, not
independently verified.

## Patterns that recur
- **All three enterprise candidates share: PLP, TLC, DRAM, ~1 DWPD class, 5-yr warranty.**
  That is exactly the spec envelope a Ceph OSD wants and exactly what the BX500 lacks
  on all four counts.
- **What differs:** workload tilt (DC600M = mixed-use; PM893/PM883 = read-intensive;
  Micron 5400 PRO = read-intensive with a higher-endurance MAX variant) and price.
- **Market reality (June 2026):** consumer-channel enterprise SATA is dry. In-stock =
  B2B resellers only, at a premium. Even the BX500 baseline (~€149) is up sharply from
  the ~€70 it sat at historically — the whole SSD market is elevated, which compresses
  the *relative* premium of going enterprise.

## Recommendation
Replace **osd.2 only** for now with **one new Samsung PM893 960 GB from Creo Server at
€659.45 incl. VAT** (best verified in-stock new enterprise price, 5 units available,
TLC + DRAM + PLP + 1 DWPD + 5-yr warranty). The Kingston DC600M 960 GB is a fine
mixed-use alternative at €675–700 but ~€20–40 more for no benefit on a read-leaning
Ceph block pool. Avoid the Micron 5400 PRO line for now — only found at ~€1020 incl.
with a 2-week lead.

**Premium for doing it right (single drive):** ~€660 (PM893) − ~€150 (BX500) ≈ **€510**.
That buys PLP (protects in-flight writes on power loss — critical for Ceph BlueStore),
~3–5× the endurance, and a DRAM cache the BX500 simply doesn't have. For one drive that
is an easy call; do not let the price spike tempt a BX500 substitution.

**Honest gaps:** I could not verify any used/refurb enterprise price live (the supposed
"value play" was out of stock everywhere I checked). If a used PM883/PM893 around
€90–150 surfaces on Tweakers V&A it could roughly halve the premium — worth a manual
check before buying, since Tweakers Pricewatch/V&A blocks automated rendering
(reCAPTCHA) and I couldn't read it this run. Per-SKU TBW/DWPD numbers in the table are
vendor-published, not independently fetched (datasheet PDFs 403'd).

## Sources
- Samsung PM893 960 GB (Creo Server, NEW, €659.45 incl., 5 in stock) — https://www.creoserver.com/samsung-enterprise-960gb-25-sata-6gb-s-pm893-nieuw — fetched 2026-06-11, 200 OK
- Samsung PM893 960 GB MZ7L3960HCJR-00A07 (DectDirect, NEW bulk, €819.50 incl.) — https://www.dectdirect.nl/nl/ssd-960gb-samsung-25-63cm-sataiii-pm893-bulk.html — fetched 2026-06-10, 200 OK
- Samsung PM893 line "1.0 DWPD / 5-yr warranty" — https://semiconductor.samsung.com/ssd/datacenter-ssd/pm893/mz7l3960hcjr-00a07/ — fetched 2026-06-10, 200 OK (per-SKU specs not shown)
- Kingston DC600M 960 GB SEDC600M/960G (ARP, NEW, €675.17 incl.) — https://www.arp.nl/shop/kingston-dc600m-ssd-960gb--4720723--p — fetched 2026-06-10, 200 OK
- Kingston DC600M 960 GB (DectDirect, NEW, €699.75 incl., on-board PLP confirmed) — https://www.dectdirect.nl/nl/dc600m-ssd-mixed-use-960-gb-sata-6gb-s.html — fetched 2026-06-10, 200 OK
- Kingston DC600M 960 GB (bol.com BE) — https://www.bol.com/be/nl/p/hard-drive-kingston-dc600m-tlc-3d-nand-960-gb-ssd/9300000149235655/ — fetched 2026-06-10, 200 OK, "Niet leverbaar" (out of stock)
- Micron 5400 PRO 960 GB (Future Store, €843 excl. VAT, ~2 wk lead) — https://futurestore.nl/webshop/micron-5400-pro-960gb-ssd-sata/ — fetched 2026-06-10, 200 OK
- Samsung PM883 960 GB used (ServerZaak) — https://www.serverzaak.nl/default/samsung-pm883-enterprise-ssd-960gb-sataiii-used.html — fetched 2026-06-10, 200 OK, "Niet op voorraad" / no price (could not verify)
- Crucial BX500 1 TB CT1000BX500SSD1 (Azerty, €149.90 incl., DRAM-less confirmed) — https://azerty.nl/product/crucial-bx500-1tb-ssd/4074858 — fetched 2026-06-11, 200 OK
- Crucial BX500 1 TB (bol.com, €149.00 incl.) — https://www.bol.com/nl/nl/p/crucial-bx500-1tb-interne-ssd-2-5-inch-sata-iii-3d-nand-560-mb-s/9200000124446138/ — fetched 2026-06-11, 200 OK
- Tweakers Pricewatch — NOT accessible: headless render hits reCAPTCHA ("Bevestig dat je geen robot bent"), screenshot /tmp/ssd-pricing/dc600m-search.png, 2026-06-11. Could not read NL aggregate lowest prices.
- Alternate.nl & Megekko DC600M/PM893 960 GB pages rendered via kiosk-verify 2026-06-11: all showed "(tijdelijk) niet meer leverbaar" — out of stock, no price.

---

## Addendum (2026-06-11): Prosumer DRAM+TLC middle tier (1 TB, 2.5" SATA)

### Question
Where do consumer/prosumer DRAM+TLC SATA SSDs (better than the DRAM-less QLC-class
BX500, cheaper than the enterprise PM893) actually land on price in NL right now — so
the middle ground between the **BX500 (~€150)** and **PM893 (~€659)** anchors is visible?

### Middle-tier table (all prices LIVE-fetched 2026-06-11; anchors carried over)

| Drive | Exact SKU | TBW (1 TB) | DRAM | partial-PLP | Price EUR (incl. VAT) | Stock | Source + fetch |
|---|---|---|---|---|---|---|---|
| **Crucial BX500** *(low anchor)* | CT1000BX500SSD1 | ~360-class (consumer) | **No** | No | **€149.90** / €149.00 | In stock | Azerty / bol.com, 2026-06-11 |
| WD Red SA500 | WDS100T1R0A | 600 TBW¹ | **Yes** | No | **€239.00** | In stock (5) | Azerty, 2026-06-11, 200 OK |
| Samsung 870 EVO | MZ-77E1T0B/EU | **600 TBW** (live-confirmed) | **Yes** (1 GB LPDDR4) | No | €246.13 (bol.com) / €259.00 (Azerty) | In stock | bol.com + Azerty, 2026-06-11, 200 OK |
| Crucial MX500 | CT1000MX500SSD1 | 360 TBW¹ | **Yes** | **Yes** (partial / data-at-rest)¹ | **€269.00** (bol.com, in stock) | see note² | bol.com, 2026-06-11, 200 OK |
| Samsung PM893 *(high anchor)* | MZ7L3960HCJR-00A07 | ~1752 TBW¹ (1 DWPD) | Yes | **Full PLP** | **€659.45** (960 GB) | In stock (5) | Creo Server, 2026-06-11 |

¹ **TBW / partial-PLP figures are vendor-published, not independently fetched this run.**
Samsung NL page DID confirm 870 EVO = 600 TBW + 1 GB LPDDR4 DRAM live (200 OK). The
Crucial MX500 flyer PDF (503) and WD Red SA500 datasheet PDF (404) were unreachable, so
WD Red SA500 600 TBW, MX500 360 TBW, and MX500 partial-PLP are vendor-spec only.
² **MX500 stock is messy.** Azerty lists CT1000MX500SSD1 at €79.00 but flags it
"Dit product komt helaas niet meer terug" / "Levertijd 10+ werkdagen" — i.e. a stale
listing for a **discontinued/out-of-stock** SKU, not a buyable price. The live *in-stock*
NL price is bol.com €269.00 ("Wel leverbaar"). The bol.com buy-box price came from the
200-OK page text; a kiosk-verify render couldn't visually confirm it because a cookie
modal covered the buy box (screenshot /tmp/ssd-mid-tier/mx500-bol.png). Treat €269 as
the verified in-stock figure with that caveat.

### One-line read
**At today's inflated NL prices the BX500 (~€150) is poor value: for €89 more the WD Red
SA500 (€239) adds a DRAM cache and 600 TBW — ~1.6× the BX500's price for a categorically
better drive — while the 870 EVO (€246) sits barely above the BX500 at the same DRAM+600
TBW spec. The prosumer tier lands at €239–269, roughly 1.6–1.8× the BX500 and ~0.4× the
PM893; if you're paying €150 for a DRAM-less QLC-class BX500, the 870 EVO at €246 makes
the BX500 look like a non-buy.** (None of the prosumer three have full PLP — only the
MX500 has *partial* power-loss immunity — so for Ceph BlueStore the PM893 anchor still
wins; this tier is about exposing how bad the BX500's price/value is, not a Ceph rec.)

### Sources (addendum)
- WD Red SA500 1 TB WDS100T1R0A (Azerty, €239.00 incl., 5 in stock) — https://azerty.nl/product/wd-red-sa500-nas-sata-solid-state-drive/4069919 — fetched 2026-06-11, 200 OK
- Samsung 870 EVO 1 TB MZ-77E1T0B/EU (Azerty, €259.00 incl., 9 in stock) — https://azerty.nl/product/samsung-870-evo-1-tb-solid-state-drive/4421728 — fetched 2026-06-11, 200 OK
- Samsung 870 EVO 1 TB (bol.com, €246.13 incl., in stock) — https://www.bol.com/nl/nl/p/samsung-870-evo-interne-ssd-2-5-inch-1tb/9300000019565775/ — fetched 2026-06-11, 200 OK
- Samsung 870 EVO 1 TB — 600 TBW + 1 GB LPDDR4 DRAM + 5-yr warranty (Samsung NL) — https://www.samsung.com/nl/memory-storage/sata-ssd/870-evo-1tb-sata-3-2-5-ssd-mz-77e1t0b-eu/ — fetched 2026-06-11, 200 OK
- Crucial MX500 1 TB CT1000MX500SSD1 (bol.com, €269.00 incl., "Wel leverbaar") — https://www.bol.com/nl/nl/p/crucial-mx500-1tb-3d-nand-sata-2-5-inch-internal-ssd-up-to-560mb-s-ct1000mx500ssd1/9300000166553773/ — fetched 2026-06-11, 200 OK
- Crucial MX500 1 TB CT1000MX500SSD1 (Azerty, €79.00 but discontinued/10+ day lead — NOT a buyable in-stock price) — https://azerty.nl/product/crucial-mx500-1tb-solid-state-drive/5756398 — fetched 2026-06-11, 200 OK
- Crucial MX500 flyer PDF — endurance/PLP NOT verified: https://content.crucial.com/content/dam/crucial/ssd-products/mx500/flyer/crucial-mx500-ssd-productflyer-en.pdf — fetched 2026-06-11, **503** (could not verify)
- WD Red SA500 datasheet PDF — TBW NOT verified: 404 on the documents.westerndigital.com path, 2026-06-11 (could not verify; 600 TBW is vendor-published)
- Amazon.nl MX500 (B084SBT58J / B077SF8KMG) — WebFetch 500; kiosk-verify render of B084SBT58J resolved to an unrelated ski-helmet product (stale ASIN); B016PX03UW rendered as the correct SKU but buy-box price not isolatable — Amazon.nl price could not be cleanly verified (screenshots /tmp/ssd-mid-tier/).

— Athena
