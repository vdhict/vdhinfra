# AI course guest edition: public, invite-only, isolated (chg-2026-10-28-002)

- Status: **proposed**, 2026-10-28. Risk **high**: this is the first web page the cluster serves to the internet.
- Request: Larry tsk-2026-10-28-005. The owner's go is AGR-071, relayed. The design choice is Atlas's (AGR-126).
- Owners: platform (`k8s-engineer`) builds it. Mack's team builds the guest image. Argus reviews this design before any
  build.
- Anything not proven live or in source is marked **UNVERIFIED** and gets a test in section 6.

## 1. Facts (measured 2026-10-28 15:20-15:30Z)

| Fact | Source |
|---|---|
| No HTTPRoute is attached to `envoy-external` except `https-redirect`. No SecurityPolicy exists. Nothing on the cluster is public today | `kubectl get httproute -A`, `kubectl get securitypolicy -A` |
| UDM port forwards: tcp 80 to the NAS (disabled), 61952 (disabled), 32400 Plex (enabled). Nothing on 443 | UniFi `rest/portforward` |
| Authelia (`auth.${SECRET_DOMAIN}`) is on `envoy-internal` only. It authenticates against LLDAP, which holds the family accounts | `security/authelia` |
| The family course `cursus.${SECRET_DOMAIN}` is on `envoy-internal` only, in namespace `family`, behind default-deny | `family/courseware`, `family/network-policies` |
| The external-dns Cloudflare token is active. It can read tunnels (200). It cannot read Access apps (403) | CF API `/user/tokens/verify`, `/cfd_tunnel`, `/access/apps` |
| One old tunnel, `k8s`, exists from 2024-11-19. It is `down` with 0 connections | CF API `/cfd_tunnel` |

## 2. Options

| Option | For | Against | Verdict |
|---|---|---|---|
| **A. Cloudflare Tunnel + Cloudflare Access** | No inbound port at home and the WAN IP stays hidden. Unauthenticated requests stop at Cloudflare's edge and never reach the cluster. Invite = add an email. $0 for up to 50 users | A third party sees the TLS-terminated traffic (it holds only generic course text). Needs a token with Access rights, which only the owner can create | **Pick** |
| B. Port-forward 443 to its own Envoy gateway + a guest-only Authelia (file backend, passkey/TOTP) | No third party | The WAN IP is exposed to the internet on 443, and every scan and exploit attempt reaches our Envoy. The invite flow needs Authelia to email the guest. It is a new internet-facing IdP that we have to patch | Reject |
| C. Expose the existing Authelia | Reuses the existing tool | Puts the family's LLDAP login on the internet | **Reject on security** |
| D. WireGuard (chg-2026-10-19-002) | Already planned | A VPN app for a guest who only wants to read a course. Plan A is not live yet | Reject on usability |

## 3. Design (option A)

```
guest browser --TLS--> Cloudflare edge: Access app cursus-gast.${SECRET_DOMAIN}
   (allow: invited emails only; login = one-time PIN by email + MFA)
   --Access JWT--> tunnel `cursus-gast` (outbound QUIC/HTTP2 from the cluster, tcp/udp 7844)
   --> cloudflared pod (ns cursus-gast) --checks the Access JWT (aud tag)--> svc courseware-gast:8080
```

1. **Namespace `cursus-gast`**, with its own Flux Kustomization and nothing else in it. It has no ExternalSecret except
   the tunnel token, and no ServiceAccount token mount.
2. **Workload:**
   - `courseware-gast` runs Mack's guest image, a vendor-built image pinned by digest. It is static and read-only.
   - It runs non-root with a read-only root filesystem, all capabilities dropped, and seccomp RuntimeDefault.
3. **Connector:**
   - `cloudflared`, the official `cloudflare/cloudflared` image pinned by digest. It runs as 2 replicas with
     `--no-autoupdate`.
   - The tunnel is new and dedicated, named `cursus-gast`. The old `k8s` tunnel is not reused.
   - Config file, not dashboard config. One ingress rule:
     - `cursus-gast.${SECRET_DOMAIN}` -> `http://courseware-gast:8080`;
     - catch-all `http_status:404`;
     - `originRequest.access: {required: true, teamName, audTag}`, so the connector itself rejects any request without
       a valid Access JWT. Even a misconfigured Cloudflare hostname cannot reach the origin unauthenticated.
