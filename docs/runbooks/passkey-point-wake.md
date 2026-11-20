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
5. CronJobs: `kubectl get cronjob -n passkey-point-e2e` and `-n devtenant-build` show `SUSPEND False`.
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
