# Talos Linux Upgrade: v1.12.6 → latest stable (2026-06)

## Question
For our bare-metal homelab (3 CP + 3 worker, k8s v1.35.3, Image Factory schematic with
i915 + intel-ucode), what is the upgrade path from the deployed Talos **v1.12.6** to the
current latest stable — and how urgent is it?

## TL;DR
- **Latest stable is v1.13.4** (2026-06-09). 1.14 is not released — only `v1.14.0-alpha.x`.
- **Our 1.12.6 is EOL.** Per the official support matrix, Talos 1.12 community support
  ended at the **1.13.0 release (2026-04-27)**. Sidero maintains ~2 minors at a time, so
  1.12 is out of the window (1.12.8 on 2026-05-22 was a courtesy tail patch; the line is
  past community support). This makes the upgrade a **maintenance/EOL-driven should-do**,
  not an emergency — no critical CVE forces it today.
- **Single minor hop: 1.12.6 → 1.13.4 directly.** Talos forbids skipping *minor* versions,
  but 1.12→1.13 is one minor, so a direct hop to the latest 1.13 patch is the supported path.
- **No forced Kubernetes bump.** Talos 1.13 supports k8s 1.31–1.36; our 1.35.3 is in range.
  Do **Talos-only first, k8s later** (staged) — but only on **1.13.3+** (a 1.13.2 regression
  crashed kube-scheduler when k8s stayed on 1.35; fixed in 1.13.3, hardened in 1.13.4).
- **Extensions do NOT auto-carry.** The upgrade installer image must itself be built from our
  schematic. Use the Image Factory `metal-installer/<schematic-id>:v1.13.4` URL, not the
  plain `ghcr.io/siderolabs/installer`. i915 + intel-ucode both still exist in release-1.13.

## Deployed vs latest vs supported status
| | Deployed | Latest stable | Latest 1.12 patch |
|---|---|---|---|
| Talos | **v1.12.6** | **v1.13.4** (2026-06-09) | v1.12.8 (2026-05-22) |
| Talos minor support | **EOL** — 1.12 EoCS at 1.13.0 (2026-04-27) | supported until 1.14.0 (~2026-08-30 TBD) | — |
| Kubernetes | v1.35.3 | 1.13 supports 1.31–1.36 (in range) | 1.12 supports 1.30–1.35 |
| Bundled k8s in target | — | k8s 1.36.1 (default, not required) | — |

Releases between 1.12.6 and latest: 1.12.7, 1.12.8 (1.12 line) · **1.13.0** (2026-04-27),
1.13.1, 1.13.2, 1.13.3, **1.13.4** (2026-06-09). 1.14.0-alpha.0/alpha.1 are pre-release.

## Breaking / notable changes 1.12.6 → 1.13.4
Source: 1.13.0 release notes (everything below lands when we cross the minor boundary).

| Area | Change | Impact for us |
|---|---|---|
| Component bumps | Linux 6.18.34, etcd 3.6.12, containerd 2.2.x, runc 1.4.2, CoreDNS 1.14.2, Flannel 0.28.5, k8s 1.36.1 bundled | Kernel/etcd/containerd jump is significant but standard; etcd 3.6.x quorum-protected upgrade handled by Talos. We don't use Flannel (Cilium CNI). |
| Kernel | Now built with **Clang + ThinLTO**; dynamic preemption default on amd64; `proc_mem.force_override=never` default | No config impact; behavioural/security hardening only. |
| Machine config | `.machine.env` superseded by `EnvironmentConfig` doc; `.machine.network.kubespan` → `KubeSpanConfig` doc (back-compat kept); `EtcdConfigs`/`KubeletConfigs`/etc. protobuf `map<string,string>`→`map<string,message>` | We use neither kubespan nor those protobuf resources directly. `.machine.env` deprecation is back-compat; review if our Talos config sets it. |
| Resolver | `nameservers` in machine config now **overwrites** prior layers instead of smart-merge | Check our Talos config doesn't rely on merged DNS layers. |
| Upgrade flags | `--force`, `--insecure`, **`--preserve`**, `--stage` **deprecated**, removal in **1.18** | See "Upgrade safety" — preserve is now default; don't pass `--preserve` reflexively on 1.13. |
| Cilium / kube-proxy | No 1.13 breaking changes affecting external CNI / kube-proxy-replacement | Cilium eBPF setup unaffected by the OS bump. Validate post-upgrade as usual. |
| Extensions / Factory | i915 (drm, core tier) and intel-ucode (firmware, core tier) **both present in release-1.13** | Extensions must be re-included via the target-version installer image (see below). |

