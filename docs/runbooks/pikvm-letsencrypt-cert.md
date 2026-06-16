# Runbook — PiKVM browser-trusted Let's Encrypt cert (on-device kvmd-certbot, Cloudflare DNS-01)

Status: ready to execute (USER-RUN on the device)
Owner: net.dns.pikvm (Iris / udm-engineer) · author: Daedalus
Design basis: `docs/research/device-tls-certs-pikvm-synology-2026-06.md` — **option P2**
Change record for this doc: `chg-2026-06-16-007` (low). The **execution** below is a separate **HIGH-risk, user-approved** change when you run it.

---

## Why this runbook exists (read first)

The PiKVM is a **break-glass tool**: it must work when the cluster is down. We deliberately chose to put a
trusted cert **on the device itself** (its built-in `kvmd-certbot` ACME client) rather than proxy it behind the
cluster's Envoy gateway. Reasons:

- A reverse proxy **breaks the KVM's low-latency Direct-H.264 / WebRTC video** (the whole reason a KVM exists) —
  see research option P3.
- The PiKVM's trusted cert **must not depend on the cluster** — if Flux/Envoy/cert-manager are all down, you
  still need a clean HTTPS path to the KVM to fix things.

So the cert lives on the device and renews from the device. This is intentional.

> **The agent (Atlas / Daedalus) cannot run any of these steps.** The PiKVM LAN (172.16.3.0/x) is outside the
> agent's network sandbox — no SSH reachability. **You run every command below on the PiKVM.** Where a command
> could not be byte-confirmed against live docs it is flagged **[verify on device]**.

---

## What you'll end up with

- A dedicated cert for `pikvm.bluejungle.net` from Let's Encrypt (DNS-01 via Cloudflare), stored on the PiKVM's
  **persistent PST partition** so it survives the read-only root FS.
- nginx (`kvmd-nginx`) serving that cert at `/etc/kvmd/nginx/ssl/server.crt` + `server.key`.
- A systemd timer (`kvmd-certbot.timer`) auto-renewing it.
- A **minimally-scoped** Cloudflare API token living on the device — **separate** from the cluster's cert-manager token.

---

## Prerequisites

1. **SSH access to the PiKVM as root.**
   ```bash
   ssh root@172.16.3.115
   # default PiKVM creds are root / root unless you changed them
   ```

2. **DNS already resolves.** `pikvm.bluejungle.net` → `172.16.3.115` (CMDB `net.dns.pikvm`, a UDM static A record).
   Confirm from your workstation:
   ```bash
   dig +short pikvm.bluejungle.net
   # expect: 172.16.3.115
   ```
   DNS-01 does **not** require this A record to validate (validation is a TXT record Certbot creates), but the cert
   is useless if the name doesn't point at the device.

3. **A NEW, minimally-scoped Cloudflare API token** (created in the next section). **Do not** use the Cloudflare
   Global API Key, and **do not** reuse the cluster's cert-manager token — this token will sit on the PiKVM.

---

## Step 0 — Create the scoped Cloudflare API token (do this in the Cloudflare dashboard)

> SECURITY: This token lives on a break-glass appliance. Scope it to the **bluejungle.net zone only**, **DNS edit
> only**. It is independent from the cluster's cert-manager Cloudflare token — they must be separate so revoking one
> never affects the other.

