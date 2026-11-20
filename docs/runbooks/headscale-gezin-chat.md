# Runbook: family chat over Headscale (group:gezin)

- Status: **live**, chg-2026-11-20-060 (tsk-2026-11-20-118). Argus review 2026-11-20 (GO with conditions C1-C6).
- Owner: platform (`k8s-engineer`). Operators: Sander or Atlas.
- **No personal names anywhere.** Family accounts are the neutral Headscale users `gezin2`, `gezin3` and `gezin4`
  (user ids 2, 3, 4; user 1 is Sander). Only the owner knows who is who. Never add a display name or email to these
  users, and never paste raw `headscale nodes list` or `preauthkeys list` output into evidence, tickets or the repo.

## What it is

```
family device (Tailscale app, login server https://headscale.bluejungle.net)
  -> tailnet (embedded DERP via headscale, 443 on KPN)
  -> node gezin-router (in-cluster, node id 5, tag:gezinrouter, advertises 172.16.2.253/32 only)
  -> Gateway envoy-gezin 172.16.2.253:443 (serves chat.bluejungle.net and auth.bluejungle.net only)
  -> Open WebUI (OIDC login via Authelia; the local password login is answered 403 on this path)
```

| Layer | Where | What it allows |
|---|---|---|
| ACL | `kubernetes/main/apps/network/headscale/app/config/policy.hujson` | `group:gezin` -> `172.16.2.253/32` `tcp:443`, nothing else |
| Route | headscale node 5 | one approved route, `172.16.2.253/32` (approved by hand, no autoApprovers) |
| Router CNP | `headscale-gezin-router` in `networkpolicy.yaml` | router pod -> envoy-gezin:10443, headscale, kube-dns, API server only |
| Gateway | `kubernetes/main/apps/network/envoy-gateway/gateway/envoy-gezin.yaml` | hostnames chat + auth only; other Host 404, other SNI fails TLS |
| App | `open-webui-gezin` HTTPRoute + `open-webui-gezin-local-auth-403` filter | `/api/v1/auths/{signin,signup,ldap}` -> 403; login only via OIDC |
| DNS | headscale `dns.extra_records` | chat/auth -> 172.16.2.253 inside the tailnet only; LAN and internet unchanged |

The LAN path (envoy-internal, 172.16.2.241, including the break-glass local login) is not touched by any of this.

All commands below run from the Mini (or any machine with the cluster kubeconfig):

```bash
eval "$(mise env -s bash)"
HS() { kubectl -n network exec deploy/headscale -- headscale "$@"; }
# Node ids/users/tags only, never names:
HSN() { HS nodes list -o json | jq -c '.[] | {id, user: .user.id, tags, ip: .ip_addresses[0], online}'; }
```

## Lost or stolen device: cut it off

1. Find the node id with `HSN` (user id 2/3/4 tells you whose; renamed nodes read `gezinN-<type>`).
2. **One command, the device is out at once** (measured: chat lost within 2 s):

   ```bash
   HS nodes delete -i <NODE_ID> --force
   ```

   Read back: `HSN` no longer lists the id.
3. Application layer (Argus C5). A deleted node cannot reach the chat any more, but the browser on that device still
   holds an Open WebUI token (up to 90 days) and possibly an Authelia remember-me cookie (1 month). That matters only
   if the device ever comes back onto home Wi-Fi, but close it anyway:
   - **Open WebUI**: as an admin, Admin Panel -> Users -> that user -> role **pending** (or delete the user if the
     person leaves). A pending user cannot use the chat with any existing token. Set the role back once the user has
     a new device.
   - **Authelia / lldap**: in lldap (`https://lldap.bluejungle.net`, LAN only) either remove the user from group
     `gezin` or reset their password. Authelia re-checks the directory every `refresh_interval` (1 min) and drops
     the session.
   - **Home Wi-Fi**: if the device knew the home Wi-Fi passphrase, consider rotating that PSK (a UniFi change: only
     01:00-06:00 because it drops clients, AGR-082).
4. Log one line on the change log (`./ops/ops change event <chg> executed --actor <you> ...`): node id, user id, time.

If you only want to force a fresh login on a device that is still trusted, use `HS nodes expire -i <NODE_ID>`
instead of delete.

