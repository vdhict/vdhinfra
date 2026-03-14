---
description: Single-cluster GitOps architecture covering Flux reconciliation, routing patterns, storage, and operational constraints
tags: ["GitOps", "FluxReconciliation", "EnvoyGateway", "ExternalSecrets", "RookCeph"]
audience: ["LLMs", "Humans"]
categories: ["Architecture[100%]", "Reference[90%]"]
---

# Homelab Architecture

## Core Pattern

### Capsule: GitOpsReconciliation

**Invariant**
Cluster state converges to match Git; Flux reverts manual changes on next sync.

**Example**
Push HelmRelease to `kubernetes/main/apps/media/immich/app/helmrelease.yaml`; Flux detects within 1 hour; cluster deploys. `kubectl edit` gets overwritten on reconciliation.

**Depth**

- Distinction: GitOps is declarative (desired state in Git); `kubectl` is imperative
- Trade-off: Consistency and auditability vs immediate manual changes
- NotThis: `kubectl apply` bypasses GitOps and creates drift
- Timing: Flux reconciles every 1 hour or on Git push webhook
- SeeAlso: `FluxBootstrap`, `ExternalSecretSync`

---

### Capsule: ExternalSecretSync

**Invariant**
ExternalSecrets pull from 1Password; Kubernetes secrets populate before pods can start.

**Example**
HelmRelease references `app-secret`; ExternalSecret pulls from 1Password item; pod receives value at runtime.

**Depth**

- Distinction: 1Password is source of truth; ExternalSecrets sync values to cluster
- Trade-off: More indirection, but repo stays public safely and secrets centralized
- NotThis: Hardcoding secrets in manifests defeats the pattern
- Store: ClusterSecretStore named `onepassword-connect`
- Refresh: ExternalSecrets refresh every 12 hours by default
- SeeAlso: `SOPSEncryption`, `SecretManagement`

---

### Capsule: SOPSEncryption

**Invariant**
SOPS/Age encrypts secrets committed to Git; files must end in `.sops.yaml`.

**Example**
`kubernetes/main/bootstrap/secrets.sops.yaml` contains Age-encrypted data. SOPS decrypts at apply time using the Age key.

**Depth**

- Distinction: SOPS encrypts files in Git; ExternalSecrets pulls from 1Password at runtime
- Both patterns coexist: SOPS for bootstrap/Talos secrets, ExternalSecrets for app secrets
- Config: `.sops.yaml` at repo root defines encryption rules and Age public key
- NotThis: Committing plaintext secrets (pre-commit hooks should catch this)
- SeeAlso: `ExternalSecretSync`

---

## Routing Patterns

### Capsule: EnvoyGatewayRouting

**Invariant**
External/internal traffic routes via Envoy Gateway using Gateway API `HTTPRoute`.

**Example**

```yaml
route:
  internal-app:
    hostnames:
      - home.${SECRET_DOMAIN}
    parentRefs:
      - name: envoy-internal
        namespace: network
```

**Depth**

- Distinction: `envoy-external` for public internet; `envoy-internal` for private LAN
- Gateway names: `envoy-external`, `envoy-internal` (both in `network` namespace)
- Trade-off: More explicit than Ingress but requires Gateway API infrastructure
- NotThis: Old-style Kubernetes Ingress resources (Gateway API is the standard)
- SeeAlso: `ExternalDNS`, `CloudflareTunnel`

---

### Capsule: ExternalDNS

**Invariant**
external-dns watches HTTPRoutes and creates Cloudflare DNS records automatically.

**Example**
HTTPRoute with hostname `app.${SECRET_DOMAIN}` -> external-dns creates A/CNAME record pointing to gateway -> traffic flows.

**Depth**

- Distinction: DNS records managed declaratively from cluster, not manually in Cloudflare
- Trade-off: Automation vs manual control
- Provider: Cloudflare (configured in `kubernetes/main/apps/network/external-dns/`)
- SeeAlso: `EnvoyGatewayRouting`

---

## Application Patterns

### Capsule: AppTemplateChart

**Invariant**
Apps use `bjw-s/app-template` chart; vendor charts are exceptions, not defaults.

**Example**

```yaml
chart:
  spec:
    chart: app-template
    version: 3.x.x
    sourceRef:
      kind: HelmRepository
      name: bjw-s
      namespace: flux-system
```

