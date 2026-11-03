# vdhwslin01 waker: narrow queue-read route (design note, Argus C6)

- **Status:** proposed, 2026-11-03.
- **Change:** chg-2026-10-05-031, owner k8s-engineer (Heph).
- **Deadline:** within 30 days of the waker going live (Argus qa_failed 2026-11-03T13:40Z, condition C6).
- **This note:** design only. Nothing here is applied.

## Problem

The Mini waker has to know whether org vdhict has waiting jobs for labels `docker`/`x86-linux`. Today it runs one
read-only SELECT on the forge-pg primary through `kubectl --context admin@vdhinfra-local exec`, which is
**cluster-admin**. No credential is added, but an unattended loop holds rights far beyond "count the queue". The
Forgejo API is no alternative: every route that lists jobs needs org or repo **owner** rights, and an owner-read token
can also fetch a runner registration token.

## Target: the Mini reads one number from one ConfigMap

```
forge-pg (CNPG) --SELECT on one view--> CronJob devtools/vdhwslin01-queue (every 1 min)
   --> ConfigMap devtools/vdhwslin01-queue {waiting, running, oldest_waiting_unix, ts}
   --> Mini: SA vdhwslin01-queue-reader, Role: get on configmaps, resourceNames [vdhwslin01-queue]
```

1. **DB role and view** (CNPG managed role, declarative in the forge-pg `Cluster` spec):
   - Role `vdhwslin01_queue`: LOGIN, NOINHERIT, no superuser, no createdb, `CONNECTION LIMIT 2`. The password comes
     from a CNPG-managed Secret in devtools, which never leaves the namespace.
   - View `public.vdhwslin01_queue` (owner postgres, `security_barrier`). It returns exactly one row:
     `count(*) FILTER (status=5)`, `count(*) FILTER (status=6)`, and `min(created) FILTER (status=5)`. Only jobs of
     org vdhict whose `runs_on` (jsonb) is a non-empty subset of `["docker","x86-linux"]` are counted. Labels and org
     are fixed in the view, not parameters.
   - `REVOKE ALL ON SCHEMA public FROM vdhwslin01_queue`, then `GRANT USAGE ON SCHEMA public` and
     `GRANT SELECT ON public.vdhwslin01_queue` only. No table grants at all.
   - pg_hba: `hostssl forgejo vdhwslin01_queue <pod CIDR> scram-sha-256` only.
2. **CronJob `vdhwslin01-queue`** (devtools, every 1 min, `concurrencyPolicy: Forbid`, ttl 300 s):
   - Image: vendor `postgres` client by digest, plus `kubectl` (or a tiny stdlib script with the SA token). It writes
     the one-row result into the ConfigMap.
   - Runs as uid 65534, read-only root, drop ALL, seccomp RuntimeDefault, no service links.
   - Its own SA with RBAC `update, patch, get` on `configmaps` resourceName `vdhwslin01-queue` only.
   - CNP egress: forge-pg-rw:5432 + kube-apiserver; ingress none.
3. **Mini reader:**
   - SA `vdhwslin01-queue-reader` (devtools) with Role `get` on configmaps, resourceNames `[vdhwslin01-queue]`.
   - Token: `kubectl create token --duration 720h`, stored 0600 at `~/.config/vdhwslin01/queue-reader.kubeconfig`,
     rotated monthly.
   - The waker drops `--kubectl`/cluster-admin and reads the ConfigMap over the apiserver with that kubeconfig. It
     treats `ts` older than 5 min as `queue_unreadable`, which fails closed and gives the hourly line.
4. **What the Mini can still do with it:** read three integers and a timestamp. No exec, no pods, no secrets, no
   forge data. The Mini's cluster-admin is no longer used by the waker. It still exists for Atlas: retiring it is a
   separate topic.

## Tests (before switching)

- The role can `SELECT` the view. `SELECT 1 FROM action_run_job`, `secret`, `user` and `access_token` → permission
  denied. `CREATE` anything → denied.
- A login from outside the pod CIDR is rejected by pg_hba.
- The SA reader can get the ConfigMap. Get any other ConfigMap, list configmaps, get secrets, or exec → 403.
- Counts equal the current waker query on the same snapshot, including 0 jobs, waiting-only and running-only.
- Stale `ts` (CronJob suspended) → waker `queue_unreadable` after the grace period, then one line and one ntfy.
- Rollback: unsuspend nothing. Revert the commit (Flux prunes CronJob/RBAC/ConfigMap), drop the role and view via
  the CNPG spec, and the waker falls back to `--kubectl` (kept behind a flag for one release).

## Not chosen

- **An org-owner forge token:** it can fetch registration tokens, and that means rogue runners.
- **A Postgres port-forward from the Mini with the role:** it needs `pods/portforward`. That is broader than a single
  ConfigMap get, and the DB password would have to live on the Mini.
- **A webhook from Forgejo on job queued:** Forgejo 15 has no queued-job webhook event for org runners.
