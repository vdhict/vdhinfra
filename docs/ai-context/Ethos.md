---
description: Documentation philosophy, hard rules, and values for vdhinfra AI context
tags: ["Philosophy", "Documentation", "Ethos", "Principles"]
audience: ["LLMs", "Humans"]
categories: ["Meta[100%]", "Guidance[95%]"]
---

# Ethos: Documentation Philosophy and Principles

**Purpose**: The values, principles, and rules that guide what we capture in this knowledge base.

**Audience**: AI agents and humans contributing to repository documentation.

---

## The Philosophy

This knowledge base exists to answer: **"How does this homelab infrastructure work as a coherent whole?"**

Not "how do I use kubectl?" or "what's the Helm chart syntax?" - those belong in external docs. This is the **context layer** that explains why the system is designed this way, how components relate, and what invariants must be preserved.

**After 10-15 minutes reading**, you should understand:

1. **What it does** - GitOps-managed single Kubernetes cluster on bare metal
2. **How it does it** - Flux + Talos + SOPS/Age + 1Password
3. **What must stay true** - Invariants and constraints
4. **How to find more** - Pointers to specific manifests and configs

---

## The Hard Rules (Never Violate)

These are non-negotiable. Violating them undermines the entire knowledge base.

### Rule 1: Only Record What You Can Verify

**Why**: Wrong information is worse than missing information.

**Hierarchy of evidence** (prefer higher levels):

1. **Code** - Directly observed in manifests, Taskfile, scripts
2. **Documentation** - Stated in existing docs or READMEs
3. **Synthesis** - Derived from multiple verified sources
4. **User** - Confirmed by the operator
5. **Intuition** - Inferred from patterns (mark as low confidence)

### Rule 2: When in Doubt, Omit

**Why**: Missing information prompts questions. Wrong information causes failed deployments and wasted debugging.

Better to say "see the HelmRelease for details" than guess incorrectly.

**The cost calculation**:

- **Wrong information** - Incorrect manifests, broken deployments, hours of debugging
- **Missing information** - Extra research time, asking for clarification

Missing is recoverable. Wrong is destructive.

### Rule 3: Never Use Actual Domain Names or Secrets

**Why**: This is a public repository. Actual values leak information and create security exposure.

**Always use placeholders**:

- `${SECRET_DOMAIN}` - The primary domain (in hostnames, URLs, DNS records)
- `${SECRET_*}` - Any other sensitive values from 1Password
- `<REDACTED>` - When showing example values in documentation

**In documentation**:

- Write `app.${SECRET_DOMAIN}` not the actual URL
- Write `id.${SECRET_DOMAIN}` not the actual identity provider URL
- Use "DOMAIN" in ASCII diagrams where variable syntax breaks formatting

**The test**: Grep for known secrets should return zero results in docs.

---

## Strong Guidance (Follow Unless You Have Good Reason)

These patterns create durable, useful documentation. Deviation should be intentional and justified.

### Capture Temporally Stable Information

**Prefer documenting**:

- Architectural patterns (GitOps, Flux reconciliation, Talos immutability)
- Infrastructure constraints (SOPS encryption, 1Password integration, storage requirements)
- Operational invariants (never edit generated files, never commit plaintext secrets)
- Critical dependencies (Flux depends on secrets, pods depend on PVCs)

**Avoid documenting**:

- Specific versions ("Flux 2.3.0") - unless they create understanding
- Point-in-time info ("recently added", "planned upgrade")
- Configuration values (belong in manifests)
- Step-by-step tutorials (belong in external docs)
- Exact counts ("47 HelmReleases") - unless critical to understanding

**The test**: Will this still be true in 6 months? If not, consider omitting.

### Document Shape, Not Detail

**Good**: "Each app follows the install.yaml + HelmRelease + ExternalSecret triad"

**Bad**: "The immich app has env vars IMMICH_DB_HOST, IMMICH_DB_PORT, IMMICH_DB_NAME..."

**Why**: Implementation details change. The conceptual structure persists.

### Focus on Why, Not Just What

**Good**: "Secrets use 1Password because the repo is public and values must not be committed"

**Bad**: "Add ExternalSecret with onepassword-connect store reference"

**Why**: The "why" teaches the principle. The "what" becomes obvious once you understand why.

### Document Patterns, Not Instances

**Good**: "HelmReleases define persistence sections with existingClaim, tmpfs, or NFS mounts"

**Bad**: "immich uses immich-data claim, plex uses plex-data claim, sonarr uses..."

**Why**: Patterns are durable. Instance lists go stale and create maintenance burden.

### Provide Trails, Not Destinations

**Good**: "For storage configuration, see kubernetes/main/apps/media/immich/app/helmrelease.yaml"

**Bad**: Duplicating the entire persistence section here

**Why**: This knowledge base points to specific locations; it doesn't replace reading the actual configs.

---

## The Values (These Guide Our Choices)

### We Value Context Over Completeness

Every component must answer: **"Where does this fit in the wider system?"**

Required context:

- What layer? (Flux, Talos, app, infrastructure)
- What depends on this? (blast radius)
- What does this depend on? (prerequisites)
- What breaks if this changes?

### We Document Non-Obvious Truths

Capture things that:

- Surprise newcomers to the system
- Waste significant time when misunderstood
- Reflect infrastructure complexity (not just tooling quirks)
- Matter in operations (not just theory)

Examples:

- Flux reverts manual kubectl changes (GitOps fundamental)
- ExternalSecrets must sync before pods can start (ordering dependency)
- SOPS-encrypted files must end in `.sops.yaml` (convention enforced by `.sops.yaml` config)

### We Create Maps, Not Transcripts

**We document the durable conceptual structure**, not the ephemeral implementation details.

**We capture why the system exists and how components relate**, then point to manifests for specifics.

---

## When to Break the Guidance

The strong guidance exists to create durable, useful documentation. But **if breaking it aids understanding, break it**.

**Example**: We generally avoid specific timings. But "Flux reconciles every 1 hour" substantially improves understanding of operational behavior. Keep it.

**The test**: Does this create the "aha!" moment? Does it explain why the system works this way? If yes, keep it even if it technically violates guidance.

**Remember**: The hard rules are never negotiable. The guidance is strong but not absolute.

---

## Hierarchy

1. **Hard Rules** - Never violate
2. **Strong Guidance** - Follow unless you have good reason
3. **Philosophy** - Understand the why behind our choices
