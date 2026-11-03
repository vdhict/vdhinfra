# Headscale stage 2: ACL, public entry on KPN, own DERP, server nodes

- Status: **proposed**, 2026-11-03. Change **chg-2026-11-02-012** (tsk-2026-10-21-006). The owner mandate to build today was relayed through Larry.
- Review: Argus (security-engineer) today. The build starts only after `qa_passed`.
- Owners: platform (`k8s-engineer` cluster, `udm-engineer` forward + DNS) and the observability skill (alert rule). Author: Daedalus. No production writes.
- Anything not measured is marked **UNVERIFIED**, and each has a test in section 8.

## 1. Context (measured 2026-11-03 11:56Z unless noted)

| Fact | How measured |
|---|---|
| Headscale v0.29.7 runs on node02. The LB is `172.16.2.249`, ports `443/TCP, 9090/TCP`. The L2 lease is held by **node01** | `kubectl -n network get svc,pod -o wide`; lease `cilium-l2announce-network-headscale` |
| **Source IP is lost today.** Every request, including vdhnblin01's registration, logs `remote=172.16.2.81` (the node01 IP). The lease node and the pod node differ, so Cilium SNATs. That breaks STUN, which reports the wrong mapped address, and it makes logs and policy blind to the real source | `kubectl logs deploy/headscale` |
| The tailnet has one node: id 1, vdhnblin01, user `sander`, untagged, online. **0 API keys, 0 pre-auth keys** | `headscale nodes list` / `apikeys list -o json` / `preauthkeys list -o json` (counts only) |
| The policy is `acls: []` (deny-all). Upstream docs say that **omitting both `acls` and `grants` means allow-all**, and an empty array means deny | file + headscale.net/stable/ref/policy |
| `derp.server.enabled: false`, `urls:` the Tailscale public derpmap, refreshed every 3h. **`ipv4: 198.51.100.1` / `ipv6: 2001:db8::1` are the upstream example placeholders.** They are inert while DERP is off, but they would be wrong the moment it is enabled | `config.yaml` |
| LAN HTTP surface on :443: `/health` 200, `/version` 200 (version disclosed), `/key` 200, `/apple` `/windows` `/swagger` `/swagger/v1/openapiv2.json` 200, `/api/v1/*` **401**, `/verify` 405, `/ts2021` 500 to a GET, `/metrics` `/debug` 404. On **:9090**, `/metrics` is **200 from the LAN**. 50443 is closed (gRPC is bound to 127.0.0.1) | `curl -w '%{http_code}'` per path; `nc -z` with 443 as control |
| KPN = `wan2` (PPPoE, eth9) at **86.80.222.126**, the same address as on 2026-05-13 and 2026-09-15. It is stable but not proven static (**UNVERIFIED**). Ziggo `wan` is 80.57.149.10. WAN balancing is **per destination**, not per connection | `stat/device` wan2, memory `wan-and-udm-backup`, chg-2026-10-21-006 A6 |
| Port forwards: `LetsEncrypt tcp/80 wan2 -> NAS` **disabled**, `Wireguard 61952 wan` **disabled**, `Plex tcp/32400 all` enabled. **Nothing on 443 or 3478 on any WAN** | GET `rest/portforward` |
| External->Internal is block-all, except the predefined auto-allow `Allow Port Forward Plex`. External->Gateway allows only udp/51820 plus ICMPv6/DHCPv6 | GET `v2 firewall-policies` (183 policies) |
| **172.16.2.249 is still a fixed-IP DHCP reservation** for a Hue bridge. That bridge was last seen 282 days ago and is offline now. It is a latent ARP conflict on the public entry IP | GET `rest/user`, `stat/sta` |
| DNS: the LAN gets `172.16.2.249` from external-dns-unifi (Service annotation). Public DoH (Cloudflare and Google) returns NXDOMAIN. `bluejungle.net` is on Cloudflare NS and has **no DNSSEC** (AD=false) | `dig`, DoH |
| external-dns-cloudflare-external sources `crd` + `gateway-httproute` with `--cloudflare-proxied`. **external-dns-unifi also sources `crd`**, with no label or annotation filter. Upstream `source/crd.go` does **not** honour the controller annotation | helmreleases; GitHub source |
| Mixed TCP+UDP on one Cilium LB is already in production (vector `.235`). The cluster has no CNP in `network`. `csi-ceph-blockpool` VolumeSnapshotClass exists. The headscale PVC has no VolSync | `kubectl get svc/cnp/volumesnapshotclass` |
| Nodes to enroll: **vdhmini01** (agent host, uid 501 shared with myPKA, holds a kubeconfig), **vdhllmsrv01** (the "Studio", which handles client material), **vdhwslin01** (LUKS, on demand) | `~/Code/pka-wires/estate/machines.yaml`, CMDB |

