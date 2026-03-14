---
description: Network architecture covering Cilium CNI, Envoy Gateway routing, DNS resolution, and traffic flows
tags: ["Cilium", "EnvoyGateway", "GatewayAPI", "DNS", "Cloudflare", "LoadBalancer"]
audience: ["LLMs", "Humans"]
categories: ["Architecture[100%]", "Networking[100%]"]
---

# Networking Architecture

## Network Overview

Single Kubernetes cluster on bare metal with Cilium eBPF networking, Envoy Gateway for traffic routing, and Cloudflare for external access.

---

## Capsule: CiliumNetworking

**Invariant**
Cilium provides eBPF-based networking with native routing, replaces kube-proxy entirely.

**Example**
Service with LoadBalancer type gets IP from Cilium L2 pool in 172.16.2.x range.

**Depth**

- Mode: Native routing with full kube-proxy replacement (eBPF)
- LoadBalancer: L2 announcements for LoadBalancer IPs
- IPAM: Kubernetes mode
- Features: BBR bandwidth manager, socket LB
- NotThis: No BGP - uses L2 mode for LoadBalancer IP advertisement
- SeeAlso: `CiliumLoadBalancer`

---

## IP Address Map

### LoadBalancer IPs (Cilium L2)

LoadBalancer IPs are allocated from the 172.16.2.x range via Cilium L2 announcements.

| IP           | Service          | Purpose                                   |
| ------------ | ---------------- | ----------------------------------------- |
| 172.16.2.x   | envoy-internal   | Internal/LAN traffic gateway              |
| 172.16.2.x   | envoy-external   | External traffic gateway (via Cloudflare) |

### Key Addresses

| Address       | Purpose             |
| ------------- | ------------------- |
| 172.16.2.246  | Synology NAS (NFS)  |

---

## Capsule: CiliumLoadBalancer

**Invariant**
Cilium L2 announcements advertise LoadBalancer IPs on the local network; services get IPs from the 172.16.2.x range.

**Example**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: envoy-external
  annotations:
    lbipam.cilium.io/ips: "172.16.2.x"
spec:
  type: LoadBalancer
```

**Depth**

- Mode: L2 announcements (ARP-based)
- Range: 172.16.2.x subnet
- Allocation: Services annotated with `lbipam.cilium.io/ips` get specific IP
- NotThis: No BGP peering; L2 only
- SeeAlso: `CiliumNetworking`, `EnvoyGatewayPattern`

---

## Envoy Gateway Routing

### Capsule: EnvoyGatewayPattern

**Invariant**
Apps route through Envoy Gateway using Gateway API HTTPRoute; external gateway for public traffic, internal gateway for LAN-only traffic.

**Example**

```yaml
route:
  internal-app:
    hostnames: ["home.${SECRET_DOMAIN}"]
    parentRefs:
      - name: envoy-internal
        namespace: network
    rules:
      - backendRefs:
          - name: home-assistant
            port: 8123
```

**Depth**

- Distinction: envoy-internal (LAN) vs envoy-external (internet via Cloudflare)
- Trade-off: Explicit gateway selection vs implicit routing
- NotThis: Old Kubernetes Ingress resources (Gateway API is the standard)
- Pattern: Apps use `route:` section in HelmRelease with app-template chart
- SeeAlso: `HTTPRouteConfiguration`, `ExternalDNSIntegration`

---

### Gateway Configuration

Both gateways live in the `network` namespace:

| Gateway  | Name             | Purpose                                   |
| -------- | ---------------- | ----------------------------------------- |
| Internal | `envoy-internal` | Private LAN access                        |
| External | `envoy-external` | Public internet via Cloudflare tunnel     |

**Key Features**:

- Both gateways support HTTPS with automatic HTTP redirect
- TLS termination at gateway with wildcard certificates
- Cross-namespace routing (`from: All`) allows any namespace to route through gateways
- Cilium LB-IPAM assigns specific IPs via annotation

---

### Capsule: HTTPRouteConfiguration

**Invariant**
HTTPRoute defines hostname, parent gateway, and backend service; external-dns watches HTTPRoutes to create DNS records.

**Example**
Internal-only app:

```yaml
route:
  main:
    parentRefs:
      - name: envoy-internal
        namespace: network
        sectionName: https
    hostnames:
      - "grafana.${SECRET_DOMAIN}"
