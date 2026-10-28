# AI course guest edition: public, invite-only, isolated (chg-2026-10-28-002)

- Status: **approved design** (Argus `qa_passed` 2026-10-28T15:36:08Z, conditions C1-C11 folded in below). The
  implementation review of 8a758d92 required R1/R2, which this revision fixes.
- Risk **high**: this is the first web page the cluster serves to the internet.
- Request: Larry tsk-2026-10-28-005. The owner's go is AGR-071, relayed. The design choice is Atlas's (AGR-126).
- Owners: platform (`k8s-engineer`) builds it. Mack's team builds the guest image. Argus reviews.
- Anything not proven live or in source is marked **UNVERIFIED** and has a test in section 6.

## 1. Facts (measured 2026-10-28 15:20-15:30Z)

| Fact | Source |
|---|---|
| No public web route: no HTTPRoute is attached to `envoy-external` except `https-redirect`, and no SecurityPolicy exists. The only forward is Plex tcp 32400 to media/plex 172.16.2.236 (F7) | `kubectl get httproute -A`, UniFi `rest/portforward` |
| Authelia (`auth.${SECRET_DOMAIN}`) is on `envoy-internal` only. It authenticates against LLDAP, which holds the family accounts | `security/authelia` |
| The family course `cursus.${SECRET_DOMAIN}` is on `envoy-internal` only, in namespace `family`, behind default-deny | `family/courseware`, `family/network-policies` |
| The external-dns Cloudflare token can read tunnels (200). It cannot read Access apps (403) | CF API |
| One old tunnel, `k8s`, exists from 2024-11-19. It is `down` with 0 connections | CF API `/cfd_tunnel` |
| Vault home-infra is readable and editable by the `mypka-agents` service account | inc-2026-10-25-002 |

## 2. Options

| Option | Verdict |
|---|---|
| **A. Cloudflare Tunnel + Cloudflare Access.** No inbound port, and unauthenticated requests stop at the edge | **Pick** |
| B. Port-forward 443 to its own Envoy gateway + a guest-only Authelia | Reject: it exposes the WAN IP and adds an internet-facing IdP |
| C. Expose the existing Authelia | Reject on security: it puts the family LLDAP login on the internet |
| D. WireGuard (chg-2026-10-19-002) | Reject on usability, and it is not live yet |
| E. Static site on Cloudflare Pages behind the same Access app | It would leave no path into the home network, but the owner chose cluster hosting. It is the fallback if the cluster path has to close |

## 3. Design (option A)

```
guest browser --TLS--> Cloudflare edge: Access app cursus-gast.${SECRET_DOMAIN}
   (Emails include only; one-time PIN + Independent MFA)
   --Access JWT--> tunnel `cursus-gast` (config_src=local, outbound tcp/udp 7844 from the cluster)
   --> cloudflared (ns cursus-gast, checks the JWT: originRequest.access) --> svc courseware-gast:8080 (ClusterIP)
```

1. **Namespace `cursus-gast`:**
   - pod security `restricted` is enforced;
   - both workloads have `automountServiceAccountToken: false`;
   - workloads run non-root, with a read-only root filesystem, all capabilities dropped and seccomp RuntimeDefault.
2. **courseware-gast:**
   - Mack's guest image, pinned by digest, with the signature verified;
   - ClusterIP Service only: no HTTPRoute, no LoadBalancer, no LAN DNS.
3. **cloudflared:**
   - the official `cloudflare/cloudflared` image pinned by digest, running with `--no-autoupdate`;
   - a new tunnel `cursus-gast` created with **`config_src=local`**. Its run token is in `TUNNEL_TOKEN`, and the local
     `--config` holds the ingress rules: the single hostname, plus a catch-all `http_status:404`;
   - `originRequest.access {required: true, teamName, audTag}` sits at the **top level** of the config, so the
     connector rejects any request without a valid Access JWT;
   - a remote configuration would replace all local ingress rules, including that check (cloudflared source,
     `orchestration/orchestrator.go`). So the tunnel stays local-only, and T9 checks that daily.
4. **Access app** (C6):
   - The policy has only an Emails include: no Everyone, email-domain, Bypass or Service Auth rule.
   - The one-time PIN is the only login method.
   - Independent MFA is on at org and app level (changelog 2026-04-15). Free-plan availability is **UNVERIFIED**; T2
     decides.
   - Accepted residual (F8): the first MFA device is enrolled by whoever controls the mailbox.
   - If MFA cannot be enforced, fallback F1 applies: a guest-only Authelia behind Access, file backend, never LLDAP. It
     needs its own Argus review.