The constraints from `remote-access-wireguard-udp443.md` s1 apply here too: SNAT mode, `eTP: Local` is unsupported with L2 announcements, and DSR is out. WireGuard plan A is folded into Headscale (changes.jsonl 2026-11-02T20:03Z), so **UDP/443 on KPN stays free**.

## 2. Decisions

**D1 Source preservation by co-location.** Pin the pod to **node01** (`nodeSelector kubernetes.io/hostname: vdhclu01node01`), which has no Lab trunk. Add a dedicated `CiliumL2AnnouncementPolicy l2-headscale` (serviceSelector `app.kubernetes.io/name: headscale`, nodeSelector node01). Give the global `l2-policy` a `serviceSelector` that excludes headscale. Once the announcer is also the backend node, no SNAT hop should happen (**UNVERIFIED**, test T3). This is the pattern Argus already accepted for wg443 (I1). The cost is that node01 becomes a single point of failure. Recovery is a two-line Git change to another worker.

**D2 Own DERP only** (`derp.server.enabled: true`, `urls: []`, `auto_update_enabled: false`, `verify_clients: true`). Reasons:
- Every server node is at home. A relay at home costs one LAN hop to the destination. A public relay (e.g. Amsterdam) adds a round trip to a third party.
- Tailscale Inc. stops seeing node keys, client IPs and timing.
- No egress from the pod is needed, so a CNP can deny all egress.
- `verify_clients` keeps the relay closed to anyone outside our tailnet.

The cost: if the pod or KPN is down, no node has a relay. Paths that are already direct survive, and VDHVPN02 stays the emergency route. If E2E from a hostile network fails, the fallback is one line (`urls:` back) under the same change.

**D3 DERP address: `ipv4: ""`, `ipv6: "none"`** (DNS, split horizon). This deviates from the brief, which asked for the KPN IP. With the KPN IP hard-coded, every home server dials its DERP over the **UDM hairpin** (**UNVERIFIED** that it works). It would also break silently on a PPPoE address change. With DNS, the LAN uses `.249` directly and the internet uses the public A record. Upstream says the hard-coded IP helps only "when using an exit node and DNS is not working", and we run no exit nodes. Argus rules on this (Q2). Either way, **the placeholders must go**.

Side effect to know about: home nodes never learn their true public mapping from our STUN, whether through the LAN or a hairpin. They rely on relay or disco. Because the relay is at home, the cost is small.

**D4 Public DNS: one Cloudflare A record `headscale.bluejungle.net -> 86.80.222.126`, DNS-only (not proxied), TTL 300.**
- Proxying breaks `/ts2021` (Noise upgrade), DERP and every UDP flow.
- A `DNSEndpoint` is **not** usable: external-dns-unifi would also consume it and add the public IP to the LAN record (`policy: sync`, no filter, and the crd source ignores `controller:`).
- So the record is written by a one-shot in-cluster Job, `hack/ops/chg-2026-11-02-012-cf-record.sh`. It mounts the existing external-dns Cloudflare secret, so the token never leaves the cluster.
- The record has no external-dns owner TXT, so neither Cloudflare instance touches it.
- The LAN record stays owned by the Service annotation.
- Making this GitOps (a label filter on the unifi instance) is a separate change with all-LAN-records blast radius (Q3).