```

**Depth**

- Components: hostnames (DNS names), parentRefs (which gateway), backendRefs (target service)
- Pattern: Most apps use app-template chart's `route:` helper which generates HTTPRoute
- SeeAlso: `EnvoyGatewayPattern`, `ExternalDNSIntegration`

---

## DNS Architecture

### Capsule: ExternalDNSIntegration

**Invariant**
external-dns watches HTTPRoutes and creates Cloudflare DNS records automatically.

**Example**
HTTPRoute with hostname `app.${SECRET_DOMAIN}` -> external-dns creates CNAME in Cloudflare -> traffic routes to gateway.

**Depth**

- Provider: Cloudflare DNS with API token from ExternalSecret
- Proxied: Records created with Cloudflare proxy enabled (orange cloud) for external
- SeeAlso: `CloudflareTunnel`, `DNSResolution`

---

### Capsule: K8sGatewayDNS

**Invariant**
k8s-gateway provides internal DNS resolution for cluster services, returning LoadBalancer IPs for internal hostnames.

**Example**
LAN client queries `grafana.${SECRET_DOMAIN}` -> k8s-gateway returns envoy-internal LoadBalancer IP -> client connects directly.

**Depth**

- Distinction: k8s-gateway handles internal DNS; external-dns handles Cloudflare/public DNS
- Use case: LAN clients resolving `*.${SECRET_DOMAIN}` to internal gateway IPs
- SeeAlso: `ExternalDNSIntegration`, `TrafficFlowInternal`

---

### Capsule: DNSResolution

**Invariant**
CoreDNS handles cluster-internal DNS; k8s-gateway handles `${SECRET_DOMAIN}` resolution; external-dns manages Cloudflare.

**Example**
Pod queries `grafana.${SECRET_DOMAIN}` -> CoreDNS -> upstream resolver -> returns appropriate IP.

**Depth**

- Cluster DNS: CoreDNS for `cluster.local` zone
- Internal domain: k8s-gateway for `${SECRET_DOMAIN}` from LAN
- External domain: external-dns creates Cloudflare records
- SeeAlso: `ExternalDNSIntegration`, `K8sGatewayDNS`

---

## Cloudflare Integration

### Capsule: CloudflareTunnel

**Invariant**
cloudflared tunnel connects cluster to Cloudflare edge; external traffic routes through tunnel to envoy-external gateway.

**Example**
Internet client -> Cloudflare edge -> QUIC tunnel -> cloudflared pod -> envoy-external:443 -> backend service.

**Depth**

- Protocol: QUIC transport
- Target: Routes wildcard traffic to envoy-external gateway service
- Replicas: Multiple pods for high availability
- SeeAlso: `ExternalDNSIntegration`, `TrafficFlowExternal`

---

## TLS and Certificate Management

### Capsule: CertManagerIntegration

**Invariant**
cert-manager issues wildcard certificates from Let's Encrypt via Cloudflare DNS-01 challenge.

**Example**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
spec:
  secretName: wildcard-tls
  dnsNames:
    - "${SECRET_DOMAIN}"
    - "*.${SECRET_DOMAIN}"
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

**Depth**

- Issuer: Let's Encrypt production (ClusterIssuer)
- Challenge: DNS-01 via Cloudflare API (supports wildcard certificates)
- Secret: Certificate stored in Secret, referenced by Gateway listeners
- Renewal: Automatic renewal before expiration
- SeeAlso: `EnvoyGatewayPattern`, `TLSTermination`

---

### Capsule: TLSTermination

**Invariant**
TLS terminates at Envoy Gateway; backend communication uses HTTP within cluster.

**Example**
Gateway listens on HTTPS:443 with wildcard cert -> terminates TLS -> forwards HTTP to backend service.

**Depth**

- Mode: Terminate (not Passthrough) - gateway decrypts traffic
- Backend: HTTPRoute backendRefs use HTTP to cluster services
- Certificates: Wildcard cert covers all subdomains
- SeeAlso: `CertManagerIntegration`, `EnvoyGatewayPattern`

---

## Authentication

### Capsule: AutheliaSSO

**Invariant**
Authelia provides SSO/OIDC authentication backed by LLDAP as the user directory.

**Example**
Apps requiring auth redirect to Authelia at `id.${SECRET_DOMAIN}` -> Authelia authenticates against LLDAP -> returns session/OIDC token.

**Depth**

- Distinction: Authelia handles authentication/authorization; LLDAP stores users/groups
- Integration: Apps integrate via OIDC or forward-auth middleware
- SeeAlso: `EnvoyGatewayRouting`

---

## Traffic Flows

### Capsule: TrafficFlowExternal

**Invariant**
External internet traffic routes via Cloudflare edge -> tunnel -> envoy-external -> HTTPRoute -> service.

**Example**
User requests `app.${SECRET_DOMAIN}`:

1. DNS resolves to Cloudflare edge IP (proxied)
2. Cloudflare terminates TLS, applies WAF
3. Traffic tunnels via QUIC to cloudflared pod
4. cloudflared forwards to envoy-external:443
5. Envoy terminates TLS, routes via HTTPRoute
6. Backend service receives HTTP request

**Depth**

- Double TLS: Cloudflare terminates, then Envoy terminates (end-to-end encryption)
- Protection: Cloudflare WAF, DDoS protection before reaching cluster
- SeeAlso: `CloudflareTunnel`, `EnvoyGatewayPattern`

---

### Capsule: TrafficFlowInternal

**Invariant**
Internal LAN traffic routes directly to envoy-internal gateway; no tunnel traversal.

**Example**
LAN client requests `grafana.${SECRET_DOMAIN}`:

1. DNS resolves via k8s-gateway to envoy-internal LoadBalancer IP
2. Client connects directly to gateway HTTPS:443
3. Envoy terminates TLS, routes via HTTPRoute
4. Backend service receives HTTP request

**Depth**

- Direct: No Cloudflare, no tunnel, direct HTTPS to gateway
- Performance: Lower latency than external path
- Access: Requires LAN access to reach LoadBalancer IP
- DNS: k8s-gateway resolves `${SECRET_DOMAIN}` hostnames to internal IPs
- SeeAlso: `EnvoyGatewayPattern`, `K8sGatewayDNS`

---

## App Exposure Patterns

### Pattern 1: External (Internet Access via Cloudflare)

```yaml
route:
  app:
    parentRefs:
      - name: envoy-external
        namespace: network
        sectionName: https
