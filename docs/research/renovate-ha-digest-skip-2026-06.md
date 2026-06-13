# Renovate skipped the digest-pinned HelmRelease on the HA minor bump (2026-06)

## Question

Why did Renovate fail to generate the digest-pinned HelmRelease bump for
`ghcr.io/home-operations/home-assistant` `2026.5.4` → `2026.6.2`, while it DID
bump the same image in the non-digest-pinned `docker-compose.yaml` — even though
*patch* bumps of the same digest-pinned reference (e.g. `2026.5.3` → `2026.5.4`)
had worked fine?

## TL;DR

- **Confirmed from source:** the failing PR (#79, Renovate worker `43.209.4`,
  created 2026-06-04) contained **only one changed file** — the docker-compose
  fixture hunk (`+image: …:2026.6.2`). The digest-pinned `helmrelease.yaml`
  occurrence was omitted from the branch entirely. The PR update table has a
  single row, type `minor`, no separate `digest` line.
- **The asymmetry is structural, not random.** The docker-compose occurrence is
  a bare tag (`currentValue` only → simple single-field string replace, always
  works). The helmrelease occurrence is a combined `tag: <ver>@sha256:<digest>`
  string, which the kubernetes/flux manager parses into **both** `currentValue`
  *and* `currentDigest`. A minor bump changes **both fields at once** — Renovate's
  weakest autoreplace path.
