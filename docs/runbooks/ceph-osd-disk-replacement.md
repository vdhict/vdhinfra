# Runbook: Rook-Ceph OSD SATA SSD Replacement (rolling, one OSD at a time)

**Audience**: Heph (k8s-engineer), executing a user-approved high-risk maintenance window.
**Goal**: replace the worn consumer PNY OSD disks with WD Red SA500 1 TB SATA SSDs, one OSD at a time, never dropping below redundancy unexpectedly, returning to `active+clean` between each drive.

> **Cluster**: vdhinfra main · **Rook**: v1.16.5 · **Ceph**: v19.2.1 (squid) — write for the **currently deployed** version. Rook 1.19.3 is rehearsed but NOT in prod (see [[rook-upgrade]]); do not assume any 1.17+ behaviour.
> **Pools**: `ceph-blockpool` (replicated `size: 3`, `failureDomain: host`) · `ceph-filesystem` metadataPool + `data0` dataPool (both replicated `size: 3`, `failureDomain: host`)
> **OSD topology**: 3 OSDs, **one OSD per worker node**, on `/dev/sda` (raw SATA SSD). `size: 3` + `failureDomain: host` ⇒ **only ONE OSD may be absent at a time.** Two absent = PGs go inactive, writes block, risk of data loss.

This runbook is **prescriptive**. Where a value can only be read live, it is marked **`<FILL: …>`** — Heph fills it in during execution and records it in the change.

---

## 0. Source-of-truth facts (verified against the repo, 2026-06-11)

| Fact | Value | Source |
|---|---|---|
| Talos boot disk (workers) | NVMe, selected by **serial** (`installDiskSelector.serial`) — node01 `2244E6801787`, node02 `2244E6801A88`, node03 `2244E6801A85` | `kubernetes/main/talos/talconfig.yaml:86-136` |
| OSD device | `/dev/sda` (SATA), explicitly listed per node | `…/rook-ceph-cluster/app/helmrelease.yaml:78-92` |
| Device discovery | `useAllNodes: false`, `useAllDevices: false`, explicit `nodes[].devices[].name: /dev/sda` | same, lines 78-92 |
| Pool replication | `size: 3`, `failureDomain: host` (both pools + cephfs metadata) | same, lines 94-99, 126-136 |
| mon / mgr count | 3 / 3, `allowMultiplePerNode: false` | same, lines 38-48 |
| `cleanupPolicy` / `sanitizeDisks` | **NOT configured anywhere in the CephCluster spec** | grep of `…/rook-ceph/` returns nothing |
| Rook upgrade `force` setting | not set on this HelmRelease (only relevant for upgrades, not this runbook) | n/a |

### CRITICAL device-discovery finding (this drives the whole procedure)

The CephCluster uses an **explicit device list keyed by Linux path** (`/dev/sda`), NOT `useAllDevices`, NOT a serial/WWN selector. Consequences:

1. **A new blank disk that enumerates as `/dev/sda` WILL be auto-discovered** by the Rook operator and a prepare job WILL run — *no Git change is required* to add the new disk. This is the desired behaviour and the reason the swap is clean.
2. **But Rook will NOT consume a disk that still carries a Ceph BlueStore label / LVM PV / old partition table.** Because there is **no `cleanupPolicy.sanitizeDisks`**, Rook will **not** auto-zap a dirty disk. A brand-new WD Red is blank from the factory and provisions fine; a disk that was previously an OSD (e.g. if you ever reuse a pulled drive) must be **manually wiped** first (see §6, "Prepare job skips the disk").
3. Disk path stability: with a single SATA drive in the NUC and the M.2 as the boot disk, the SATA SSD reliably enumerates as `/dev/sda`. If a second SATA device were ever present, path assignment could race — out of scope here (single SATA bay in use).

> **Correction to the prior runbook** (`ceph-osd-replacement.md`): that document claimed `cleanupPolicy.sanitizeDisks` is set to `method: quick` and that Rook auto-zaps. **That is false for the current spec.** This runbook supersedes it on that point.

---

## Pre-replacement: drive map & order

**OSD → host (Heph live-confirmed 2026-06-11):**

