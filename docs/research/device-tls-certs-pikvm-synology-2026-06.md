# Device TLS Certs — PiKVM & Synology DSM

## Question
How do we give two standalone appliances (PiKVM at 172.16.3.115, Synology DSM at 172.16.2.246, browser-only) a browser-trusted (non-self-signed) cert, using each platform's best-practice path, given our stack (cert-manager wildcard `*.bluejungle.net` via DNS-01/Cloudflare, Envoy internal gateway at 172.16.2.241, external-dns → UDM)?

## TL;DR
- **Synology DSM → reverse-proxy behind Envoy.** Browser-only access is a perfect fit for a proxy; the wildcard cert never leaves the cluster. One HTTPRoute + a DSM WebSocket-aware setup. *Alternative if direct `:5001` access is required: acme.sh `synology_dsm` deploy hook pushing a per-host cert via the DSM API — fully automatable, no key-on-NAS handling because acme.sh runs off-box.*
- **PiKVM → on-device per-host cert.** A naive reverse proxy **breaks the WebRTC/Direct-H.264 video** (the whole point of a KVM). Put a dedicated `pikvm.bluejungle.net` cert into `/etc/kvmd/nginx/ssl/` and reload `kvmd-nginx`. Automate the push from the cluster on renewal.
- **Security: do NOT copy the `*.bluejungle.net` wildcard private key onto either appliance.** Issue **dedicated per-host certs** (`pikvm.bluejungle.net`, `nas.bluejungle.net`) from cert-manager so an appliance compromise can't MITM the whole domain. Reverse-proxy paths keep the wildcard key in-cluster, which is strictly better.
- Both appliances already resolve via external-dns/UDM, so per-host hostnames are cheap.

## What the world does

### Device 1 — PiKVM (Arch-based, kvmd-nginx serves the UI)

**Option P1 — Replace the on-device cert (official).** PiKVM's nginx reads a fixed path. The shipped `ssl.conf` hard-codes `ssl_certificate /etc/kvmd/nginx/ssl/server.crt;` and `ssl_certificate_key /etc/kvmd/nginx/ssl/server.key;` [src 2]. The root FS is read-only, so the procedure is `rw` → drop the cert/key → fix ownership (`chown :kvmd-nginx /etc/kvmd/nginx/ssl/*`, key `-r--r-----`) → `systemctl restart kvmd-nginx` → `ro` [src 1, src 3]. Optimised for: zero proxy hops, native WebRTC. Sacrifices: a key lands on the device → renewal automation required.

**Option P2 — ACME on the PiKVM itself.** PiKVM ships `kvmd-certbot` precisely because the FS is read-only; cert lives on the PST partition. Workflow: `rw; kvmd-certbot certonly_webroot ...; kvmd-certbot install_nginx <fqdn>; ro` and `systemctl enable --now kvmd-certbot.timer` for renewal. **DNS-01 is supported, including Cloudflare** (`certbot-dns-cloudflare`, creds at `/var/lib/kvmd/pst/data/certbot/runroot/.cloudflare.auth`) [src 4]. Optimised for: self-contained, internal-only works (no inbound :80). Sacrifices: a second ACME client + Cloudflare creds on the device, parallel to cert-manager.

**Option P3 — Reverse proxy in front (BREAKS VIDEO if done naively).** Officially supported since KVMD 4.51 [src 5]. **But:** if you terminate TLS on the proxy and speak HTTP to PiKVM, you "lose the ability to use some features such as Direct H.264 streaming, because browser security policies require HTTPS" [src 5]. Worse, **WebRTC uses a separate UDP/ICE media path that does not ride the HTTP request** — a real user behind Apache reported "MJPEG and all other functionality works except for WebRTC" until they additionally proxied the Janus WebSocket (`wss://.../janus/ws`); even then the UDP media path is NAT/proxy-fragile [src 6]. Optimised for: no device key handling. Sacrifices: the KVM's reason to exist (low-latency H.264 video).

### Device 2 — Synology DSM (browser-only)

**Option S1 — Manual import into DSM cert store.** Control Panel > Security > Certificate > Add > Add a new certificate > Import certificate. DSM wants a **private key + certificate + (optional) intermediate/chain**, "X.509 PEM or DER format … RSA cannot be passphrase protected" [src 7]. Assign to services under **Settings > Configure** (per-service cert dropdown; "System Default applies to connections not on the service list") [src 7]. Optimised for: simple, official. Sacrifices: manual re-import every 90 days unless automated.

