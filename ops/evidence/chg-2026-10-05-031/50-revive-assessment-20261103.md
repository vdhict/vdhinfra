# chg-2026-10-05-031 revive: read-only assessment (Heph, 2026-11-03)

Measured 2026-11-03T13:14Z to 13:25Z from vdhmini01. No production writes, no push, no secret read or printed.
Box access: three read-only ssh sessions as `agent`, no sudo. vdhwslin01 was already UP (booted 08:48 local for
chg-2026-11-03-001); it was not woken by this assessment and was left as found.

## 1. Inventory: what survives the 14-10 stop

| Piece | State (measured) |
|---|---|
| envoy-forge Gateway (R9) | On main (f2aa2a1f, cherry-picked 13-10 23:30Z). Live: 172.16.2.251, Accepted+Programmed. forgejo HTTPRoute parents = envoy-internal, envoy-forge. `/api/healthz` via .251 = 200. **R9 met.** |
| Waker CronJob + generators | Removed from main (c9c4b881). devtools: no waker CronJob/ES/Secret/ConfigMap left (grep empty). |
| Waker forge token (id 31) | Deleted 14-10 (DELETE 204). Must be re-minted if the waker reads the API. |
| Unlock Secret (in-cluster passphrase + key) | Deleted 14-10. No LUKS keyslot was ever added on the box. |
| HA webhook package | Never installed. Source still in `hack/forgejo-runner/vdhwslin01/ha/vdhwslin01_wake.yaml`. |
| known_hosts pin (C7) | Not done in-cluster. The Mini has the 22 and 2222 host keys pinned (`~/.ssh/known_hosts_vdhwslin01`, StrictHostKeyChecking yes; chg-2026-10-21-003). |
| Bundle on main | provision.sh sha256 ad030451…de38 (Argus 13-10 21:52Z). Same sha installed on the box at /usr/local/sbin/vdh-provision.sh (+ wrapper 2894f7d9…), root 0755, from 14-10. The sudoers drop-in is gone: `sudo -n -l` as agent asks for a password. |
| Parked 14-10 fix (working tree, not on main) | provision.in.sh +41/-7: accept the custom `remote-unlock` dropbear hook, keep mode/owner on authorized_keys, fail-closed key-loss post-check; provision.sh sha256 b0fd313f…12be1; tests/remote-unlock.test.sh 25/25. Never reviewed by Argus (stopped). |
| Forge runners | action_runner id 1 `forgejo-runner-vdhict` (org vdhict): no labels, last_online never, no version. Its credential holder is unknown. |
| Registration tokens | id 1 org vdhict **active** (created 2026-10-05). ids 2, 3 (mypka-bot repo) inactive. |
| Box runner state | No `runner` user, no vdh units, no /var/lib/forgejo-runner, no qemu, no forgejo-runner, no podman. **Clean first install.** |

Queue (status waiting, runs_on docker): org vdhict = 13 waiting + 2 blocked, across 3 repos, oldest 2026-11-02 14:44Z.

**Finding: run 1 will leave `waiting` by itself, as `cancelled`.** The forge cancels a waiting job after about 24 h.
This was measured: the last 8 cancelled jobs were cancelled 24.3 to 28.4 h after they were created. Run 1 was created
2026-11-02 14:44Z, so it gets cancelled during today. The done-when has to read: run 1 (or a re-run of it) is picked up
by the vdhwslin01 runner (task status running, then success or failure).

## 2. Drift since 13/14-10

| Item | Pinned | Now | Action |
|---|---|---|---|
| forgejo-runner | 13.2.0 (sha256 fadaec89…) | 13.2.1 (2026-10-29; dependency bumps only: buildx 0.37.2, docker cli 29.8.2); sha256 bb369fe1…8b34 | bump + re-pin |
| Debian 13 cloud image | 20261001-2618 (still downloadable) | 20261026-2643, sha512 3ace18e3…1b8e | bump + re-pin |
| docker in golden image | Debian `docker.io` (trixie: 26.1.5+dfsg1-9+deb13u1) | same | no change (vendor = Debian). It is upstream-EOL, but Debian maintains it. |
| Job image `node:24-bookworm` | tag only (design said digest) | - | pin to a digest (Argus delta) |
| Forgejo server | 15.0.9 | 15.0.11 / 16.0.7 / 17.0.1 available (2026-10-26) | not blocking; Renovate track (AGR-029) |
| Box OS | Omarchy 4.0.x on 14-10 | Omarchy 4.5.0rc2, kernel 7.2.8, docker 29.9.2 (socket-activated, group docker empty), limine-mkinitcpio-hook 1.40 | re-test the initramfs path |
| Effective HOOKS | - | `... block remote-unlock encryptssh filesystems fsck btrfs-overlayfs resume` | the parked fix covers it; add this exact line to tests |
| Runner scope | repo mypka-bot/passkey-point-dotnet (Argus A3) | wanted: org VDHICT | **scope change, Argus delta** |
| ssh allow list | .81–.83 (cluster waker), .201, MacBook LAN+WG | the cluster waker is gone | drop .81–.83 |

`provision.sh` has to be rebuilt with `build.sh` in any case: version pins, labels/scope, allow list, the parked fix,
and the wrapper + install-window re-pinned to the new sha.

