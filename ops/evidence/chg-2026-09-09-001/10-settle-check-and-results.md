# Settle check (T+12 min after last write) and consolidated results

## Settle check — the end state is stable, not momentary
Re-polled UniFi `stat/sta` ~12 min after the last Part B write and re-polled
`Cloud.GetStatus` on all ten.

| IP | network | assoc_time unchanged since T2 | assoc age (min) | rssi | satisfaction | cloud connected |
|---|---|---|---|---|---|---|
| .20 | IOT-VLAN | yes | 1781.9 | 25 | 100 | false |
| .21 | IOT-VLAN | yes | 10.3 | 40 | 95 | false |
| .22 | IOT-VLAN | yes | 11798.1 | 34 | 100 | false |
| .23 | IOT-VLAN | yes | 10.2 | 30 | 95 | false |
| .24 | IOT-VLAN | yes | 9.8 | 31 | 92 | false |
| .25 | IOT-VLAN | yes | 8.9 | 15 | 100 | false |
| .26 | IOT-VLAN | yes | 8.8 | 22 | 100 | false |
| .27 | IOT-VLAN | yes | 8.7 | 23 | 100 | false |
| .28 | IOT-VLAN | yes | 8.6 | 24 | 100 | false |
| .29 | IOT-VLAN | yes | 8.5 | 24 | 86 | false |

**PASS.** Zero further re-associations after the change window. 10/10 stable on
`network_id 6226f5bddd6f9706a46a66cb`. Cloud severed on 10/10 and staying severed —
the devices are not retrying and re-establishing the channel.

### Unplanned bonus: RF improved on the devices that re-associated
The rejoin let several devices re-select a better BSSID:
- `.23` satisfaction **78 -> 95**
- `.21` rssi **20 -> 40** (moved AP 56:e5 -> ac:52)
- `.26` rssi 21 -> 22, `.24` 26 -> 31

So the re-association, while unintended and contrary to Argus's prediction, left the
fleet in a *better* RF state than it started. `.25` at rssi 15 is the weakest and is the
one to watch, since it is now single-path.

## Consolidated test results

| Test | Result |
|---|---|
| T1 config readback (GET-after-SET, field-by-field) | **PASS 10/10**, zero silent drops |
| T2 no re-association | **FAILED THE PREDICTION** — 8/10 re-associated. Security outcome PASS: 10/10 back on IOT-VLAN, 0 on CLIENT-VLAN |
| T3 cloud channel severed (end-to-end transport) | **PASS 10/10** `connected: true -> false`, still false at T+12min |
| T4a HA control plane, all ten | **PASS 10/10** none unavailable, all config entries loaded |
| T4b HA write path (real relay + real load) | **PASS** 8.8 W measured on switch.verlichting_schuur |
| T5 persistence (cfg_rev) | **PASS 10/10** exactly one increment per write, no async revert |
| Settle check T+12min | **PASS** stable |

## Sonos safety
All nine Sonos mains held state `on` continuously through the entire operation. No relay
changed state, no device was rebooted, no Sonos lost power at any point.