**Depth**

- Distinction: app-template provides consistent structure; vendor charts vary wildly
- Trade-off: Learning curve but consistent patterns across all apps
- NotThis: Using random Helm charts without checking if app-template works
- Exception: Infrastructure (cilium, cert-manager, rook-ceph) uses vendor charts
- SeeAlso: `InstallYamlPattern`, `ImagePinning`

---

### Capsule: InstallYamlPattern

**Invariant**
Each app has `install.yaml` (Flux Kustomization wrapper) pointing to `app/` subdirectory with HelmRelease.

**Example**

```
kubernetes/main/apps/media/immich/
├── install.yaml          # Flux Kustomization (entry point)
└── app/
    ├── helmrelease.yaml  # HelmRelease definition
    ├── kustomization.yaml # Kustomize resources list
    └── secrets.yaml       # ExternalSecret (optional)
```

**Depth**

- Distinction: install.yaml is Flux entry; app/ contains actual resources
- Variables: install.yaml can use postBuild.substitute for templating
- Dependencies: install.yaml declares `dependsOn` for deployment order
- NotThis: Putting HelmRelease directly in namespace folder
- SeeAlso: `AppTemplateChart`, `ExternalSecretSync`

---

### Capsule: ImagePinning

**Invariant**
Production images include `@sha256:` digest; Renovate updates digests automatically.

**Example**

```yaml
image:
  repository: ghcr.io/immich-app/immich-server
  tag: v1.118.0@sha256:abc123...
```

**Depth**

- Distinction: Tag alone can change; digest is immutable
- Trade-off: Extra verbosity but guarantees exact image version
- Automation: Renovate updates both tag and digest
- NotThis: Using `:latest` or tags without digests in production
- SeeAlso: `RenovateAutomation`

---

## Directory Structure

```
kubernetes/main/
├── apps/                  # Application manifests (install.yaml pattern)
│   ├── cert-manager/
│   ├── database/          # CloudNative-PG, Dragonfly, InfluxDB, pgAdmin
│   ├── flux-system/       # Flux operator and instance
│   ├── gpu-system/        # Intel GPU device plugins
│   ├── home-automation/   # Home Assistant, Zigbee, Z-Wave, ESPHome, etc.
│   ├── kube-system/       # Cilium, CoreDNS, metrics-server, reloader, spegel
│   ├── media/             # Plex, qBittorrent, Readarr, Calibre
│   ├── network/           # Envoy Gateway, external-dns, cloudflared, k8s-gateway
│   ├── observability/     # Prometheus, Grafana, Loki, Thanos
│   ├── rook-ceph/         # Distributed storage operator and cluster
│   ├── security/          # Authelia, external-secrets, LLDAP
│   ├── storage/           # OpenEBS, MinIO
│   ├── system/            # node-feature-discovery
│   └── tools/             # it-tools
├── bootstrap/             # Helmfile-based bootstrap (CRDs, core apps)
├── cluster/               # Flux cluster configuration
├── components/            # Shared kustomize components
└── talos/                 # Talos OS configuration
```

---

## Cluster Topology

| Aspect             | Details                                      |
| ------------------ | -------------------------------------------- |
| **Nodes**          | 3 control plane + 3 worker (bare metal)      |
| **OS**             | Talos Linux (immutable, API-driven)          |
| **CNI**            | Cilium (eBPF, replaces kube-proxy)           |
| **GitOps**         | Flux v2 (flux-operator + flux-instance)      |
| **Gateway**        | Envoy Gateway (Gateway API)                  |
| **Storage**        | Rook-Ceph (NVMe) + OpenEBS + NFS (Synology) |
| **Secrets**        | SOPS/Age + ExternalSecrets with 1Password    |
| **Certificates**   | cert-manager with Let's Encrypt (DNS-01)     |
| **DNS**            | external-dns (Cloudflare) + k8s-gateway      |
| **Auth**           | Authelia (SSO/OIDC) + LLDAP                  |
| **External Access** | cloudflared tunnel                           |

---

## Storage Patterns

### Capsule: RookCephFast

**Invariant**
Rook-Ceph provides fast replicated storage from NVMe drives across worker nodes.

**Example**

```yaml
persistence:
  data:
    enabled: true
    storageClass: rook-ceph-block
    size: 10Gi
```

