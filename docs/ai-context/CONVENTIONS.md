---
description: Coding standards, naming conventions, and project structure rules for vdhinfra
tags: ["NamingConventions", "DirectoryStructure", "CommitGuidelines", "YAMLStyle"]
audience: ["LLMs", "Humans"]
categories: ["Conventions[100%]", "Reference[85%]"]
---

# Repository Conventions

## Directory Structure

### Capsule: SingleClusterLayout

**Invariant**
All cluster code lives in `kubernetes/main/`; a test cluster will be a separate repository later.

**Example**

```
kubernetes/main/
├── apps/           # Application manifests
├── bootstrap/      # Helmfile-based bootstrap
├── cluster/        # Flux cluster configuration
├── components/     # Shared kustomize components
└── talos/          # Talos OS configuration
```

**Depth**

- Distinction: Single cluster now; structure supports future multi-cluster via separate repos
- NotThis: Do not create `kubernetes/staging/` or `kubernetes/test/` in this repo
- SeeAlso: `InstallYamlPattern` in ARCHITECTURE.md

---

### App Structure Pattern

### Capsule: InstallYamlPattern

**Invariant**
Each app has `install.yaml` (Flux Kustomization wrapper) pointing to subdirectories with actual resources.

**Example**

```
kubernetes/main/apps/<namespace>/<app>/
├── install.yaml                    # Flux Kustomization (entry point)
├── app/                            # Application resources
│   ├── helmrelease.yaml           # HelmRelease
│   ├── kustomization.yaml         # Kustomize resources list
│   ├── secrets.yaml               # ExternalSecret (optional)
│   └── *-pvc.yaml                 # PVCs (optional)
└── db/                             # Database resources (optional)
    ├── helmrelease.yaml
    ├── kustomization.yaml
    ├── secrets.yaml
    └── cluster.yaml               # CloudNativePG cluster
```

**Depth**

- Distinction: install.yaml is Flux entry point; subdirectories contain actual resources
- Components: install.yaml can reference shared components from `kubernetes/main/components/`
- Variables: install.yaml uses `postBuild.substitute` for templating
- Dependencies: install.yaml declares `dependsOn` for deployment order
- NotThis: Putting HelmRelease directly in namespace folder
- SeeAlso: `AppTemplateChart`, `ExternalSecretSync`

---

### Template vs Generated

| Location                             | Type             | Edit?        | Purpose               |
| ------------------------------------ | ---------------- | ------------ | ---------------------- |
| `kubernetes/main/talos/**/*.j2`      | Jinja2 templates | Yes - source | Node configurations    |
| `kubernetes/main/bootstrap/`         | Bootstrap        | Yes          | Bootstrap manifests    |
| `kubernetes/main/apps/`             | Static YAML      | Yes          | Application manifests  |
| `kubernetes/main/cluster/`          | Static YAML      | Yes          | Flux configuration     |

---

## Naming Conventions

### Files

| Type               | Pattern              | Example                                                    |
| ------------------ | -------------------- | ---------------------------------------------------------- |
| Flux Kustomization | `install.yaml`       | `kubernetes/main/apps/media/immich/install.yaml`           |
| HelmRelease        | `helmrelease.yaml`   | `kubernetes/main/apps/media/immich/app/helmrelease.yaml`   |
| Kustomization      | `kustomization.yaml` | `kubernetes/main/apps/media/immich/app/kustomization.yaml` |
| ExternalSecret     | `secrets.yaml`       | `kubernetes/main/apps/media/immich/app/secrets.yaml`       |
| PVC                | `<name>-pvc.yaml`    | `kubernetes/main/apps/media/immich/app/immich-pvc.yaml`    |
| SOPS secret        | `*.sops.yaml`        | `kubernetes/main/bootstrap/secrets.sops.yaml`              |
| Component          | `components/<name>/` | `kubernetes/main/components/volsync/`                      |

### Resources

| Type           | Pattern                             | Example                            |
| -------------- | ----------------------------------- | ---------------------------------- |
| App name       | lowercase, hyphenated               | `home-assistant`, `pdf-tools`      |
| Secret name    | `<app>-secret`                      | `immich-secret`                    |
| PVC name       | `<app>-<purpose>`                   | `immich-data`, `immich-backups`    |
| ConfigMap      | `<app>-config` or `<app>-configmap` | `immich-configmap`                 |
| ExternalSecret | Same as target secret               | `immich` (creates `immich-secret`) |

---

## YAML Style

### HelmRelease Pattern

### Capsule: AppTemplateStandard

**Invariant**
Apps use `bjw-s/app-template` chart with consistent boilerplate.