| OSD | Node | IP | Talos NVMe serial (boot, DO NOT TOUCH) | Current wear | Order |
|---|---|---|---|---|---|
| osd.2 | vdhclu01node03 | 172.16.2.83 | `2244E6801A85` | **91%** (~30-day runway, 228 realloc, 18,199 POH) | **1st** |
| osd.1 | vdhclu01node01 | 172.16.2.81 | `2244E6801787` | 75% | **2nd** |
| osd.0 | vdhclu01node02 | 172.16.2.82 | `2244E6801A88` | 66% (flat) | shelf spare / later |

**Replacement drive**: **WD Red SA500 1 TB SATA 2.5"** (600 TBW, DRAM+TLC, NAS 24/7). 2 to install now (osd.2 then osd.1), 1 cold spare. See [[ceph-ssd-wear]] for the buy decision.

**Old PNY drives are sequential serials from one lot (…277 / …877 / …879)** → batch-failure hedge is exactly why osd.1 follows osd.2 in the same pass.

---

## Checklist (per drive — copy into the change record and tick live)

```
□ NEW drive baseline captured (serial, SMART wear 0%, model = WD Red SA500) BEFORE install
□ Pre-flight passed: HEALTH_OK (or only chronic BLUESTORE_SLOW_OP_ALERT), all PGs active+clean,
  3 mons in quorum, NO other OSD down/out
□ ABORT gate cleared
□ OSD marked out → backfill complete (active+clean) — cluster now redundant on remaining 2 OSDs
□ Node cordoned + drained (node-local PVC check done — see §3)
□ OSD deployment scaled to 0, reconcile paused
□ OSD purged (ceph osd purge) → no longer in `ceph osd tree`
□ Old OSD deployment + prepare job deleted
□ Talos node graceful shutdown confirmed (NotReady)
□ Physical swap done — OLD drive bagged + labelled, NOT wiped (keep until new is healthy)
□ Node powered on → Talos Ready → `/dev/sda` present & blank
□ Node uncordoned → Rook prepare job ran → new OSD up + in
□ Backfill complete again (active+clean)
□ Post-checks: ceph osd df balanced, health back to baseline, new drive serial + 0% wear recorded
□ GATE: active+clean confirmed BEFORE starting next drive
□ CMDB updated (hw.ssd.osdN + ceph.osd.N)
```

---

## 1. Pre-flight gates  (ABORT if any fail)

Set up a shell alias against the toolbox:

```bash
TOOLS="kubectl -n rook-ceph exec deploy/rook-ceph-tools --"
```

```bash
# 1. Overall health
$TOOLS ceph status
#   ACCEPTABLE: HEALTH_OK, or HEALTH_WARN whose ONLY warnings are the chronic
#   BLUESTORE_SLOW_OP_ALERT (and DB_DEVICE_STALLED_READ_ALERT on osd.0).
#   ABORT on any other warning/error (esp. degraded/undersized/inactive PGs).

# 2. All PGs active+clean — NO recovering / backfilling / degraded / remapped
$TOOLS ceph pg stat
#   Expected: "<N> pgs: <N> active+clean"

# 3. Confirm replication is still size 3 on both pools
$TOOLS ceph osd pool ls detail | grep -E "pool|size"
#   Expected: size 3 on ceph-blockpool, ceph-filesystem-metadata, data0

# 4. Mon quorum — all 3 mons in
$TOOLS ceph mon stat
#   Expected: 3 mons, quorum a,b,c (or whatever the 3 names are)

# 5. OSD tree — all 3 OSDs up AND in
$TOOLS ceph osd tree
#   Expected: 3 osds, each "up   1.00000", reweight 1.00000

# 6. No OSD already out / no recovery underway
$TOOLS ceph health detail | grep -Ei "backfill|recover|degraded|undersized|down|out" || echo "clean"
#   Expected: "clean"

# 7. Capture current device wear for the record
$TOOLS ceph device ls
```

**ABORT CONDITIONS — do NOT start the drain if any are true:**
- Any PG not `active+clean`.
- Any OSD already `down` or `out`.
- Fewer than 3 mons in quorum.
- A pool shows `size < 3`.
- An active recovery/backfill is in progress.
- Any HEALTH_WARN/ERR other than the known chronic BlueStore slow-op alerts.

**Capture the NEW drive baseline BEFORE installing it** (on a USB-SATA dock from the Mac, or via `smartctl` on any host that can see it):
```bash
smartctl -a /dev/<new-disk> | grep -Ei "Model|Serial|Percentage Used|Wear|Power_On_Hours"
#   Record: Model=WD Red SA500, Serial=<FILL: new serial>, wear ~0%.
```

