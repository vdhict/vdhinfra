# Ceph Health Investigation — 2026-05-14

**Author:** Heph (k8s-engineer) · **Change:** chg-2026-05-14-001 (low, read-only) · **Trigger:** AM `CephDaemonCrash` + `BlueStoreSlowOps`.

## State now

- `ceph -s`: `HEALTH_WARN`. 3/3 mons quorum (5w), 3/3 OSDs `up`+`in`, 81/81 PGs `active+clean`, 291 GiB / 2.7 TiB used.
- `ceph osd perf`: commit_latency=3ms, apply_latency=3ms on all OSDs. **No active slow ops** (`dump_blocked_ops` num_blocked=0 on osd.0).
- Last slow op recorded: **2026-05-12T02:15:30Z** — ~48h ago. Cluster I/O is currently healthy.
- OSD pod mem 1.37–1.43 GiB. No OOMKills/evictions in current events.

## Crash detail (`ceph crash ls`)

| ID timestamp | Entity | Host | Assert | Signal |
|---|---|---|---|---|
| 2026-05-01T18:42:18Z | osd.1 | vdhclu01node01 | `KernelDevice::_aio_thread` line 663: `ceph_abort_msg("Unexpected IO error. This may suggest a hardware issue.")` | `io_error=true`, `errno=-5 (EIO)`, devname=`sda`, offset 687421476864, length 64K, optype 8 (write) |
| 2026-05-04T04:53:20Z | osd.0 | vdhclu01node02 | `KernelDevice::_discard_thread` segfault (rbtree iterator) | No io_error flag — likely discard/TRIM-path crash |

Both crashed once, both have run cleanly since (osd.1 = 12d uptime, osd.0 = 9d uptime). Crashes are **10–13 days old, well before** the 2026-05-13 plug-flap window. The HomeWizard plug correlation does **not** hold.

## Slow-ops detail

- `BLUESTORE_SLOW_OP_ALERT` lists all 3 OSDs, but the latency counters tell the story: the alert is a **sticky historical flag** triggered when the slow-op counter increments. Last actual incident was 2026-05-12 ~02:15 UTC (multi-OSD, ~12s duration, write path, kv_commit phase = ~12s). Counters on osd.0:
  - `slow_committed_kv_count = 10,853`
  - `slow_aio_wait_count = 1,890`
  - `kv_sync_lat avg = 7.5 ms` (fine on average; tail is the issue)
- Pattern: every long op stalls in **`kv_commit`** (`kv_sync_lat → kv_commit_lat`) — RocksDB WAL fsync. Typical SATA-SSD-without-PLP signature.

## Disk health

`ceph device ls` wear / `get-health-metrics` reallocated sectors (Attribute 5, raw):

| OSD | Host | Device | Wear | Reallocated_Sector_Ct | Power-On Hours |
|---|---|---|---|---|---|
| osd.0 | node02 | PNY 1TB SATA `...0277` | **66%** | **180** | 16,593 |
| osd.1 | node01 | PNY 1TB SATA `...0877` | **68%** | **36** | 16,656 |
| osd.2 | node03 | PNY 1TB SATA `...0879` | **84%** | **228** | 17,670 |

All three are consumer **PNY 1TB SATA SSDs**, no PLP. osd.2 also shows `Unused_Rsvd_Blk_Cnt_Tot raw=65,497` (vs 119/143 on the others) — sharply elevated reserve-block churn.

## Root-cause hypothesis (ranked)

1. **Disk hardware degradation on the PNY SATA SSDs (HIGH confidence).** Both crashes were in `KernelDevice` paths (aio + discard). osd.1 crash explicitly returned EIO from the block layer with a specific LBA — that is a kernel-confirmed I/O error, not a Ceph bug. Reallocated-sector counts (36 / 180 / 228) and 84% wear on osd.2 corroborate. Slow-op tails clustering in `kv_commit` (WAL fsync) match consumer-SSD fsync stalls under sustained write pressure.
2. **Discrete event, transient host pressure (LOW).** Both crashes are single occurrences, weeks apart, no co-incident OOMKill/eviction in cluster events. Possible but doesn't explain the SMART trend.
3. **Power instability from the plug-flap (REJECTED).** Crashes are 10–13d old, predate the 2026-05-13 plug-flap window. No new crashes after yesterday's event.

## Recommended next action

**Archive the current crash records** (`ceph crash archive-all`) **to clear the `RECENT_CRASH` flag** — this is a write but it's the documented mechanism to acknowledge known crashes, and it does not touch data. The `BLUESTORE_SLOW_OP_ALERT` flag will clear on its own when no slow op has occurred for the alert window (or can be cleared with `ceph tell osd.* clear_shard_op_history` if it persists).

**Real action: plan PNY SSD replacement.** osd.2 (node03) is the most-worn (84%, 228 reallocated sectors) — replace first. Replication=3, failureDomain=host → one OSD can be drained/replaced safely, but we have **zero headroom for a second failure during the operation** (same constraint flagged in `memory:rook-upgrade`). Procure enterprise-grade replacements (Samsung PM893 / Micron 5400 PRO 960 GB, both have PLP) before the Rook 1.16→1.19 upgrade — replacing disks first gives the upgrade actual headroom.

**Approval needed for:**
- `ceph crash archive-all` (clears the AM alert — minor, but it is a write).
- Disk procurement decision + replacement schedule.

— Heph
