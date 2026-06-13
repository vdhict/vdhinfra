# Renovate Auto-Merge Stuck in Flux/k8s Homelab Repos

## Question

Why are Renovate PRs in `vdhict/vdhinfra` not auto-merging despite `automergeType: "branch"` + `ignoreTests: true` + `minimumReleaseAge` conditions being met?

## TL;DR

- **Root cause 1 (YAML anchor key / parsing skip):** Renovate's YAML parser silently skips files where a YAML merge key (`*app:`) is used as a map key. `vdhict/vdhinfra` had one such file (`mealie/app/helmrelease.yaml`). This explains why mealie was never proposed as an update, not why general auto-merge is stuck. PR #66 fixes this.
- **Root cause 2 (stability-days + branch automerge interaction):** `automergeType: "branch"` with `minimumReleaseAge` works as follows: Renovate creates the branch and posts a `renovate/stability-days: pending` commit status. On a _subsequent_ run after the age passes, Renovate updates the status to `success` and merges the branch directly. If that follow-up run is rate-limited, scheduled out, or blocked by a config error, the status turns green but no merge happens, leaving a "stuck" PR.
- **Root cause 3 (Renovate config error unblocks everything):** `onedr0p/cluster-template` received a "Action Required: Fix Renovate Configuration" bot issue (#2231, opened and self-closed on 2026-05-26). The corresponding fix (`allowedEnv`/`env` for `MISE_TRUSTED_CONFIG_PATHS`) was committed the same day. This pattern — a config error halting all PR creation — matches the symptom of "all PRs stuck for weeks, then activity resumes."
- **Root cause 4 (mise strict lockfile mode):** The new `home-operations/renovate-presets` library (created 2026-05-19) shipped with `settings.locked = true` in `.mise.toml` in v1.2.0, which caused Renovate to fail during `mise install` when updating packages. Commit message: "drop strict lockfile mode to unblock Renovate" (2026-05-19, `e45aee9`). `vdhict/vdhinfra` does not use the preset library, so this root cause does not apply directly.
- **Recommended action for vdhict/vdhinfra:** Two independent fixes needed. (1) Merge PR #66 (mealie YAML anchor). (2) Diagnose why stability-days branches are not being followed up: check if Renovate's scheduled window (`before 6am every day`) is being honored, and whether the current open PRs (especially #72, cloudnative-pg patch, stability-days=success since ~May 14) can be merged by triggering a manual Renovate run via the Dependency Dashboard checkbox.

---

## What the community is reporting

### onedr0p/cluster-template

**Issue #2231** — "Action Required: Fix Renovate Configuration" (2026-05-26, opened and closed by `renovate[bot]` within 14 minutes). Body: "There is an error with this repository's Renovate configuration that needs to be fixed. As a precaution, Renovate will stop PRs until it is resolved." The fix was a same-day commit (`16d8f3b4`) adding `allowedEnv` and `env` for `MISE_TRUSTED_CONFIG_PATHS` to `.renovaterc.json5`.

**Commit `6966fb53`** (2026-05-20): "chore: update renovate config to use home-ops presents" — `onedr0p/cluster-template` migrated from an inline `config:recommended`-based config to `github>home-operations/renovate-presets#1.3.0`. This is a significant divergence from what `vdhict/vdhinfra` runs today.

**Commit `27f80e4e`** (2026-05-02): "chore: add auto-merge configuration for Mise Tools" — added the `automergeType: "branch"` pattern for mise tools, same as what `vdhict/vdhinfra` has.

### home-operations/renovate-presets (new library, first release 2026-05-19)

**v1.2.0** (2026-05-20): "chore: drop strict lockfile mode to unblock Renovate" (`e45aee9`). The library shipped with `settings.locked = true` in its own `.mise.toml`. When Renovate tried to run `mise install` during the preset's lock-file maintenance pass, it failed because the lock file couldn't be updated in the Renovate sandbox. The fix: remove `[settings] locked = true` and change `MISE_LOCKED=0 mise lock` back to `mise lock` in `.lefthook.toml`.

This confirms the pattern: **mise strict lockfile mode breaks Renovate's update cycle** and the community workaround is to drop `settings.locked = true`.

**v1.3.1** (2026-05-21): Minor cleanup. All auto-merge in the preset library is handled by `baseConfig.json5` extending `:automergeBranch` from `config:recommended`.

### renovatebot/renovate upstream

**PR #42591** (merged 2026-05-19): "feat(mise): add lock file support" — Renovate now natively understands `mise.lock` files and runs `mise lock [tools]` in `updateArtifacts()`. Before this was merged, any repo with `mise.lock` (or `settings.locked = true`) would cause `mise install` to fail in Renovate's sandboxed environment, blocking all updates.

**PR #42056** (merged 2026-05-13): "fix(github): set commit message explicitly for platform automerge" — When GitHub's "Use PR title and body as commit message" setting is enabled, Renovate's verbose PR description was being embedded as the squash commit body. This was cosmetic but affected repos using platform-level auto-merge.

**Issue #42161** (open, 2026-03-26): "Remove configuration options with `env: true` that don't make sense" — directly relevant to the `allowedEnv`/`env` config additions in the May 26 cluster-template fix.

---

## Root causes identified

### 1. YAML anchor as map key — silent parser skip

Renovate's YAML parser cannot handle files where an anchor alias (`*app`) is used as a **map key** (e.g., `*app: ...` inside `spec.values.controllers`). The parser silently skips the file and omits it from the Dependency Dashboard's "Detected Dependencies." No error is raised. This is a known limitation in Renovate's YAML handling; no upstream issue tracks it specifically.

Evidence: `vdhict/vdhinfra` PR #66 description (2026-05-01): "Renovate has never proposed an update for mealie even though it's 13 minor versions behind... The parser silently skips files that use a YAML anchor (`*app:`) as a map key." The diff shows replacing `*app:` with literal `mealie:` in three locations and dropping the `&app` anchor.

Impact: **Scoped to mealie only.** Does not explain the 11 open PRs.

### 2. Branch automerge + stability-days + no follow-up run

With `automergeType: "branch"` and `minimumReleaseAge: "3 days"`:

1. Renovate creates the branch and posts `renovate/stability-days: pending` commit status.
2. On a later run (after the release age passes), Renovate re-evaluates the branch, updates the status to `success`, and merges directly into `main` — **without any GitHub PR merge action**.
3. If step 2 never fires (Renovate doesn't re-visit the branch), the status shows `success` but no merge happens.

Observed in `vdhict/vdhinfra`: PR #72 (`fix(helm): update chart cloudnative-pg 0.28.0 → 0.28.2`) was created 2026-05-11. Its `renovate/stability-days` status shows `success` as of 2026-05-26 but `auto_merge: null` and the branch has not been merged. Renovate pushed updates to all open branches at 14:08–14:09 UTC on 2026-05-26, confirming it is running — but no branch merge fired.

The current `vdhict/vdhinfra` config has `ignoreTests: true` on all auto-merge rules. Per Renovate docs, `ignoreTests: true` causes Renovate to "ignore _all_ status checks." However, `renovate/stability-days` is an **internal Renovate check**, not an external CI check. The docs state internal checks "are not counted towards a branch being green" by default — they are treated separately from `ignoreTests`. This means `ignoreTests: true` may bypass external CI but still respect the stability-days pending state until Renovate itself resolves it.

### 3. Config validity error halts all PR activity

`onedr0p/cluster-template` had a Renovate config error that caused `renovate[bot]` to open issue #2231 on 2026-05-26 and self-close it 14 minutes later after a config fix was pushed. The bot's behavior ("stop PRs until resolved") matches what a blocked queue looks like from the outside.

`vdhict/vdhinfra` does not currently have an equivalent "Action Required" issue open. However, the dashboard issue #1 was last updated 2026-05-11, while Renovate has been actively pushing branches since. A stale dashboard combined with no merges is consistent with Renovate running branch updates but not completing the merge step.

---

## Recommendation

For `vdhict/vdhinfra` specifically (single operator, ~5 changes/day, no CI beyond stability-days):

**Immediate (Heph's domain — ref task #81):**
1. Merge PR #66 (mealie YAML anchor fix) — removes the parser-skip and enables mealie version detection.
2. Trigger a manual Renovate run on PR #72 by checking its "approvePr" checkbox in the Dependency Dashboard (issue #1). If Renovate merges it cleanly, the branch-automerge mechanism is intact and a scheduling/queue issue was the blocker.
3. If manual trigger does not fire a merge, investigate whether the `schedule: ["before 6am every day"]` is being honored by the Mend.io app. Check the Mend Developer Portal (`developer.mend.io/github/vdhict/vdhinfra`) for error logs.

**Config debt (watch, not urgent):**
- `vdhict/vdhinfra` still extends the pre-May-20 inline config (`config:recommended`, custom manager patterns). `onedr0p/cluster-template` migrated to `home-operations/renovate-presets` on 2026-05-20. The preset library centralizes manager patterns and semantic commits. Migration is optional but aligns with the upstream template direction.
- The preset library's current issue with `mise strict lockfile mode` is resolved in v1.2.0+. If `vdhict/vdhinfra` ever adopts the preset, ensure `.mise.toml` does not have `[settings] locked = true`.

---

## Sources

| # | URL | Fetch status | Date |
|---|-----|-------------|------|
| 1 | `github.com/vdhict/vdhinfra/issues/1` — Renovate Dashboard | live (API) | 2026-05-26 |
| 2 | `github.com/vdhict/vdhinfra/pulls/66` — YAML anchor fix | live (API) | 2026-05-26 |
| 3 | `github.com/vdhict/vdhinfra/pulls/72` — cloudnative-pg stuck PR | live (API) | 2026-05-26 |
| 4 | `github.com/onedr0p/cluster-template/issues/2231` — "Action Required: Fix Renovate Configuration" | live (API) | 2026-05-26 |
| 5 | `github.com/onedr0p/cluster-template` commit `16d8f3b4` — allowedEnv/env fix | live (API) | 2026-05-26 |
| 6 | `github.com/onedr0p/cluster-template` commit `6966fb53` — migrate to home-ops presets | live (API) | 2026-05-20 |
| 7 | `github.com/home-operations/renovate-presets/releases` — v1.0.0–v1.3.1 | live (WebFetch) | 2026-05-26 |
| 8 | `github.com/home-operations/renovate-presets` commit `e45aee9` — drop strict lockfile mode | live (API) | 2026-05-19 |
| 9 | `github.com/home-operations/renovate-presets/contents/config/baseConfig.json5` | live (API) | 2026-05-26 |
| 10 | `github.com/renovatebot/renovate/issues/42591` — feat(mise): add lock file support | live (API) | 2026-05-19 |
| 11 | `github.com/renovatebot/renovate/issues/42056` — fix(github): platform automerge commit message | live (API) | 2026-05-26 |
| 12 | `github.com/renovatebot/renovate/discussions/28268` — automerge commit message context | live (WebFetch) | 2026-05-26 |
| 13 | `docs.renovatebot.com/key-concepts/automerge/` — automergeType branch behavior | live (WebFetch) | 2026-05-26 |
| 14 | `raw.githubusercontent.com/renovatebot/renovate/main/docs/usage/configuration-options.md` — internalChecksAsSuccess / stability-days | live (WebFetch) | 2026-05-26 |
| 15 | `github.com/vdhict/vdhinfra` push events (API) — Renovate ran at 14:08 UTC 2026-05-26 | live (API) | 2026-05-26 |

— Athena
