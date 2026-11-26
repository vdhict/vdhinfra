# Runbook: wake Passkey Point on the cluster

**Audience**: Heph (k8s-engineer) or Atlas, when the team asks for a Passkey Point test environment.
**Background**: on 2026-11-20 the team decided Passkey Point is no longer internal; on the cluster it is a test
environment spun up on request (chg-2026-11-20-040). It was put to sleep in Git, nothing deleted: manifests,
images, Secrets, PVCs and the PostgreSQL data all stay.

## What is asleep

| Commit | What it did |
|---|---|
| `ff017cf6` | `replicas: 0` on `passkey-point-api` and `passkey-point-web` in `lab-passkey`, `lab-passkey-dotnet`, `lab-passkey-dotnet-maxsession`; `suspend: true` on CronJobs `passkey-point-e2e`, `passkey-point-e2e-dotnet` (ns `passkey-point-e2e`) and `devtenant-refresh-contractor-new` (ns `devtenant-build`) |
| `479c58d0` | the `lab-passkey-dotnet(-maxsession)-db` health check accepts a hibernated CNPG Cluster. **Keep this one**: it also works for a running Cluster |
| `76debd8f` | `cnpg.io/hibernation: "on"` on Cluster `pp-dotnet-pg` in `lab-passkey-dotnet` and `lab-passkey-dotnet-maxsession` |

`passkey-point-portal` and `passkey-point-roster` in `lab-passkey` were already at `replicas: 0` before this; the
revert leaves them at 0.

## Wake (one step)

From a fresh worktree off `origin/main`, never the main checkout:

```bash
git fetch origin main
git worktree add /path/to/wt-pp-wake origin/main && cd /path/to/wt-pp-wake
git switch -c chore/pp-wake
git revert --no-commit 76debd8f ff017cf6      # newest first; keep 479c58d0
git checkout HEAD -- ops/evidence/chg-2026-11-20-040   # ff017cf6 also added the evidence: keep it
git diff --cached --stat                        # expect 11 manifests: 6 replicas, 3 suspend, 2 annotations
git commit -m "chore(passkey): wake Passkey Point on the cluster (revert 76debd8f ff017cf6)"
# check + lines, then: gitleaks, push to main (fetch+rebase on non-ff, never force)
git push origin HEAD:main
```

If a later commit touched the same lines, resolve the conflict to: `replicas: 1`, `suspend: false`, and no
`cnpg.io/hibernation` annotation.

**Partial wake** (only the TypeScript LAB, or only the .NET LAB): edit `replicas` back to `1` in the matching
`desk/app/{api,web}.yaml` or `passkey-point/app/{api,web}.yaml`, and for .NET also remove the annotation from that
namespace's `db/app/cluster.yaml`. Leave the CronJobs suspended unless the nightly E2E must run again.

**Also on wake (two follow-up commits of chg-2026-11-20-040 that the revert above does not cover):**

- Turn the PDB back on: remove `enablePDB: false` (comment "hibernated, chg-2026-11-20-040") from
  `kubernetes/main/apps/lab-passkey-dotnet/db/app/cluster.yaml` and
  `kubernetes/main/apps/lab-passkey-dotnet-maxsession/db/app/cluster.yaml` (CNPG default is true).
- Remove the Alertmanager route that sends `KubeQuotaFullyUsed` for `namespace =~ "lab-passkey.*"` to `"null"`
  in `kubernetes/main/apps/observability/kube-prometheus-stack/app/alertmanager-secret.yaml`, so quota alerts
  watch the running LABs again. Then reconcile `kube-prometheus-stack`.

**Also on wake: the build app's Graph roles and its key (ar-011 D1, chg-2026-11-18-001).** From D1 (2026-11-23)
the build app `atlas-devtenant-build` (dev tenant 7m5b27gbc only) holds only K4: `AppRoleAssignment.ReadWrite.All`,
`Application.Read.All`, `RoleManagement.Read.Directory`, `Organization.Read.All`, and its key is NOT in the cluster.
The devtenant image's `appSignIn()` refuses a token whose roles differ from its 24-role manifest, so bootstrap-v01
and every other build-key tool fail closed until this step is done. Per-run mode (Argus review
`ops/evidence/chg-2026-11-24-003/argus-k4-regrant-81b70c3c-20261126T144228Z.txt`, C3): the CronJob
`devtenant-refresh-contractor-new` stays `suspend: true` during a wake. In the wake commit, keep it out of the
`ff017cf6` revert (or set it back to `suspend: true` in that same commit). The refresh runs only as a manual
`kubectl -n devtenant-build create job --from=cronjob/devtenant-refresh-contractor-new <name>`, after the regrant
Job ended exit 0 with a `done` line (mode regrant, `fullStateSha256`) AND a `fresh-token` line `ok:true`
`rolesCount:24` (C1). Read `spec.suspend` back (`true`) before the regrant and again after the cut. The
steps, in this order:

1. Key back (every run, since each sleep removes the key): `hack/ops/chg-2026-11-18-001-ar011-key-out.sh restore` re-applies the ExternalSecret
   `devtenant-build/atlas-devtenant-build-key` (ClusterSecretStore `onepassword-devtenant-build`, item
   `atlas-devtenant-build`, `tls.key` + `tls.crt`). Readback: ES Ready, Secret has exactly those two keys.
   The 1Password item in vault `passkey-point-devtenant-build` was never removed.