---

## 2. Replacement loop — ONE OSD at a time

> Substitute throughout: `<OSD_ID>` (2, then 1), `<NODE>` (`vdhclu01node03`, then `vdhclu01node01`), `<NODE_IP>` (`172.16.2.83`, then `172.16.2.81`).

### 2a. Mark OSD out, wait for backfill to FINISH (restore redundancy first)

We mark `out` and let Ceph re-replicate **while the old disk is still readable**, so we never voluntarily drop below 3 replicas. During this window PGs go `active+remapped+backfilling` — available, but a *second* OSD failure here is dangerous. Keep it short and watch.

```bash
$TOOLS ceph osd out <OSD_ID>

# Watch until fully active+clean again (no backfilling/recovering/remapped)
watch -n 10 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status"
```

**Wait until** `ceph status` shows `<N> pgs: <N> active+clean` and the `recovery:`/`io recovery` lines have disappeared. **Do not use a fixed time estimate** — read the `recovery:` progress line. With ~`<FILL: data %used from ceph df>` used across 3 OSDs this is typically tens of minutes; the cluster's own estimator is the only reliable source.

> If backfill stalls (no byte progress for >15 min), see §6 before proceeding.

### 2b. Cordon + drain the node

```bash
# Cordon: stop new scheduling
kubectl cordon <NODE>

# BEFORE draining, list anything node-local that will NOT reschedule:
kubectl get pods --field-selector spec.nodeName=<NODE> -A -o wide
kubectl get pvc -A -o json | \
  jq -r '.items[] | select(.spec.storageClassName=="openebs-hostpath") | "\(.metadata.namespace)/\(.metadata.name)"'
#   See §3 — node-local storage handling. Resolve before draining.

# Drain (Rook OSD/mon pods + Ceph daemons tolerate this; --ignore-daemonsets for Cilium etc.)
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

> **mon co-location note**: mons run `allowMultiplePerNode: false` across 3 nodes, so the node you drain very likely hosts one mon. Draining evicts that mon pod; with the node about to go down anyway, quorum drops to 2/3 — **still a quorum** (2 of 3). This is expected and safe for a single-node window. It is the second reason only ONE node may be down at a time: losing a second node would also break mon quorum, not just OSD redundancy.

### 2c. Stop the OSD, pause reconcile, purge

```bash
# Stop the Rook operator from recreating the OSD while we work
kubectl -n rook-ceph scale deploy/rook-ceph-operator --replicas=0
#   (Simpler and more reliable on 1.16 than per-deploy do-not-reconcile annotations.)

# Scale the OSD deployment to 0 (graceful stop)
kubectl -n rook-ceph scale deploy/rook-ceph-osd-<OSD_ID> --replicas=0
kubectl -n rook-ceph wait --for=delete pod -l ceph-osd-id=<OSD_ID> --timeout=120s

# Purge OSD from CRUSH map, auth, and OSD map
$TOOLS ceph osd purge <OSD_ID> --yes-i-really-mean-it

# Confirm it's gone
$TOOLS ceph osd tree    # OSD <OSD_ID> should no longer appear

# Delete the now-orphaned OSD deployment and the node's prepare job
kubectl -n rook-ceph delete deploy/rook-ceph-osd-<OSD_ID>
kubectl -n rook-ceph delete job -l app=rook-ceph-osd-prepare,rook.io/node=<NODE> --ignore-not-found
#   If the label selector matches nothing, list jobs and delete by name:
#   kubectl -n rook-ceph get jobs | grep prepare
#   kubectl -n rook-ceph delete job rook-ceph-osd-prepare-<NODE>
```

> At this point the cluster is intentionally running on **2 OSDs**. PGs are `active+undersized` (degraded but available). **Move forward without delay** — do not leave the cluster here.

### 2d. PHYSICAL SWAP

> **STOP — physical work. The Intel NUC 11 AHCI controller does NOT advertise SATA hot-plug. Power the node off cleanly first.**

```bash
# Graceful Talos shutdown
talosctl -n <NODE_IP> shutdown

