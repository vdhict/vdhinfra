# Runbook: Rook-Ceph OSD SATA SSD Replacement

> **Cluster**: vdhinfra main · **Rook**: v1.16.5 · **Ceph**: v19.2.1 (squid)  
> **Pools**: `ceph-blockpool` (replicated size 3) · `ceph-filesystem/data0` (replicated size 3)  
> **OSD count**: 3 — one OSD per node, `replication=3` means **only 1 OSD may be absent at a time**

**Checklist**

```
□ Drive ordered/on-hand
□ Pre-flight passed (health HEALTH_OK or known-safe WARN)
□ OSD marked out
□ Backfill complete (all PGs active+clean)
□ Node cordoned + OSD pod scaled down
□ OSD purged from CRUSH/auth
□ OSD prepare job deleted
□ Physical swap done (new disk seated)
□ Node uncordoned
□ New OSD up + BlueStore initialized
□ Backfill complete again (all PGs active+clean)
□ ceph health HEALTH_OK
□ CMDB updated
```

---

## 1. When to Use This Runbook

Use when **one** of the following is true for a drive listed in the OSD map:

| Trigger | Check |
|---|---|
| Wear ≥ 90 % | `ceph device ls` — WEAR column |
| Reallocated sector spike | `ceph health detail` — `DEVICE_HEALTH_TOOMANY_REPAIRS` |
| Kernel I/O errors | `talosctl dmesg -n <node>` — EIO / SCSI errors on `sda` |
| Ceph marks OSD `out` automatically | `ceph osd tree` — OSD shows `out` |
| Drive physically dead | OSD deploy crash-loops, `blk_update_request I/O error` in pod logs |

**Current OSD / disk map (verified 2026-05-14)**

| OSD | Node | IP | Device | S/N | Wear |
|---|---|---|---|---|---|
| osd.0 | vdhclu01node02 | 172.16.2.82 | /dev/sda | PNF24235017670900277 | 66 % |
| osd.1 | vdhclu01node01 | 172.16.2.81 | /dev/sda | PNF24235017670900877 | 68 % |
| osd.2 | vdhclu01node03 | 172.16.2.83 | /dev/sda | PNF24235017670900879 | 84 % |

Replacement drive spec: **Samsung 870 EVO 1 TB SATA 2.5"**.

---

## 2. Pre-flight Checks

Run all commands against the tools pod:

```bash
TOOLS="kubectl -n rook-ceph exec deploy/rook-ceph-tools --"
```

```bash
# 1. Overall health — must be HEALTH_OK or only the known BlueStore slow-op WARN
$TOOLS ceph status

# 2. Confirm replication factor (must show size: 3)
$TOOLS ceph osd pool ls detail | grep -E "pool|size"

# 3. No degraded or recovering PGs
$TOOLS ceph pg stat
# Expected: "81 pgs: 81 active+clean"

# 4. No backfill in progress
$TOOLS ceph health detail | grep -E "backfill|recovery|degraded"
# Expected: no output

# 5. OSD tree — confirm all 3 OSDs are up + in
$TOOLS ceph osd tree
# Expected: all OSDs show "up  1.00000"

# 6. Device health + wear
$TOOLS ceph device ls
```

**Do not proceed if**: any PG is not `active+clean`, or if two OSDs are already `out`, or if an active recovery is underway.

---

## 3. Replacement Loop

> **Do ONE drive at a time.** Never start a second replacement until the cluster is `HEALTH_OK` again.

Substitute `<OSD_ID>` (0, 1, or 2) and `<NODE>` (e.g. `vdhclu01node02`) throughout.

### 3a. Mark OSD Out and Wait for Backfill

```bash
TOOLS="kubectl -n rook-ceph exec deploy/rook-ceph-tools --"

# Mark out — Ceph starts migrating data off this OSD immediately
$TOOLS ceph osd out <OSD_ID>

# Watch until all PGs are active+clean again (no recovering/backfilling)
watch -n 10 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status"
```

**Wait until** `ceph status` shows `X pgs: X active+clean` with no `backfilling` or `recovering` states.

