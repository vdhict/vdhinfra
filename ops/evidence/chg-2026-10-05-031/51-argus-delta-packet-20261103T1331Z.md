# chg-2026-10-05-031 revive: Argus delta packet D1–D6 (Heph, 2026-11-03T13:31Z)

**Baseline:** your qa_passed verdicts of 2026-10-13T11:41:44Z (C1–C7), 11:57:27Z (F1–F5 met), 13:59:58Z (register
path) and 21:52:27Z (sudo window C1–C8). Everything not listed here is unchanged from those. That includes:
- the VM per job, the token on the host only, and the runner unit sandbox;
- the nft egress table plus the guard;
- the F1 no-root-into-runner-paths rules and the team-boot marker;
- idle-poweroff only on a team boot;
- the sudo-window mechanics.

Context: `50-revive-assessment-20261103.md`. The owner's correction came via Larry on 2026-11-03 at 14:13 local.

**State:** nothing is applied. No push and no commit. The edits are working-tree only, under
`hack/forgejo-runner/vdhwslin01/`. The box, the forge and HA were only read.

## Files for review (sha256)

| File | sha256 |
|---|---|
| `provision.sh` (generated; `provision.in.sh` diff vs main ad030451: +81/−29) | 8420c072…91b5 |
| `sudo-window/vdh-provision-tonight` | b428faf9…633a |
| `sudo-window/install-window.sh` (pins re-synced by `pin.sh`) | bf3b608d…14fa |
| `sudo-window/90-agent-provision` | 108c432d…356b (unchanged) |
| `mini/vdhwslin01-waker.py` (new) | a63c7dfd…c60a |
| `mini/net.vdhict.vdhwslin01-waker.plist` (new, not loaded) | dc4e4c50…a2d |
| `mini/make-webhook-id.sh` (new, not run) | 53328783…74cd |
| `ha/vdhwslin01_wake.yaml` (header only) | 0c726b89…4425 |

Tests: `tests/run-all.sh` ALL GREEN. Evidence `52-run-all-20261103T1330Z.txt` (write-once):
- shellcheck clean and `build.sh --check` in sync;
- idle-poweroff 18/18, nft-guard 11/11, remote-unlock 32/32 (including the new case 8);
- D6 groups 7/7, Mini waker 36/36 on /usr/bin/python3 3.9 and on python3;
- revive invariants and the secret scan pass.

---

## D1 Scope: repo mypka-bot/passkey-point-dotnet → org VDHICT

- **What changed:**
  - registration uses an **org vdhict** token; the scope follows from the token;
  - `RUNNER_SCOPE=vdhict` is only a marker, printed in the report and checked by `post-run-checks.sh c1`;
  - `post-run-checks.sh scope` reads back that runner `vdhwslin01` has owner vdhict and repo_id 0;
  - only VDHICT is registered on this box, never mypka-bot (your A3: separate instances).
- **Why:** the owner wants label `docker` for org VDHICT. 13 jobs are waiting and 2 blocked across 3 vdhict repos
  (read-only DB, 13:15Z). The forge cancels waiting jobs after ~24 h, so run 1 needs a re-run once the runner is
  online.
- **Your B3 (13-10) asked for repo scope because of a persistent VM, the `.runner` token readable by VM root, and
  org secrets.** What remains:
  - a. The VM-per-job (A6) and token-on-host (R5/R7) controls have been in place since 13-10. A hostile job no longer
    reaches `.runner` or a later job.
  - b. **Org secrets: org vdhict holds 2 org-level secrets (count only, names not read).** Your R8/C5 require 0
    readable secrets for the scope, and A4 says repo secret, never org secret. **Open, Larry/Mack (Atlas has sent it):**
    move them to repo secrets on the repos that need them, or accept explicitly.
  - c. Every writer in any of the 34 vdhict repos can run code here as VM root, with internet 80/443 egress and
    envoy-forge. This is the A3 trust question at org size.
- **Ask:** rule D1 with b and c as conditions or as accepted residuals.

## D2 Waker: in-cluster CronJob → launchd on vdhmini01

