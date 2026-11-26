# 0009: The VDHICT `docker` runner runs off-cluster, in a VM on LAB-VLAN

Status: proposed
Date: 2026-10-05
Decision-makers: user (via myPKA orchestrator), infra-ops, k8s-engineer, udm-engineer, security-engineer
Design: `docs/design/forgejo-runner.md` (chg-2026-10-05-032); implementation chg-2026-10-05-031

## Context

Org VDHICT needs a Forgejo Actions runner with label `docker`. Its first job is the passkey-point compliance workflow: build, scan, sign, push to the forge registry. Any writer in any VDHICT repo can add a workflow, and third-party actions are fetched at run time, so every job has to be treated as hostile.

A `docker` label means the job controls a Docker daemon. On Kubernetes that daemon needs `privileged: true`, and Docker states the rootless DinD image needs it too. Privileged access means node root. The cluster has only three schedulable workers, and all three run family-critical pods (HA stack, z2m, zwave, postgres16, authelia, family-ai, Flux, envoy), so no node can be dedicated to CI. Rootless BuildKit avoids `privileged`, but it needs Unconfined seccomp (forbidden by PSA baseline) or user namespaces (a Talos change on every worker), and it removes `docker` semantics anyway. Forgejo Runner has no first-party Kubernetes executor. The v13.1 plugin protocol is alpha, and the existing plugins are third-party, which conflicts with the vendor-images-only rule.

## Decision

We do not run the `docker` runner on this cluster. forgejo-runner v13.2.0 runs in a dedicated Linux VM whose only NIC is on LAB-VLAN 60 (fixed 172.16.6.20, no inbound). The VM gets full Docker semantics, and the VM itself is the isolation boundary. The default host is the Mac Studio (no shared folders, VLAN 60 tagged on its port). The alternative is a dedicated x86 box, which needs the owner because it is a purchase. The UDM Lab zone enforces egress: internet 80/443 plus one new allow to a new single-hostname Gateway `envoy-forge`, so jobs cannot reach the other envoy-internal hostnames. The registration token never enters the cluster. It is regenerated after registration.

## Consequences

- Enables: unmodified workflows; isolation that can be proven with UDM hit counters and pcaps; no new privileged or PSA exemption on family nodes; Argus sec-03 is not triggered, because devtools gets no attacker-controlled pods.
- Constrains: the runner is not Flux-managed. Its config lives in Git (`hack/forgejo-runner/`), and myPKA operates the instance. LAB-VLAN becomes a long-lived dependency, beyond the 2026-10-29 Passkey teardown. arm64 hosting needs amd64 cross-builds. A hostile job can persist in the VM between jobs (capacity 1, monthly rebuild).
- Owes: the `envoy-forge` Gateway, one UniFi policy and a port-24 VLAN tag (high); CMDB entries; Argus answers A1-A6; a decision on repo-scope versus org-scope registration and on secret scoping for the registry token and cosign key.
- Revisit: when Forgejo ships a first-party Kubernetes backend, or when the cluster gains a node that can be dedicated to untrusted workloads.

## Related

- Changes: chg-2026-10-05-031, chg-2026-09-15-003 (P7 "Studio runner"), chg-2026-09-18-003 (Argus sec-01/sec-03, FORCE_PRIVATE), chg-2026-10-05-008 (LAB UniFi build)
- ADR 0007 (LAB VLAN), ADR 0008 (image signature admission)
- CMDB `k8s.devtools.forgejo`, `hw.mac.studio`, `net.vlan.lab`, `net.firewall.zone.lab`
- Memory: `vendor-images-only`, `flux-deploys-from-main`, `security-review-is-a-gate`, `test-evidence-required`
