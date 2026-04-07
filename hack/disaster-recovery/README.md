# Disaster Recovery Scripts

Companion automation for `docs/runbooks/disaster-recovery.md`. **Read the runbook first** — these scripts are the moving parts; the runbook is the assembly manual.

## ⚠️ Safety properties

Every script in this directory:
- **Refuses to run against a healthy cluster** unless `--force` is passed
- **Is idempotent** — re-running after a failure doesn't compound the damage
- **Prints exactly what it will do and pauses** for confirmation before any destructive action
- **Logs every kubectl call** so you can audit afterward

## Script index

| Script | Phase | What it does |
|---|---|---|
| `00-prereqs.sh` | Pre-flight | Verifies the age key, sops, kubectl, mc, and cluster reachability |
| `15-pause-stateful.sh` | After bootstrap | Suspends Flux KSes for postgres16 + 7 VolSync apps so they don't start with empty data |
| `20-restore-postgres.sh` | Data recovery | Recovers postgres16 from barman. Supports `--pitr` for point-in-time recovery |
| `30-restore-volsync-app.sh` | Data recovery | Restores ONE VolSync app's PVC from MinIO. Pass app name as arg |
| `30-restore-volsync-all.sh` | Data recovery | Loops `30-restore-volsync-app.sh` over all 7 apps |
| `90-verify.sh` | Post-recovery | Health-checks the cluster and verifies expected data |
| `95-resume-backups.sh` | Post-recovery | Re-enables ScheduledBackup + ReplicationSource triggers |

## Templates

`recovery-templates/` holds the one-shot manifests that recovery scripts apply to override the canonical app specs:

- `postgres16-recovery.yaml` — CNPG cluster with `bootstrap.recovery` instead of `bootstrap.initdb`
- `volsync-restore-<app>.yaml` — generated per-app at recovery time, NOT committed to repo (each script writes its template to /tmp before applying)

## Required CLI tools

- `kubectl` (1.35+)
- `flux` (Flux v2 CLI)
- `sops`
- `age`
- `mise` (provides everything via `.mise.toml`)

Install all of them with `mise install` from the repo root.

## Required env

```bash
export KUBECONFIG=/path/to/recovered/kubeconfig
export SOPS_AGE_KEY_FILE=~/Code/homelab-migration/config/age.key
```

## Usage examples

```bash
# Full DR after total loss
./00-prereqs.sh
just main bootstrap            # standard bootstrap
./15-pause-stateful.sh         # IMMEDIATELY after bootstrap
./20-restore-postgres.sh
./30-restore-volsync-all.sh
./90-verify.sh
./95-resume-backups.sh

# Just restore one VolSync app (e.g. zwave got nuked)
./30-restore-volsync-app.sh zwave-js-ui

# Postgres point-in-time recovery
./20-restore-postgres.sh --pitr "2026-04-07 14:00:00+02"
```

## Limits

These scripts assume the cluster, MinIO, and 1Password are all reachable. If any is missing, you have a deeper problem — see `docs/runbooks/disaster-recovery.md` §C (gap analysis) for that case.