2. Roles back, per E2E run (teamkeuze B1 (a), tsk-2026-11-17-110): `K4_REGRANT=1 node /work/k4.mjs regrant --expect 7db4ce52073d5e7a91e46c3bfeb14ed406d96808741027ef91b57c10b35d92b9`
   in a devtenant-build Job with the build key mounted (same own sign-in, accepts K4, a partial run or the 7d850ff5 set).
   It POSTs exactly the 20 `regrantForWake` roles (list pinned by that sha; planSha `33720a3d...` of the 20-role cut is
   its origin), then reads back FULL24 three times in a row and needs a fresh token with exactly 24 roles, wids
   `[0997a1d0...]` only, roleAssignments 0, transitiveMemberOf 0. Fail closed: exit 6 after a write that did not end
   in that state. Idempotent. Exit 6 (or any exit other than 0 without the `done` line): no refresh, no E2E. One
   resume is allowed (same `--expect`); if that does not end in a `done` line, run `key-out.sh remove`, open an
   incident, and do not hand-craft a partial cut (C5). The `done`
   line prints `fullStateSha256`: assignment ids are new, so 7d850ff5 no longer matches. Needs Argus GO on the script
   first (AGR-087). After D2 (OwnedBy + window helper) this step becomes "open a provisioning window"; do not re-grant 20.
3. Then wake as above, and run the refresh by hand as described above (not by schedule); `bootstrap-v01` uses the
   image's own `appSignIn()` again.

Sleeping again (after each run): `node /work/k4.mjs plan` -> `cut --expect <planSha> --state <fullStateSha256 from regrant>` -> `readback` (devtenant-build Job, build key
mounted), then `hack/ops/chg-2026-11-18-001-ar011-key-out.sh remove`.

## Reconcile

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile ks lab-passkey-app -n flux-system
flux reconcile ks lab-passkey-dotnet-db -n flux-system
flux reconcile ks lab-passkey-dotnet-maxsession-db -n flux-system
flux reconcile ks devtenant-base -n flux-system
```

The .NET chain runs in order by itself: `*-db` (waits until PostgreSQL is healthy) -> `*-migrate` -> `*-grants` ->
`*-desk` (api/web back to 1) -> `devtenant-e2e-dotnet`. Allow up to 10 minutes.

## CNPG hibernation off

The revert drops the annotation; Flux removes it from the live Cluster (Flux owns that field). Check:

```bash
kubectl -n lab-passkey-dotnet get cluster pp-dotnet-pg -o jsonpath='{.metadata.annotations}'
```

If `cnpg.io/hibernation` is still `on` after Flux applied the revert commit, set it off by hand (do not delete
the Cluster or its PVC):

```bash
kubectl -n lab-passkey-dotnet annotate cluster pp-dotnet-pg cnpg.io/hibernation=off --overwrite
```

Same for `lab-passkey-dotnet-maxsession`. CNPG starts `pp-dotnet-pg-1` on the existing PVC `pp-dotnet-pg-1`.

## Readback: proof it is up

All must hold; "reconciled" alone is not proof.

1. `flux get ks -n flux-system | grep -E 'passkey|devtenant'`: every line `True`, at the revert commit or later.
2. Per .NET namespace: `kubectl -n <ns> get cluster pp-dotnet-pg -o jsonpath='{.status.phase} {.status.readyInstances}'`
   gives `Cluster in healthy state 1`, and the condition `cnpg.io/hibernation` is gone or `False`.
3. `kubectl -n <ns> get deploy` in `lab-passkey`, `lab-passkey-dotnet`, `lab-passkey-dotnet-maxsession`:
   `passkey-point-api` and `passkey-point-web` at `1/1`; `kubectl -n <ns> get pods` all `Running`, `0` restarts climbing.
4. The site answers through the internal gateway: HTTPRoutes `passkey-point-lab`, `passkey-point-dotnet-lab`,
   `passkey-point-dotnet-lab-maxsession` show `Accepted`/`ResolvedRefs` True, and a GET on the host
   (`kubectl get httproute -n <ns> -o jsonpath='{.items[*].spec.hostnames}'`) returns the login page, not 503.
5. CronJobs: `kubectl get cronjob -n passkey-point-e2e` and `-n devtenant-build` show `SUSPEND False`, except `devtenant-refresh-contractor-new`, which shows `SUSPEND True` (per-run
   mode, run by hand after a successful regrant); the build
   app's roles are back to the 24 names and `atlas-devtenant-build-key` exists (step "build app's Graph roles").
6. The next nightly E2E (`passkey-point-e2e` 02:40, `-dotnet` 03:50 Europe/Amsterdam) ends `Complete`. A manual
   run (`kubectl create job --from=cronjob/...`) writes to the dev tenant: only when the team asks for it.

## Rollback of the wake

`git revert` the wake commit and reconcile: this is the sleep state again. Before hibernating again, take a
VolumeSnapshot of `pp-dotnet-pg-1` (class `csi-ceph-blockpool`), as on 2026-11-20
(`pp-dotnet-pg-1-pre-hibernate-20261120` in both .NET namespaces).

## Notes

- Images are pinned by digest on the forge registry and were not removed; if a wake fails with `ImagePullBackOff`,
  check the registry and `*-pull` Secrets before anything else.
- The cluster-health triage never touches these namespaces (NEVER_NAMESPACES); wake and sleep are manual.
- `CronJobNoRecentSuccess` ignores suspended CronJobs; after a wake it watches them again (26 h).
