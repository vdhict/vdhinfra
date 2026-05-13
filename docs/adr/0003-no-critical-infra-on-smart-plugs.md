# 0003 — Critical infrastructure must not be gated by smart plugs

Status: accepted
Date: 2026-05-13
Decision-makers: user (Sander), Atlas

## Context

On 2026-05-13 the UDM Pro Max (the household firewall, UniFi controller, **and** Protect NVR) repeatedly destabilised under what looked like polling load. Hours of investigation by Athena (research) and Iris (UDM state) chased software hypotheses: poller surface changes in UniFi Network 10.x, a dnsmasq class of bug, an AAAA-static-DNS footgun. All plausible. All wrong.

The actual cause was physical. The HomeWizard Energy Socket at 172.16.3.205 — the one powering the UDM — had a failing relay that the user could hear clicking on-off. The clicks were faster than HA's 60-second power-sensor poll could resolve, so HA's energy graph showed a perfectly steady 33 W draw while the device behind it was getting brief power glitches that destabilised the controller's services.

Findings file: `docs/research/udm-crash-rootcause-10.3.x.md` (`chg-2026-05-13-021`).
Incident: `inc-2026-05-13-003` (closed with postmortem).

This pattern — invisible-to-polling power glitches mistaken for a software problem — is high-cost: ~6 hours of agent + human time chased the wrong hypothesis, multiple secondary mitigations (poller scope changes, suspends, retires) were enacted along the way. The fix that mattered was four words: **unplug it from there**.

## Decision

**No component classified `family-critical` or whose failure would compromise the household's connectivity, safety, or data integrity may have a smart plug (or any non-essential active component) in its power path.**

Concretely:

- UDM Pro Max — direct mains.
- Cluster nodes (3 CP + 3 worker) — direct mains or dumb UPS.
- Synology NAS (NFS for `media`, source of truth for some backups) — direct mains or dumb UPS.
- HomeWizard P1 / Watermeter / similar passive meters — exempt; they read, they don't gate.
- Any future "core" device added to the CMDB tier 0–2 — same rule.

"Dumb UPS" = pure power-conditioning + battery, no managed PDU functions, no Wi-Fi, no firmware that can crash and open a relay.

## Alternatives considered

1. **Keep smart plugs but only on certified low-failure models** — no manufacturer documents relay MTBF; we have no way to certify in advance.
2. **Monitor smart plugs aggressively and auto-fail-over** — adds more software in front of a hardware failure mode that takes <100 ms; complex; doesn't actually prevent the outage.
3. **Status quo + caveats** — what we did before today. The cost of one missed-cause incident (~6 hours) exceeds the cost of the rule.

## Consequences

- **Operational**: home automation (Hestia's domain) can still use smart plugs everywhere they're useful — fridges, washing machines, sockets where remote control matters. The rule scopes only to `sla_tier: family-critical` infrastructure.
- **CMDB**: any CMDB entry with `tier: 0` or `tier: 1` and `sla_tier: family-critical` whose `depends_on` includes a `type: power-device` will be flagged by Argus's posture scan as a **medium-severity finding** until the dependency is removed. The current `hw.plug.vdhngfw_power → net.udm` link exists only because the warranty replacement hasn't arrived; this finding is the "still on borrowed time" reminder.
- **Future hardware adds**: a step in any new-device runbook is "is this device family-critical? if yes, NO smart plug in the power path".

## Argus rule

The posture scan's `check_power_path()` (Phase 2c work) will:

```text
for each component where sla_tier == family-critical AND tier <= 2:
    for each id in transitive depends_on:
        if cmdb[id].type == 'power-device':
            FINDING(medium, "family-critical {id_a} powered through smart plug {id_b}",
                    remediation="move to direct mains or dumb UPS; see ADR-0003")
```

Until then, the rule is operator-enforced via this ADR and the explicit `hw.plug.*` flag in the CMDB.

## Review

Revisit when:
- A "smart plug" architecture emerges that is electrically passive (e.g. a relay that fails closed by hardware design, with no firmware in the failure path). Today no consumer device meets that bar.
- The household scales to where remote power-cycling of core gear becomes operationally necessary (rare in a single-operator homelab).

Otherwise this ADR is reviewed annually with ADR-0001 and ADR-0002.

## Related

- ADR-0001 — Flux cluster-admin (parallel "accepted risk" pattern, different domain).
- ADR-0002 — CMDB vs live data.
- Incident `inc-2026-05-13-003` — the post-mortem captures the timeline.
- Memory: `unifi-v10-poller-breakage` — the *secondary* problem the misdiagnosis surfaced (and that we did fix).
- Accepted risk: none. This is a *rule*, not an accepted risk.
