# chg-2026-09-09-002 — READ-ONLY recon. NO WRITES PERFORMED.

Iris, 2026-09-09. I stopped before executing this change (Argus condition 3 fired on
chg-001). Everything below is reconnaissance to let Atlas decide. Nothing was written.

## A. Firmware delta — UniFi Network **10.6.101** (last recorded memory was 10.4.57)

The `reference_unifi_10_4_57` memory is stale. Per the udmcontrol firmware checklist the
delta must be recorded **before** non-trivial writes, and chg-002 Part A *is* a UniFi
write. Confirmed delta so far (integration X-API-KEY, `/proxy/network/v2/api/site/default/`):

| path | 10.6.101 | note |
|---|---|---|
| `firewall-policies` | **200** | 104 policies, readable |
| `firewall-zones` | **404** | **RENAMED** |
| `firewall/zone` | **200** | new path for zones |
| `firewall/zone-matrix` | **200** | present |
| `firewall-zone`, `zone-matrix` | 404 | not valid |

Zones present: Dmz, External, Gateway, Hotspot, Internal, IoT, Vpn.
**Writability of firewall policies on 10.6.101 was NOT tested** (that is a write).
Given 10.4.57 already removed `rest/device` from the X-API-KEY scope, we must NOT assume
`firewall-policies` PUT works. Test on one low-risk policy first.

## B. Confirmed: `logging=true` on **0 of 104** policies. Matches Atlas.

## C. The IoT<->Internal boundary, with MEASURED traffic rates

Rates derived from two `hits` snapshots 3.0 min apart. NB the `hits` counter updates
coarsely (a 90 s sample showed zero delta), so these are 3-min averages, not instantaneous.

| direction | action | predefined | total hits | rate/s | **est. syslog lines/day if logged** | name |
|---|---|---|---|---|---|---|
| IoT->Internal | **BLOCK** | **true** | 1,769 | ~0 | **~0** (last hit 08-31 01:07) | Block All Traffic |
| IoT->Internal | ALLOW | false | 1,392,098 | 1.51 | **130,111** | Allow IoT to MQTT broker |
| IoT->Internal | ALLOW | true | 1,599,865 | 2.01 | 173,963 | Allow Internal to IoT (Return) |
| Internal->IoT | ALLOW | false | 2,984,482 | 3.61 | **312,266** | Allow Internal to IoT |

## D. Assessment Atlas asked for: does the MQTT hole need logging?

First, the hole is **properly scoped** — I checked the object, it is not an ANY/ANY:
```
protocol: tcp
destination: { matching_target: IP, matching_target_type: SPECIFIC, ips: ["172.16.2.244"],
               port_matching_type: SPECIFIC, port: "1883" }
source:      { matching_target: ANY }   # any host inside the IoT zone
```
Combined with evidence file 08 of chg-001 (`allow_anonymous false`, password file in
force), this hole does **not** expose an unauthenticated broker.

**My recommendation, and it differs from the brief:**

1. **`Block All IoT->Internal` — LOG IT. Highest value, essentially free.** ~0 lines/day,
   1,769 hits ever, last hit 2026-08-31. This is the actual escalation-attempt signal.
   Every line is interesting. This should be logged regardless of what else is decided.
2. **`Allow IoT to MQTT broker` — LOG IT, second priority.** 130k lines/day is real but
   affordable, and this is the *only permitted* IoT->Internal path, so it is the one an
   abusing IoT device would have to use. Worth the volume.
3. **`Allow Internal to IoT` (ALLOW ANY/ANY) — I recommend NOT logging it, or logging it
   last.** It is the **most expensive** (312k lines/day, the largest of the four) and the
   **least security-relevant**: it is trusted->untrusted, which is *not* the escalation
   direction. The threat model here (per the CMDB) is a device escaping ONTO the trusted
   VLAN. Logging the outbound trusted->IoT direction does not detect that.

   Total if all three are logged: **~442,000 lines/day** added to the log pipeline.
   Logging only 1+2: **~130,000/day**, i.e. **71% less volume for nearly all of the
   security value.** Given the Vector/Loki pipeline history (memory: the 4-issue cascade,
   and `reference_flux_configmap_shell_scripts` on Loki log-alert quirks), I would not
   add 312k lines/day of low-value ALLOW records without a deliberate retention decision.

**Blocking unknown:** the `Block All IoT->Internal` policy is `predefined: true`. Whether
a predefined policy accepts a `logging` write via the API on 10.6.101 is **untested**. If
it does not, recommendation 1 — the highest-value item — may not be achievable via API at
all and may need the GUI. This should be established before the change is planned.

## E. Ownership boundary that needs Atlas's ruling before Part B

Part B (VLAN-drift detection) is **not** wholly mine:
- extending the unifi-exporter and adding a PrometheusRule = manifests under
  `kubernetes/main/`, owned by **k8s-engineer** (`obs.prometheus` is Heph's CMDB entry).
- it must land on **refs/heads/main** for Flux to reconcile (memory: flux-deploys-from-main).
- the alerting/recording-rule design is arguably **Sibyl's** (observability-engineer).
I can specify and validate the detection logic (it is my domain knowledge: network_id,
DHCP reservations, the dual-PPSK trap), but I should not be the one writing another
engineer's manifests. Suggest: I hand the spec to Heph/Sibyl, and I review it.

Also: `ha.integration.shelly` (Hestia's CMDB entry) still describes the Shellys without
noting the cloud channel is now disabled. Worth a line from Hestia. The optional HA
config-entry-not-loaded alert in the brief is likewise Hestia's, and I recommend handing
it to her rather than taking it.