# Confirm NotReady
kubectl get node <NODE> -w     # wait for NotReady, then Ctrl-C
```

Physical steps (NUC 11, UPS-backed — pull from UPS-protected outlet only after OS is down):
1. Remove the bottom lid (Phillips screws).
2. The 2.5" SATA SSD is in the lower bay. **The M.2 NVMe boot disk is on the top board — DO NOT TOUCH IT.** (Boot disk is selected by serial `<see drive map>`, so even if paths shuffle the OS is safe — but don't risk it.)
3. Unscrew the SATA bracket, disconnect SATA data + power.
4. **Bag and label the OLD PNY drive** with its OSD id + serial. **Do NOT wipe it** — it's the fallback until the new OSD is confirmed healthy (§6).
5. Seat the new **WD Red SA500**, reconnect data + power, screw bracket back.
6. Replace lid, power on.

```bash
# Wait for Talos to rejoin
kubectl get node <NODE> -w     # wait STATUS=Ready, then Ctrl-C

# Confirm the new blank disk is present at /dev/sda and is EMPTY
talosctl -n <NODE_IP> get disks
talosctl -n <NODE_IP> read /proc/partitions | grep sda
#   Expect sda present with NO partitions (sda1/sda2…) — a factory-fresh WD Red is blank.
```

### 2e. Resume reconcile, let Rook provision the new OSD

```bash
# Bring the operator back
kubectl -n rook-ceph scale deploy/rook-ceph-operator --replicas=1

# Uncordon so workloads can return and Rook can place the OSD pod
kubectl uncordon <NODE>

# Watch the prepare job run (auto-discovery because /dev/sda is in the explicit device list)
kubectl -n rook-ceph get jobs -w | grep prepare
#   Expect: rook-ceph-osd-prepare-<NODE>  Complete  1/1

# New OSD deployment appears and comes up (may reuse the same numeric id)
kubectl -n rook-ceph get deploy -w | grep osd
#   Expect: rook-ceph-osd-<NEW_ID>  1/1

# Confirm in Ceph: new OSD up + in, under the correct host
$TOOLS ceph osd tree
#   Expect new OSD "up   1.00000" under host <NODE>

# Confirm BlueStore initialised cleanly
kubectl -n rook-ceph logs deploy/rook-ceph-osd-<NEW_ID> -c osd | tail -20
```

> If the prepare job does NOT appear within ~3 min, or appears and **skips** `/dev/sda`, see §6 ("Prepare job skips the disk") — most likely a leftover Ceph label needing a manual zap (because there is no `sanitizeDisks` auto-zap).

### 2f. Wait for backfill into the new OSD

```bash
watch -n 10 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status"
```

**Wait until** `<N> pgs: <N> active+clean` — the new OSD pulls its share from the other two nodes. Watch the `recovery:` line.

---

## 3. Node-local storage during drain (read before §2b)

`openebs-hostpath` (basePath `/var/openebs/local`, `isDefaultClass: false`) is a **node-bound** provisioner: a PVC on it lives on one node's local disk and **cannot reschedule** to another node on drain. A pod using such a PVC will go `Pending` while its node is down and recover when the node returns — acceptable for a short window, but you must know which pods will stall.

From the repo, **no app statically declares `storageClassName: openebs-hostpath`** — the default class is `rook-ceph-block`, and `openebs-hostpath` is `isDefaultClass: false`, so nothing picks it up implicitly. **However, dynamic PVCs are not visible in Git.** Before draining, Heph MUST check live:

```bash
kubectl get pvc -A -o json | \
  jq -r '.items[] | select(.spec.storageClassName=="openebs-hostpath") | "\(.metadata.namespace)/\(.metadata.name) -> node?"'
# For each hit, find which node it's bound to and whether that node is <NODE>:
kubectl get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="openebs-hostpath") |
  "\(.metadata.name) \(.spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[].values[])"'
```

- If a hostpath PVC is bound to the node being drained → its pod will be `Pending` for the maintenance window. Decide per-app whether that's acceptable (most likely yes for a ~30 min window) and **note it in the change record**.
- Ceph mon stores: mons use their own Rook-managed dataDirHostPath, not `openebs-hostpath`. The drained mon simply restarts elsewhere/on return; quorum stays at 2/3 (§2b note).

> **OPEN QUESTION** carried to §8 — confirm live whether any node-local PVC pins a stateful workload to the worker being drained.

---

## 4. Post-checks + evidence (per drive)

```bash
TOOLS="kubectl -n rook-ceph exec deploy/rook-ceph-tools --"