1. Cloudflare dashboard → **My Profile** → **API Tokens** → **Create Token** → **Create Custom Token**.
2. **Token name:** `pikvm-certbot-dns01` (so it's obvious what it is when you audit tokens later).
3. **Permissions:** one row only:
   - **Zone** · **DNS** · **Edit**
4. **Zone Resources:**
   - **Include** · **Specific zone** · `bluejungle.net`
   (NOT "All zones".)
5. (Optional but recommended) **Client IP Address Filtering** → restrict to your WAN egress IP if it's static.
6. **TTL:** leave default (no expiry) — the renewal timer needs it long-lived.
7. **Continue to summary** → **Create Token** → **copy the token value** (shown once). You'll paste it into the
   auth file in Step 3.

Verify the token works before putting it on the device (run from your workstation):
```bash
curl -s -H "Authorization: Bearer <TOKEN>" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | grep -o '"status":"active"'
# expect: "status":"active"
```

---

## Execution — run ALL of these on the PiKVM over SSH

> **CRITICAL SAFETY NOTE:** PiKVM's root filesystem is **read-only**. You make it writable with `rw` and **must**
> set it back to read-only with `ro` at the end. **Leaving it `rw` risks SD-card corruption and a bricked KVM.**
> The final `ro` step (Step 8) is the most important line in this runbook. If anything goes wrong mid-way, your
> recovery includes running `ro`.

### Step 1 — Make the filesystem writable
```bash
rw
```

### Step 2 — (Only if Step 3's `pacman -S` fails with signature/keyring errors) refresh the pacman keyring
The live PiKVM Let's Encrypt doc does **not** list these, but a PiKVM that hasn't updated in a while often has an
expired Arch Linux ARM keyring, which makes `pacman -S` fail with "signature is unknown trust" / "invalid or
corrupted package". **Only run this if Step 3 fails:**  **[verify on device]**
```bash
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy
```

### Step 3 — Install the Cloudflare DNS plugin
```bash
pacman -S certbot-dns-cloudflare
```
(Accept the install. This pulls `certbot` + the `certbot-dns-cloudflare` plugin.)

### Step 4 — Write the Cloudflare credentials file on the PST partition
The auth file must live on the persistent partition (survives the read-only FS) and be owned by `kvmd-certbot`.

```bash
# create the runroot dir on the PST partition
kvmd-pstrun -- mkdir -p /var/lib/kvmd/pst/data/certbot/runroot

# create/edit the auth file
kvmd-pstrun -- nano /var/lib/kvmd/pst/data/certbot/runroot/.cloudflare.auth
```
Put exactly this single line in the file (paste the token from Step 0), then save & exit nano (Ctrl-O, Enter, Ctrl-X):
```ini
dns_cloudflare_api_token = <PASTE_YOUR_SCOPED_TOKEN_HERE>
```
Then lock it down:
```bash
kvmd-pstrun -- chmod 600 /var/lib/kvmd/pst/data/certbot/runroot/.cloudflare.auth
kvmd-pstrun -- chown kvmd-certbot: /var/lib/kvmd/pst/data/certbot/runroot/.cloudflare.auth
```

### Step 5 — Obtain the certificate (DNS-01 via Cloudflare)
Replace the email with yours.
```bash
kvmd-certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-propagation-seconds 60 \
    --dns-cloudflare-credentials /var/lib/kvmd/pst/data/certbot/runroot/.cloudflare.auth \
    --agree-tos -n --email sheijden@vdh-ict.nl -d pikvm.bluejungle.net
```
Expected: `Successfully received certificate.` and a path under the PST partition.
- If it fails with a Cloudflare auth error → re-check the token scope (Zone:DNS:Edit on bluejungle.net) and the
  auth-file line.
- If it times out waiting for DNS propagation → re-run; bump `--dns-cloudflare-propagation-seconds` to `120`.

### Step 6 — Wire the cert into kvmd-nginx
```bash
kvmd-certbot install_nginx pikvm.bluejungle.net
```
This installs the cert/key into `/etc/kvmd/nginx/ssl/server.crt` + `server.key` and **reloads kvmd-nginx
automatically** (the doc states "running services will be restarted/reloaded automatically"). If the UI doesn't pick
up the new cert, restart explicitly:  **[verify on device — explicit restart is a safety belt, not in the doc's happy path]**
```bash
systemctl restart kvmd-nginx
```

### Step 7 — Enable automatic renewal
```bash
systemctl enable --now kvmd-certbot.timer
```

### Step 8 — RETURN THE FILESYSTEM TO READ-ONLY  ← DO NOT SKIP
```bash
ro
```
Confirm it's read-only:
```bash
mount | grep ' / ' | grep -o 'ro,\|rw,'
# expect: ro,
```

You can now close the SSH session.

---

## Verification — THE user-visible outcome (you must do this; the agent cannot reach the device)

This is the whole point of the change. Do **both** the curl check and the browser check.

### V1 — Cert chain (from your workstation)
```bash
curl -v https://pikvm.bluejungle.net 2>&1 | grep -Ei "issuer|subject"
```
**Pass:** issuer shows **Let's Encrypt** (e.g. `issuer: C=US; O=Let's Encrypt; CN=R...`) and
`subject: CN=pikvm.bluejungle.net`.
**Fail:** issuer/subject still shows the self-signed PiKVM cert (CN=`localhost`/`PiKVM` or a self-signed CA) — the
install didn't take. Re-do Steps 5–6.

### V2 — Browser, no warning AND video still works (the regression check)
1. Open `https://pikvm.bluejungle.net` in a browser.
2. Confirm **(a)** there is **no certificate warning** (padlock is clean).
3. Click into the KVM view and confirm **(b)** the **video stream still connects** — try the **H.264 / WebRTC**
   mode specifically (the streamer mode selector in the PiKVM UI). MJPEG working but H.264/WebRTC failing is the
   exact symptom we were avoiding by NOT proxying; if H.264/WebRTC is broken while the cert is fine, that's a
   **regression to report to Atlas**, not a success.

> If you cannot personally watch the video render, this step is **not** verified — do not mark the change done until
> you (the human) have seen a live frame over H.264/WebRTC on the trusted cert.

---

## Renewal verification

Confirm the timer is active and scheduled:
```bash
systemctl is-active kvmd-certbot.timer     # expect: active
systemctl list-timers kvmd-certbot.timer   # shows NEXT run time
```
Dry-run a renewal (forces a real issuance against LE staging-free path; safe to run once — needs `rw` because
install touches the FS):
```bash
rw
kvmd-certbot renew --force-renewal
ro
```
Then re-run **V1** to confirm the (renewed) cert is still a valid Let's Encrypt cert. Don't force-renew repeatedly —
Let's Encrypt rate-limits issuance per domain.

---

## Rollback — restore the self-signed cert

If the LE cert causes problems (UI won't load, video broke and you need the KVM back fast), revert to PiKVM's
self-signed cert.

1. Stop renewal so it can't re-install the LE cert:
   ```bash
   rw
   systemctl disable --now kvmd-certbot.timer
   ```
2. Regenerate the stock self-signed cert into the nginx ssl paths. PiKVM ships a helper; if present use it,
   otherwise regenerate with openssl:  **[verify on device — confirm the helper name `kvmd-certbot install_self_signed` / equivalent on your build; if absent, use the openssl fallback below]**
   ```bash
   # preferred (if the subcommand exists on your build):
   kvmd-certbot install_self_signed pikvm.bluejungle.net

   # fallback — generate a fresh self-signed pair into the paths nginx reads:
   openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
     -keyout /etc/kvmd/nginx/ssl/server.key \
     -out  /etc/kvmd/nginx/ssl/server.crt \
     -subj "/CN=pikvm.bluejungle.net"
   chown :kvmd-nginx /etc/kvmd/nginx/ssl/server.crt /etc/kvmd/nginx/ssl/server.key
   chmod 640 /etc/kvmd/nginx/ssl/server.key
   ```
3. Restart nginx and return to read-only:
   ```bash
   systemctl restart kvmd-nginx
   ro
   ```
4. (Optional, full cleanup) remove the certbot artefacts on the PST partition and the Cloudflare token:
   ```bash
   rw
   kvmd-pstrun -- rm -f /var/lib/kvmd/pst/data/certbot/runroot/.cloudflare.auth
   # remove the issued cert/account if you want a clean slate:
   kvmd-pstrun -- rm -rf /var/lib/kvmd/pst/data/certbot/runroot/config   # [verify on device — path may differ]
   ro
   ```
   Then **revoke the `pikvm-certbot-dns01` token in the Cloudflare dashboard** so the device no longer holds a live
   credential.

Browser will now show a cert warning again (expected for self-signed) but the KVM is fully functional.

---

## Validation plan (for the change record when this is executed)

| # | Test | Pass criterion | Evidence to capture |
|---|------|----------------|---------------------|
| V1 | `curl -v https://pikvm.bluejungle.net` from workstation | issuer = Let's Encrypt, subject CN = pikvm.bluejungle.net | paste of the grepped issuer/subject lines |
| V2 | Load UI in browser | no cert warning AND H.264/WebRTC video renders a live frame | screenshot of clean padlock + a frame of live video |
| R1 | `systemctl list-timers kvmd-certbot.timer` | timer active, has a NEXT run | paste of the timer line |
| R2 | FS state after Step 8 | `mount` shows `/` mounted `ro` | paste of the `mount` grep |

V2 is the load-bearing test — it proves we kept the device's native TLS path instead of breaking video with a proxy.

---

## References (live-verified 2026-06-16)

- PiKVM Handbook — Let's Encrypt certificates (rw/ro, kvmd-certbot, Cloudflare DNS-01, auth file path, renew/timer):
  https://docs.pikvm.org/letsencrypt/
- certbot-dns-cloudflare — credentials file format (`dns_cloudflare_api_token = ...`), Zone:DNS:Edit scope, chmod 600:
  https://certbot-dns-cloudflare.readthedocs.io/en/stable/
- Research / decision (option P2): `docs/research/device-tls-certs-pikvm-synology-2026-06.md`

Items flagged **[verify on device]** could not be byte-confirmed against the live PiKVM docs and should be confirmed
against your installed kvmd-certbot version at execution time:
- pacman keyring refresh (Step 2) — only if `pacman -S` fails on signatures.
- explicit `systemctl restart kvmd-nginx` (Step 6) — install_nginx is documented to reload automatically; restart is a belt-and-braces fallback.
- self-signed regeneration subcommand name (Rollback) — openssl fallback provided.
- certbot config cleanup path (Rollback).

— Daedalus