- **Best-supported root cause (inference, grounded in Renovate source + the
  upstream fix-chain):** Renovate's `confirmIfDepUpdated` gate
  (`auto-replace.ts` L106–122) rejects an occurrence with log `"Digest is not
  updated"` when `newDigest` is set but the post-replace re-extracted
  `currentDigest` ≠ `newDigest`. When that gate fails for the combined-string
  occurrence, that file edit is dropped while the other occurrence in the same
  branch proceeds — exactly the observed shape. The "both value + digest change"
  autoreplace path has a multi-year bug history (#36461 → #38066 → #38308 →
  #42840), all scoped to *separate-token / jsonata* managers; **no upstream issue
  precisely covers the combined-string kubernetes/flux manager case.**
- **Why patch bumps worked but the minor didn't is *not* fully provable from the
  evidence I can reach** (the Mend job log is auth-gated — see Sources). The most
  likely differentiator is digest *resolution* timing on the month-rollover index,
  not the replace logic. Stated honestly as a hypothesis, not a confirmed fact.
- **Recommended fix: stop tracking the duplicate.** `ignorePaths` the
  `hack/restore-test/**` fixture (or drop its version pin). This removes the
  second occurrence that shares the branch, so the helmrelease becomes a clean
  single-occurrence update — and it deletes a class of "fixture gates prod PR"
  problems we have already had to paper over once. Low risk, no prod impact.

---

## Evidence (confirmed from live source, 2026-06-10)

All GitHub data fetched via the GitHub App installation token (REST + GraphQL
API), not WebFetch React shells.

### 1. The PR contained only the fixture, not the helmrelease

`GET /repos/vdhict/vdhinfra/pulls/79` and `/pulls/79/files`:

- Title: `feat(container): update image ghcr.io/home-operations/home-assistant ( 2026.5.4 ➔ 2026.6.2 )`
- State: `closed`, `merged: true` (Athena's hand-bump merge), head ref
  `renovate/ghcr.io-home-operations-home-assistant-2026.x`.
- **Files changed: exactly one** — `hack/restore-test/docker-compose.yaml`,
  `+1 -1`, patch `-image: …:2026.5.4` / `+image: …:2026.6.2`.
  `helmrelease.yaml` is **absent** from the file list.
- Body update table: a single dependency row, `minor 2026.5.4 → 2026.6.2`. No
  separate digest row.
- `renovate-debug` footer (base64-decoded): `createdInVer`/`updatedInVer`
  `43.209.4`, `targetBranch main`, `labels: ["renovate/container","type/minor"]`
  — only the minor/container labels, **no `type/digest`**.
- Body Configuration block: `🚦 Automerge: Disabled by config.` (the fixture rule
  matches, but the combined PR still surfaced as manual — consistent with the
  earlier automerge investigation; see Reconciliation).

### 2. Digest resolution for this image works normally for patch bumps

`GET /commits/cab0754`:
`fix(container): update image … ( 2026.5.3 ➔ 2026.5.4 )` patched
`helmrelease.yaml`:
`tag: 2026.5.3@sha256:05dc00… → tag: 2026.5.4@sha256:42d1bc…` — **both tag AND
digest updated in the combined string**. So the docker datasource resolves and
the autoreplace writes this image's digests correctly for patch.

### 3. Both occurrences feed the same branch / are both tracked

Dependency Dashboard (issue #1, stale — last updated 2026-05-11) "Detected
Dependencies" lists the image under both the `docker-compose (…)` group
(`hack/restore-test/docker-compose.yaml`) and the `flux (57)` group
(`…/home-assistant/app/helmrelease.yaml`). Same `depName`, same datasource
(`docker`) → same branch `renovate/…-2026.x`.

### 4. The kubernetes/flux manager parses the combined string into both fields

`lib/modules/manager/kubernetes/extract.ts` (main) emits `currentValue` *and*
`currentDigest` per dep (L66–67, L90–91) — it uses the shared docker
`splitImageParts`. So `tag: 2026.5.4@sha256:42d1bc…` becomes
`{currentValue: "2026.5.4", currentDigest: "sha256:42d1bc…"}`. A minor bump
therefore presents Renovate with **both `newValue` and `newDigest` changing for
the same single token** — the multi-field replace case. The docker-compose
occurrence has `currentValue` only (no digest), so it is a trivial single-field
replace.

### 5. The autoreplace gate that drops a digest occurrence

`lib/workers/repository/update/branch/auto-replace.ts` (main):

- `doAutoReplace` (L200+) builds `replaceString` and, when both `currentValue`
  and `currentDigest` change, must replace **both** within the one token
  (L299–327 handle digest, including the `currentDigestShort` fallback).
- `confirmIfDepUpdated` (L106–122) is the verification gate:
  ```
  if (upgrade.newDigest &&
      (upgrade.isPinDigest === true || upgrade.currentDigest) &&
      upgrade.newDigest !== newUpgrade.currentDigest) {
    logger.debug({…}, 'Digest is not updated');
    return false;
  }
  ```
  If the post-replace re-extract doesn't show the new digest, the occurrence is
  rejected. A rejected occurrence is left out of the branch — which is precisely
  what we observe: the helmrelease hunk never appeared.

### 6. Upstream fix-chain for "both value + digest change" — adjacent, not exact

- Discussion **#36461** `custom.jsonata: manager can't update both the
  currentDigest and the currentVersion` — the canonical statement of this bug
  class (separate `version`/`digest` tokens in a jsonata manager).
- PR **#38066** (merged 2025-09-19) `fix(jsonata): updates when version and
  digest changed` — added the `changedCount`/`replaceWithoutReplaceString`
  heuristic.
- PR **#38308** (merged 2026-02-27) `fix(autoreplace): updates when version and
  digest changed` — cherry-pick + regression fix of the same.
- PR **#42840** (merged 2026-05-30) `fix(autoreplace): handle digest-only update
  without replaceString` — *replaced* the `changedCount > 1` heuristic; body
  explicitly scopes to "jsonata custom managers where `currentValue` and
  `currentDigest` live in separate tokens."

Worker **`43.209.4` was published 2026-06-03** — so PR #79 (2026-06-04) ran a
worker that **already included #42840**, yet still failed. This rules out "#42840
would have fixed it." The remaining gap (combined single-token `tag@sha256` for
the docker/flux manager on a both-fields change) is **not covered by any upstream
issue I could find** (searched the renovatebot/renovate tracker via API; closest
hits are all jsonata/separate-token).

### 7. What I could NOT verify

- **Mend job log** (`developer.mend.io/github/vdhict/vdhinfra`): not accessible
  to me (page returns empty content without an authenticated session). I cannot
  confirm whether the live log shows the `"Digest is not updated"` debug line or a
  digest-lookup warning. **Could not verify** — the `confirmIfDepUpdated` root
  cause is inference from source, not a quote from this repo's run log.
- Why **patch** succeeded while **minor** failed for the *same* combined-string
  occurrence is therefore not provable end-to-end from my reachable evidence.

---

## Root-cause analysis

**Confirmed:** The two occurrences take different autoreplace paths. The fixture
is a bare tag (single-field replace, robust). The helmrelease is a combined
`tag@sha256` token whose minor bump changes *both* `newValue` and `newDigest`
inside one string — the path guarded by `confirmIfDepUpdated`'s "Digest is not
updated" rejection. A rejected occurrence is omitted from the branch while the
sibling occurrence proceeds. This fully explains the *asymmetry* (helmrelease
skipped, docker-compose updated) directly from source.

**Inference (best hypothesis, because X / because Y):** the helmrelease
occurrence's `newDigest` either (X) was not resolved for the `2026.6.x`
multi-arch index at branch time, or (Y) was resolved but failed the in-token
replace+confirm, tripping the L119 gate. Either way `confirmIfDepUpdated`
returns false and the edit is dropped. The patch bump (`cab0754`) worked because
it is the same code path on a same-month digest that resolved cleanly; the only
plausible differentiator on the month-rollover minor is a transient digest
resolution / index-mediatype hiccup on the new `2026.6.x` OCI index. **I cannot
confirm which without the Mend job log** (see §7), so I am labelling this a
hypothesis, not a fact.

**What is NOT the cause** (ruled out from source/config): not a general digest
failure (patch worked, §2); not the `*app:` YAML-anchor parser skip from the May
investigation (HA file parses, §3/§4); not `minimumReleaseAge` (a held update
would still appear in the dashboard/branch with both files — here the helmrelease
hunk is simply absent); not worker version lag past #42840 (43.209.4 includes it,
§6).

---

## Recommendation

**Pick (b): stop tracking the fixture duplicate.** Add `hack/restore-test/**`
to `ignorePaths` (or drop the version pin in the fixture to `:latest`/unpinned so
Renovate ignores it). Rationale:

1. It removes the *second occurrence that shares the branch*. The helmrelease
   then updates as a single-occurrence dependency — still a combined-string
   minor bump, but with no sibling masking the failure and no fixture-gates-prod
   coupling. (We already had to add a whole `packageRule` on 2026-05 just so the
   fixture wouldn't gate the prod PR's automerge — see the config comment block.
   Ignoring the fixture deletes that entire failure class.)
2. The restore-test compose file is a **disaster-recovery drill fixture**, not a
   running service. Its image version does not need to track prod automatically;
   the drill pulls whatever is current when it runs. Tracking it buys nothing and
   has now cost two investigations.
3. Lowest risk: a one-line `ignorePaths` edit, no prod manifest touched, no
   change to how the prod helmrelease is updated.

**Trade-off:** the fixture's images will drift; on the next restore drill,
manually align the compose tags with prod first (a 30-second `grep`).

**Why not the others:**
- **(a) config tweak / `pinDigests` / `postUpgradeTasks`:** does not address the
  root mechanism (the combined-string both-fields replace), and there is no
  upstream-documented option that flips this behavior. `separateMinorPatch` would
  not help (still a minor). A `postUpgradeTask` re-running a digest resolver is
  fragile and disabled on Mend-hosted Renovate anyway. Higher complexity, lower
  confidence.
- **(c) accept + hand-bump monthly:** what we did this time. Sustainable only
  because HA's monthly cadence is predictable, but it silently re-introduces the
  "prod stuck on old version" risk every month and depends on a human noticing.
  Reject as the standing answer.

**Secondary (optional), independent of the fix:** when a clean repro is wanted,
file an upstream issue against renovatebot/renovate with a minimal
kubernetes-manager fixture (`tag: <ver>@sha256:<digest>`, minor bump, both fields
change) — none exists today (§6), and the maintainers' jsonata fix chain shows
they treat this class as a real bug.

---

## Reconciliation with `renovate-stuck-auto-merge-2026-05.md`

That earlier doc investigated **why Renovate PRs were not auto-merging** (branch
automerge + stability-days follow-up, the `*app:` YAML-anchor parser skip, and a
config-error halt). **This doc is a different failure** and supersedes nothing in
it; it *extends* it:

- The May doc's root causes were about **merge/creation of PRs**. This is about
  **content of a created PR** — a per-occurrence autoreplace skip.
- The `🚦 Automerge: Disabled by config` line on PR #79 is consistent with the May
  doc's branch-automerge findings and the fixture `packageRule` added afterwards;
  it is **not** the cause of the missing helmrelease hunk.
- The stale Dependency Dashboard (issue #1, frozen at 2026-05-11) noted here as
  §3 is the same staleness the May doc flagged (root cause 2/3). Unresolved;
  tracked there, not re-opened here.

---

## Sources

| # | URL | Fetch status | Date |
|---|-----|-------------|------|
| 1 | `api.github.com/repos/vdhict/vdhinfra/pulls/79` + `/files` — single fixture file, minor-only table, renovate-debug `43.209.4` | live (API) | 2026-06-10 |
| 2 | `api.github.com/repos/vdhict/vdhinfra/commits/cab0754` — patch bump updated tag+digest in helmrelease | live (API) | 2026-06-10 |
| 3 | `api.github.com/repos/vdhict/vdhinfra/issues/1` — Dependency Dashboard (stale 2026-05-11), HA tracked in both managers | live (API) | 2026-06-10 |
| 4 | `api.github.com/repos/vdhict/vdhinfra/contents/.../home-assistant/app/helmrelease.yaml` — current `tag: 2026.6.2@sha256:124cfd…` | live (API) | 2026-06-10 |
| 5 | `renovatebot/renovate` `lib/modules/manager/kubernetes/extract.ts` — emits currentValue+currentDigest | live (API, contents) | 2026-06-10 |
| 6 | `renovatebot/renovate` `lib/workers/repository/update/branch/auto-replace.ts` — `confirmIfDepUpdated` L106–122 "Digest is not updated"; combined-token replace L299–327 | live (API, contents) | 2026-06-10 |
| 7 | `renovatebot/renovate` discussion #36461 — "can't update both currentDigest and currentVersion" | live (GraphQL) | 2026-06-10 |
| 8 | `renovatebot/renovate` PR #38066 (merged 2025-09-19) — jsonata both-fields fix | live (API) | 2026-06-10 |
| 9 | `renovatebot/renovate` PR #38308 (merged 2026-02-27) — autoreplace both-fields fix | live (API) | 2026-06-10 |
| 10 | `renovatebot/renovate` PR #42840 (merged 2026-05-30) — digest-only-without-replaceString; scoped to separate-token jsonata | live (API) | 2026-06-10 |
| 11 | `renovatebot/renovate` release tag `43.209.4` published 2026-06-03 (≥ #42840) | live (API) | 2026-06-10 |
| 12 | `docs.renovatebot.com/docker/` — retains tag alongside digest; combined-ref simultaneous update undocumented | live (WebFetch) | 2026-06-10 |
| 13 | `developer.mend.io/github/vdhict/vdhinfra` — Mend job log | **could not verify** (auth-gated, empty content) | 2026-06-10 |

— Athena
