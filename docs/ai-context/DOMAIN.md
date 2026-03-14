---
description: Domain model covering business rules, state machines, operational invariants, and conceptual patterns
tags: ["DomainRules", "StateMachines", "FluxLifecycle", "HelmRelease", "ExternalSecrets", "PodStates"]
audience: ["LLMs", "Humans"]
categories: ["Domain[100%]", "Reference[90%]"]
---

# Homelab Domain Model

**Purpose**: The conceptual model, business rules, and state machines that govern vdhinfra.

**Scope**: Domain logic and invariants, not implementation details (those are in ARCHITECTURE.md).

---

## Core Rules

### Rule 1: GitOps is the source of truth

**Rule**: All changes flow through Git. Manual cluster changes revert on next reconciliation.

**Enforced By**: Flux reconciliation loop (every 1 hour or on Git push webhook).

**Violation**: `kubectl edit` changes are overwritten when Flux reconciles.

**Why**: Ensures cluster state is auditable, reproducible, and version-controlled.

---

### Rule 2: Secrets live in 1Password, not Git

**Rule**: All app secrets pulled from 1Password via ExternalSecrets; bootstrap/Talos secrets encrypted with SOPS/Age.

**Enforced By**: ExternalSecret resources with ClusterSecretStore `onepassword-connect`; `.sops.yaml` config rules.

**Violation**: Missing 1Password entry blocks ExternalSecret sync, which blocks pod startup.

**Why**: Repository is public; secrets must stay encrypted and centralized.

---

### Rule 3: Apps use app-template chart

**Rule**: Default to `bjw-s/app-template` Helm chart; vendor charts only when necessary.

**Why**: Consistent structure, predictable patterns, easier maintenance.

**Exception**: Infrastructure components (cilium, cert-manager, rook-ceph) use vendor charts.

---

### Rule 4: Images are pinned by digest

**Rule**: Production images must include `@sha256:` digest; Renovate updates automatically.

**Enforced By**: Renovate automation monitoring all HelmReleases.

**Violation**: Using `:latest` or tags without digests creates non-reproducible deployments.

---

## State Machines

### Flux HelmRelease Lifecycle

```
[Created] -> Pending -> Reconciling -> Ready
                                    -> Failed -> Reconciling (retry, max 3)
Ready -> Reconciling (values changed in Git)
Ready/Failed -> Deleting (removed from Git)
```

**State Transitions**:

| From         | To          | Trigger                                     | Duration            |
| ------------ | ----------- | ------------------------------------------- | ------------------- |
| Pending      | Reconciling | Chart and values resolved                   | Seconds             |
| Reconciling  | Ready       | Helm install/upgrade success                | 30s-5m              |
| Reconciling  | Failed      | Chart error, missing secret, invalid values | Variable            |
| Ready        | Reconciling | Git push with changed values                | Immediate           |
| Failed       | Reconciling | Remediation retry (max 3)                   | Exponential backoff |
| Ready/Failed | Deleting    | HelmRelease deleted from Git                | Immediate           |

**Critical Insight**: `Ready` state means Helm succeeded, NOT that pods are healthy. Pod failures appear in `kubectl get pods`, not HelmRelease status.

---

### ExternalSecret Lifecycle

```
[Created] -> Pending -> Syncing -> Ready
                                -> Failed -> Syncing (retry)
Ready -> Refreshing (12h interval) -> Ready (no changes)
                                   -> Updated -> Ready (secret updated)
```

**State Transitions**:

| From    | To         | Trigger                               | Blocks Pods? |
| ------- | ---------- | ------------------------------------- | ------------ |
| Pending | Syncing    | ClusterSecretStore ready              | Yes          |
| Syncing | Ready      | 1Password entry found and pulled      | No           |
| Syncing | Failed     | Missing entry, wrong path, store down | Yes          |
| Ready   | Refreshing | 12h interval or manual refresh        | No           |
| Failed  | Syncing    | Retry after exponential backoff       | Yes          |

**Critical Dependencies**:

- ExternalSecret MUST be Ready before pods referencing the secret can start
- onepassword-connect MUST be running before any ExternalSecret can sync
- 1Password vault MUST contain entry at specified path

---

### Pod Lifecycle (Common Failure Points)