## 3. Waker: on the Mini, not in-cluster (recommendation)

The in-cluster design needed an in-cluster passphrase, which meant a new keyslot plus a PushSecret or an
ESO generator. That is now redundant. The proven unlock path is the Mini:
- WoL through HA;
- 2222 with a pinned host key;
- `~/bin/vdhwslin01-unlock-and-wait.sh`.

That script sends `~/.config/vdhwslin01/luks-passphrase` (0600, 48 bytes, not read) as ssh stdin, to a dropbear key
that is forced into the LUKS prompt. A full Mini-only cycle was proven 2026-10-27 15:08–15:15Z.

Design: a launchd agent on vdhmini01 runs `hack/forgejo-runner/vdhwslin01/waker-mini.sh`. It keeps the logic of the
13-10 controller, which Argus passed with 21 unit tests:
1. Every 2 min, count waiting jobs with label `docker` for org vdhict. The count comes from a read-only forge token
   (0600 on the Mini), with an expiry date that the waker enforces itself.
2. If at least one job waits and tcp 22 is closed, POST the HA webhook (Hestia package, local_only, 4 per day cap in an
   HA counter). The waker then holds no HA token.
3. Unlock only within 15 min of its own wake. It never touches a running box and never unlocks a prompt it did not cause.
4. Wait for 22.
5. Write one change-log line per action.
6. **Failed wake**: any of the following writes a `wake_failed` change-log line plus one ntfy message (silent
   23:00–07:00, AGR-074):
   - no 2222 within 10 min;
   - passphrase rejected (rc 2);
   - no sshd (rc 3);
   - cap reached;
   - token expired.

   Until the queue drains it repeats at most once an hour, so a job never waits silently.

Properties kept:
- No passphrase in the cluster: there is no cluster component at all.
- Unlock fails closed on the host-key pin.
- The waker holds no HA token.
- The cap is enforced by HA.
- The box itself powers off when idle (`idle-poweroff.timer`, root, only on a team boot, by its boot_id marker).

What is new for Argus:
- The passphrase and the unlock key sit on the Mini under uid 501. That uid is shared with myPKA (Argus M1 13-10).
  The Mini route (chg-2026-10-21-003) has had **no security review**.
- The passphrase is the owner's own LUKS passphrase, not a dedicated keyslot. The waker adds automation, not new
  secret material.

## 4. Who does what

**Sander, one sudo session on vdhwslin01 (via Larry; ~15 min of typing, the rest unattended):**
1. `sudo pacman -S --needed podman` (chg-2026-11-03-001; Argus 4850 passed: distro package, no docker group).
2. `sudo bash install-window.sh` from the refreshed bundle (sha in the handoff). It installs the re-pinned
   `/usr/local/sbin/vdh-provision.sh` + wrapper, the narrow sudoers drop-in, and the 3 h removal backstop
   (Argus 13-10 C1–C3).
3. The team then runs `dry`, `real` and `c4` through the wrapper. The org registration token goes in via expect from a
   0600 file (C5/C6), and the window is revoked with a read-back (C4).

   Alternative for step 3: Sander runs `sudo vdh-provision.sh` himself and pastes a registration token that he
   generates in the forge UI (org → Actions → Runners).

No reboot is needed in the session. The first team wake proves the new initramfs, and console unlock stays unchanged.

**Hestia:** install `ha/vdhwslin01_wake.yaml`, with the webhook id via stdin into secrets.yaml (low, ~30 min).
**Hermod:** read-only check that the 172.16.3.205 reservation is unchanged. Note that the Headscale nodes
(chg-2026-10-21-006, from 06-11) will need a CGNAT source in the allow list later.
**Atlas/Heph after the run:**
- delete stale runner id 1;
- regenerate the org registration token (R7);
- pin known_hosts on the Mini;
- run the R5 two-job test and R6 negatives as workflow jobs;
- re-run run 1.

**Argus delta review, against qa_passed 2026-10-13 11:41Z / 11:57Z / 13:59Z / 21:52Z:**
- D1: scope from repo mypka-bot to **org VDHICT** (34 repos). Original A3/B3 objection: with a VM per job and the
  token on the host, the remaining risk is that every org writer gets jobs here. **Org vdhict holds 2 org secrets
  (count only).** R8/C5 require 0, and A4 says repo secret, never org. The owner or Argus must decide whether they
  move to repo secrets first.
- D2: waker moves to the Mini, using the owner passphrase file and the Mini unlock key (the Mini route was never reviewed).
- D3: the parked remote-unlock fix (+41/-7) and its tests.
- D4: version bumps and the node image digest.
- D5: allow list without .81–.83.
- D6: add `docker` to the forbidden groups for `runner`, since host dockerd now runs.

## 5. ETA (honest)

| Step | Time |
|---|---|
| Heph: rebuild + tests + Mini waker + launchd dry run | ~4 h. Ready Wed 04-11 midday. |
| Argus delta | Same day. |
| Hestia webhook | 30 min, Wed. |
| **Gating item: Sander's sudo session** (he travels until Thu 05-11) | If he does it remotely Wed evening: runner online and run 1 re-run picked up Wed night. Otherwise **Thu 05-11 evening / Fri 06-11 morning**. |
| After the session | Golden build ~20 min, first job, then the R5/R6 tests. Results are advisory until those pass. |
