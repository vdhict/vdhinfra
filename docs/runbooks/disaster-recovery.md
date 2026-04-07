# Disaster Recovery Runbook

**Audience**: future-you, possibly under stress, possibly without your laptop.
**Goal**: rebuild the homelab cluster with all data restored, in <2 hours of hands-on time, from a worst-case starting point (all hardware lost, only offsite backups remain).

This runbook is intentionally **prescriptive**. Where automation exists, the script paths are listed. Where steps are manual, exact commands are given.

---

## TL;DR — recovery decision tree

```
What was lost?
├── A single PVC (e.g. zwave-js-ui store corrupted)
│   └── See: §B.1 — single VolSync app restore
├── Postgres data corrupted but cluster healthy
│   └── See: §B.2 — postgres point-in-time recovery
├── A whole node (e.g. one NUC died)
│   └── See: §B.3 — replace one node
└── EVERYTHING (cluster lost, all hardware gone)
    └── See: §A — full disaster recovery
```

---

## Critical assets — verify these survive any disaster

| # | Asset | Lives at | Lost = ? |
|---|---|---|---|
| 1 | Git repo | github.com/vdhict/vdhinfra | Recover from local clone OR re-init from any past clone |
| 2 | **Age private key** | `~/Code/homelab-migration/config/age.key` (184 B) | **CATASTROPHIC** — cannot decrypt any sops-encrypted state in repo, including the Talos secret bundle. **Back this up offline** (USB drive in a safe, printed QR, etc). |
| 3 | Talos secret bundle | `kubernetes/main/talos/talsecret.sops.yaml` (encrypted with #2) | Recoverable from git as long as #2 survives |
| 4 | Flux bootstrap age secret | `kubernetes/main/bootstrap/sops-age.sops.yaml` (encrypted with #2) | Same as #3 |
| 5 | 1Password vault | 1Password cloud | If 1Password account is lost, all runtime credentials are gone. 1Password keeps its own offsite versioning; recovery requires the 1P emergency kit. |
| 6 | MinIO buckets | Synology `/volume1/minio` (`cnpg-backups`, `volsync`) | **Single point of failure** — if the NAS dies, all backups die with it. See §C — gap analysis. |
| 7 | `VOLSYNC_REPO_PASSWORD` | 1Password `minio` item | Encryption password for every restic repo. If 1P + this password are both lost, even an intact MinIO bucket is unrecoverable. |

**Action item**: Make sure item #2 is on at least one offline medium. The literal contents:
```
$ cat ~/Code/homelab-migration/config/age.key
# AGE-SECRET-KEY-1...
```
Print it, scan it, store it. It is 184 bytes — fits on a sticky note.

---

## §A — Full disaster recovery (cluster + hardware lost)

**Prerequisites you must have on hand:**
- A laptop with `sops`, `age`, `talosctl`, `kubectl`, `helmfile`, `flux`, `just`, `git` installed (mise can install all of these from the repo's `.mise.toml`)
- The age private key from item #2 above
- 1Password access (for runtime secrets)
- 6 nodes (3 control plane + 3 worker) booted from the Talos ISO at `https://factory.talos.dev/image/4b3cd373a192c8469e859b7a0cfbed3ecc3577c4a2d346a37b0aeff9cd17cdb0/v1.12.6/metal-amd64.iso`
- The Synology NAS reachable at 172.16.2.246 with the existing MinIO data (or restored from offsite mirror — see §C)

### A.1. Clone the repo and restore the age key

```bash
git clone git@github.com:vdhict/vdhinfra.git
cd vdhinfra

# Place the age key where sops + Flux expect it
mkdir -p ~/Code/homelab-migration/config
# Restore the key from offline backup
cp /path/to/offline/age.key ~/Code/homelab-migration/config/age.key
chmod 600 ~/Code/homelab-migration/config/age.key
export SOPS_AGE_KEY_FILE=~/Code/homelab-migration/config/age.key

# Verify decryption works
sops -d kubernetes/main/cluster/cluster-secrets.sops.yaml | head -5
# Expected: plaintext SECRET_DOMAIN, SECRET_ACME_EMAIL, etc.
```

**If the sops decryption fails**, STOP. The age key is wrong or corrupted. Recovery is not possible without it.

### A.2. Install tools

```bash
mise install
```

This installs the exact pinned versions of every tool from `.mise.toml`.

### A.3. Apply Talos config and bootstrap Kubernetes

```bash
just main bootstrap
```

This single command (defined in `kubernetes/main/bootstrap/mod.just`) does:

1. `talos`: applies Talos config to all 6 nodes from `kubernetes/main/talos/clusterconfig/`
2. `kubernetes`: bootstraps the K8s control plane via `talosctl bootstrap`
3. `kubeconfig`: fetches the kubeconfig
4. `wait`: waits for all nodes Ready
5. `namespaces`: creates all app namespaces
6. `secrets`: applies the sops-age secret (decrypted with item #2)
7. `resources`: applies `bootstrap/resources.yaml` (CRDs needed early)
8. `crds`: helmfile-templates and applies `00-crds.yaml`
9. `apps`: helmfile-syncs `01-apps.yaml` (cilium, coredns, spegel, cert-manager, flux-operator, flux-instance, onepassword-connect)

After this completes, **Flux is running and reconciling from git**. Within minutes, it will start applying every app — including stateful ones with empty PVCs. This is the point where data recovery must begin.

### A.4. **CRITICAL — Pause stateful apps before they start with empty data**

Run **immediately** after step A.3 (literally seconds matter — stateful apps may already be reconciling):

```bash
hack/disaster-recovery/15-pause-stateful.sh
```

This suspends the Flux Kustomizations for postgres16 and all 7 VolSync-protected apps so they don't start up with empty data:
- `postgres16`
- `home-assistant`, `zwave-js-ui`, `zigbee2mqtt`, `node-red`, `esphome`, `mealie`
- `radarr`

If any of these had already started with empty PVCs by the time this ran, the script will print warnings — see §A.5 for cleanup.

### A.5. Recover postgres from barman

```bash
hack/disaster-recovery/20-restore-postgres.sh
```

This:
1. Verifies MinIO is reachable and `cnpg-backups/postgres16` contains a base backup
2. Generates a one-shot recovery cluster manifest from `recovery-templates/postgres16-recovery.yaml`
3. Deletes any existing (empty) postgres16 cluster
4. Applies the recovery manifest — CNPG bootstraps from barman, replays WAL to the latest point
5. Waits for the recovery to complete
6. Re-resumes the postgres16 Flux KS — which then applies the canonical (non-recovery) cluster spec via `cnpg.io/skipReinitWithMode` annotation (or similar — see script comments)

Recovery time: **~5–10 minutes** for current ~300 MiB of data. WAL replay adds time proportional to how much WAL has accumulated since the last base backup.

### A.6. Recover VolSync PVCs

```bash
hack/disaster-recovery/30-restore-volsync-all.sh
```

This loops over all 7 VolSync apps and runs `30-restore-volsync-app.sh` for each. Per-app it:
1. Confirms the app's Flux KS is suspended (left over from A.4)
2. Confirms the app's PVC does not exist (or is empty)
3. Applies `recovery-templates/<app>-restore.yaml` — a temporary manifest containing the volsync-restore component variables
4. Waits for the ReplicationDestination to materialize the restored PVC
5. Verifies the PVC has data
6. Removes the temporary recovery manifest
7. Resumes the Flux KS — the app now starts with the restored data

Each app takes **30s–2min** depending on data size. Total ~10 minutes for all 7.

### A.7. Verify everything

```bash
hack/disaster-recovery/90-verify.sh
```

Runs the same checks the cluster-health daily report runs, plus a few DR-specific ones (e.g. `home-assistant.io/states` returns the expected entity count).

### A.8. Re-enable backups

The recovery scripts leave the system in a state where backups are paused (so they don't immediately overwrite the recovered state with a fresh-but-empty one). Re-enable:

```bash
hack/disaster-recovery/95-resume-backups.sh
```

After this, the next scheduled CNPG ScheduledBackup + VolSync hourly sync will create a new restore point. **Wait for at least one full backup cycle to complete before declaring recovery done.**

---

## §B — Partial recovery scenarios

### §B.1. Single VolSync app restore

Scenario: just one PVC is corrupted (e.g. zwave store got nuked by a bad upgrade).

```bash
hack/disaster-recovery/30-restore-volsync-app.sh zwave-js-ui
```

The script:
1. Suspends the `zwave-js-ui` Flux KS
2. Scales the Deployment/StatefulSet to 0
3. Deletes the existing PVC (last chance to abort — script will pause here)
4. Applies the temporary restore manifest
5. Waits for restore to complete
6. Removes the temporary manifest
7. Scales the workload back, resumes the KS

### §B.2. Postgres point-in-time recovery (PITR)

Scenario: a bad migration corrupted the `home_assistant` database 2 hours ago.

```bash
hack/disaster-recovery/20-restore-postgres.sh --pitr "2026-04-07 14:00:00+02"
```

This is the same script as §A.5 but with a `--pitr` flag that adds `recoveryTarget.targetTime` to the recovery manifest. CNPG replays WAL up to that timestamp instead of the latest available.

You can also use `--pitr-backup-id <id>` to recover to a specific base backup (useful if you know exactly which backup is the last clean one).

### §B.3. Replace one node

Scenario: one of your NUCs died. The cluster keeps running on the remaining 5 nodes; this is just adding a replacement back.

This is **not a data recovery scenario** — Ceph re-replicates automatically once the new node joins. Steps:

```bash
# 1. Boot the new node from the Talos ISO at the same MAC address
# 2. Apply the existing Talos config for that hostname
just main talos apply-node vdhclu01node03

# 3. Wait for the node to join and Ceph to rebalance
kubectl wait node vdhclu01node03 --for=condition=Ready --timeout=10m
just main sync-hr rook-ceph rook-ceph-cluster
```

If the new node has a different MAC, update `kubernetes/main/talos/talconfig.yaml` first.

---

## §C — Gap analysis (what's NOT yet covered)

### C.1. **MinIO offsite mirror — single point of failure**

Currently: `cnpg-backups` + `volsync` buckets exist only on the Synology NAS at `/volume1/minio`. If the NAS dies (disk failure, lightning strike, theft), **all backups die with it**.

Mitigation options, in order of operational simplicity:

**Option 1: Synology Hyper Backup (NAS-side)**
- Configure Hyper Backup task on the Synology
- Source: `/volume1/minio`
- Target: Backblaze B2, AWS S3, Azure, or another Synology
- Pros: zero cluster involvement, encryption at rest, NAS-native scheduling
- Cons: tied to Synology UI, no in-cluster visibility

**Option 2: In-cluster `mc mirror` CronJob**
- Add a CronJob in `storage` ns running `minio/mc:latest`
- Daily `mc mirror local/{cnpg-backups,volsync} remote/...`
- Credentials from a new 1P field (`MINIO_OFFSITE_*`)
- Pros: same secret-management pattern as everything else, observable from cluster-health
- Cons: additional cluster surface area, requires offsite credentials

**Option 3: rclone CronJob (more provider support)**
- Same as option 2 but with rclone for non-S3 targets (Google Drive, OneDrive, Dropbox, etc.)
- Useful if you want to put backups in a personal cloud you already have

**Recommendation**: Option 1 (Synology Hyper Backup → Backblaze B2) is the cheapest and least invasive. ~$0.005/GB/month at B2 — your ~600 MiB of backups would cost <$0.01/month. Configure once, forget.

**Until this is in place**, treat the Synology as a hot copy and **manually rsync `/volume1/minio` to a USB drive monthly**. Don't skip this.

### C.2. Age key not yet backed up offline

**Action item**: copy `~/Code/homelab-migration/config/age.key` to:
- A physical USB drive in a safe at home
- A second USB drive in a different physical location (parent's house, bank safety deposit box, etc.)
- Optionally: print as a QR code (it's only 184 bytes — fits in a small QR)

The key looks like `AGE-SECRET-KEY-1...` — once printed, it's recoverable by retyping.

### C.3. Talos schematic + boot ISO

The Talos boot ISO URL is in memory (`https://factory.talos.dev/image/4b3cd373.../v1.12.6/metal-amd64.iso`). If Talos's image factory ever disappears, recovery becomes harder.

**Mitigation**: download the ISO once and store it on the same offline medium as the age key. It's ~80 MiB.

### C.4. DR procedure not yet tested

This runbook is unverified by drill. Recommended cadence:
- Quarterly: full DR drill into a test cluster (or Talos-in-Docker if hardware unavailable)
- Verifies the runbook still matches reality + your familiarity with the steps

---

## §D — Frequently missed pitfalls

1. **Don't forget to SUSPEND the Flux KS before deleting a PVC.** Without suspending, Flux will recreate the PVC empty within seconds, and the volsync-restore component won't get a chance to populate it.

2. **The CNPG recovery manifest is one-shot.** Once postgres has been recovered, you must remove the `bootstrap.recovery` block and re-apply the canonical cluster manifest, or every pod restart will trigger another recovery attempt.

3. **VolSync ReplicationDestination uses the same encryption password as ReplicationSource.** If `VOLSYNC_REPO_PASSWORD` was rotated but the rotation didn't get into the restored 1P, restore will fail with `cipher: message authentication failed`.

4. **Don't restore from a backup taken WHILE you were already in a degraded state.** If postgres started crashing 6 hours ago and the backup ran 4 hours ago, that backup is corrupt-state. Use `--pitr` to recover to a moment BEFORE the corruption began.

5. **The cluster-secrets Secret is bootstrapped via helmfile, not Flux.** A re-bootstrap re-creates it from `bootstrap/cluster-secrets.sops.yaml` (decrypted with the age key). It is intentionally NOT in the Flux kustomization — see commit `173c8ba` for the reasoning.

---

## §E — Useful one-liners during recovery

```bash
# Find the most recent postgres barman base backup ID
mc ls local/cnpg-backups/postgres16/postgres16/base/ | sort | tail -5

# Find the latest restic snapshot for a VolSync app
kubectl run -n storage --rm -it restic-list --image=restic/restic:0.17.0 --restart=Never \
  --env-from=secret/zwave-js-ui-volsync-secret -- snapshots latest

# Force a fresh manual sync trigger on a ReplicationSource
kubectl -n home-automation patch replicationsource zwave-js-ui --type merge \
  -p '{"spec":{"trigger":{"manual":"force-'$(date -u +%s)'"}}}'

# Suspend / resume a Flux KS
flux suspend ks postgres16
flux resume ks postgres16

# Show cluster bootstrap progress (during step A.3)
kubectl get nodes -w
```

---

## See also

- `kubernetes/main/bootstrap/mod.just` — the `just main bootstrap` recipe
- `hack/disaster-recovery/` — recovery automation scripts
- `hack/disaster-recovery/recovery-templates/` — manifest templates
- `docs/ai-context/WORKFLOWS.md` — day-to-day operational workflows
