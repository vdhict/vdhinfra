# chg-2026-10-05-031 B3: who can make the vdhict runner run code (read-only, 2026-11-03T13:36Z)

**Source:** forge-pg primary, `SET default_transaction_read_only = on`, SELECT only, via
`kubectl --context admin@vdhinfra-local`. Only names and counts are recorded: no tokens, no secret names, no repo
names.

## Org vdhict (34 repositories, 34/34 private)

| Account | Kind | How it can write | Reach |
|---|---|---|---|
| admforgejo | team: forge site admin | org team `owners` (authorize 4 = owner, all repos) | 34 repos, every unit incl. Actions |
| mypka-bot | team: myPKA bot | org team `mypka-write` (authorize 1; units code/issues/PRs/releases/wiki = write; **no Actions unit**) | 6 repos |
| docs-bot | team: docs bot | collaborator, mode 2 (write), **not** an org member | 1 repo |
| palamedes | team: app-engineer agent identity | collaborator, mode 2 (write), not an org member | 1 repo |
| pka-mini-read | team: Mini read-only fetch (chg-2026-10-30-001) | collaborator, mode 1 (read), not an org member | 7 repos, read only |

**Result:** every account that can push a workflow is a team or system account. No client or other non-team account
appears anywhere in vdhict:
- no org member outside the team;
- no outside collaborator with write;
- no forks of vdhict repos.

**Flag:** none (`<klant>` not needed).

## Writers who can trigger a `docker` job

A writer can trigger a job by pushing a workflow or a commit: admforgejo (34 repos), mypka-bot (6), docs-bot (1)
and palamedes (1). That is 4 identities, all team-controlled. Their credentials sit on:
- the Mini (uid 501, shared with myPKA);
- the cluster;
- the MacBook.

The D1c residual (every org writer gets VM root) therefore means "every team identity that holds a write credential
to vdhict".

## Fork-PR approval

- **Forgejo 15 has no off switch** (source `forgejo/services/actions/trust.go`, branch v15.0, lines 80, 214–232).
  A pull request **from a fork** (or AGit) gets `need_approval` unless the poster has **write on the Actions unit**
  of the base repo, or has been explicitly trusted (`action_user.trusted_with_pull_requests`).
- **Measured:**
  - 0 explicit trust entries (`action_user` empty);
  - 0 forks of vdhict repos;
  - 0 of 323 vdhict runs needed approval.
- **The only fork-capable non-writer is pka-mini-read** (read on 7 repos). A fork PR from it would wait for approval
  from someone with Actions write. In vdhict that is only admforgejo, because mypka-write has no Actions unit.

## For Argus

- Condition B3 "non-team/client writer -> repo scope" does not trigger: there is none.
- The fork-PR approval is enforced by the forge itself, with no explicit-trust bypass present. Keep it so: never use
  "always trust" on vdhict.
- Re-check before the first counted job, and again whenever a collaborator or team member is added to vdhict.
  `post-run-checks.sh writers` repeats this query.