- **What changed:**
  - The cluster waker, its generators, forge token 31 and the in-cluster unlock key and passphrase are gone (14-10).
  - The new `mini/vdhwslin01-waker.py` (stdlib, Python 3.9) ports your 13-10 `decide()` logic, which you passed:
    - it never touches a running box;
    - it never unlocks a prompt it did not cause, and only unlocks within 15 min of its own wake;
    - at most 2 unlock attempts per wake;
    - no pinned host key means it refuses to wake.
  - Wake goes through the HA webhook. It is local_only, HA presses WoL and caps it at 4/day, and the waker holds
    **no HA token**.
  - Unlock uses the Mini route from chg-2026-10-21-003 (proven 27-10 15:08–15:15Z):
    - ssh alias `vdhwslin01-unlock` (key `~/.ssh/vdhwslin01_unlock_mini`, `known_hosts_vdhwslin01`,
      StrictHostKeyChecking yes);
    - the existing 0600 file `~/.config/vdhwslin01/luks-passphrase` is sent as ssh stdin.
  - **No new LUKS keyslot:** keyslot is out of the default steps, and the wrapper never runs it.
- **New: a failed wake is never silent.** These reasons write one `executed` change-log line with result
  wake_failed plus one ntfy message, at most hourly per reason while the cause persists:
  - no_unlock_prompt, passphrase_rejected, no_ssh_after_unlock;
  - cap_reached, no_host_key, webhook_error, queue_unreadable;
  - foreign_prompt_jobs_waiting, and jobs_stuck_box_up (a job waits ≥30 min with the box up and nothing running).

  At night the message has priority 1 and a `[night]` title (AGR-074). Tested, including the boundaries 22:59, 23:00,
  06:59 and 07:00.
- **Secrets handling:**
  - the webhook id and the ntfy topic go to curl via `-K -` on stdin;
  - the passphrase goes to ssh via stdin;
  - none is printed, logged or placed on argv (tests check this, plus a sentinel test).
  - Dry-run makes no webhook call, no unlock, writes no line or ntfy, and keeps no state (tested).
- **Queue source (needs your ruling).** It is a read-only SQL query (`SET default_transaction_read_only = on`,
  SELECT only) on the forge-pg primary, using the Mini's **existing** kubectl access. Live dry-run at 13:27:07Z:
  `box=up jobs=13 oldest=81762s action=stuck`.

  Alternatives I rejected:
  - **Forgejo 15 API:** `/orgs/{org}/actions/runners/jobs` needs **org ownership** (api.go
    `addActionsRoutes(m, reqOrgOwnership(), …)`), and the repo route needs repo owner. A read-scoped org-owner token
    can also `GET …/runners/registration-token`, which would let anyone holding it register a rogue runner and
    receive jobs and org secrets.
  - **A narrower route** is possible later: a dedicated Postgres role with SELECT on one view, reached through an SA
    allowed only `pods/portforward`. That needs a forge-pg write, so it is outside this turn.
- **Residuals to rule on:**
  1. The Mini's uid 501 is shared with myPKA (your M1, 13-10). The **owner's own LUKS passphrase** and the unlock key
     already sit there since 27-10, and the Mini route **has never had a security review** (0 security events on
     chg-2026-10-21-003). The waker automates that material; it does not add new secret material.
  2. An unattended loop runs kubectl with cluster-admin every 2 min. The SQL is fixed and runs in a read-only
     transaction, and no credential is added. But a tampered script would run with the same broad rights, the same
     exposure as every other Mini launchd job.
  3. The cap of 4/day is enforced in HA. HA's WoL button can still be pressed by any HA token (M2, unchanged).

## D3 Parked 14-10 fix: custom `remote-unlock` dropbear hook

- **What it does:**
  - `detect_initramfs` accepts exactly one ssh unlock hook (dropbear, tinyssh or remote-unlock); more than one means
    refuse;
  - the key goes into `/etc/remote-unlock/authorized_keys` with mode and owner kept;
  - the backup is kept outside the hook input dir, and a post-check restores the backup on any key loss;
  - the host-key pin comes from `dropbear_ed25519_host_key`.

  You never reviewed it, because it was stopped on 14-10.
- **Measured on the box today** (as agent, read-only):
  - Omarchy 4.5.0rc2, kernel 7.2.8;
  - effective HOOKS: `… block remote-unlock encryptssh filesystems fsck btrfs-overlayfs resume`;
  - `limine-mkinitcpio` present (hook 1.40.0).