**Example**

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app immich
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: app-template
  maxHistory: 3
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  uninstall:
    keepHistory: false
  values:
    controllers:
      server:
        strategy: Recreate
        annotations:
          secret.reloader.stakater.com/reload: immich-secret
        containers:
          main:
            image:
              repository: ghcr.io/immich-app/immich-server
              tag: v2.4.1@sha256:abc123...
            envFrom:
              - secretRef:
                  name: immich-secret
```

**Depth**

- Schema: Always include yaml-language-server schema comment
- Interval: Standard is `1h` (hourly reconciliation)
- ChartRef: Use OCIRepository named `app-template` in `flux-system` namespace
- Retries: Always set remediation retries (typically 3)
- Anchors: Use YAML anchors (`&app`, `*app`) for repeated values
- NotThis: Random Helm charts without checking if app-template works
- SeeAlso: `ImageDigestPinning`, `ExternalSecretSync`

---

### Image Tags

### Capsule: ImageDigestPinning

**Invariant**
Production images must include `@sha256:` digest; Renovate updates both tag and digest automatically.

**Example**

```yaml
# CORRECT
image:
  repository: ghcr.io/immich-app/immich-server
  tag: v2.4.1@sha256:e6a6298e67ae077808fdb7d8d5565955f60b0708191576143fc02d30ab1389d1

# WRONG
tag: latest                          # Never use
tag: v2.4.1                          # Missing digest
```

**Depth**

- Distinction: Tag alone can change; digest is immutable and guarantees exact image
- Automation: Renovate updates both tag and digest in PRs
- Trade-off: Extra verbosity but guarantees reproducibility

---

### Environment Variables

```yaml
# From ExternalSecret
envFrom:
  - secretRef:
      name: app-secret

# Direct values (non-sensitive only)
env:
  TZ: Europe/Amsterdam
  LOG_LEVEL: info
```

---

### Storage Configuration

```yaml
# Rook-Ceph block storage (fast, replicated)
persistence:
  config:
    enabled: true
    storageClass: rook-ceph-block
    accessMode: ReadWriteOnce
    size: 10Gi
    globalMounts:
      - path: /config

# NFS storage (large capacity, Synology NAS)
persistence:
  media:
    enabled: true
    type: nfs
    server: 172.16.2.246
    path: /volume1/media
    globalMounts:
      - path: /media
        readOnly: true

# Tmpfs (ephemeral)
persistence:
  cache:
    enabled: true
    type: emptyDir
    medium: Memory
    globalMounts:
      - path: /cache
```

---

## Git Conventions

### Commit Messages

### Capsule: CommitMessageFormat

**Invariant**
Commit messages follow conventional commits: `type(scope): description`.

**Example**

```
feat(immich): initial deployment
fix(envoy-gateway): correct client traffic policy CIDRs
chore(renovate): update helm chart versions
docs(ai-context): add networking documentation
```

**Depth**

| Type       | Use For                            |
| ---------- | ---------------------------------- |
| `feat`     | New app or feature                 |
| `fix`      | Bug fix (app or container update)  |
| `chore`    | Maintenance, configuration changes |
| `docs`     | Documentation                      |
| `refactor` | Code restructure                   |

**Scope**: Usually the app name or component name.

---

### Branch Strategy

- `main` is the deployment branch
- Flux reconciles from `main`
- Feature branches for complex changes
- Direct commits to `main` for simple changes acceptable

---

## Security Practices

### Secrets

### Capsule: ExternalSecretsOnly

**Invariant**
App secrets come from 1Password via ExternalSecrets; never commit unencrypted secrets.

**Example**

```yaml
# secrets.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: immich
spec:
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: immich-secret
    creationPolicy: Owner
    template:
      data:
        DB_URL: "postgres://{{ .DB_USERNAME }}:{{ .DB_PASSWORD }}@immich-rw.database.svc.cluster.local:5432/immich"
  dataFrom:
    - extract:
        key: immich
```

**Depth**

- Store: Always use ClusterSecretStore named `onepassword-connect`
- Template: Use template section to compose values from 1Password fields
- Refresh: Default 12h refresh interval
- Trade-off: More indirection but repo stays public safely
- SeeAlso: `ExternalSecretSync` in ARCHITECTURE.md

---

### SOPS Encryption Rules

SOPS is configured via `.sops.yaml` at repo root with three path-based rules:

1. `kubernetes/main/talos/` - Full file encryption
2. `kubernetes/main/bootstrap/` - Only `data` and `stringData` fields
3. `kubernetes/main/apps/` - Only `data` and `stringData` fields

All rules use the same Age public key. Files must end in `.sops.yaml`.

---

## Routing Conventions

### Gateway References

### Capsule: EnvoyGatewayNames

**Invariant**
Gateways are `envoy-internal` and `envoy-external` in namespace `network`.

**Example**

```yaml
# Internal app route
route:
  main:
    parentRefs:
      - name: envoy-internal
        namespace: network
        sectionName: https
    hostnames:
      - "{{ .Release.Name }}.${SECRET_DOMAIN}"