**Option S2 — acme.sh `synology_dsm` deploy hook (automatable).** Official acme.sh wiki: since the deployhook was added, "it is no longer required to run acme.sh on your Synology device… acme.sh just needs to be run on something that has access to the DSM's administrative interface" [src 9]. Drives `SYNO.Core.Certificate` via the DSM API: `SYNO_USERNAME`/`SYNO_PASSWORD` (+ `SYNO_OTP_CODE`/`SYNO_DEVICE_ID` for 2FA), `SYNO_SCHEME=https`, `SYNO_PORT=5001`, `--insecure`; `SYNO_CERTIFICATE="<description>"` + `SYNO_CREATE=1` to target/create a specific cert [src 8, src 9]. Optimised for: full automation, **no private key stored on the NAS by us** (acme.sh runs off-box and pushes via API). Sacrifices: a DSM admin credential held by the deployer.

**Option S3 — DSM built-in Let's Encrypt (does NOT fit us).** Official DSM doc: LE issuance "will perform domain validation… make sure your Synology NAS and router have **port 80 open** for domain validation from the Internet" and again "have port 80 open for certificate renewal" [src 7]. Our NAS is internal-only — no inbound :80 from LE. DSM's native LE has **no DNS-01**; wildcards are "only supported for Synology DDNS" [src 7]. So built-in LE can't issue for `nas.bluejungle.net`.

**Option S4 — Reverse proxy behind Envoy (browser-only → viable).** Browser-only DSM proxies cleanly. DSM itself documents reverse-proxy behaviour and that you must **add a WebSocket custom header** for WS to survive ("Click WebSocket from the Create drop-down menu… to allow reverse proxy to support WebSocket") [src 10] — the same requirement applies to any upstream proxy (Envoy) fronting DSM, since the DSM UI uses WebSockets. Optimised for: wildcard key stays in-cluster, zero NAS-side cert work. Sacrifices: an extra hop; must pass WS upgrade + the right Host.

## Patterns that recur
- **Every path needs a per-host FQDN** — we already have `pikvm.bluejungle.net`; add `nas.bluejungle.net` (external-dns/UDM). Essential.
- **On-device cert = renewal automation is mandatory** (90-day LE / our cert-manager renewals). Shared by P1/P2/S1/S2.
- **Reverse-proxy keeps the key in-cluster** — shared by P3/S4; only viable where the app is plain HTTP(S)+WebSocket. **DSM yes, PiKVM no** (video).
- **Optional / axis of choice:** run the ACME client *on* the device (P2) vs *push from cluster* (P1/S2). Pushing from the cluster is better here — one source of truth (cert-manager), no duplicate Cloudflare creds on appliances.

## Recommendation (this homelab)

| Device | Recommended | Effort | Maintenance | What breaks | Security |
|---|---|---|---|---|---|
| **PiKVM** | **P1: per-host cert pushed to `/etc/kvmd/nginx/ssl/` + reload** | Med (one push script) | Auto on renewal | Nothing (native HTTPS preserves WebRTC) | Per-host key only; wildcard stays in cluster |
| PiKVM (alt) | P2 kvmd-certbot DNS-01 | Low-med | Self (timer) | Nothing | Cloudflare creds on device (worse) |
| PiKVM (reject) | P3 reverse proxy | — | — | **WebRTC/Direct-H.264 video** | n/a |
| **Synology** | **S4: reverse-proxy behind Envoy** (browser-only) | Low (1 HTTPRoute) | None on NAS | Nothing if WS upgrade passed | **Wildcard key never leaves cluster** |
| Synology (alt) | S2 acme.sh `synology_dsm` per-host push | Med | Auto (scheduled) | Nothing | Per-host key on NAS + DSM admin cred |
| Synology (reject) | S3 DSM built-in LE | — | — | Can't issue (no inbound :80 / no DNS-01) | n/a |

**Why PiKVM differs from Synology:** the NAS is browser-only HTTP+WebSocket → a proxy is transparent and keeps the key in-cluster. PiKVM's value is low-latency H.264/WebRTC video over a separate media path that does not survive a generic HTTP proxy → keep TLS on the device and just hand it a trusted per-host cert.

### Implementation sketch for our stack

**Issue two dedicated per-host certs from cert-manager** (NOT the wildcard) so a device compromise can't MITM `*.bluejungle.net`:

