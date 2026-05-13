# 0001 — Accept cluster-admin RBAC for Flux core controllers

Status: accepted
Date: 2026-05-13
Decision-makers: user (Sander), Atlas, Argus

## Context

Argus's weekly posture scan (first run 2026-05-13, `chg-2026-05-13-008`) flags
three `ClusterRoleBinding` resources that grant `cluster-admin`:

| Binding | Subject |
|---|---|
| `cluster-reconciler-flux-system` | `ServiceAccount/kustomize-controller/flux-system` |
| `cluster-reconciler-flux-system` | `ServiceAccount/helm-controller/flux-system` |
| `flux-operator` | `ServiceAccount/flux-operator/flux-system` |

These bindings exist because **Flux v2 needs cluster-admin to apply arbitrary
cluster resources from the repo**: HelmReleases create Helm chart resources of
any kind across any namespace; Kustomizations apply manifests of any kind across
any namespace. Both controllers must be able to create / patch / delete every
API resource type, or GitOps simply stops working.

This is the upstream design — see the [Flux RBAC guide](https://fluxcd.io/flux/security/multi-tenancy/),
which explicitly notes that without further isolation, the controllers need
cluster-admin or equivalent.

## Decision

**Accept** the cluster-admin grants on `kustomize-controller`,
`helm-controller`, and `flux-operator` in the `flux-system` namespace.

## Alternatives considered

1. **Scope down via custom ClusterRole** — list every resource type Flux
   applies in this cluster (Deployments, Services, Secrets, HelmReleases,
   Kustomizations, …, plus every CRD's custom kinds, plus everything Renovate
   might introduce next month). Practical maintenance burden = high; first
   missed CRD type = GitOps stalled mid-flight = sev2 incident.
   **Rejected** — maintenance cost outweighs realised benefit for a homelab.

2. **Multi-tenant Flux setup** — one Flux per namespace, each with namespace-
   scoped RoleBindings. Doubles the operator count, complicates dependency
   ordering, requires every shared CRD to be redeclared. Adds permanent
   complexity for an environment with a single operator (Sander).
   **Rejected** — wrong tradeoff for this scale.

3. **OPA/Kyverno admission policies on top of cluster-admin** — keep the
   binding, layer a policy engine that denies "dangerous" operations.
   **Deferred** — worthwhile, but separate work; doesn't make today's binding
   any less cluster-admin and doesn't change Argus's finding.

## Consequences

A compromise of any of these controllers' pods is equivalent to cluster
compromise. Mitigations in place that make this acceptable:

- **Signed-commits + branch protection** on `vdhict/vdhinfra` — Flux only
  reconciles what's in `main`, and `main` only takes commits via PR review
  (with the user's explicit GitHub App attestation in Renovate's case).
- **Image pinning with SHA digests** on all Flux components (Renovate keeps
  these current).
- **No public webhook endpoint** for Flux — reconciliation is pull-based.
- **The controllers' pods are in `flux-system`** — a namespace nothing else
  schedules workloads into.
- **SOPS-encrypted secrets** — even with cluster-admin, the controllers
  can't decrypt secrets at rest without the age key (mounted from
  `cluster-health-secret` only on read).
- **Backups** (Rook-Ceph + VolSync + Azure offsite mirror) — recovery path
  exists if a compromise modifies state.

## Review

Revisit when any of the following become true:

- Flux v2 supports finer-grained RBAC out of the box (the Flux team has open
  RFCs on this — track upstream).
- We add multi-user / multi-team usage of this cluster (then the multi-tenant
  setup becomes worth the complexity).
- An external audit (formal pentest by Pan, or a third-party engagement)
  produces a specific reason this is unacceptable here.

Otherwise this ADR is reviewed annually.

## Related

- Memory: `security-audits`
- Posture scan: `chg-2026-05-13-008` (first surfaced)
- Accepted risk id: `ar-001` (see `ops/accepted_risks.yaml`)
