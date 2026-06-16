# Runbook: Talos OS rolling upgrade v1.12.6 → v1.13.4 (Kubernetes UNTOUCHED)

**Audience**: operator (Sander) at a terminal that can reach the nodes on `:50000`, with Heph (k8s-engineer) and Atlas verifying live state between nodes.
**Risk tier**: **HIGH** (Talos config / OS image on every node — CMDB high tier). Requires explicit user `approved` event + Themis QA pass before any node is touched.
**Goal**: bring all 6 nodes from Talos **v1.12.6 → v1.13.4**, one node at a time, never losing etcd quorum or Ceph redundancy, **leaving Kubernetes on v1.35.3 unchanged**. Return to `HEALTH_OK` / quorum / Ready between each node.

> This runbook is **doc-only**. It changes nothing in production. Execution is a separate high-risk change.
> **Sandbox limitation (load-bearing):** the agent sandbox **cannot reach node `:50000`** (reject route). Every `talosctl` / `just main talos upgrade-node` / `apply-node` command in this runbook MUST be run from the **operator's terminal**. Only the Git edits and `generate-config` (no node contact) can be done by the agent.

---

## 0. Scope, summary, version table

**Why now:** Talos **1.12 is EOL** — community support ended at the 1.13.0 release (2026-04-27). 1.12.8 (2026-05-22) was a courtesy tail patch; the line is past support. **Urgency is moderate, EOL-driven — not an emergency.** No critical CVE in the 1.12.6→1.13.4 range. The driver is "stay on a supported line."

**What this change is:** a **Talos-only** OS upgrade. Direct single-minor hop 1.12.6 → 1.13.4 (Talos forbids skipping minors; 1.12→1.13 is one minor, so the latest 1.13 patch is the supported target — no intermediate stop).

**What this change is NOT:** the Kubernetes 1.35.3 → 1.36 bump is **explicitly out of scope** and is a **separate future change**. Talos 1.13 supports k8s 1.31–1.36, so 1.35.3 is in range and stays put.

| | Current | Target | Notes |
|---|---|---|---|
| Talos | **v1.12.6** | **v1.13.4** | latest stable (2026-06-09); 1.14 is alpha-only |
| Kubernetes | **v1.35.3** | **v1.35.3 (unchanged)** | in 1.13's supported range 1.31–1.36; bump is a later change |
| talosctl client | v1.13.4 (mise-pinned) | v1.13.4 | already matches target — no client change needed |
| Factory schematic | `4b3cd373…cdb0` (i915 + intel-ucode) | **unchanged** | i915 + intel-ucode both present in release-1.13; no schematic regen |
| Installer URL prefix | `installer/` | `metal-installer/` | aliases (identical digest) on 1.13.4; `metal-installer/` is canonical going forward |