5. **Network** (C4, CiliumNetworkPolicy):
   - The namespace denies all ingress and egress by default.
   - `private-deny` adds an explicit `egressDeny` to the API server, host, nodes, RFC1918, CGNAT and link-local.
   - courseware-gast accepts ingress only from cloudflared on 8080, and has no egress.
   - cloudflared's egress is allowed only to these exact names:
     - `region1.v2.argotunnel.com` and `region2.v2.argotunnel.com` on tcp/udp 7844;
     - `<team>.cloudflareaccess.com` on tcp 443.

     The kube-dns rule allows exactly those names plus `_v2-origintunneld._tcp.argotunnel.com` and
     `cfd-features.argotunnel.com`.
   - No `world`, no 0.0.0.0/0, no `api.cloudflare.com`, no `cftunnel.com`. In Cilium, `*.` matches one label only.
   - home-automation, network, database, storage, observability and media have no own policy (F6). The wall is
     cursus-gast's own egress deny, and T4 proves it from both sides.
   - Accepted residual (F9): FQDN rules resolve to shared Cloudflare anycast IPs.
6. **DNS:** the tunnel route creates one proxied CNAME, `cursus-gast` -> `<tunnel-id>.cfargotunnel.com`. T10 diffs the
   zone.
7. **Content gate** (C8, `hack/ops/chg-2026-10-28-002-content-gate.sh`):
   - It runs on the exported filesystem of the exact deployed digest, after the cosign signature has been verified.
   - It checks the family-names and client-names lists (files outside the repo), gitleaks, internal IP and hostname
     patterns, and image/PDF metadata. The image must have no `.git` and no `*.map`.
   - It fails on any binary or compressed file whose text it cannot extract.
   - It prints counts only and writes write-once evidence (digest + counts).

## 4. Inviting a guest

1. The owner adds the guest's email to the Access policy (Emails include) in the Cloudflare dashboard. Guest emails
   never appear in the repo, evidence, Loki or the change log (C11).
2. The owner sends the link himself. The team never contacts the guest.
3. The guest enters her email, receives a one-time PIN from Cloudflare, and enrolls a passkey or authenticator app on
   her first login.
4. To revoke, the owner removes the email from the policy and revokes the guest's sessions in Access.

## 5. Credentials (C1, C2)

- There is **no standing Cloudflare API token**.
- **Setup token, used once:**
  - rights: account Tunnel Edit, Access Apps and Policies Edit, zone DNS Edit;
  - client-IP filtered to the two WAN addresses, TTL 24 h;
  - stored in its own vault `cursus-gast`, never in home-infra;
  - Atlas reads it through a Connect token scoped to that vault. It is never synced into the cluster, and the owner
    revokes it after setup.
- **The cluster's own store:** ClusterSecretStore `onepassword-cursus-gast`. Its namespaceSelector allows
  `cursus-gast` only, and it reads vault `cursus-gast` only. It syncs only the tunnel run token.
  `onepassword-connect` excludes `cursus-gast`.
- **Connect token location:** the owner puts `op-connect-token-cursus-gast`, read-only on vault `cursus-gast`, in
  home-infra (the devtenant pattern). It gets an accepted-risk entry (G5) until a contained store exists.
- **Owner steps in the dashboard:** turn on the one-time PIN login and Independent MFA. A token cannot do either.

## 6. Tests (the gate, AGR-109)

| # | Test | Pass |
|---|---|---|
| T1 | Request from the internet without a session. It is also a scheduled probe that triggers the kill switch on any course HTML | 302 to `*.cloudflareaccess.com` |
| T2 | Log in as a test email that is not on the list; then as an allowed test email | Denied; allowed only after MFA |
| T2+ | One-time PIN without an MFA device | No content |
| T3 | Temporary second hostname with the same `access` block and no Access app, removed afterwards | 403 |
| T4 | Phase A: a probe with cloudflared's labels to family courseware, .237:8123, .241:443, .239, .245, .244, .81-.86, .240:6443, .1, .246, the API server, plus an arbitrary DNS name; region1 as the positive control. Phase B (only valid if A passed in the same run): from a namespace without policies to the courseware-gast pod/Service :8080 and cloudflared :2000, with a positive control in the same pod | Only DNS for the allowed names and region1 succeed; REFUSED for the arbitrary name; reverse blocked |
| T5 | Family `cursus.${SECRET_DOMAIN}` from outside | Not publicly resolvable, unchanged |
| T6 | Content gate (3.7) | 0 hits |
| T7 | Remove the test email and revoke its sessions explicitly | Redirected to login within 60 s |
| T8 | Forged `Cf-Access-Jwt-Assertion` header from the internet | Still 302 |
| T9 | API read of the tunnel. Also runs in the daily posture scan | config_src local, no remote configuration |
| T10 | Diff of the zone records | Only the cursus-gast CNAME was added; no other `*.cfargotunnel.com` CNAME |

**Go-live check:**
- no placeholder is left (`replace-team`, `replace-aud`, `registry.invalid`, the zero digest);
- the old `k8s` tunnel is deleted, or its credentials are proven revoked (C10).

## 7. Rollback (C7, `hack/ops/chg-2026-10-28-002-rollback.sh`)

1. Delete the tunnel's DNS route (Cloudflare API).
2. **Kill:**
   - suspend the Kustomizations and scale cloudflared to 0;
   - require kubectl to succeed and report 0 connector pods;
   - require Cloudflare to report 0 connections for the tunnel.
3. Git revert.

Never disable the Access app while a connector is up.
