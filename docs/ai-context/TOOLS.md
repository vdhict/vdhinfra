---
description: Tool strategy covering CLI commands, task runner, and exploration patterns for vdhinfra
tags: ["TaskfileCLI", "FluxCLI", "KubectlCLI", "TalosctlCLI"]
audience: ["LLMs", "Humans"]
categories: ["Reference[100%]", "Tools[95%]"]
---

# Tool Strategy

**Principle**: Query before reading. Use structured tools to understand scope, then drill down.

---

## CLI Tools

### Taskfile (go-task)

**Location**: `Taskfile.yaml`, `.taskfiles/`

**Discovery**:

```bash
task --list        # See all available tasks
task --list-all    # Include internal tasks
```

#### Quick Reference

| Command                              | Purpose                    |
| ------------------------------------ | -------------------------- |
| `task bootstrap:talos`               | Bootstrap Talos cluster    |
| `task bootstrap:apps`                | Bootstrap applications     |
| `task kubernetes:kubeconform`        | Validate manifests         |
| `task sops:re-encrypt`               | Re-encrypt all SOPS files  |

---

## Flux CLI

| Command                                                     | Purpose                  |
| ----------------------------------------------------------- | ------------------------ |
| `flux get kustomizations`                                   | List all kustomizations  |
| `flux get helmreleases -A`                                  | List all HelmReleases    |
| `flux get helmrelease <name> -n <ns>`                       | Check specific release   |
| `flux reconcile kustomization <name> -n flux-system`        | Force sync kustomization |
| `flux reconcile helmrelease <name> -n <ns>`                 | Force sync HelmRelease   |
| `flux reconcile source git flux-system`                     | Sync Git source          |
| `flux logs`                                                 | View controller logs     |
| `flux suspend helmrelease <name> -n <ns>`                   | Suspend release          |
| `flux resume helmrelease <name> -n <ns>`                    | Resume release           |

**Common Workflows**:

```bash
# Check cluster status
flux get kustomizations
flux get helmreleases -A

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps -n flux-system

# Debug failed release
flux get hr <name> -n <namespace>
kubectl logs -n flux-system deploy/helm-controller | grep <name>
```

---

## kubectl

| Command                                                          | Purpose                 |
| ---------------------------------------------------------------- | ----------------------- |
| `kubectl get pods -A`                                            | List all pods           |
| `kubectl get hr -A`                                              | List HelmReleases       |
| `kubectl logs -n <ns> <pod>`                                     | View pod logs           |
| `kubectl describe hr <name> -n <ns>`                             | HelmRelease details     |
| `kubectl get events -A --sort-by=.lastTimestamp`                 | Recent events           |
| `kubectl get pvc -A`                                             | List persistent volumes |
| `kubectl get externalsecrets -A`                                 | List external secrets   |
| `kubectl get httproutes -A`                                      | List all HTTP routes    |
| `kubectl get gateways -n network`                                | List gateways           |

---

## talosctl

**Purpose**: Manage Talos Linux nodes.

| Command                                 | Purpose         |
| --------------------------------------- | --------------- |
| `talosctl dashboard --nodes <ip>`       | Node dashboard  |
| `talosctl health --nodes <ip>`          | Cluster health  |
| `talosctl logs -f kubelet --nodes <ip>` | Node logs       |
| `talosctl get members --nodes <ip>`     | Cluster members |
| `talosctl upgrade --nodes <ip>`         | Upgrade nodes   |
| `talosctl reboot --nodes <ip>`          | Reboot node     |

---

## Discovery Patterns

### Understanding the Repository

```bash
# Via CLI
task --list                          # See available tasks
ls kubernetes/main/apps/             # See namespaces
ls kubernetes/main/apps/<namespace>/ # See apps in namespace

# Via documentation
cat docs/ai-context/ARCHITECTURE.md  # System architecture
cat docs/ai-context/CONVENTIONS.md   # Coding standards
cat CLAUDE.md                        # Quick reference
```

### Finding an App

```bash
# Via directory structure
ls kubernetes/main/apps/media/

# Via grep
grep -r "app: immich" kubernetes/main/apps/

# Via flux
flux get hr -A | grep immich
```

### Checking Deployment Status

```bash
# Flux status
flux get hr immich -n media

# Pod status
kubectl get pods -n media -l app.kubernetes.io/name=immich

# Events
kubectl get events -n media --sort-by=.lastTimestamp
```

### Debugging a Failure

```bash
# 1. Check HelmRelease status
flux get hr <name> -n <namespace>

# 2. Describe HelmRelease
kubectl describe hr <name> -n <namespace>

# 3. View Flux controller logs
kubectl logs -n flux-system deploy/helm-controller | grep <name>

# 4. Check pod events
kubectl describe pod -n <namespace> -l app.kubernetes.io/name=<name>

# 5. View pod logs
kubectl logs -n <namespace> -l app.kubernetes.io/name=<name>

# 6. Check external secrets
kubectl get externalsecrets -n <namespace>
kubectl describe externalsecret <name> -n <namespace>
```

### Validating Changes

```bash
# Before commit
task kubernetes:kubeconform

# After push
flux get kustomizations
flux get helmreleases -A
```

---

## Environment Setup

### Required Tools

- `flux` - Flux CLI for GitOps operations
- `kubectl` - Kubernetes CLI
- `talosctl` - Talos Linux CLI
- `task` - Task runner (go-task)
- `sops` - Secret encryption/decryption
- `age` - Age encryption (used by SOPS)
- `kubeconform` - Manifest validation
- `stern` - Multi-pod log tailing (optional)

### Installation (macOS)

```bash
brew install fluxcd/tap/flux kubectl siderolabs/tap/talosctl go-task/tap/go-task sops age kubeconform stern
```

---

## Quick Reference

### When to Use What

| Task                      | Tool                                  |
| ------------------------- | ------------------------------------- |
| Understand repo structure | `task --list`, directory navigation   |
| Find specific pattern     | `grep -r` or Grep tool                |
| Validate YAML             | `task kubernetes:kubeconform`         |
| Check cluster state       | `flux get` / `kubectl get`            |
| Debug app                 | `kubectl logs` / `kubectl describe`   |
| Force deployment          | `flux reconcile`                      |
| Encrypt secrets           | `sops --encrypt`                      |
| Re-encrypt all secrets    | `task sops:re-encrypt`                |

---

## Non-Obvious Truths

- **SOPS files must be encrypted**: `.sops.yaml` config enforces encryption rules by path
- **Age key required**: SOPS decryption needs the Age private key available
- **Flux operator pattern**: This repo uses flux-operator + flux-instance, not standalone Flux controllers
- **Single cluster**: No `--context` flag needed for most commands (only one cluster)
- **Talos has no SSH**: Node management is exclusively via `talosctl` API
- **Pre-commit hooks**: Run `task pre-commit:init` to set up automatic validation on commit

---

**See Also**:

- `ARCHITECTURE.md` - System architecture and component relationships
- `WORKFLOWS.md` - Deployment, update, and troubleshooting workflows
- `CONVENTIONS.md` - Naming, structure, and style conventions