# External app route
route:
  main:
    parentRefs:
      - name: envoy-external
        namespace: network
        sectionName: https
    hostnames:
      - "{{ .Release.Name }}.${SECRET_DOMAIN}"
```

**Depth**

| Gateway  | Name             | Namespace | Purpose                |
| -------- | ---------------- | --------- | ---------------------- |
| Internal | `envoy-internal` | `network` | Private network access |
| External | `envoy-external` | `network` | Public internet access |

**Common mistakes**:

- Wrong: Using `internal` or `external` (need `envoy-` prefix)
- Wrong: Wrong namespace (must be `network`)
- Wrong: Wrong section name (must be `https`, not `http`)

---

### DNS Annotations

external-dns watches HTTPRoutes and creates DNS records automatically based on hostnames.

```yaml
# No special annotation needed for basic routes
# external-dns discovers routes automatically
route:
  main:
    hostnames:
      - photos.${SECRET_DOMAIN}
```

---

## Validation

### Before Commit

1. **Validate manifests**:

   ```bash
   task kubernetes:kubeconform
   ```

2. **Review changes**:

   ```bash
   git diff kubernetes/main/apps/
   ```

### After Push

1. Check Flux reconciliation:

   ```bash
   flux get helmreleases -A
   flux get kustomizations
   ```

2. Check pods:

   ```bash
   kubectl get pods -A
   ```

3. Check ExternalSecrets:

   ```bash
   kubectl get externalsecrets -A
   ```

---

## Common Patterns and Mistakes

### Storage Classes

```yaml
# CORRECT
storageClassName: rook-ceph-block       # Single-instance apps, databases
storageClassName: rook-ceph-filesystem  # Shared/multi-instance
storageClassName: openebs-hostpath      # Local-only

# WRONG
storageClassName: ceph-block-storage    # Does not exist
storageClassName: cephfs                # Wrong name
```

### ExternalSecret Provider

```yaml
# CORRECT
secretStoreRef:
  kind: ClusterSecretStore
  name: onepassword-connect

# WRONG
name: onepassword         # Missing "-connect"
name: 1password-connect   # Wrong prefix
```

### Route Hostnames

```yaml
# CORRECT - Use Helm template
hostnames:
  - "{{ .Release.Name }}.${SECRET_DOMAIN}"

# ACCEPTABLE - Explicit hostname
hostnames:
  - photos.${SECRET_DOMAIN}
```

### Reloader Annotations

```yaml
controllers:
  server:
    annotations:
      secret.reloader.stakater.com/reload: immich-secret
      configmap.reloader.stakater.com/reload: immich-configmap
```

---

## Components (Shared Kustomize Resources)

### Capsule: SharedComponents

**Invariant**
Reusable Kustomize components live in `kubernetes/main/components/` and are referenced in install.yaml.

**Example**

```yaml
# In install.yaml
components:
  - ../../../../components/gatus/guarded
  - ../../../../components/nfs-scaler
```

**Depth**

- Distinction: Components are reusable across apps; not copied per-app
- Usage: Referenced via relative path in Kustomization components field
- SeeAlso: Kustomize components documentation

---

## Dependencies

### Capsule: FluxDependencies

**Invariant**
install.yaml declares dependencies via `dependsOn` to ensure deployment order.

**Example**

```yaml
# In kubernetes/main/apps/media/immich/install.yaml
spec:
  dependsOn:
    - name: immich-database
      namespace: media
    - name: external-secrets
      namespace: security
```

**Depth**

- Common dependencies:
  - `external-secrets` - Required if app uses ExternalSecrets
  - `cloudnative-pg-operator` - Required for PostgreSQL databases
  - `rook-ceph-cluster` - Required if using Ceph storage
  - `envoy-gateway` - Required if app has HTTPRoutes
- Flux waits for dependencies to be Ready before deploying app
- Cross-namespace dependencies allowed

---

## Documentation Standards

### File Path Format

**Always use paths from repo root** in documentation:

```markdown
# CORRECT
See kubernetes/main/apps/media/immich/app/helmrelease.yaml

# WRONG
See helmrelease.yaml
See ../immich/app/helmrelease.yaml
```

### Placeholder Usage

**Never expose actual values** (see Ethos.md Rule 3):

```markdown
# CORRECT
https://photos.${SECRET_DOMAIN}

# WRONG
https://photos.example.com
```

---

**See Also**:

- `ARCHITECTURE.md` - System architecture and capsule patterns
- `WORKFLOWS.md` - How to deploy, update, troubleshoot
- `Ethos.md` - Documentation philosophy and hard rules
- `NETWORKING.md` - Traffic flows, DNS, gateways