4. **Access app** on `cursus-gast.${SECRET_DOMAIN}`:
   - Policy **Allow** with the include list = the invited emails only, and no "everyone" rule.
   - Session duration 24 h.
   - Login method: one-time PIN to the invited email, plus MFA enforced by Access (passkey / security key / TOTP).
     **UNVERIFIED** on the free plan; tested by T2. If Access cannot enforce MFA itself, fallback F1 applies.
5. **Network** (CiliumNetworkPolicy, default-deny ingress and egress in the namespace):
   - `courseware-gast`: ingress only from `cloudflared` pods on 8080. Egress none.
   - `cloudflared`: ingress none. Egress only kube-dns:53, plus world `tcp/udp 7844` and `tcp 443` to the Cloudflare
     edge, by FQDN `*.argotunnel.com` and `*.cftunnel.com`, plus `api.cloudflare.com` and the team domain
     (`*.cloudflareaccess.com`, for the JWT keys).
   - No cluster CIDR, no node CIDR, no 172.16.0.0/12, no 10.0.0.0/8, no 192.168.0.0/16 anywhere in egress.
   - The `family` namespace and every other namespace get no allow rule from `cursus-gast`. Their own default-deny
     already blocks it; T4 proves it from both sides.
6. **DNS:** the tunnel route creates a proxied CNAME `cursus-gast` -> `<tunnel-id>.cfargotunnel.com` in Cloudflare.
   This is not on the UDM, and there is no LAN record.
7. **Content gate:** before the first deploy and on every image bump, the built site is scanned for the family names
   list used for pre-push checks, plus house details (addresses, network names, internal hostnames). Zero hits or no
   deploy. The scan prints counts only.

**F1 (only if T2 fails):** Access keeps the email allowlist and the PIN as the edge gate. Behind it, a guest-only Authelia
in `cursus-gast` adds a second factor, with a file backend, `two_factor`, and WebAuthn + TOTP, enforced by an Envoy
SecurityPolicy on a dedicated single-hostname gateway (the envoy-forge pattern). It never uses LLDAP. Argus re-reviews
F1 before it is built.

## 4. Inviting a guest

1. Sander adds the guest's email to the Access policy, in the Cloudflare dashboard or by asking Atlas via Larry. The
   email lives only in Cloudflare (and in 1Password, if Sander wants), never in this repo or in evidence.
2. Sander sends the guest the link `https://cursus-gast.${SECRET_DOMAIN}` himself.
3. The guest opens the link, enters her email, gets a one-time PIN mail from Cloudflare, and on her first login
   registers a passkey or an authenticator app.
4. To revoke: remove the email from the policy and revoke the sessions in Access. The guest is out within seconds.

## 5. What the owner does once (money, accounts)

- **Cloudflare Zero Trust:** activate the Free plan if the account has no Zero Trust org yet. Cloudflare may ask for a
  payment method even at $0; that is the owner's call.
- **API token:** create one with account-level `Cloudflare Tunnel: Edit` and `Access: Apps and Policies: Edit`, scoped to
  this account only, and with zone `DNS: Edit` on this zone. Put it in a new 1Password item
  (`cloudflare-cursus-gast`). Atlas reads it only via op/ESO.

## 6. Tests (the gate, AGR-109)

| # | Test | Pass |
|---|---|---|
| T1 | `curl` from the internet (a cloud runner, or a phone off wifi) without a session | 302 to `*.cloudflareaccess.com`, never course HTML |
| T2 | Log in as a test email that is not on the list; then as an allowed test email | Denied; allowed only after MFA. If Access cannot force MFA: F1 |
| T3 | From inside the cluster, request cloudflared's origin (or courseware-gast) without the Access JWT | 403 from cloudflared; courseware-gast is unreachable from any other pod |
| T4 | Probe pod in `cursus-gast`: TCP to family/courseware, HA 172.16.2.237:8123, envoy-internal .241:443, kube-apiserver, 10.43.0.10:53 (DNS allowed), 1.1.1.1:443 | Only DNS and the Cloudflare edge succeed; Hubble shows the drops |
| T5 | `cursus.${SECRET_DOMAIN}` (family) from outside, and DNS for it | Not resolvable publicly, no change |
| T6 | Content gate (section 3.7) on the image | 0 hits |
| T7 | Revoke: remove the test email | Next request is redirected to the login page within 60 s |

Rollback: suspend the `cursus-gast` Kustomization, which stops cloudflared so the tunnel goes down and nothing is
served. Disable the Access app and delete the tunnel route. That is a git revert plus two Cloudflare API calls, scripted
in `hack/ops/chg-2026-10-28-002-*.sh`.