# Health back to baseline (HEALTH_OK or only chronic BlueStore alerts)
$TOOLS ceph health detail

# All PGs active+clean
$TOOLS ceph pg stat

# All 3 OSDs up+in, roughly balanced
$TOOLS ceph osd df
#   New OSD should carry ~1/3 of data, weight ~equal to peers.

# New device present, wear ~0%, record serial + ceph device id
$TOOLS ceph device ls
```

Cross-check in Prometheus/Grafana (Sibyl's dashboards):
- `ceph_health_status == 0` (or back to the pre-existing WARN baseline, not worse)
- the per-OSD SSD-wear alert clears for the replaced OSD
- no `CephOSDDown` / `CephPGsDegraded` firing

**Evidence to attach to the change record** (this is a high-risk change — Themis gates on evidence):
- `ceph status` output showing `active+clean` after the swap.
- `ceph osd tree` showing the new OSD up+in.
- `ceph osd df` showing balance.
- `ceph device ls` / `smartctl` showing new drive serial + ~0% wear.
- The OLD drive's bag label (serial) recorded.

### GATE between drives

**Do NOT start the next OSD until `ceph status` is `active+clean` and health is back to baseline.** This is the single most important sequencing rule. Re-run §1 pre-flight in full before the next drive.

---

## 5. Update the CMDB (after each drive)

Edit `ops/cmdb.yaml` — update `hw.ssd.osd<N>` and `ceph.osd.<N>`:

```yaml
hw.ssd.osd2:
  description: "WD Red SA500 1TB SATA S/N <FILL: new serial> — /dev/sda on vdhclu01node03; wear new (~0%), 600 TBW"
  health_source: ceph://device/<FILL: ceph device id from `ceph device ls`>

ceph.osd.2:
  description: "Ceph OSD 2 — vdhclu01node03 (172.16.2.83), device: WD Red SA500 1TB SATA S/N <FILL>"
```

```bash
git add ops/cmdb.yaml
git commit -m "chore(cmdb): hw.ssd.osd<N> — WD Red SA500 replacing worn PNY after swap"
```

---

## 6. Rollback / failure handling

### New disk not detected (`/dev/sda` missing)
```bash
talosctl -n <NODE_IP> get disks
talosctl -n <NODE_IP> read /proc/partitions | grep sda || echo "NO sda"
```
If absent: power off, reseat SATA data + power cables, confirm BIOS sees the drive, power on. If still absent → the new drive or cable is faulty; **re-install the OLD drive** (still intact, not wiped) to restore redundancy, power on, and abort this drive — the cluster returns to its prior state once the old OSD rejoins (it was purged, so it will re-provision as a fresh OSD via the same prepare flow — back up to 3 OSDs, just on the old disk again).

### Prepare job skips the disk (does NOT consume `/dev/sda`)
Most likely the disk is **not blank** (stale Ceph/LVM label) and — because **there is no `cleanupPolicy.sanitizeDisks`** — Rook will refuse it. Manually wipe, then re-trigger:
```bash
# Inspect what's on it
talosctl -n <NODE_IP> read /proc/partitions
kubectl -n rook-ceph logs job/rook-ceph-osd-prepare-<NODE> | grep -i "skipping\|not empty\|in use\|filesystem"

