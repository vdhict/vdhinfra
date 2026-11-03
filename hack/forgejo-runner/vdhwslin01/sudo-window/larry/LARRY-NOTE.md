# vdhwslin01 remote provisioning through the sudo window (revised 2026-11-03)

Change chg-2026-10-05-031. The conditions are C1–C8 from Argus's verdict of 2026-10-13T21:52:27Z, plus the delta
D1–D6 (`ops/evidence/chg-2026-10-05-031/51-argus-delta-packet-*.md`).

Since 2026-10-27 **the Mini drives this, not the MacBook**:
- `ssh vdhwslin01` works as agent from the Mini (key `from=172.16.2.201`, pinned host key);
- `/usr/bin/expect` exists on the Mini.

Larry's only part is to relay Sander's sudo session.

## Not part of this window
- **No new LUKS keyslot.**
  - The wrapper's `--steps` list leaves keyslot out.
  - The default step list leaves it out too.
- **The waker unlocks with the existing passphrase file** on the Mini (chg-2026-10-21-003), over the remote-unlock dropbear.

## Order of work
1. **Sander, one sudo session on the box (as himself, over ssh or at the console):**
   ```
   sudo pacman -S --needed podman              # chg-2026-11-03-001 (Argus: distro package, no docker group)
   bash install-window.sh                      # in the folder with provision.sh, vdh-provision-tonight,
                                               # 90-agent-provision, install-window.sh (hashes pinned inside)
   ```
   `install-window.sh` does the following:
   - checks that agent has no wheel/sudo;
   - verifies every hash;
   - runs `visudo -cf`;
   - installs root-owned copies and the 0440 drop-in;
   - starts a 3 h backstop that removes the drop-in.

   That is all Sander types.
2. **B2, before minting:** run `post-run-checks.sh prereg` (dry: plan + read-back), then
   `post-run-checks.sh prereg --apply`. It rotates the org token (id 1 dies) and soft-deletes stale runner id 1, then
   reads back `PREREG PASS`. Then re-check the writers with `post-run-checks.sh writers` (B3; evidence 54).
3. **Mint the org registration token straight to a 0600 file on the Mini (C5).**
   - It is never on stdout, and the value never enters a transcript.
   - `generate-runner-token` RETURNS the active org token (Forgejo 15 `routers/private/actions.go:56-58`); it only
     creates one when none is active. After step 2 the active token is the fresh, unused one from `prereg`, and old
     id 1 (whose value sits in 1P mypka-cluster) is inactive. Rotation is always `post-run-checks.sh rotate`
     (deactivate, then generate).
   ```
   umask 077; mkdir -p ~/.vdh
   kubectl -n devtools exec deploy/forgejo -c forgejo -- forgejo actions generate-runner-token --scope vdhict \
     > ~/.vdh/regtoken-vdhict
   stat -f '%Lp %z' ~/.vdh/regtoken-vdhict      # expect 600 and a non-zero size; never cat it
   ```
4. **Drive the wrapper with expect, from the Mini.**
   - The token is read inside the script.
   - `log_user 0` is set around `send`.
   ```
   expect provision-expect.exp dry
   expect provision-expect.exp real ~/.vdh/regtoken-vdhict
   expect provision-expect.exp c4
   ```
   - **C8:** if `real` exits non-zero, run `expect provision-expect.exp uninstall`.
   - Do NOT reboot the box. The first team wake proves the new initramfs, and console unlock is unchanged.
5. **Close the window in the same session (C4):**
   - `expect provision-expect.exp revoke`;
   - then `ssh vdhwslin01 'bash -s' < ../verify-revoked.sh` writes the write-once read-back.
6. **Rotate (R7) and sweep (C7):**
   - `post-run-checks.sh rotate` creates a fresh org token and deactivates the used one. Nothing is printed.
   - `sweep-count.sh ~/.vdh/regtoken-vdhict <Atlas session jsonl dir> <captured expect output>` must give total 0.
   - Then move the token file to the scratchpad.
7. **Read back:**
   - `post-run-checks.sh scope`: runner vdhwslin01 with owner vdhict, repo 0, labels docker and x86-linux.
   - Delete the stale runner id 1 `forgejo-runner-vdhict`, which never came online.
   - `post-run-checks.sh c1 <log>`.
   - Box-only tests: R5 (two jobs back to back) and R6 negatives as workflow jobs.
   - Then re-run run 1 of the VDHICT mobile-app repo.

## Residuals to keep in mind (README "Residuals")
- mypka-bot (write on 6 vdhict repos) can push a workflow and run code in the job VM.
- The waker, its pin and its plist sit in `$HOME` under the shared uid 501; the self-check does not stop that uid.
- The 30-day deadline for the narrow queue route starts when the waker is loaded: log that date.
- Status 2026-11-03: B2 done (`58-b2-prereg-apply-20261103T134853Z.txt`, PREREG PASS: token id 4 active and unused,
  id 1 inactive, runner 1 deleted). Step 2 of the order of work is DONE; do not run `prereg --apply` again before
  registering. Step 3 mints from the now-active token id 4.