Never delete node 1 (Sander's laptop, `hosts.vdhnblin01` in the policy) without first removing its hosts entry.

## A family member should lose access entirely

- Fast, no Git: delete each of the user's nodes (above), set the Open WebUI user to pending, and expire any open
  pre-auth key of that user: `HS preauthkeys list -o json | jq -c '.[] | {id, user: .user.id, used, expiration}'`,
  then `HS preauthkeys expire -i <KEY_ID> --force`.
- Durable: remove `"gezinN@"` from `group:gezin` in `policy.hujson`, commit, push to main, and read back with
  `HS policy get`.

## Enrol a device (Argus C4: just in time, one device at a time)

Keys are made **only when Sander asks for a named device**, one key per device, never a batch. There is **no key for
user 1 (Sander)** unless Sander names a new device of his own.

1. Create one single-use, non-ephemeral key for that user, valid only as long as the hand-over needs (at most 24 h),
   straight into a 0600 file on the Mini. The key is never printed, never in a handoff, the vault or the repo:

   ```bash
   umask 077; F=~/headscale-gezin-key-$(date -u +%Y%m%dT%H%M%SZ).txt; test ! -e "$F" || exit 1
   HS preauthkeys create -u <USER_ID> -e 24h -o json | python3 -c \
     'import sys,json; k=json.load(sys.stdin); open(sys.argv[1],"w").write(k["key"]+"\n"); print("key id",k["id"])' "$F"
   stat -f '%Sp %z bytes' "$F"     # report mode + size only
   ```

   Tell Sander only the path. He passes the key on himself.
2. On the device: Tailscale app -> custom/alternate login server `https://headscale.bluejungle.net` -> auth key.
   If the app offers only a registration link (iOS/macOS may), the user sends Sander the link; after Sander confirms
   the device, Atlas runs `HS auth register --auth-id <ID_FROM_LINK> --user <USERNAME>`. No key is needed then.
3. **Rename the node at once (Argus C3)**, before any list output is captured. Phones often carry the owner's first
   name as hostname:

   ```bash
   HS nodes rename -i <NEW_NODE_ID> gezinN-<type>     # e.g. gezin3-phone, gezin3-laptop
   ```

4. Check: `HS preauthkeys list -o json | jq -c '.[] | {id, user: .user.id, used}'` shows the key `used: true`, and
   `HSN` shows the expected number of nodes for that user. Expire any leftover key:
   `HS preauthkeys expire -i <KEY_ID> --force`.
5. **Move the key file off the Mini** when done (the Mini shares uid 501 with myPKA, so 0600 is no boundary). No
   inline `rm` (AGR-121): `mv "$F"` to an off-Mini location, or truncate it (`: > "$F"`) and move the empty file to the
   scratch area.
6. Real-device check: on mobile data (Wi-Fi off) open `https://chat.bluejungle.net`, log in via "Gezin" (OIDC).
   The local password form must not work there (403).

Every new node raises the `HeadscaleNodeRegistered` warning (ntfy by day, silent at night). Expected during a logged
enrolment; **any unexpected one is an incident**.

## Router key exposed (Secret `hs-gezin-router-state` or the enrolment key leaked)

The router's node key lets the holder receive tailnet traffic for 172.16.2.253 only. Rotate it:

```bash
HS nodes list-routes                                    # note the router node id (today 5)
HS nodes delete -i <ROUTER_ID> --force
kubectl -n network scale deploy/headscale-gezin-router --replicas=0
# Reset the state Secret to empty (Flux created it with ssa IfNotPresent and never overwrites it):
kubectl -n network patch secret hs-gezin-router-state --type json -p '[{"op":"replace","path":"/data","value":{}}]'
# New single-use 30 min key, in-pod, via a 0600 file, never printed:
umask 077; K=$(mktemp); HS preauthkeys create --tags tag:gezinrouter -e 30m -o json \
  | python3 -c 'import sys,json; open(sys.argv[1],"w").write(json.load(sys.stdin)["key"])' "$K"
kubectl -n network create secret generic hs-gezin-router-authkey --from-file=authkey="$K" \
  --dry-run=client -o yaml | kubectl apply -f -
: > "$K"
kubectl -n network scale deploy/headscale-gezin-router --replicas=1
kubectl -n network rollout status deploy/headscale-gezin-router
HS nodes list-routes                                    # new id, available 172.16.2.253/32
HS nodes approve-routes -i <NEW_ROUTER_ID> -r 172.16.2.253/32
kubectl -n network patch secret hs-gezin-router-authkey --type merge -p '{"data":{"authkey":""}}'
```

Read back: `HS nodes list-routes` shows exactly one node with exactly `172.16.2.253/32` approved, and a family
device (or a test node) gets chat 200.

## Health checks

```bash
HS nodes list-routes                 # exactly: router node, 172.16.2.253/32 available AND approved; nothing else
kubectl -n network get gateway envoy-gezin               # PROGRAMMED True, address 172.16.2.253
kubectl -n network get deploy headscale-gezin-router     # 1/1 ready
kubectl -n network exec deploy/headscale-gezin-router -- tailscale --socket=/tmp/tailscaled.sock debug netmap \
  | jq -c '.PacketFilter[] | {Srcs, Dsts}'   # Srcs only untagged group members, Dsts only 172.16.2.253:443
```

The daily posture scan (Argus C6) checks that `nodes list-routes` is exactly that one route.

If the router is down, the family has no chat from outside, and a device with Tailscale on loses chat at home as
well (the /32 route captures it). Fix: `kubectl -n network rollout restart deploy/headscale-gezin-router`. If the
route shows as not approved: `HS nodes approve-routes -i <ROUTER_NODE_ID> -r 172.16.2.253/32`.

## Testing without a family device

The test node pattern from chg-2026-11-20-060 (`ops/evidence/chg-2026-11-20-060/t-results-*.txt`): a throwaway pod
with userspace tailscaled + SOCKS5, an ephemeral 30 min key for user 1, and a CNP that denies the pod all egress
except headscale and kube-dns. Without that CNP the SOCKS5 server dials non-tailnet addresses directly from the pod
and every negative test falsely "connects". Remove the namespace and `HS nodes delete` the node afterwards.

## Roll back the whole feature

`git revert` the chg-2026-11-20-060 commits on main and let Flux reconcile; then `HS nodes delete` the router node and
the family nodes, and `HS users destroy -i <ID> --force` for users 2-4 if they are to go too. Pre-change Headscale PVC
snapshot: VolumeSnapshot `network/headscale-data-pre-chg-2026-11-20-060`.
