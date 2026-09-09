# Rotate the UniFi API key

**Why:** `inc-2026-09-09-001` — an incomplete redaction filter rendered `x_api_token` and
`x_mgmt_key` to an agent transcript on 2026-09-09. Stdout only; nothing reached disk or git
(verified blob-level, 0 hits). Rotation is precautionary, not incident response.

**Written 2026-09-09.** Verify the consumer list still holds before executing.

## There is exactly ONE key

Confirmed by md5 comparison on 2026-09-09 — the local file, `cluster-health-secret` and
`external-dns-unifi-secret` all carry the **same value** (`3c804a6d…`). So one rotation
covers everything, and everything breaks together if it is done wrong.

## Blast radius — read this before starting

| Consumer | Namespace | Breaks if stale |
|---|---|---|
| **`external-dns-unifi`** | `network` | ⚠️ **LAN DNS for `*.bluejungle.net` stops updating.** This replaced k8s-gateway; it writes per-host A records to the UDM. Highest impact. |
| `unifi-exporter` | `observability` | WAN bandwidth + gateway uptime metrics stop; kitchen "Netwerk" subview goes stale |
| `cluster-health` cronjobs | `observability` | Daily 06:00 report loses its UniFi section |
| `config/unifi-api-key` | Mac Mini (local) | The `udmcontrol` skill and both network agents lose controller access |

Existing DNS records keep resolving — external-dns only stops *updating* them. So this is
degradation, not an outage, but do not leave it half-done.

## Procedure

1. **Mint the new key first, do not revoke the old one yet.**
   UniFi OS → Settings → Admins & Users → your admin → Control Plane API Key → Create New.
   Copy it once; it is not shown again.

2. **Update both 1Password items** (they are separate items with the same value):
   - item `cluster-health` → property `UNIFI_API_KEY`
   - item `unifi` → property `UNIFI_API_KEY`

3. **Update the local file** on the Mac Mini:
   ```bash
   printf '%s' '<NEW_KEY>' > ~/Code/homelab-migration/config/unifi-api-key
   ```
   Use `printf`, not `echo` — a trailing newline is tolerated today but do not rely on it.

4. **Force the cluster to pick it up** (ESO refreshes hourly otherwise):
   ```bash
   kubectl -n observability annotate externalsecret cluster-health \
     force-sync=$(date +%s) --overwrite
   kubectl -n network annotate externalsecret external-dns-unifi \
     force-sync=$(date +%s) --overwrite
   ```

5. **Restart the consumers** — they read the env var at start:
   ```bash
   kubectl -n network rollout restart deploy/external-dns-unifi
   kubectl -n observability rollout restart deploy/unifi-exporter
   ```

6. **Verify BEFORE revoking the old key:**
   ```bash
   # local
   curl -s -k -H "X-API-KEY: $(cat ~/Code/homelab-migration/config/unifi-api-key)" \
     https://172.16.2.1/proxy/network/api/s/default/stat/health | head -c 200
   # cluster
   kubectl -n network logs deploy/external-dns-unifi --tail=20   # no 401s
   kubectl -n observability logs deploy/unifi-exporter --tail=20
   ```
   Then confirm an actual DNS write still works — create or touch an HTTPRoute host and
   check the record appears on the UDM. **external-dns failing silently is the trap here.**

7. **Only now revoke the old key** in the UniFi GUI.

## Rollback

Until step 7 both keys are valid, so rollback is: put the old value back in the two 1Password
items and the local file, re-run steps 4–5. After step 7 the old key is gone and the only way
forward is to mint another.

## Note

`x_ssh_sha512passwd` and `x_ssh_username` were deliberately **not** rotated (user decision,
2026-09-09). Related open finding: UDM SSH is password-auth with **zero** keys configured
(`x_ssh_enabled=true`, `x_ssh_auth_password_enabled=true`, `x_ssh_keys=[]`) — recorded, not
actioned, at the user's instruction.