**Depth**

- Use case: Databases, stateful apps requiring fast I/O
- Replication: 3x across worker nodes
- Performance: NVMe-backed
- Trade-off: Limited capacity vs speed and redundancy
- NotThis: Not for large media files (use NFS instead)
- SeeAlso: `NFSStorage`, `OpenEBSLocal`

---

### Capsule: OpenEBSLocal

**Invariant**
OpenEBS hostpath provides local-only storage on the node where the pod runs.

**Example**

```yaml
persistence:
  data:
    storageClass: openebs-hostpath
    size: 5Gi
```

**Depth**

- Use case: Non-replicated local storage, node-affinity workloads
- Trade-off: No replication, data lost if node fails, but fastest local access
- NotThis: Not for data requiring high availability
- SeeAlso: `RookCephFast`

---

### Capsule: NFSStorage

**Invariant**
NFS provides large slow storage from Synology NAS (172.16.2.246) for media and bulk data.

**Example**

```yaml
persistence:
  media:
    enabled: true
    type: nfs
    server: 172.16.2.246
    path: /volume1/media
```

**Depth**

- Use case: Media files, downloads, backups
- Capacity: Multi-TB available on Synology NAS
- Performance: Slower than Ceph but massive capacity
- Trade-off: Capacity vs speed
- NotThis: Not for databases or apps requiring fast I/O
- SeeAlso: `RookCephFast`

---

### Storage Class Reference

| Class                  | Backend           | Use Case                       |
| ---------------------- | ----------------- | ------------------------------ |
| `rook-ceph-block`      | Rook-Ceph (NVMe)  | Databases, stateful apps       |
| `rook-ceph-filesystem` | Rook-Ceph (NVMe)  | Shared storage (ReadWriteMany) |
| `openebs-hostpath`     | OpenEBS (local)    | Local-only, node-affinity      |
| NFS (direct mount)     | Synology 172.16.2.246 | Large media, bulk data      |

---

## Bootstrap Process

### Sequence

1. **Talos Installation**
   - Apply machineconfig to nodes
   - Nodes join cluster, bootstrap etcd

2. **Flux Bootstrap** (via Helmfile)
   - Install CRDs
   - Install Flux operators
   - Install core apps

3. **Dependency Order**
   - Cilium (networking)
   - CoreDNS (cluster DNS)
   - Spegel (image mirroring)
   - Cert-Manager (certificates)
   - Flux (GitOps)

4. **App Deployment**
   - Flux watches `kubernetes/main/apps/`
   - Reconciles HelmReleases
   - Creates resources in dependency order

---

## Automation

### Capsule: RenovateAutomation

**Invariant**
Renovate automatically updates container images, Helm charts, and GitHub Actions; creates PRs for review.

**Example**
Renovate detects immich v1.118.0 -> v1.118.1, updates image tag and SHA digest, creates PR with changelog.

**Depth**

- Scope: Docker images, Helm charts, GitHub Actions
- Auto-merge: Patch/minor updates auto-merge if tests pass
- Trade-off: Automation vs manual control
- SeeAlso: `ImagePinning`

---

## Common Failures

### HelmRelease stuck Reconciling

**Cause**: Missing ExternalSecret, invalid values, or chart error
**Fix**: Check `flux logs`, ensure ExternalSecrets are Ready, validate values

### Pod stuck Pending

**Cause**: ExternalSecret not synced, PVC not bound, or node affinity
**Fix**: Check ExternalSecret status, verify PVC exists, check node labels

### HTTPRoute not working

**Cause**: Missing gateway, wrong `parentRefs`, or DNS not configured
**Fix**: Verify gateway exists (`kubectl get gateway -n network`), check external-dns logs

### ExternalSecret failing to sync

**Cause**: Missing 1Password entry, wrong path, or onepassword-connect not ready
**Fix**: Verify entry exists in 1Password, check path format

---

## Operational Limits

| Resource               | Behavior                                       |
| ---------------------- | ---------------------------------------------- |
| Flux reconciliation    | Every 1 hour or on Git push                    |
| HelmRelease retry      | Retries with exponential backoff (max 3)       |
| ExternalSecret refresh | Every 12 hours                                 |
| Image pull             | Cached by Spegel (distributed registry mirror) |