| State          | Common Causes                      | Fix                                                 |
| -------------- | ---------------------------------- | --------------------------------------------------- |
| WaitingSecrets | ExternalSecret not Ready           | Check ExternalSecret status, verify 1Password entry |
| PullingImages  | Wrong image tag, missing digest    | Verify image exists, check registry auth            |
| CrashLoop      | App config error, missing env vars | Check logs, verify ExternalSecret template          |
| Pending        | PVC not bound, node affinity       | Check PVC status, verify node labels                |

---

## Entity Relationships

### Deployment Flow

```
Git Push -> Flux Detects (1h or webhook)
  -> Reconcile Kustomization
    -> Build Manifests
      -> Apply Resources
        -> ExternalSecret -> Kubernetes Secret -> Pods Start
        -> HelmRelease -> Pods Start
        -> HTTPRoute -> Envoy Gateway -> external-dns -> Cloudflare DNS
```

**Key Insight**: ExternalSecret must complete before pod scheduling if pods reference the secret.

### Resource Dependencies

| Resource       | Depends On                                   | Blocks      | Prune Behavior |
| -------------- | -------------------------------------------- | ----------- | -------------- |
| HelmRelease    | Chart source, ExternalSecret (if referenced) | Pods        | Cascade delete |
| ExternalSecret | ClusterSecretStore, 1Password entry          | Pods        | Delete secret  |
| HTTPRoute      | Gateway, Service                             | DNS records | Delete route   |
| PVC            | StorageClass                                 | Pods        | Retained       |
| Pod            | Secret, PVC, Image                           | Nothing     | Immediate      |

### Secret Flow

| Stage  | State                  | Location        | Encrypted?    |
| ------ | ---------------------- | --------------- | ------------- |
| Source | 1Password vault entry  | 1Password cloud | Yes           |
| Pull   | ExternalSecret syncing | Cluster memory  | No            |
| Store  | Kubernetes Secret      | etcd            | Yes (at rest) |
| Mount  | Pod environment/volume | Container       | No            |

**Critical Path**: 1Password -> onepassword-connect -> ExternalSecret controller -> Kubernetes Secret -> Pod

**Failure Impact**: Any failure in this chain blocks pod startup indefinitely.

---

## Business Rules and Constraints

### Capsule: OrderedBootstrap

**Invariant**: Infrastructure components must start before applications; dependencies enforce order.

**Bootstrap Order**:

1. Cilium (networking) - Nothing works without CNI
2. CoreDNS (DNS) - Required for service discovery
3. Spegel (image cache) - Accelerates image pulls
4. Cert-Manager (certificates) - Required for HTTPS
5. External-Secrets (secrets) - Required for app secrets
6. CloudNative-PG (database operator) - Required for databases
7. Envoy Gateway (routing) - Required for HTTPRoutes
8. Applications - Can start after infrastructure ready

**Enforcement**: `dependsOn` in install.yaml files create dependency graph.

---

### Capsule: StorageClassSelection

**Invariant**: Storage class determines performance, capacity, and redundancy characteristics.

**Decision Matrix**:

| Use Case           | StorageClass           | Backed By       | Performance | Redundancy |
| ------------------ | ---------------------- | --------------- | ----------- | ---------- |
| Database, fast I/O | `rook-ceph-block`      | NVMe SSD        | High        | 3x replica |
| Shared files       | `rook-ceph-filesystem` | NVMe SSD        | Medium      | 3x replica |
| Local-only         | `openebs-hostpath`     | Node disk       | High        | None       |
| Large media        | NFS mounts             | Synology NAS    | Low         | RAID       |
| Cache, temp        | `emptyDir`             | Node memory     | Highest     | None       |

**Rules**:

- Databases -> rook-ceph-block (fast, replicated)
- App configs -> rook-ceph-block (small, persistent)
- Media downloads -> NFS (large capacity)
- Caches -> emptyDir or tmpfs (ephemeral)

---

### Capsule: GatewaySelection

**Invariant**: Gateway determines network exposure and access path.

**Decision Matrix**:

| Access Pattern   | Gateway          | DNS                    | Auth            |
| ---------------- | ---------------- | ---------------------- | --------------- |
| Public internet  | `envoy-external` | Cloudflare (proxied)   | App-level/Authelia |
| Private LAN only | `envoy-internal` | k8s-gateway (internal) | Network-level   |

**Rules**:

- Home Assistant -> envoy-internal (LAN only)
- Apps needing remote access -> envoy-external (via Cloudflare tunnel)
- Internal tools -> envoy-internal (security)

---

### Capsule: SecretTemplating

**Invariant**: ExternalSecrets can compose values from multiple 1Password fields using templates.

**Pattern**: Complex secrets (database URLs, multi-value configs) built from individual fields.