**D5 Port forwards on `wan2` only:**

| name | proto | dst_port | fwd | fwd_port | src | log |
|---|---|---|---|---|---|---|
| `Headscale` | tcp | 443 | 172.16.2.249 | 443 | any | true |
| `Headscale STUN` | udp | 3478 | 172.16.2.249 | 3478 | any | true |

**D6 Service:**
- `https 443->8443/TCP` stays.
- Add `stun 3478->3478/UDP` (mixed protocol, as vector does).
- **Remove `metrics 9090` from the LB**: a second `ClusterIP` service, `metrics`, plus a ServiceMonitor. The forward would never expose 9090, but today every Internal-zone client and VPN peer can read it.
- `eTP: Cluster` stays.

**D7 Hardening in `config.yaml`:**
- `tuning.register_cache_max_entries: 64`. That caps unauthenticated pending-registration memory at about 4 MiB instead of about 64 MiB against a 256 Mi limit.
- `taildrop.enabled: false`.
- `log.level: info` stays. Registrations are logged at INF.
- `grpc_listen_addr` stays on 127.0.0.1.
- `node.expiry: 0` is unchanged for now (Q7).

There is **no path filtering and no rate limiting**. Headscale terminates its own TLS, and Envoy v1.3 cannot pass the upgrade (stage 1). So `/swagger`, `/version`, `/apple` and `/windows` stay public. Protection rests on these points:
- `/api/v1` needs an API key, and **there are 0 API keys**. V0 re-checks this, and so does a daily check.
- Registration completes only through `headscale auth register` in-pod, or through a tagged single-use key.
- `verify_clients` protects DERP.

**D8 CiliumNetworkPolicy `headscale`** (allow-only, no ranges, per inc-002):
- Ingress tcp 8443 and udp 3478 from `world`, `host` and `remote-node`. LAN clients and kubelet probes keep working even if SNAT happens.
- Ingress tcp 9090 only from `observability` Prometheus pods.
- Egress only to kube-dns 53.
- Its value is to close 9090 and egress, not to tell the internet from the LAN.

## 3. ACL (`config/policy.hujson`, stage 2)

```hujson
// chg-2026-11-02-012 stage 2, Argus-reviewed. Deny by default: only the grants below pass.
// NEVER drop the "grants" key: Headscale treats a policy without acls/grants as ALLOW-ALL.
// No autoApprovers, no routes, no exit nodes, no ssh rules (OpenSSH over the tailnet IP only).
{
  "groups":    { "group:admin": ["sander@"] },
  "tagOwners": {
    "tag:agenthost":   ["group:admin"],  // vdhmini01: shared uid with myPKA, destination only, never a source
    "tag:rekenkracht": ["group:admin"],  // vdhllmsrv01 (Studio), vdhwslin01
    "tag:canary":      ["group:admin"]   // in-cluster test node, mirrors vdhnblin01 (Q4)
  },
  "hosts":     { "vdhnblin01": "100.64.0.1/32" },
  "grants": [
    { "src": ["vdhnblin01", "tag:canary"], "dst": ["tag:agenthost", "tag:rekenkracht"], "ip": ["tcp:22"] }
  ],
  "ssh": []
}
```

- **Only vdhnblin01**, by its tailnet /32, not `sander@`. A future device of the owner gets nothing until a change adds it. WireGuard cryptokey routing binds 100.64.0.1 to node 1's key.
- Server->client is nothing. Server<->server is nothing too: all three are on the same LAN, and the tailnet adds no path between them today.
- The later tags `router` and `werkplek`, the model port and LAN 443 (gated on chg-2026-10-20-007) are out of scope.
- **UNVERIFIED:** whether headscale v0.29.7 accepts a `hosts` alias as a grant `src`. The fallback is the literal `"100.64.0.1/32"`. `headscale policy check` decides in V0.
- Recommended for the owner, one command: `tailscale set --shields-up` on vdhnblin01, as defence in depth.

