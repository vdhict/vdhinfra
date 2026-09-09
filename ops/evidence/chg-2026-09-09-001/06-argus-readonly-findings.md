# Read-only findings requested by Argus (chg-2026-09-09-001)
NO CHANGES MADE to any of the below. Report-only.

## 1. mgmt.x_ssh_enabled — ANSWER: enabled, and it is NOT key-only

Source: GET /proxy/network/api/s/default/rest/setting, section key=mgmt (10.6.101).
Booleans only; all credential material deliberately omitted from this file.

| field | value | meaning |
|---|---|---|
| `x_ssh_enabled` | **true** | device SSH is on |
| `x_ssh_auth_password_enabled` | **true** | PASSWORD auth permitted |
| `x_ssh_keys` | **[] (empty list)** | ZERO public keys installed |
| `x_ssh_bind_wildcard` | false | not bound to all interfaces |
| `debug_tools_enabled` | false | - |
| `auto_upgrade` / `auto_upgrade_hour` | true / 3 | UNCHANGED per Argus, confirms CMDB recurrence driver |

**Finding: Argus asked to confirm SSH is "intentional and key-only". It is NOT key-only —
it is the exact inverse: password auth enabled, zero keys installed. So UniFi device SSH
is reachable with a username+password only.** This is a real posture gap, not a
false positive. Recommend (do NOT execute without user approval, this is a `high`
class change — it is UDM management-plane auth):
  - install an SSH public key and set `x_ssh_auth_password_enabled=false`, or
  - set `x_ssh_enabled=false` if nothing consumes it.
Note nothing in this repo is known to consume UDM device SSH; the agent host has no
UDM local-admin credential at all (see reference_unifi_10_4_57 memory, "Action needed").

## 2. ⚠️ SELF-REPORTED REDACTION MISS (disclosing, per the standing instruction)

`rest/setting` is a **credential-bearing endpoint** and must be treated like
`rest/wlanconf`. My capture-time scrub filter was written for the Shelly schema and
did NOT cover the UniFi mgmt schema. It correctly redacted `x_ssh_password` and `key`
but it MISSED four secret fields which were rendered to the agent transcript:
`x_api_token`, `x_mgmt_key`, `x_ssh_sha512passwd` (a $6$ SHA-512 crypt hash), and
`x_ssh_username`.

Containment: stdout only. **Nothing was written to disk, this file contains none of
those values, and nothing reached git.** Verify with the grep in evidence file 07.

Consequences / recommendations:
  - Treat those four values as exposed-in-transcript and **rotate them**: the UDM
    device SSH username+password, and the site `x_api_token` / `x_mgmt_key`.
  - Add `rest/setting` to the "never capture raw" list alongside `rest/wlanconf`
    in the udmcontrol operating manual, and extend the scrub list with
    `x_api_token, x_mgmt_key, x_ssh_sha512passwd, x_ssh_username, x_ssh_password, x_ssh_keys`.
  - The generic lesson: a redact-by-keyname allowlist is schema-specific. For UniFi,
    prefer requesting only the specific boolean fields rather than fetching the object.

## 3. MQTT broker anonymous-auth posture at 172.16.2.244:1883
See evidence file 08. (Argus could not probe this; macOS Local Network Privacy blocked him.)