Duration heuristic: with ~96 GiB of data spread across 3 OSDs and ~30 MB/s recovery throughput on spinning-SSD mix, Ceph's own recovery estimator is the only reliable source. Watch `ceph status` — the `recovery:` line shows remaining bytes. Do **not** use a fixed time estimate; wait for clean.

### 3b. Cordon Node, Stop OSD Pod, Purge OSD

```bash
# Cordon the node (prevents new pod scheduling, does not evict running pods)
kubectl cordon <NODE>

# Prevent Rook operator from re-creating the OSD pod while you work
kubectl -n rook-ceph annotate deploy/rook-ceph-osd-<OSD_ID> \
  rook.io/do-not-reconcile=true

# Scale down the OSD deployment (graceful stop)
kubectl -n rook-ceph scale deploy/rook-ceph-osd-<OSD_ID> --replicas=0
# Wait for pod to terminate
kubectl -n rook-ceph get pod -l ceph-osd-id=<OSD_ID> -w

# Purge the OSD from CRUSH map, auth, and PG maps
$TOOLS ceph osd purge <OSD_ID> --yes-i-really-mean-it

# Confirm the OSD is gone
$TOOLS ceph osd tree
# OSD should no longer appear

# Delete the deployment (Rook will recreate it on a clean device)
kubectl -n rook-ceph delete deploy/rook-ceph-osd-<OSD_ID>

# Delete the OSD prepare job so Rook re-runs provisioning after the new disk appears
kubectl -n rook-ceph delete job rook-ceph-osd-prepare-<NODE>
```

### 3c. PHYSICAL SWAP

> **STOP — physical work required before continuing.**

**Intel NUC 11 does NOT guarantee SATA hot-swap.** The Intel Tiger Lake PCH uses an AHCI controller that does _not_ advertise hot-plug capability in its port registers. **Power the node down cleanly before touching the drive.**

```bash
# Shut down the Talos node gracefully
talosctl -n <NODE_IP> shutdown
# Wait ~30 s, confirm node shows NotReady
kubectl get node <NODE> -w
```

Then physically:

1. Remove the bottom lid (two Phillips screws).
2. The 2.5" SATA drive is in the lower bay. **The M.2 NVMe (boot disk) is on the top board — do not touch it.**
3. Unscrew the SATA drive bracket (one screw), disconnect SATA data + power cable.
4. Seat the new Samsung 870 EVO. Reconnect SATA data + power. Screw the bracket back in.
5. Replace lid. Power on.

Wait for Talos to boot and the node to rejoin the cluster:

```bash
kubectl get node <NODE> -w
# Wait until STATUS = Ready (typically 60-90 s after power-on)
```

### 3d. Uncordon and Let Rook Provision the New OSD

```bash
# Uncordon the node
kubectl uncordon <NODE>

# Rook operator will detect the blank disk (/dev/sda) and launch a new prepare job.
# Watch for it:
kubectl -n rook-ceph get jobs -w
# Expect: rook-ceph-osd-prepare-<NODE>  Complete  1/1  ~15s

# Watch for the new OSD deployment to appear and come up
kubectl -n rook-ceph get deploy -w | grep osd
# Expect: rook-ceph-osd-<NEW_ID>  1/1

# Confirm new OSD ID is assigned and up
$TOOLS ceph osd tree
# Expect a new OSD (may reuse the same ID) under the correct host, status: up  in

# Confirm BlueStore initialized (no errors in the new OSD pod logs)
kubectl -n rook-ceph logs deploy/rook-ceph-osd-<NEW_ID> -c osd | tail -20
```

If Rook does not start the prepare job within ~3 min, check operator logs:

```bash
kubectl -n rook-ceph logs deploy/rook-ceph-operator --since=5m | tail -40
```

### 3e. Wait for Backfill to Complete

```bash
watch -n 10 "kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status"
```

Wait until: `X pgs: X active+clean` — same as 3a. The new OSD will receive data from the other two nodes. Monitor the `recovery:` line in `ceph status` for progress.

---

## 4. Post-checks