# Wipe from the prepare pod context is awkward on Talos (no shell). Easiest:
#   - on Talos, use `talosctl` wipe of the disk:
talosctl -n <NODE_IP> wipe disk sda --method fast    # <FILL: confirm exact talosctl subcommand on v1.12 — see OPEN QUESTIONS>
#   then restart the operator to re-scan:
kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator
```
A factory-fresh WD Red should never hit this. It only applies if a previously-used drive is installed.

### OSD prepare job fails / OSD pod crash-loops
```bash
kubectl -n rook-ceph logs job/rook-ceph-osd-prepare-<NODE>
kubectl -n rook-ceph logs deploy/rook-ceph-operator --since=10m | grep -iE "error|warn|osd|sda"
kubectl -n rook-ceph logs deploy/rook-ceph-osd-<NEW_ID> -c osd | tail -40
```

### Node does not rejoin (stays NotReady)
```bash
talosctl -n <NODE_IP> dmesg | tail -50
talosctl -n <NODE_IP> health
kubectl describe node <NODE>
```
If the node is unrecoverable, you have lost the node entirely (not just the OSD) — this is the §B.3 "replace one node" path in `disaster-recovery.md`. The cluster stays on 2 OSDs / 2 mons (still quorum) until the node returns. **Do not touch any other node** until this one is back.

### Backfill stalls (no progress >15 min)
```bash
$TOOLS ceph health detail
$TOOLS ceph osd blocked-by
$TOOLS ceph pg dump_stuck | head -30
```
Check msgr2 host-network connectivity between nodes (`network.provider: host`, `requireMsgr2: true`). A stuck `active+remapped+backfilling` with zero byte progress usually means a node-to-node network problem, not a Ceph problem.

### Keep the old drive
**Do not wipe or repurpose the pulled PNY drive until the replacement OSD has been `active+clean` for at least one full backfill cycle and post-checks pass.** It is your only fast rollback if the new drive is dead on arrival.

---

## 7. Aborted halfway — state recovery

| You stopped after… | Cluster state | Recovery action |
|---|---|---|
| `ceph osd out` only | OSD still up, data migrating off | `ceph osd in <id>` to cancel, or proceed forward |
| Operator scaled to 0, OSD scaled to 0, purge done | OSD absent; PGs `active+undersized` (2 replicas) | **Proceed forward now.** Swap disk, power on, scale operator back to 1, uncordon |
| Node powered off, disk not swapped | Node NotReady; 2 OSDs + 2 mons | Power node back on with OLD disk → it rejoins, OSD re-provisions → back to 3. Reschedule window |
| Prepare job deleted, new disk seated, operator still at 0 | Rook idle, 2 OSDs | Scale operator to 1, uncordon → prepare job runs |

> **Two OSDs (or two nodes) absent simultaneously = PGs inactive, writes blocked, possible data loss.** If this ever happens: restore the second node/OSD immediately and open an incident:
> ```bash
> ./ops/ops incident new critical --summary "Two Ceph OSDs offline simultaneously during disk swap" --actor k8s-engineer
> ```

---

## 8. OPEN QUESTIONS (confirm live before/at execution)

1. **Node-local PVCs (`openebs-hostpath`)** — no app declares it statically in Git, and it's not the default class, so *probably* nothing pins a workload to a worker. **Confirm live** with the `kubectl get pvc/pv` queries in §3 before draining each node. If a stateful pod is pinned to the node being drained, decide acceptability and record it.
2. **`talosctl` disk-wipe subcommand on Talos v1.12.6** — the exact syntax for wiping `/dev/sda` from Talos (`talosctl wipe disk …` vs `talosctl reset --system-disk` — the latter is wrong, it's not the system disk). Verify against `talosctl wipe --help` on the running version. Only needed in the rare "dirty disk" rollback path; a factory WD Red won't need it.
3. **Exact mon names / quorum** — §1 step 4 expects 3 mons; confirm the actual mon letters (`a,b,c`?) live, and confirm which node currently hosts the mon for the node you're about to drain (so you anticipate the 2/3 quorum dip).
4. **Current data %used** for the §2a backfill-time expectation — read `ceph df` live; substitute into the `<FILL>` so the window estimate is grounded.
5. **OSD numeric id reuse** — Rook/Ceph *may* assign the new OSD the same id (2) or a new one (3). Both are fine; the runbook handles `<NEW_ID>` generically. Just record which it chose.
6. **Whether to do osd.2 and osd.1 in one maintenance window or split** — both are planned for "one pass" per [[ceph-ssd-wear]], but each is a full independent §1–§5 cycle with the §4 gate between them. Confirm with Sander that the back-to-back window (≈2× backfill cycles) is acceptable, or split across two evenings.

---

## Related
- Memory [[ceph-ssd-wear]] — buy decision (WD Red SA500), wear snapshot, order qty.
- Memory [[rook-upgrade]] — prod still 1.16.5; do NOT assume 1.19 behaviour. Zero OSD headroom is the same constraint that governs this runbook.
- `docs/runbooks/disaster-recovery.md` §B.3 — "replace one node" (the escalation path if a node dies during the swap).
- Superseded fact: `docs/runbooks/ceph-osd-replacement.md` (older draft) — wrong on `sanitizeDisks` auto-zap and lists Samsung 870 EVO; this runbook is authoritative for the WD Red swap.

— Daedalus
