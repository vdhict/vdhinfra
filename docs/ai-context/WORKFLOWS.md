---
description: Operational workflows for deployment, troubleshooting, and maintenance
tags: ["AppDeployment", "SecretManagement", "Troubleshooting", "TaskfileOperations"]
audience: ["LLMs", "Humans"]
categories: ["How-To[100%]", "Workflows[95%]"]
---

# Homelab Workflows

**Purpose**: Practical workflows for deploying apps, managing secrets, troubleshooting failures, and maintaining the cluster.

---

## Deploying a New App

### Prerequisites

- Decide namespace placement (see ARCHITECTURE.md for namespace purposes)
- Identify dependencies (databases, secrets, storage)

### Directory Structure

Create app structure in `kubernetes/main/apps/{namespace}/{app}/`:

```
kubernetes/main/apps/media/myapp/
├── install.yaml          # Flux Kustomization (entry point)
└── app/
    ├── helmrelease.yaml  # HelmRelease definition
    ├── kustomization.yaml # Kustomize resources list
    └── secrets.yaml       # ExternalSecret (if needed)
```

### Steps

**1. Create HelmRelease** using app-template pattern:

```yaml
# kubernetes/main/apps/media/myapp/app/helmrelease.yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app myapp
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
      myapp:
        containers:
          app:
            image:
              repository: ghcr.io/org/myapp
              tag: v1.0.0@sha256:abc123...
            env:
              TZ: Europe/Amsterdam
            envFrom:
              - secretRef:
                  name: myapp-secret
    service:
      app:
        controller: myapp
        ports:
          http:
            port: 8080
    route:
      app:
        parentRefs:
          - name: envoy-internal  # or envoy-external
            namespace: network
            sectionName: https
        hostnames:
          - "{{ .Release.Name }}.${SECRET_DOMAIN}"
    persistence:
      config:
        enabled: true
        storageClass: rook-ceph-block
        size: 5Gi
```

**2. Create Kustomization**:

```yaml
# kubernetes/main/apps/media/myapp/app/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./secrets.yaml  # If using ExternalSecrets
```

**3. Create ExternalSecret** (if needed):

```yaml
# kubernetes/main/apps/media/myapp/app/secrets.yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp
spec:
  refreshInterval: 12h
  secretStoreRef:
    name: onepassword-connect
    kind: ClusterSecretStore
  target:
    name: myapp-secret
    creationPolicy: Owner
    template:
      data:
        API_KEY: "{{ .api_key }}"
  dataFrom:
    - extract:
        key: myapp  # 1Password item name
```

**4. Create install.yaml** (Flux entry point):

```yaml
# kubernetes/main/apps/media/myapp/install.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
spec:
  targetNamespace: media
  path: ./kubernetes/main/apps/media/myapp/app
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  dependsOn:
    - name: external-secrets
      namespace: security
  prune: true
  wait: false
  interval: 1h
  timeout: 5m
```

**5. Wire into namespace kustomization**:

```yaml
# kubernetes/main/apps/media/kustomization.yaml
resources:
  - ./myapp/install.yaml  # Add this line
```

**6. Validate and deploy**:

```bash
task kubernetes:kubeconform
git add kubernetes/main/apps/media/myapp/
git commit -m "feat(myapp): initial deployment"
git push
```

---

## Updating an Existing App

### Image Update

**Preferred**: Let Renovate handle this automatically via PR.

**Manual**:

1. Edit `kubernetes/main/apps/{namespace}/{app}/app/helmrelease.yaml`
2. Update `image.tag` and `@sha256:` digest
3. Validate, commit, push

```bash
task kubernetes:kubeconform
git add -A && git commit -m "chore(myapp): update to v1.2.3"
git push
```

### Force Reconciliation

```bash
# Sync all resources
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps -n flux-system

# Sync specific HelmRelease
flux reconcile hr myapp -n media --with-source
```

---

## Adding Secrets via ExternalSecrets/1Password

### Workflow

1. **Add secret to 1Password** - Create item with fields matching expected keys
2. **Create ExternalSecret manifest** - `secrets.yaml` in app directory
3. **Reference in HelmRelease** - `envFrom` or `env` with `secretRef`
4. **Add to kustomization.yaml** - Include `secrets.yaml` in resources
5. **Deploy** - Validate, commit, push

### SOPS-Encrypted Secrets (Alternative)

For bootstrap/Talos secrets not in 1Password:

```bash
# Create secret file (must end in .sops.yaml)
# Encrypt
sops --encrypt --in-place kubernetes/main/apps/media/myapp/app/secret.sops.yaml

# Re-encrypt all secrets (after key rotation)
task sops:re-encrypt
```

---

## Troubleshooting HelmRelease Failures

### Check HelmRelease Status

```bash
# All HelmReleases across all namespaces
flux get helmreleases -A

# Specific HelmRelease
flux get helmrelease myapp -n media

# Detailed events
kubectl describe hr myapp -n media
```

### Common Failure Modes