```bash
TOOLS="kubectl -n rook-ceph exec deploy/rook-ceph-tools --"

# Must be HEALTH_OK
$TOOLS ceph health detail

# All PGs active+clean
$TOOLS ceph pg stat

# New drive present with low wear (should show 0% for a new drive)
$TOOLS ceph device ls

# OSD map shows all 3 OSDs up+in with equal weight
$TOOLS ceph osd df
```

Also verify in Prometheus/Grafana that:
- `ceph_health_status` == 0 (HEALTH_OK)
- `CephOsdSsdWearCritical` alert is cleared for the replaced OSD
- No `CephPGsDegraded` or `CephOSDDown` alerts are firing

---

## 5. Update the CMDB

Edit `ops/cmdb.yaml` directly — update the `hw.ssd.osdN` and `ceph.osd.N` entries for the replaced OSD:

```yaml
# Example for osd.2 replaced with Samsung 870 EVO:
hw.ssd.osd2:
  description: "Samsung 870 EVO 1TB SATA S/N <NEW_SERIAL> — /dev/sda on vdhclu01node03; wear new (0%)"
  health_source: ceph://device/<CEPH_DEVICE_ID_FROM_ceph_device_ls>

ceph.osd.2:
  description: "Ceph OSD 2 — runs on vdhclu01node03 (172.16.2.83), device: Samsung 870 EVO 1TB SATA S/N <NEW_SERIAL>"
```

Retrieve the new serial and Ceph device ID from `ceph device ls` output after the OSD is up.

Commit:

```bash
git add ops/cmdb.yaml
git commit -m "chore(cmdb): update hw.ssd.osd<N> — Samsung 870 EVO replacing PNY SSD after swap"
```

---

## 6. Rollback — New Drive Not Seen / OSD Fails to Come Up

**New disk not detected (`/dev/sda` missing in Rook logs)**

```bash
# Check the node sees the disk
talosctl -n <NODE_IP> read /proc/partitions
# If /dev/sda not present, reseat the SATA cable and recheck BIOS/firmware sees it
```

**Prepare job fails or OSD pod crashes**

```bash
# Check prepare job logs
kubectl -n rook-ceph logs job/rook-ceph-osd-prepare-<NODE>

# Check operator logs
kubectl -n rook-ceph logs deploy/rook-ceph-operator --since=10m | grep -i "error\|warn\|osd"
```

Common cause: disk has leftover partition table or Ceph label. Rook will zap it automatically if `cleanupPolicy.sanitizeDisks` is set (it is — `method: quick`). If zap does not trigger, manually trigger via CephCluster annotation:

```bash
kubectl -n rook-ceph annotate node <NODE> \
  "ceph.rook.io/DevicePathFilter=/dev/sda"
# Then restart the operator to force re-scan:
kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator
```

**Backfill stalls** (no progress for > 15 min):

```bash
$TOOLS ceph health detail
$TOOLS ceph osd blocked-by
# Look for SLOW_OPS or unfound objects
$TOOLS ceph pg dump_stuck | head -30
```

If a PG is stuck `active+remapped+backfilling` with no progress, check for network issues between the affected nodes before escalating.

---

## 7. Aborted Halfway

If you stop mid-procedure, determine the state:

| You stopped after… | Cluster state | Recovery action |
|---|---|---|
| `ceph osd out` only | OSD still running, data migrating off | Either continue (mark back `in`: `ceph osd in <id>`) or proceed forward |
| OSD pod scaled to 0, purge done | OSD absent, PGs may be degraded (not enough replicas) | **Proceed forward immediately.** Do not leave cluster in this state. Swap disk + uncordon. |
| Node powered off, disk not swapped | Node NotReady; 1 of 3 replicas unavailable | Power the node back on with the old disk to restore redundancy, then schedule a new maintenance window |
| Prepare job deleted, new disk not seated | Rook will not provision; cluster has 2 OSDs | Seat the disk and power on the node; Rook will self-recover |

**Two OSDs simultaneously absent = potential data loss.** If this happens accidentally, restore the second node immediately and open an incident (`./ops/ops incident new critical --summary "Two Ceph OSDs offline simultaneously" --actor k8s-engineer`).