**Pre-auth keys** (per server node, created only when that host is up and ready to enroll):
- Created in-pod with `headscale preauthkeys create --tags tag:<t> --expiration 30m`. That is single-use by default. **No `--reusable`, no `--user`.** The flag syntax is confirmed with `--help` in V0.
- The output goes into a 0600 file in a 0700 scratch directory, reaches the host over LAN SSH (stdin), and is consumed with `tailscale up --login-server https://headscale.bluejungle.net --auth-key file:<path> --accept-dns=false --accept-routes=false`. The file is then moved out of reach.
- **Never in argv, chat, ntfy, git or evidence.**
- Evidence records the key ID and `used=true` / `expired`, nothing else.
- Every evidence file is grepped for `hskey-` before commit. Headscale's own INF log prints `auth id: hskey-authreq-…` and `registration_key=hskey-reg-…` into Loki, so redact these. The alert must not template the log line.
- macOS daemon: the open-source `tailscaled` runs as a root LaunchDaemon. The GUI app needs a logged-in user. Whether Atlas has sudo on the Mini and the Studio is **UNVERIFIED**.
- vdhwslin01 enrolls only after WoL plus remote unlock (memory `vdhwslin01-unlock`).

## 4. Exposure after stage 2 (what the internet reaches)

`86.80.222.126:443/tcp` reaches headscale: `/key`, `/ts2021`, `/register/<id>`, `/verify`, `/derp` (+`/derp/probe`, `/derp/latency-check`, `/bootstrap-dns`), `/health`, `/version`, `/swagger*`, `/apple`, `/windows`, and `/api/v1` (401 without a key).

`86.80.222.126:3478/udp` reaches STUN. A STUN reply is about the size of the request, so the amplification is roughly 1x.

Nothing else is reachable: 9090 is not forwarded and leaves the LB, 50443 is loopback only, and tcp/80 is disabled. The IP was already public through `cloudnas.vdh-ict.nl`.

## 5. Plan (parallel where independent; one change-log line per action)