**Example**:

```yaml
target:
  template:
    data:
      DB_URL: "postgres://{{ .DB_USERNAME }}:{{ .DB_PASSWORD }}@host:5432/db"
      JWT_SECRET: "{{ .JWT_SECRET }}"
dataFrom:
  - extract:
      key: immich  # 1Password item name
```

**Why**: Secrets in 1Password stored as individual fields; apps need composed values.

---

## Temporal Rules

### Reconciliation Timing

| Component          | Interval | Trigger         |
| ------------------ | -------- | --------------- |
| Flux Kustomization | 1h       | Webhook, manual |
| HelmRelease        | 1h       | Values change   |
| ExternalSecret     | 12h      | Manual refresh  |

### Retry Behavior

| Resource       | Max Retries | Backoff              |
| -------------- | ----------- | -------------------- |
| HelmRelease    | 3           | Exponential          |
| ExternalSecret | Infinite    | Exponential          |
| Pod            | Infinite    | Exponential (max 5m) |

**Key Differences**:

- HelmRelease gives up after 3 failures (requires manual fix)
- ExternalSecret retries forever (eventual consistency)
- Pods restart forever with increasing backoff (CrashLoopBackOff)

---

## Anti-Patterns

### Don't: Use kubectl for Permanent Changes

**Wrong**: `kubectl edit deployment immich-server -n media`

**Right**: Edit `kubernetes/main/apps/media/immich/app/helmrelease.yaml`, commit, push.

**Why**: GitOps reverts kubectl changes. Git is source of truth.

### Don't: Use :latest Tag

**Wrong**: `tag: latest`

**Right**: `tag: v2.4.1@sha256:e6a6298e67ae077808fdb7d8d5565955...`

**Why**: `:latest` changes unpredictably. Digest pins exact version.

### Don't: Hardcode Secrets

**Wrong**: `DB_PASSWORD: "mySecretPassword123"` in manifests

**Right**: ExternalSecret pulling from 1Password via `onepassword-connect`.

**Why**: Public repository. Secrets must come from 1Password.

### Don't: Skip Dependencies

**Wrong**: install.yaml with no `dependsOn` but app uses ExternalSecret and database.

**Right**: Declare all prerequisites in `dependsOn`.

**Why**: Missing dependencies cause race conditions and startup failures.

---

## Glossary

| Term                    | Definition                                                            |
| ----------------------- | --------------------------------------------------------------------- |
| **app-template**        | bjw-s Helm chart providing consistent app deployment patterns         |
| **Authelia**            | SSO/OIDC authentication proxy                                        |
| **Cilium**              | CNI and network policy provider (eBPF-based, replaces kube-proxy)    |
| **ClusterSecretStore**  | External-Secrets resource defining 1Password connection               |
| **CloudNative-PG**      | PostgreSQL operator for managed database clusters                     |
| **Envoy Gateway**       | Gateway API implementation for HTTP/HTTPS routing                     |
| **ExternalSecret**      | Resource syncing secrets from 1Password to Kubernetes                 |
| **Flux**                | GitOps operator synchronizing cluster state to Git                    |
| **Gateway API**         | Kubernetes routing API replacing Ingress (HTTPRoute, Gateway)         |
| **HelmRelease**         | Flux resource managing Helm chart deployment                          |
| **HTTPRoute**           | Gateway API resource defining HTTP routing rules                      |
| **k8s-gateway**         | CoreDNS plugin providing internal DNS for cluster services            |
| **Kustomization**       | Flux resource defining what to apply from Git path                    |
| **LLDAP**               | Lightweight LDAP server for user directory                            |
| **OCIRepository**       | Flux resource for OCI registry-hosted Helm charts                     |
| **onepassword-connect** | 1Password service providing API access to vaults                      |
| **Renovate**            | Automation bot updating dependencies (images, charts, actions)        |
| **Rook-Ceph**           | Distributed storage system on NVMe drives                             |
| **Spegel**              | Peer-to-peer image cache across cluster nodes                         |
| **Talos**               | Immutable Linux OS for Kubernetes nodes (API-driven, no SSH)          |

---

**See Also**:

- `ARCHITECTURE.md` - System architecture and implementation details
- `NETWORKING.md` - Traffic flows, DNS, and routing configuration
- `WORKFLOWS.md` - Operational procedures and troubleshooting
- `CONVENTIONS.md` - Coding standards and naming patterns
- `Ethos.md` - Documentation philosophy and principles