Known regression worth noting: **Talos 1.13.2** rendered k8s-1.36 scheduler fields
(`placementGenerate`/`placementScore`) into a v1.35 kube-scheduler config → scheduler
CrashLoopBackOff (issue #13350). **Fixed in 1.13.3** ("rework how scheduler config is
marshaled") and hardened in 1.13.4. → If we go to 1.13.4, the staged "Talos-on-1.13 + k8s
still-1.35" state is safe. Do **not** stop on 1.13.2.

## Kubernetes coupling
- Talos 1.13 support matrix: **k8s 1.36, 1.35, 1.34, 1.33, 1.32, 1.31**. Our **1.35.3 is
  supported** — no forced k8s bump.
- Talos 1.12 supports k8s 1.30–1.35, so 1.35.3 is also fine on the current OS.
- **Staged approach is supported and safer:** upgrade Talos OS to 1.13.4 first (k8s stays
  1.35.3), verify, then later run `talosctl upgrade-k8s` to 1.36 as a separate change.
  This is exactly the path the community 1.12.6→1.13.0 case (dbirks/home-k8s #47) plans
  (Talos first, verify, then k8s). Caveat: only valid on 1.13.3+ per the #13350 regression.

## Upgrade safety notes (from official docs)
- **No skipping minors:** *"the recommended upgrade path is to always upgrade to the latest
  patch release of all intermediate minor releases."* 1.12→1.13 is one minor → **direct hop
  to 1.13.4 is correct**; no intermediate stop needed.
- **etcd quorum protection (CP nodes):** *"Talos will refuse to upgrade a control plane node
  if that upgrade would cause a loss of quorum for etcd … only one control plane node
  actively upgrades at any time."* Roll nodes one at a time; Talos self-serialises CP.
- **Image Factory installer (load-bearing):** extensions do **not** carry forward
  automatically — *"generate a custom installer container for a new version of Talos … and
  perform upgrade pointing to the custom installer image."* Use:
  `talosctl upgrade --nodes <ip> --image factory.talos.dev/metal-installer/<schematic-id>:v1.13.4`
  Our recorded schematic ID is `4b3cd373a192c8469e859b7a0cfbed3ecc3577c4a2d346a37b0aeff9cd17cdb0`
  (i915 + intel-ucode). **Verify it resolves on factory.talos.dev for v1.13.4 before the run**
  (the URL prefix is now `metal-installer/`, not the older `installer/`).
- **`--preserve`:** deprecated in 1.13 (removal 1.18). On 1.13 the upgrade preserves
  ephemeral/data by default; prefer not passing the legacy flag. Confirm current `--preserve`
  default semantics against the 1.13 upgrade guide at execution time.
- **Per-node, validate between:** boot disk `/dev/nvme0n1` (CP) / NVMe boot (workers); Ceph
  OSD on `/dev/sda` (workers) must stay untouched — an EPHEMERAL wipe would not hit `/dev/sda`
  but confirm OSDs `up/in` after each worker. Drain-and-wait between workers for Ceph health.

## Recommendation framing (decision is the user's)
- **Urgency: moderate, EOL-driven — not an emergency.** 1.12.6 is past community support; no
  newer 1.12 security patches are guaranteed. No critical CVE in the 1.12.6→1.13.4 range was
  found in release notes (fixes are stability/bug, not disclosed CVEs). The driver is "stay
  on a supported line," not "patch now."
- **Target 1.13.4 specifically** (not 1.13.2). Direct single hop, no k8s bump required.
- **Sequence:** Talos OS 1.12.6→1.13.4 (staged, CP first one-by-one, then workers with Ceph
  health gates), verify Cilium + Ceph + workloads, **then** a separate later change for
  k8s 1.35.3→1.36. Treat both as **high risk** (Talos config = high per CMDB tiers); this
  doc is research only.

## Sources (all live-fetched 2026-06-16; official docs distinguished from community)
- Talos releases (latest = v1.13.4, 2026-06-09; release list) — https://github.com/siderolabs/talos/releases — *official*
- v1.13.4 release notes (Linux 6.18.34, etcd 3.6.12, k8s 1.36.1, scheduler int-types fix) — https://github.com/siderolabs/talos/releases/tag/v1.13.4 — *official*
- v1.13.0 release notes (breaking changes, component bumps, deprecations) — https://github.com/siderolabs/talos/releases/tag/v1.13.0 — *official*
- v1.13.3 release notes ("rework how scheduler config is marshaled") — https://github.com/siderolabs/talos/releases/tag/v1.13.3 — *official*
- Support matrix v1.13 (1.12 EoCS = 1.13.0 / 2026-04-27; k8s 1.31–1.36) — https://docs.siderolabs.com/talos/v1.13/getting-started/support-matrix (raw mdx via siderolabs/docs) — *official*
- Upgrading Talos guide v1.13 (no-skip-minors; CP quorum protection; --image; --preserve deprecation) — siderolabs/docs `.../lifecycle-management/upgrading-talos.mdx` (raw) — *official*
- System extensions guide v1.13 (custom installer per version; extensions not auto-carried) — siderolabs/docs `.../system-extensions.mdx` (raw) — *official*
- Boot assets / Image Factory v1.13 (factory.talos.dev metal-installer/<schematic>:<ver> pattern) — siderolabs/docs `.../boot-assets.mdx` (raw) — *official*
- Extensions repo release-1.13 (i915 = drm/core, intel-ucode = firmware/core both present) — https://github.com/siderolabs/extensions/tree/release-1.13 — *official*
- Issue #13350 (1.13.2 kube-scheduler regression on k8s 1.35; closed/Done) — https://github.com/siderolabs/talos/issues/13350 — *official tracker*
- dbirks/home-k8s #47 (community 1.12.6→1.13.0 + k8s 1.35→1.36 staged plan) — https://github.com/dbirks/home-k8s/issues/47 — *community, corroborating only*

Freshness note: WebFetch on `docs.siderolabs.com` HTML returns a JS shell; all doc quotes
above were taken from the **raw `.mdx`** in `siderolabs/docs` (main branch, v1.13 tree),
which is the authoritative static source. v1.14 is alpha-only as of 2026-06-16; no GA.

— Athena