| Symptom                       | Cause                              | Fix                                                    |
| ----------------------------- | ---------------------------------- | ------------------------------------------------------ |
| **Install Retries Exhausted** | Missing dependency, invalid values | Check controller logs, verify dependencies exist       |
| **Upgrade Failed**            | Chart compatibility issue          | Review chart version, check breaking changes           |
| **Reconciliation Suspended**  | Manual suspension                  | `flux resume hr myapp -n media`                        |
| **Secret not found**          | ExternalSecret not synced          | Check `kubectl get es -n media`                        |
| **Image pull error**          | Invalid digest, registry auth      | Verify image exists, check imagePullSecrets            |

### View Logs

```bash
# Helm controller logs
kubectl logs -n flux-system deploy/helm-controller --tail=100

# App pod logs
kubectl logs -n media -l app.kubernetes.io/name=myapp

# Previous crash logs
kubectl logs -n media -l app.kubernetes.io/name=myapp --previous
```

### Suspend/Resume HelmReleases

```bash
# Suspend (stops reconciliation)
flux suspend hr myapp -n media

# Resume
flux resume hr myapp -n media
```

---

## Checking Flux Reconciliation Status

### Overall Cluster Health

```bash
# Kustomizations
flux get kustomizations

# HelmReleases
flux get helmreleases -A

# GitRepositories
flux get sources git

# HelmRepositories
flux get sources helm
```

---

## Validating Manifests Before Push

### Kubeconform Validation

```bash
task kubernetes:kubeconform
```

### What It Checks

- YAML syntax validity
- Kubernetes API schema compliance
- CRD validation (Flux, Gateway API, etc.)
- Kustomize build correctness

### Common Validation Errors

| Error                      | Cause                         | Fix                                     |
| -------------------------- | ----------------------------- | --------------------------------------- |
| **Invalid YAML**           | Syntax error                  | Check indentation, quotes, line breaks  |
| **Unknown field**          | Typo or wrong API version     | Verify field names, check API version   |
| **Missing required field** | Incomplete spec               | Add required fields per schema          |
| **Kustomize build failed** | Missing resource or bad patch | Check kustomization.yaml resources list |

---

## Managing Storage

### Rook-Ceph Storage

```bash
# Ceph status (via toolbox)
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# OSD status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status

# Pool usage
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph df
```

### Troubleshoot PVC not binding

```bash
kubectl get pvc -n media
kubectl describe pvc myapp-data -n media
kubectl logs -n rook-ceph deploy/rook-ceph-operator --tail=100
```

### NFS Storage

NFS mounts are direct in HelmRelease persistence section (no PVC needed):

```yaml
persistence:
  media:
    enabled: true
    type: nfs
    server: 172.16.2.246
    path: /volume1/media
    globalMounts:
      - path: /media
```

---

## Checking Cluster Health

### Node Status

```bash
kubectl get nodes
kubectl top nodes
```

### Pod Health

```bash
# All pods
kubectl get pods -A

# Failed/pending pods
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

### Certificate Status

```bash
kubectl get certificates -A
kubectl get certificaterequests -A
```

---

## Working with Talos Nodes

### Common Talos Commands

```bash
# Check cluster health
talosctl health --nodes <node-ip>

# Node dashboard
talosctl dashboard --nodes <node-ip>

# View logs
talosctl logs --nodes <node-ip> --tail 100

# Reboot node
talosctl reboot --nodes <node-ip>

# Apply configuration
talosctl apply-config --nodes <node-ip> --file kubernetes/main/talos/nodes/k8s-1.yaml
```

### Node Maintenance

```bash
# Drain node before maintenance
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Uncordon after maintenance
kubectl uncordon <node-name>
```

---

## Common Debugging Commands

```bash
# List all HelmReleases
flux get hr -A

# List all Kustomizations
flux get ks

# List all ExternalSecrets
kubectl get es -A

# List all HTTPRoutes
kubectl get httproutes -A

# List all Gateways
kubectl get gateways -A

# Network debugging pod
kubectl run -it --rm debug --image=nicolaka/netshoot -- bash
```

### Check Specific App

```bash
# HelmRelease status
flux get hr myapp -n media

# ExternalSecret status
kubectl get es myapp -n media

# Pod status
kubectl get pods -n media -l app.kubernetes.io/name=myapp

# Pod logs
kubectl logs -n media -l app.kubernetes.io/name=myapp --tail=100

# Pod events
kubectl describe pod <pod-name> -n media

# Service endpoints
kubectl get endpoints myapp -n media

# HTTPRoute status
kubectl describe httproute myapp -n media
```

---

## Database Operations (CloudNative-PG)

### Check Cluster Status

```bash
kubectl get clusters.postgresql.cnpg.io -A
kubectl describe cluster immich -n database
kubectl get pods -n database -l cnpg.io/cluster=immich
```

---

**See Also**:

- `ARCHITECTURE.md` - System architecture and component relationships
- `CONVENTIONS.md` - Naming, structure, and style conventions
- `NETWORKING.md` - Traffic flows, DNS, and routing
- `TOOLS.md` - CLI tools and command reference