```

Access: Internet via Cloudflare -> tunnel -> envoy-external

### Pattern 2: Internal-Only (LAN Access)

```yaml
route:
  app:
    parentRefs:
      - name: envoy-internal
        namespace: network
        sectionName: https
```

Access: LAN direct to envoy-internal. Not reachable from internet.

---

## Service Mesh

### Capsule: NoServiceMesh

**Invariant**
Cluster does not use a service mesh; Envoy Gateway provides edge routing only, not sidecar proxies.

**Example**
Pod-to-pod communication uses Cilium CNI directly; no mTLS sidecars or service mesh overhead.

**Depth**

- Trade-off: Simpler architecture vs service mesh features
- Routing: Gateway API for north-south traffic; Cilium for east-west (pod-to-pod)
- NotThis: Envoy Gateway is not a service mesh

---

## Troubleshooting

### Check Gateway Status

```bash
kubectl get gateways -n network
kubectl get httproutes -A
```

### Check DNS Resolution

```bash
# External perspective
dig app.${SECRET_DOMAIN} @1.1.1.1

# From within cluster
kubectl run -it --rm debug --image=alpine -- nslookup app.${SECRET_DOMAIN}
```

### Check External-DNS

```bash
kubectl logs -n network -l app.kubernetes.io/name=external-dns
```

### Check Cilium LB

```bash
kubectl get ciliumloadbalancerippool
kubectl get services -A -o wide | grep LoadBalancer
```

### Check Cloudflare Tunnel

```bash
kubectl logs -n network -l app.kubernetes.io/name=cloudflared
kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
```

---

**See Also**:

- `ARCHITECTURE.md` - System architecture overview
- `CONVENTIONS.md` - Gateway naming conventions
- `WORKFLOWS.md` - Troubleshooting workflows