```yaml
# cert-manager Certificate, network namespace, same Cloudflare DNS-01 issuer as the wildcard
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: pikvm-tls, namespace: network }
spec:
  secretName: pikvm-tls
  dnsNames: ["pikvm.bluejungle.net"]
  issuerRef: { name: <cloudflare-dns01-clusterissuer>, kind: ClusterIssuer }
```

**PiKVM (P1):** a small CronJob/reloader (or trigger on the cert-manager secret) does, over SSH to 172.16.3.115:
`rw` → write `tls.crt`→`/etc/kvmd/nginx/ssl/server.crt`, `tls.key`→`server.key` → `chown :kvmd-nginx /etc/kvmd/nginx/ssl/*` (key `chmod 640`) → `systemctl restart kvmd-nginx` → `ro` [src 1,2,3]. Verify: `curl -v https://pikvm.bluejungle.net` shows the LE chain, not self-signed; then load the UI and confirm the video stream still connects (WebRTC).
*(Simpler alt = P2: install `certbot-dns-cloudflare` on the PiKVM, `kvmd-certbot` DNS-01, enable `kvmd-certbot.timer`.)*

**Synology (S4, recommended):** add `nas.bluejungle.net` A record (external-dns/UDM) → HTTPRoute on `envoy-internal` (172.16.2.241) → backend 172.16.2.246:5001 (HTTPS, skip upstream cert verify — DSM self-signed is fine to the proxy, exactly like the PiKVM nginx case). Ensure the route passes **WebSocket upgrade** (DSM UI needs it) [src 10]. TLS terminated at Envoy with the in-cluster wildcard; the NAS never gets a key from us. Verify: browse `https://nas.bluejungle.net`, log in, confirm the UI is interactive (WS up) and the cert is the LE wildcard.
*(If direct `:5001` is ever required, switch to S2: run acme.sh with `--deploy-hook synology_dsm`, `SYNO_SCHEME=https SYNO_PORT=5001`, pushing the `nas.bluejungle.net` per-host cert via the DSM API on a schedule [src 8,9].)*

## Sources
All fetched live 2026-06-16. Official docs marked **[official]**.
1. **[official]** PiKVM Handbook — Let's Encrypt certificates (read-only FS, `rw`/`ro`, `kvmd-certbot`, Cloudflare DNS-01): https://docs.pikvm.org/letsencrypt/
2. **[official]** PiKVM kvmd source — `configs/nginx/ssl.conf` (cert/key paths): https://github.com/pikvm/kvmd/blob/master/configs/nginx/ssl.conf (raw: raw.githubusercontent.com/pikvm/kvmd/master/configs/nginx/ssl.conf)
3. PiKVM cert ownership / `chown :kvmd-nginx` (via search of pikvm/kvmd config + handbook) — corroborated by [src 1,2]
4. **[official]** PiKVM Handbook — Let's Encrypt DNS-01 providers incl. Cloudflare auth path: https://docs.pikvm.org/letsencrypt/
5. **[official]** PiKVM Handbook — Reverse proxy (KVMD 4.51+, HTTP-only loses Direct H.264, nginx/Caddy snippets, WS headers): https://docs.pikvm.org/reverse_proxy/
6. PiKVM GitHub issue #1081 — "H.264/WebRTC not working behind Apache2 Reverse Proxy" (MJPEG works, WebRTC needs `/janus/ws` proxied): https://github.com/pikvm/pikvm/issues/1081
7. **[official]** Synology DSM 7.3 Knowledge Center — Certificate (Import wizard files/format, Configure tab service assignment, LE needs port 80 inbound, wildcard only via Synology DDNS): https://kb.synology.com/en-us/DSM/help/DSM/AdminCenter/connection_certificate
8. **[official]** acme.sh wiki — deployhooks, `synology_dsm` env vars: https://github.com/acmesh-official/acme.sh/wiki/deployhooks
9. **[official]** acme.sh wiki — Synology NAS Guide (remote deploy off-box, temp/existing admin, `SYNO_SCHEME=https`/`SYNO_PORT=5001`, `--insecure`, `SYNO_CERTIFICATE`/`SYNO_CREATE`): https://github.com/acmesh-official/acme.sh/wiki/Synology-NAS-Guide
10. **[official]** Synology DSM 7 Knowledge Center — Login Portal > Advanced (reverse proxy + WebSocket custom header requirement): https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_login_portal_advanced?version=7

— Athena
