# 0004 — Forge backups stay on-prem only (interim)

Status: accepted (interim)
Date: 2026-09-23
Decision-makers: user (Sander), recorded by Atlas

## Context

The Forgejo programme (`chg-2026-09-15-003`) backs up the forge in two ways: barman
for forge-pg goes to `s3://forge-backups`, and VolSync restic for the Forgejo data
PVC goes to `s3://forge-volsync`. Both buckets live on MinIO, which is backed by the
Synology NAS. Neither bucket is in the `minio-offsite-mirror` loop
(`for bucket in cnpg-backups volsync`). That was deliberate: the programme approval
says "off-site copying of client repos … default remains NO".

Themis raised this as a user decision on `chg-2026-09-18-002`. One event (a house
fire, theft, or losing both Ceph and the NAS) destroys the forge and every copy of
it at once. The NAS has no backup of itself either (`inc-2026-09-15-005`).

## Decision

Sander, 2026-09-23, typed in session:

> I accept that the forge has no off-site backup for now, and the same risk for
> other projects until I decide on off-site backups in general. Not a blocker for
> P2 or P3.

- Forge backups (`forge-backups`, `forge-volsync`) stay **on-prem only**.
- The same acceptance covers other projects' repos hosted on the forge. The first
  are `garmin-health`, `pka-tennis-sync` and `pka-voetbal-sync`, which today have
  **no remote at all**. Moving them to the forge strictly improves their position
  (one copy on the Mini → Mac + forge + on-prem backups).
- This is **not** a decision against off-site backup. It lasts until Sander decides
  on off-site backups in general.

## Consequences

- A site-level loss destroys the forge and its backups. For the three repos above,
  the Mini's working copy is a second copy only while the Mini survives.
- The off-site path stays opt-in. Adding a forge bucket to the mirror loop, or any
  other off-site copy, needs a separate approval. `chg-2026-09-15-003` does not
  cover it.
- Review when the general off-site-backup decision is made, and by 2027-03-23 at
  the latest.