**Why 1.13.4 specifically and not 1.13.2:** Talos **1.13.2** had a kube-scheduler regression (#13350) — it rendered k8s-1.36 scheduler fields into a v1.35 scheduler config and crash-looped the scheduler. **Fixed in 1.13.3, hardened in 1.13.4.** Because we keep k8s on 1.35, **pin 1.13.4** so the "Talos-on-1.13 + k8s-still-1.35" staged state is safe. **Do not stop on 1.13.2.**

**Cross-references (read, don't re-read here):**
- Research basis: `docs/research/talos-upgrade-1.12-to-latest-2026-06.md` (Athena) — version matrix, EOL status, breaking changes, source citations.
- **Ceph-gate pattern**: `docs/runbooks/ceph-osd-disk-replacement.md` §1 / §4 — the "one OSD down → wait for `active+clean` before touching the next host" gate. **This runbook reuses that exact gate** for every worker reboot (a worker reboot takes its one OSD down). Do not duplicate it; apply it.

---

## ⚠️ 1. Pre-flight gate — must be ALL GREEN before starting

> ABORT (do not touch any node) if any check below fails. Run from the operator terminal (cluster reads) + agent (Git/Factory checks).

```bash
TOOLS="kubectl -n rook-ceph exec deploy/rook-ceph-tools --"
```

```
□ 1. Ceph HEALTH_OK
     $TOOLS ceph status
     ACCEPTABLE: HEALTH_OK, or HEALTH_WARN whose ONLY warnings are the chronic
     BLUESTORE_SLOW_OP_ALERT (+ DB_DEVICE_STALLED_READ_ALERT on osd.0). ABORT on anything else.

□ 2. All PGs active+clean — NO recovering/backfilling/degraded/remapped
     $TOOLS ceph pg stat            # expect: "81 pgs: 81 active+clean"
     >>> CONFIRM the WD Red OSD backfill from the disk-swap is FULLY SETTLED. If any
         backfill/recovery is still in flight, ABORT and wait. (Same gate as the OSD runbook.)

□ 3. 3 OSDs up AND in
     $TOOLS ceph osd tree           # expect 3 osds, each "up 1.00000", reweight 1.00000

□ 4. mon quorum 3/3
     $TOOLS ceph mon stat           # expect 3 mons in quorum

□ 5. 6 nodes Ready, all on v1.12.6 / k8s v1.35.3
     kubectl get nodes -o wide
     kubectl get nodes -o custom-columns=NAME:.metadata.name,\
KUBELET:.status.nodeInfo.kubeletVersion,OSIMAGE:.status.nodeInfo.osImage
     # expect all Ready; kubelet v1.35.3; osImage shows Talos v1.12.6

□ 6. etcd healthy (run from operator terminal — needs :50000)
     talosctl -n 172.16.2.84 etcd status
     # expect 3 members, all healthy, one leader, raft index converged

□ 7. Flux fully reconciled (no failing/suspended Kustomizations or HelmReleases)
     flux get kustomizations -A | grep -v "True" || echo "all reconciled"
     flux get helmreleases -A   | grep -v "True" || echo "all reconciled"

□ 8. FRESH backups
     - CNPG: latest daily base backup < 24h old
       kubectl -n database get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp | tail -3
     - VolSync: all ReplicationSource last-sync recent (no overdue)
       kubectl get replicationsources -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,LAST:.status.lastSyncTime

□ 9. Factory installer resolves (RE-CONFIRM AT EXECUTION TIME — agent can run this)
     SCHEMATIC=4b3cd373a192c8469e859b7a0cfbed3ecc3577c4a2d346a37b0aeff9cd17cdb0
     curl -sSI "https://factory.talos.dev/metal-installer/${SCHEMATIC}:v1.13.4" | head -1
     # expect: HTTP 200. Verified this session digest sha256:22735af5…de76fd.
     # NOTE: installer/ and metal-installer/ are ALIASES on 1.13.4 (identical digest, both 200);
     #       we adopt metal-installer/ as the canonical forward path.

□ 10. talosctl client = v1.13.4 (operator terminal)
     talosctl version --client    # expect Client v1.13.4 — already matches target, no change
```

**ABORT CONDITIONS — do not start if any are true:**
- Any PG not `active+clean`, or any Ceph backfill/recovery still running (incl. unsettled WD Red backfill).
- Any OSD down/out, fewer than 3 mons, any pool `size < 3`.
- Any node NotReady, or any node not on v1.12.6 / v1.35.3.
- etcd not 3/3 healthy.
- Any Flux Kustomization/HelmRelease not reconciled.
- CNPG daily backup ≥ 24h old, or any VolSync source overdue.
- Factory `metal-installer/…:v1.13.4` does not return HTTP 200.

---

## 2. Git changes (do FIRST, review + merge BEFORE any node is touched)

These edits are config-only and contact no node — **the agent (Heph) can make and commit them**. They must be merged and Flux-clean before the operator runs a single `upgrade-node`.

### 2a. `kubernetes/main/talos/talenv.yaml` — bump Talos version only

```yaml
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
talosVersion: v1.13.4          # was: v1.12.6
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetesVersion: v1.35.3     # UNCHANGED — do NOT touch
```

### 2b. `kubernetes/main/talos/talconfig.yaml` — 6× `talosImageURL` prefix `installer/` → `metal-installer/`

The schematic ID is **unchanged**. Only the path prefix changes, on **all six** node entries (lines 29, 49, 69, 91, 108, 125). Each line goes from:

```
    talosImageURL: factory.talos.dev/installer/4b3cd373a192c8469e859b7a0cfbed3ecc3577c4a2d346a37b0aeff9cd17cdb0
```

to:

```
    talosImageURL: factory.talos.dev/metal-installer/4b3cd373a192c8469e859b7a0cfbed3ecc3577c4a2d346a37b0aeff9cd17cdb0
```

> Optional but tidy: the Renovate comment on `talenv.yaml` still points at `ghcr.io/siderolabs/installer` for version discovery — that's fine; it's only the datasource for the version string, not the image actually pulled. Leave it.

### 2c. Regenerate per-node config (agent OK — no node contact)

```bash
just main talos generate-config
# runs: cd kubernetes/main/talos && talhelper genconfig
# regenerates clusterconfig/<node>.yaml for all 6 nodes with:
#   machine.install.image = factory.talos.dev/metal-installer/4b3cd373…:v1.13.4
```

### 2d. Verify the generated config carries the new image, then commit

```bash
grep -h "install:" -A2 kubernetes/main/talos/clusterconfig/*.yaml | grep image
# expect every node: …/metal-installer/4b3cd373…  (NO version mismatch, NO old installer/ prefix)
git diff --stat kubernetes/main/talos/
```

```
□ talenv.yaml: talosVersion v1.13.4, kubernetesVersion still v1.35.3
□ talconfig.yaml: all 6 talosImageURL lines now metal-installer/, schematic unchanged
□ clusterconfig/*.yaml regenerated; every node image = metal-installer/…:v1.13.4
□ Commit + open PR; Themis QA pass; user approval recorded
□ Flux reconciled clean after merge (the Talos config is not applied by Flux — apply is manual
  via talosctl upgrade — but keep Git the source of truth and merged before execution)
```

> **Important:** merging Git does **not** upgrade any node. The Talos OS upgrade is applied **manually**, per node, by the operator in §4 via `talosctl upgrade`. Git-first just guarantees the source of truth and the regenerated `clusterconfig/<node>.yaml` match what the operator will push.

---

## 3. Node order + the per-node gate model

### Recommended order: **WORKERS FIRST (node01 → node03 → node02), THEN control plane (master01 → master02 → master03)**

**Justification:**

1. **Validate the image on a less-critical node first.** A worker reboot does not risk the API server / etcd. If `metal-installer/…:v1.13.4` had any node-specific boot problem (it shouldn't — Factory round-trip verified — but byte-level extension verification was *not* done), we discover it on a worker, where the blast radius is one OSD + reschedulable pods, not the control plane.
2. **Etcd is self-protected.** Talos *refuses* to upgrade a CP node if doing so would lose etcd quorum, and only one CP upgrades at a time. So CP safety is enforced by Talos regardless of order; we don't gain CP safety by doing CP first. We *do* gain image-validation safety by doing workers first. → workers first wins.
3. **Each worker reboot drops its one Ceph OSD** — exactly the OSD-runbook constraint (`size: 3`, `failureDomain: host` ⇒ only ONE OSD absent at a time). Doing workers one-at-a-time with the `active+clean` gate between them satisfies this. CP nodes carry no OSD, so the Ceph gate doesn't bind on CP — but the etcd gate does.

**Within the workers, do node02 LAST** because the CNPG Postgres primary historically lands on node02. We want the cluster fully warmed up (two workers already proven on 1.13.4) before we force the CNPG failover. Order: **node01, node03, node02.**

| Step | Node | IP | Role | OSD on host? | CNPG primary? | Gate before next |
|---|---|---|---|---|---|---|
| 1 | vdhclu01node01 | 172.16.2.81 | worker | yes (osd) | no | Ceph active+clean + node Ready/v1.13.4 |
| 2 | vdhclu01node03 | 172.16.2.83 | worker | yes (osd) | no | Ceph active+clean + node Ready/v1.13.4 |
| 3 | vdhclu01node02 | 172.16.2.82 | worker | yes (osd) | **yes — failover FIRST** | Ceph active+clean + CNPG primary healthy + node Ready/v1.13.4 |
| 4 | vdhclu01master01 | 172.16.2.84 | CP | no | no | etcd 3/3 healthy + node Ready/v1.13.4 (VIP may move) |
| 5 | vdhclu01master02 | 172.16.2.85 | CP | no | no | etcd 3/3 healthy + node Ready/v1.13.4 |
| 6 | vdhclu01master03 | 172.16.2.86 | CP | no | no | etcd 3/3 healthy + node Ready/v1.13.4 |

> **NEVER upgrade two nodes at once.** Two workers ⇒ two OSDs down ⇒ PGs inactive, writes block, data-loss risk. Two CP ⇒ etcd quorum loss (Talos will refuse the second, but don't rely on it — serialise yourself).

---

## 4. Per-node upgrade sequence (operator runs talosctl; one node at a time)

> `upgrade-node` resolves the image from the node's **live machineconfig**, which must already carry `metal-installer/…:v1.13.4`. Two ways to get it there before the upgrade:
> - **(A) apply-config then upgrade** — push the regenerated config first so `machine.install.image` is the new URL, then `upgrade-node` reads it. Recommended (keeps node config and Git aligned).
> - **(B) explicit image** — skip the recipe and pass the URL directly: `talosctl -n <ip> upgrade -i factory.talos.dev/metal-installer/4b3cd373…:v1.13.4 -m powercycle --timeout=10m`.
> This runbook uses **(A)**. Confirm with the operator which they prefer; both reach the same digest.

For EACH node in the §3 order, copy this block into the change record and tick live. Substitute `<NODE>` / `<NODE_IP>`.

```
─── NODE: <NODE> (<NODE_IP>) ──────────────────────────────────────────────

□ PRE: re-run the §1 gate health checks (Ceph active+clean, etcd 3/3, all OTHER nodes Ready).
       Do NOT proceed if the previous node hasn't fully settled.

── Worker-only pre-steps (skip on CP nodes) ──
□ (node02 ONLY) Fail over CNPG primary OFF node02 BEFORE rebooting it:
     kubectl -n database get cluster postgres16 -o jsonpath='{.status.currentPrimary}{"\n"}'
     # if currentPrimary is on node02, promote a standby on another node:
     kubectl cnpg promote postgres16 <standby-pod-on-other-node> -n database
     # WAIT-FOR: currentPrimary is now NOT on node02, and the cluster reports healthy
     kubectl -n database get cluster postgres16 -o jsonpath=\
'{.status.currentPrimary} {.status.readyInstances}/{.status.instances}{"\n"}'
     # expect: primary on node01/03, readyInstances == instances (e.g. 3/3)

□ Note: the single-replica HA pod (home-assistant) on the rebooting worker will reschedule —
       expect a brief HA blip while the pod restarts on another node. This is acceptable for a
       one-node window. (HA serves again once rescheduled + DB reachable.)

── Apply new config + upgrade (operator terminal — needs :50000) ──
□ Push the regenerated config so machine.install.image = metal-installer/…:v1.13.4
     just main talos apply-node <NODE>
     # (= talosctl -n <NODE> apply-config -f clusterconfig/<NODE>.yaml)
     # confirm the node accepted it (no schema error). This does NOT reboot.

□ Run the rolling OS upgrade (Talos powercycle reboot, in-place boot-disk image swap)
     just main talos upgrade-node <NODE_IP>
     # = talosctl -n <NODE_IP> upgrade -i "$(just talos machine-image <NODE_IP>)" \
     #     -m powercycle --timeout=10m
     # Talos: pulls metal-installer image → writes boot disk → powercycle → boots 1.13.4.
     # CP nodes: Talos enforces etcd-quorum safety and serialises CP upgrades automatically.
     # NOTE: do NOT pass --preserve (deprecated on 1.13; preserve is the default behaviour).

── WAIT-FOR gates (operator + Heph/Atlas verify live) ──
□ Node returns Ready
     kubectl get node <NODE> -w     # wait STATUS=Ready, then Ctrl-C

□ Node reports Talos v1.13.4 (and k8s STILL v1.35.3)
     kubectl get node <NODE> -o custom-columns=NAME:.metadata.name,\
KUBELET:.status.nodeInfo.kubeletVersion,OSIMAGE:.status.nodeInfo.osImage
     talosctl -n <NODE_IP> version    # Server: v1.13.4
     # expect: osImage Talos v1.13.4 ; kubeletVersion STILL v1.35.3

── Worker-only post-gate (the Ceph gate — same as the OSD runbook) ──
□ The OSD on this worker went down during the reboot. WAIT for full re-peer + active+clean:
     watch -n 10 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status"
     # WAIT-FOR: "81 pgs: 81 active+clean", recovery: line gone, 3 OSDs up+in.
     # Do NOT proceed to the next node on a degraded/backfilling cluster.

── CP-only post-gate (the etcd gate) ──
□ etcd member rejoined, quorum 3/3 healthy, raft converged:
     talosctl -n 172.16.2.84 etcd status    # (or any surviving CP member)
     # WAIT-FOR: 3 members healthy, one leader, indices converged.
□ VIP 172.16.2.240 still answers (it may have moved to another CP during the reboot):
     kubectl --server=https://172.16.2.240:6443 get --raw='/readyz'    # expect: ok

□ GATE: ALL of the above green for THIS node before starting the NEXT node.
       Pause here. Atlas/Heph sign off the node in the change record (§5).
─────────────────────────────────────────────────────────────────────────
```

---

## 5. 📞 Atlas / operator check-in gates

This is a high-risk, multi-step change run by a human operator with the agents verifying. The hand-off points:

- **Before node 1:** operator confirms §1 gate green (with Heph reading Ceph/etcd/Flux/backups). Atlas confirms user `approved` event + Themis QA pass are on the change record. GO/NO-GO.
- **After EACH node:** operator runs the `talosctl` steps; **Heph reads back live state** (node Ready + Talos v1.13.4 + k8s still v1.35.3; Ceph active+clean for workers; etcd 3/3 for CP); **Atlas spot-checks one claim** (per verify-before-report) and records the per-node sign-off in the change. Only then GO for the next node.
- **node02 specifically:** Atlas confirms the CNPG primary failover landed on another node and the cluster is healthy **before** the operator reboots node02.
- **If any gate is red:** STOP. Do not start the next node. Hold on the mixed-version cluster (safe — see §7) and open an incident if it's a failure rather than a slow backfill.
- **After node 6:** run §6 end-state verification before closing the change.

> The operator owns every `talosctl`/`upgrade-node` invocation (sandbox can't reach `:50000`). The agents own the read-back verification and the change record.

---

## 6. End-state verification (before closing the change)

```
□ All 6 nodes Talos v1.13.4
     kubectl get nodes -o custom-columns=NAME:.metadata.name,OSIMAGE:.status.nodeInfo.osImage
     # every node: Talos v1.13.4

□ Kubernetes STILL v1.35.3 on every node (the whole point of this change)
     kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion
     # every node: v1.35.3  — if anything shows v1.36, STOP: k8s was bumped unintentionally
     kubectl version --short   # Server Version still v1.35.3

□ All nodes Ready
     kubectl get nodes

□ etcd 3/3 healthy
     talosctl -n 172.16.2.84 etcd status

□ Ceph HEALTH_OK, 81 PGs active+clean, 3 OSDs up+in
     kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status

□ Cilium healthy (eBPF / kube-proxy-replacement unaffected by OS bump, but confirm)
     kubectl -n kube-system exec ds/cilium -- cilium status --brief    # expect OK
     cilium connectivity test    # optional, if time permits

□ All workloads Running (no CrashLoop/Pending left from reschedules)
     kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

□ CNPG cluster healthy, expected number of ready instances
     kubectl -n database get cluster postgres16

□ HA serving (verify-before-report — hit the real endpoint)
     curl -s -o /dev/null -w "%{http_code}\n" https://home-assistant.<domain>/   # expect 200/302
     # confirm HA UI loads; if a kiosk is in scope, poke Fully Kiosk Browser REST per the HA rule.

□ Flux fully reconciled
     flux get kustomizations -A | grep -v True || echo clean
```

**Evidence to attach to the change record** (high-risk — Themis gates on evidence, not description): the `kubectl get nodes` output showing all 6 on Talos v1.13.4 + k8s v1.35.3; `ceph status` active+clean; `talosctl etcd status` 3/3; HA HTTP response; Flux reconciled.

---

## 7. Rollback — be honest about what it can and can't do

Talos upgrades are an **in-place OS-image swap on the boot disk** with an A/B partition scheme. There is no Git "revert and reconcile" for the OS image — recovery is per-node via Talos.

### 7a. A node fails to come up after upgrade
```bash
talosctl -n <NODE_IP> dmesg | tail -80
talosctl -n <NODE_IP> health
kubectl describe node <NODE>
```
- **`talosctl rollback`** boots the node back into its **previous** (1.12.6) boot partition:
  ```bash
  talosctl -n <NODE_IP> rollback     # reverts to the prior boot entry, powercycles
  ```
  This works only while the previous partition is intact (it is, immediately after an upgrade). Confirm exact flag/semantics against `talosctl rollback --help` on the **v1.13.4 client** at execution time — do not assume.
- If rollback fails / the node is unrecoverable, this is a **lost node**, not just a failed upgrade → follow `docs/runbooks/disaster-recovery.md` §B.3 ("replace one node"). The cluster tolerates **one** missing node (2 OSDs still = quorum on Ceph at size 3 only if PGs already active+clean; 2 CP still = etcd quorum). Do **not** touch a second node.

### 7b. Safe-hold state (the important one)
**A partially-upgraded cluster — some nodes on 1.13.4, some on 1.12.6 — is a SUPPORTED, SAFE state.** Talos explicitly supports running mixed minor versions *during* a rolling upgrade. If anything looks wrong mid-roll:

1. **STOP.** Do not upgrade the next node.
2. Leave the already-upgraded nodes on 1.13.4 (do **not** mass-rollback healthy nodes — that's more churn and risk than holding).
3. Verify the cluster is healthy in its mixed state (nodes Ready, etcd 3/3, Ceph active+clean).
4. Open an incident, diagnose, and only resume (forward or a targeted single-node rollback) once root-caused.

> Mass-rollback of all nodes is a last resort, not a default. The default on trouble is **hold the mixed-version cluster**.

### 7c. What rollback CANNOT do
- It cannot undo a Kubernetes version change — irrelevant here (we don't bump k8s), but the reminder stands for the future k8s change.
- It does not restore data. Ceph/CNPG/VolSync are your data safety net (that's why §1 demands fresh backups). An OS rollback brings back the *OS*, not lost PVC data — though an in-place OS upgrade should never touch Ceph's `/dev/sda` or the CNPG PVCs.

---

## 8. Honest caveats

- **k8s 1.35 → 1.36 is OUT of scope.** This runbook deliberately leaves Kubernetes on v1.35.3. The k8s bump is a separate future high-risk change (and pinning Talos 1.13.4 — not 1.13.2 — is precisely what keeps the interim "1.13 OS + 1.35 k8s" state safe per #13350). If you find yourself running `just main talos upgrade-k8s`, you are doing a different change — stop and re-scope.
- **Extension verification is a Factory round-trip, not byte-level.** We confirmed `metal-installer/4b3cd373…:v1.13.4` resolves (HTTP 200, digest `sha256:22735af5…de76fd`) and that the schematic ID is unchanged and i915+intel-ucode exist in release-1.13. We did **not** crack the image open and diff the extension binaries. The Factory round-trip + workers-first ordering (§3) is the mitigation: if an extension were somehow missing, we catch it on the first worker (GPU/i915 absence, microcode warning in `talosctl dmesg`) before any CP node.
- **The operator must confirm `talosctl` reaches `:50000` from their terminal** before the window starts. The agent sandbox cannot (reject route). A quick `talosctl -n 172.16.2.84 version` returning a Server version is the proof. If the operator can't reach the nodes, the upgrade cannot proceed — there is no agent fallback for node contact.
- **`--preserve` is deprecated on 1.13** (removal in 1.18) and preserve is now the default. The `upgrade-node` recipe does not pass it — leave it that way. Do not add `--preserve` reflexively.
- **`-m powercycle`** is a hard reboot via the recipe. On bare metal this is the standard Talos upgrade path; the node comes back via its normal boot order. Ensure UPS/power is stable for the window.

---

## Related
- `docs/research/talos-upgrade-1.12-to-latest-2026-06.md` (Athena) — version matrix, EOL status, breaking-change table, #13350, sources. **The "why" lives here; don't duplicate it.**
- `docs/runbooks/ceph-osd-disk-replacement.md` — the `active+clean`-between-hosts gate this runbook reuses on every worker; also the "one OSD/one host at a time" `size:3`/`failureDomain:host` constraint.
- `docs/runbooks/disaster-recovery.md` §B.3 — "replace one node" escalation if a node is lost during the upgrade.
- Memory `project_rook_upgrade.md` — prod Rook still 1.16.5; this OS upgrade does not touch Rook.
- Memory `feedback_verify_before_report.md` / `feedback_test_evidence_required.md` — why §5/§6 demand live read-back + attached evidence.
- `kubernetes/main/talos/talenv.yaml`, `kubernetes/main/talos/talconfig.yaml`, `kubernetes/main/talos/mod.just` — the files and recipes this runbook drives.

— Daedalus