- **Case 8 (new):** this exact line, plus the Mini unlock key already present →
  - "already in", authorized_keys byte-identical, no backup taken;
  - vdh-teamboot passes the order check after encryptssh and resume;
  - uninstall leaves the owner-added key alone, because uninstall removes only lines ending in ` vdhwslin01-waker`.
- **The wrapper's `--controller-pubkey` is now the Mini unlock key** (public), checked by run-all.
- **Risk:** the initramfs rebuild on an RC Omarchy is the riskiest box step. The guard stays: any image without
  vdh-teamboot means die before the reboot path changes, console unlock is unchanged, and no reboot happens in the
  session.

## D4 Version and image pins

| | was | now | source |
|---|---|---|---|
| forgejo-runner | 13.2.0 fadaec89… | **13.2.1** bb369fe1…8b34 (dependency bumps: buildx 0.37.2, docker cli 29.8.2) | code.forgejo.org release `.sha256` |
| Debian 13 cloud | 20261001-2618 | **20261026-2643** sha512 3ace18e3…1b8e | cloud.debian.org SHA512SUMS |
| job image | `node:24-bookworm` (tag only) | **`node:24-bookworm@sha256:e7add2a4…d413`** (OCI index, hub last_updated 2026-10-28) in both labels **and** the golden pre-pull; run-all checks they match | registry-1.docker.io |
| docker in golden | Debian docker.io | unchanged (trixie 26.1.5+dfsg1-9+deb13u1; vendor = Debian) | sources.debian.org |

The runner's label parser (`labels.Parse`, SplitN 3) keeps `@sha256:` in the argument.

## D5 ssh allow list without the cluster workers

`SSH_ALLOW_CLUSTER=(.81 .82 .83 .201)` became `SSH_ALLOW_MINI=(172.16.2.201)`. The MacBook LAN and WireGuard peers
are unchanged. run-all fails if .81–.83 come back. C6 (a non-allow-listed source is dropped) is now true for every
cluster node.

Later: the Headscale nodes (chg-2026-10-21-006, from 06-11) will need their own source, as a separate delta.

## D6 Host dockerd: `runner` must never reach it

- **Measured:** the box now runs Sander's docker 29.9.2, socket-activated. `/run/docker.sock` is root:docker 0660, and
  group docker is empty.
- **Changes:**
  - `step_user` now dies unless runner's groups are **exactly** `runner kvm`, which also refuses docker, libvirt,
    wheel, sudo and any extra group. Test 7/7; a mutation that removes the check is caught (4 fails).
  - `forgejo-runner-vm.service` adds `InaccessiblePaths=-/run/docker.sock -/var/run/docker.sock -/run/docker
    -/run/podman -/run/containerd`.
- Podman for chg-2026-11-03-001 is rootless for agent (your 4850), so it adds no root socket.

---

## Not tested yet (needs a go, or the box)

- **Needs a throwaway pod in the cluster** (I did not create one, since this turn allowed no writes):
  - `tests/arch-container.sh` (real Arch userland, with idempotency and the F1 attack paths);
  - `tests/nft-kernel.sh` (real kernel nft).
- **Box-only, after Sander's session:**
  - C4 (delete the table → the runner stops);
  - R5 (two jobs back to back);
  - R6 negatives as workflow jobs;
  - the first team wake: `/run/team-boot`, and the boot_id in the waker line.

## Order after your verdict

1. Hestia installs the HA package. The webhook id comes from `mini/make-webhook-id.sh` over stdin.
2. Sander's one sudo session (`sudo pacman -S --needed podman`, then `bash install-window.sh`).
3. The Mini mints the org token to a 0600 file.
4. Run `dry`, `real` and `c4`, then `revoke` with its read-back.
5. R7 rotation, then the C7 sweep.
6. `scope` read-back, and delete the stale runner id 1.
7. Load the launchd waker **only once the runner is online**. Otherwise `jobs_stuck_box_up` fires hourly.
8. Re-run run 1.

Rollback:
- box: `vdh-provision-tonight uninstall`;
- Mini: `launchctl bootout`;
- forge: delete runner vdhwslin01 and rotate the token.

Runbook: `sudo-window/larry/LARRY-NOTE.md` (rewritten for the Mini route).
