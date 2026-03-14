# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

GitOps-managed Kubernetes homelab running Talos Linux on bare metal (3 control plane + 3 worker nodes). All cluster state is declared in Git and reconciled by Flux v2.

## Commands

All commands use `just` (task runner). Root `.justfile` routes to clusters via `just main <cmd>` or `just test <cmd>`.

```bash
# Test cluster (Docker-based Talos, ephemeral)
just test ci              # Full pipeline: create cluster → validate all manifests → destroy
just test up              # Create cluster + install CRDs
just test validate        # Run all validations (structure, kustomize, server-side dry-run)
just test down            # Destroy cluster

# Main cluster (production, bare metal)
just main sync-hr <ns> <name>   # Force-reconcile a HelmRelease
just main sync-ks <ns> <name>   # Force-reconcile a Kustomization
just main sync-es <ns> <name>   # Force-reconcile an ExternalSecret
just main sync-all-hr           # Sync all HelmReleases
just main apply-ks <ns> <name>  # Apply local Flux Kustomization via flux-local
just main prune-pods            # Delete Failed/Pending/Succeeded pods
just main talos apply-node <n>  # Apply Talos config to node
just main talos apply-cluster   # Apply Talos config to all nodes
just main bootstrap             # Full bootstrap sequence

# Validation (no cluster needed)
just lint                 # yamllint all YAML
just validate             # kubeconform static validation
```

Tools are managed by mise (`.mise.toml`). Run `mise install` to get all dependencies.

## Architecture

### Reconciliation Flow

```
Git push → Flux GitRepository → cluster-apps Kustomization → per-namespace Kustomizations
  → per-app install.yaml (Flux Kustomization) → app/ directory (kustomize build) → HelmRelease
```

`cluster-apps.yaml` in `kubernetes/main/cluster/` is the root Kustomization. It patches all child Kustomizations with SOPS decryption and HelmRelease defaults. It performs Flux variable substitution from `cluster-settings` ConfigMap and `cluster-secrets` Secret.

### App Structure (install.yaml pattern)

Every app follows this layout:

```
kubernetes/main/apps/<namespace>/<app>/
├── install.yaml              # Flux Kustomization entry point (in flux-system namespace)
└── app/
    ├── kustomization.yaml    # Kustomize resource list
    ├── helmrelease.yaml      # HelmRelease (references chart + values)
    └── secrets.yaml          # ExternalSecret (optional)
```

Apps with multiple components add sibling directories (e.g., `gateway/`, `issuers/`, `db/`) — each gets its own Flux Kustomization resource in `install.yaml` with `dependsOn`.

Each namespace has a `kustomization.yaml` that lists all app `install.yaml` files as resources.

### Key Patterns

- **bjw-s/app-template**: Default Helm chart for apps. Shared OCIRepository defined in `kubernetes/main/components/app-template/`.
- **ExternalSecrets**: Secrets pulled from 1Password via `ClusterSecretStore: onepassword-connect`. ExternalSecret resources reference 1Password item keys.
- **SOPS/Age**: Files ending in `.sops.yaml` are encrypted. Age key: `age1dfs2z6esr6rhm46pvh6l8xlualxsn756rkkt9432d5kk3k7s4pssmus4gk`. Encryption rules in `.sops.yaml`.
- **Flux variable substitution**: `${SECRET_DOMAIN}`, `${CLUSTER_CIDR}`, etc. are replaced by Flux from cluster-settings/cluster-secrets. These are NOT environment variables.
- **VolSync backups**: Shared kustomize component in `kubernetes/main/components/volsync/` for Kopia-based PVC backups.
- **Image pinning**: Tags include `@sha256:` digest. Renovate updates both tag and digest.

### Networking

- **CNI**: Cilium (eBPF, replaces kube-proxy, L2 announcements for LoadBalancer IPs)
- **Gateway**: Envoy Gateway with Gateway API. Two gateways in `network` namespace:
  - `envoy-internal` — private LAN access
  - `envoy-external` — public internet via Cloudflare tunnel
- **Routes**: HTTPRoute resources (not Ingress). Reference a parentRef gateway.
- **DNS**: external-dns creates Cloudflare records from HTTPRoutes; k8s-gateway handles internal `.local` resolution
- **TLS**: cert-manager with Let's Encrypt DNS-01 wildcard certs; terminated at Envoy Gateway

### Storage

| StorageClass | Backend | Use Case |
|---|---|---|
| `rook-ceph-block` | Rook-Ceph (NVMe) | Databases, stateful apps |
| `rook-ceph-filesystem` | Rook-Ceph (NVMe) | Shared ReadWriteMany |
| `openebs-hostpath` | OpenEBS | Local-only, node-bound |
| NFS direct mount | Synology NAS (172.16.2.246) | Large media files |

## Directory Layout

```
kubernetes/
├── main/                     # Production cluster
│   ├── apps/<namespace>/<app>/  # All applications (14 namespaces, 56+ apps)
│   ├── bootstrap/            # Helmfile-based bootstrap (CRDs, core apps)
│   ├── cluster/              # Flux root config (cluster-apps.yaml, settings, secrets)
│   ├── components/           # Shared kustomize components (app-template, volsync)
│   └── talos/                # Talos OS node configurations
└── test/                     # Test cluster (Docker-based Talos)
    ├── .justfile             # Test recipes (ci, validate, install-crds)
    └── docker.just           # Docker cluster lifecycle
```

## Conventions

- **File names**: `install.yaml`, `helmrelease.yaml`, `kustomization.yaml`, `secrets.yaml`, `*-pvc.yaml`
- **Commits**: `type(scope): description` — types: feat, fix, chore, docs, refactor. Scope = app or component name.
- **YAML schema comments**: Add `# yaml-language-server: $schema=...` to typed resources
- **HelmRelease spec**: `interval: 30m`, `maxHistory: 2`, remediation with `retries: 3`, `cleanupOnFail: true`
- **Namespace Kustomizations**: Each namespace dir has a `kustomization.yaml` listing all child `install.yaml` files

## Deeper Context

The `docs/ai-context/` directory contains detailed capsule documentation:
- `ARCHITECTURE.md` — system architecture and patterns
- `CONVENTIONS.md` — coding standards and naming
- `NETWORKING.md` — traffic flows, DNS, gateway config
- `WORKFLOWS.md` — deploy, update, troubleshoot procedures
- `DOMAIN.md` — business rules, state machines, entity relationships