| # | Step | Owner | Canary / check (gate) | Automatic rollback |
|---|---|---|---|---|
| S0 | V0 read-only (s8). Then **delete the stale Hue reservation on .249** (JSON saved first) | udm-engineer | GET shows no fixed_ip .249 | re-POST the saved object |
| S1 | VolumeSnapshot `headscale-data-pre-s2` (`csi-ceph-blockpool`) | k8s-engineer | `readyToUse=true` | n/a |
| S2 | **Commit A to main: policy only** | k8s-engineer | pre-merge: `headscale policy check` with the pinned image + guard (s8 G1). Post: pod Ready, vdhnblin01 still online | `git revert A` + Flux |
| S3 | **Commit B to main: cluster exposure prep (LAN-only effect):** DERP on, `urls: []`, ipv4/6, D7, Service D6, pin + L2 policies D1, CNP D8, ServiceMonitor, Loki rule (s7), canary Deployment `tag:canary` (userspace tailscaled, state in a Secret, 0 privileges) | k8s-engineer | T1 + T2 (LAN) | `git revert B` + Flux |
| S4 | Enroll vdhmini01 and vdhllmsrv01 (vdhwslin01 when up) on the LAN | platform | T1 ACL matrix green | `headscale nodes delete -i <id>` + `tailscale logout` |
| S5 | **P0: create both forwards `enabled=false`**, read back. A refusal (restricted port, e.g. 3478 as the controller's own STUN) surfaces here | udm-engineer | GET: 2 forwards, wan2, as D5 | DELETE by `_id` |
| S6 | Enable both forwards | udm-engineer | GET enabled + auto-allow policy for exactly .249/443,3478 + T6 | PUT `enabled=false` + GET, then DELETE |
| S7 | Run the DNS Job (D4) | k8s-engineer | DoH Cloudflare + Google = 86.80.222.126, `proxied=false`; LAN `dig` still .249 | Job `--delete` by record id + DoH NXDOMAIN |
| S8 | E2E outside: Larry (MacBook, not a node) T3; owner (vdhnblin01, no VPN) T4 | Larry, owner | T3 + T4 | as S6 |

The verify script `hack/ops/chg-2026-11-02-012-stage2-verify.sh` runs after S3, S6 and S7, and every 15 min for 24 h (canary). On any failed **negative** test, a stale canary (>30 min), or envoy-internal/HA regression, it acts on its own: **first forwards off (PUT + GET), then `git revert` of the last stage-2 commit**, logs a line, and pushes (silent 23-07).

**Never revert stage-1 commit 590dfc38 as a rollback.** With `prune: true` the PVC goes, and so does the Noise key, which forces every node to re-register. The snapshot from S1 is the restore source: a new PVC from the snapshot, then point `persistence.data.existingClaim` at it.

A ConfigMap change restarts the pod through the reloader (`Recreate`, a few seconds). That is a full reconnect of all clients, so it is not an internet or wifi interruption. A broken policy crash-loops **without Helm remediation**, because Helm never sees a ConfigMap edit. This is why the G1 pre-merge gate is mandatory.

**Atlas reports** one line each: Argus verdict; S2 policy live; S3 DERP live on the LAN (T2); nodes enrolled (count + tags); entry live (S6 GET); DNS live (DoH); first external traffic (a non-RFC1918 `remote=` in the log, first octet only); E2E owner result.

## 6. Risks

- **R1** The pin to node01 is a single point of failure for control and relay. The fix is a Git change to another worker plus the new L2 node. VDHVPN02 covers the gap.
- **R2** The edit of the global `l2-policy` affects every LB IP. Check: lease holders of every other LB are unchanged, as a before/after diff in T2. Rollback: revert.
- **R3** **The Mini can administer headscale regardless of the ACL** (kubeconfig, then `kubectl exec`, then the CLI). myPKA shares uid 501. This is pre-existing (ar-018), but it means the tailnet adds no new boundary against a compromised Mini. `tag:agenthost` is destination-only to limit lateral use *from* its tailnet key (Q6).
- **R4** Unauthenticated, version-disclosing, unrate-limited internet surface on a pre-1.0 server. Mitigations: D7, 0 API keys, Renovate patch-fast (AGR-029), the registration alert.
- **R5** If the KPN IP changes (PPPoE), the A record goes stale. The daily external canary (T5) catches it.
- **R6** Hairpin is untested (H1). It matters only for DoH/DoT clients on the LAN. With D3 it is not on the server nodes' path.
- **R7** Inbound on KPN with **per-destination** WAN balancing. Replies follow conntrack (**UNVERIFIED**, T3 runs 20 sequential connections).

## 7. Detection

- Loki rule **`HeadscaleNodeRegistered`**: `sum(count_over_time({namespace="network", app="headscale"} |= "node registered successfully" [10m])) > 0`, severity `warning`. That reaches ntfy 07-23 and is silent at night, picked up by the morning summary (AGR-074; the route was changed 2026-10-20, re-read in V0 because the ntfy route is not in the repo). The annotation carries **no log text**.
- **`HeadscaleRegisterProbes`**: more than 20 `/register/` or `/machine/register` requests per hour from non-RFC1918 sources goes to the daily digest.
- **`HeadscaleDown`**: no ready replica for 5 m, or the ServiceMonitor `up==0`, severity critical.
- **`HeadscaleCanaryStale`**: canary test result older than 30 min.
- Daily: API-key count = 0 and node list = expected set, diffed into the digest.

## 8. Validation plan (evidence write-once into `ops/evidence/chg-2026-11-02-012/stage2-*`, `date -u` stamped)

- **V0 read-only:**
  - forwards still as s1;
  - `.249` free after S0;
  - `headscale preauthkeys create --help` and `headscale policy check --help` exist in v0.29.7;
  - Loki labels `namespace`/`app` hold for headscale;
  - the Alertmanager ntfy route is read back;
  - 0 API keys.
- **G1 pre-merge guard:**
  - `headscale policy check -f policy.hujson` in the pinned image (local container);
  - a script asserts that `grants` exists and is non-empty, with no `autoApprovers`, no `*` in `dst`, no `autogroup:internet`, no `danger-all`;
  - `just lint` + `just validate`.
- **T1 ACL matrix** (canary in-cluster, plus `nc -z -w3` from the Mini, with a known-open control port per memory):
  - Positive: canary to Mini:22, Studio:22, wslin01:22 (when up) all open.
  - **Negative, each must time out:**
    - canary to Mini 5900/445/9100 and Studio 11434/5900;
    - canary to 100.64.0.1 (any port);
    - Mini to 100.64.0.1:22, to Studio:22, to the canary;
    - Studio to Mini:22.
  - `tailscale ping` is a disco ping and is not ACL-filtered, so it is used only for path checks.
- **T2 LAN, after S3:**
  - `/metrics` on 172.16.2.249:9090 is **closed**;
  - `/health` 200;
  - the canary's `tailscale netcheck` lists only region 999;
  - `tailscale status` shows the canary relay `headscale`;
  - a STUN binding to .249:3478 is answered;
  - the pod is on node01, and lease holder = node01;
  - other LB leases unchanged;
  - envoy-internal (.241) and HA (.237) give 200;
  - vdhnblin01 still online.
- **H1 hairpin:** from the Mini, `curl --resolve headscale.bluejungle.net:443:86.80.222.126 …/health`. Record the result, informational only.
- **T3 outside (Larry, MacBook off the home network, no VPN):**
  - `/health` and `/key` 200 with valid TLS;
  - `/api/v1/node` 401;
  - `nc -z` 86.80.222.126 443 open (control), with 9090, 50443, 80, 8443 and 22 closed;
  - a STUN binding to :3478 returns Larry's public address (first octet only);
  - the headscale log shows the same non-RFC1918 `remote=`, which **proves D1**;
  - 20 sequential `/health` calls all 200 (R7);
  - Ziggo `80.57.149.10:443` closed.
- **T4 owner (vdhnblin01, VDHVPN02 off):**
  - `tailscale netcheck` shows the nearest DERP is "Headscale Embedded DERP";
  - `ssh` to Mini and Studio over the 100.64 address works;
  - negatives: Mini:5900, Studio:11434 time out.
  - One copy-paste script that prints PASS/FAIL lines only.
- **T5 daily external canary** (GitHub-hosted runner): T3's `/health`, STUN and closed-port set. A stale result goes to the digest.
- **T6 no collateral:** Plex forward unchanged, External->Gateway unchanged, UDM health ok, LAN `dig headscale…` = .249.
- **T7 drill:**
  - forward off -> T3 fails, back on;
  - scale to 0 -> `HeadscaleDown` fires (silent at night), back to 1;
  - enroll the canary again with a fresh key -> `HeadscaleNodeRegistered` fires, and its text has no `hskey-`.

## 9. Open questions for Argus

1. **Q1** Own DERP only (D2), or own plus the Tailscale public derpmap as a fallback?
2. **Q2** DERP `ipv4: ""` via DNS (D3), or the KPN IP hard-coded as the brief asked?
3. **Q3** A non-GitOps Cloudflare record via an in-cluster Job (D4) for now, against a filter change on external-dns-unifi?
4. **Q4** Is `tag:canary` mirroring vdhnblin01's grant acceptable, given that its key sits in a cluster Secret?
5. **Q5** Accept the unauthenticated, unrate-limited surface (D7, R4), or require a TLS-passthrough proxy first?
6. **Q6** Should vdhmini01 join the tailnet at all while R3 stands, or should stage 2 enroll the Studio and vdhwslin01 only?
7. **Q7** Keep `node.expiry: 0` for untagged devices, or set 180d now?
8. **Q8** Is deleting the stale `.249` Hue reservation (S0) fine, or should headscale move to `.253`/`.254`?

— Daedalus
