# vdhwslin01 runner: order of work (revised 2026-11-03, owner decisions via Larry 165632)

Change chg-2026-10-05-031. The owner decided:
- **B5 = a:** a dedicated team LUKS keyslot. The waker uses only that one.
- **Standing sudo for `agent`:** visible and logged (AGR-099).

**The 3 h sudo window (`install-window.sh` + `90-agent-provision`) is RETIRED.** Standing, logged sudo replaces it.
The files stay in Git as history. The wrapper `vdh-provision-tonight` stays: its fixed arguments and sha pin are still
the way the team runs `provision.sh`.

## 0. Before Sander (done 2026-11-03)
- B2 `post-run-checks.sh prereg --apply`: PREREG PASS. Token id 4 is active and unused, id 1 is inactive, and runner
  1 is deleted (evidence 58). Do not run it again before registering.

## 1. Sander, one session (copy-paste list: evidence `63-…`)
- `ssh -t sheijden@vdhwslin01` from the MacBook. Download `owner/owner-session.sh` from the pinned commit and check
  its sha256.
- `sudo bash owner-session.sh --dry-run`, then `sudo bash owner-session.sh`.
- It installs podman + tailscale (tailscaled stays off), the agent sudo drop-in `/etc/sudoers.d/50-agent-team`
  (visudo-checked, output-logged), and the team keyslot. cryptsetup asks him for his own passphrase once.
- He sends back the "SEND THIS BACK" block.

## 2. Team (Mini, Atlas/Heph), all through agent's sudo
1. `mini/teamkey-pull.sh`: pull the team key to `~/.config/vdhwslin01/team-luks.key` (0400), compare checksums, then
   shred the box copy and read it back.
2. **C8, attended first reboot.** Sander is told it is happening and is in reach. Reboot via
   `ssh vdhwslin01 sudo -n systemctl reboot`, then
   `PASSFILE=~/.config/vdhwslin01/team-luks.key ~/bin/vdhwslin01-unlock-and-wait.sh`. Prove:
   - 2222 answers with the pinned key;
   - the unlock succeeds with the TEAM key;
   - `/run/team-boot` carries this boot's id. This only holds after provisioning, because the initramfs wrapper
     comes with the runner bundle. So C8 for the marker runs after step 4; this first reboot proves the team key.
3. **Sander moves his own passphrase file off the Mini** (only after step 2 proved the team key), from the MacBook:
   `ssh sheijden@vdhmini01 'mkdir -p ~/.Trash && mv ~/.config/vdhwslin01/luks-passphrase ~/.Trash/vdhwslin01-luks-passphrase-$(date +%Y%m%d)'`
   He then empties the Trash himself. The MacBook copy goes too if he wants: `~/.config/vdhwslin01/luks-passphrase`
   there, the same way.
4. `mini/team-stage.sh <commit>`, then `expect provision-expect.exp dry`, then `real ~/.vdh/regtoken-vdhict`, then
   `c4`.
   - The registration token is minted to a 0600 file:
     `kubectl --context admin@vdhinfra-local -n devtools exec deploy/forgejo -c forgejo -- forgejo actions generate-runner-token --scope vdhict > ~/.vdh/regtoken-vdhict`.
     This returns the active, unused token id 4. Never cat it.
   - **C8 part 2:** reboot again (attended) and prove `/run/team-boot` plus the boot_id.
5. `post-run-checks.sh rotate` (R7: deactivate, then generate), then the `sweep-count.sh` C7 sweep (expect 0), then
   `post-run-checks.sh scope` and `writers`, then `c1 <log>`.
6. Hestia: HA wake package. Then `mini/ha-cap-readback.sh --run` (box up).
7. `mini/install-waker.sh <commit> --load`, after Argus. Log the go-live date (it starts the 30-day narrow-route
   deadline).
8. **Tailscale (later, separate):** `ssh vdhwslin01 'sudo -n systemctl enable --now tailscaled'`, then
   `tailscale up` with a single-use pre-auth key (chg-2026-11-02-012 S4, reviewed there).
9. Re-run run 1 of the VDHICT mobile-app repo.

## Logging rules for agent's sudo
- Every agent sudo command goes to journald and `/var/log/sudo-agent.log`, and its terminal OUTPUT goes to
  `/var/log/sudo-io/agent` (root 0700).
- Input is not logged. Even so, never run a command through sudo that PRINTS a secret.
- Revoke: `sudo rm /etc/sudoers.d/50-agent-team` (Sander, or the team itself).

## Residuals (README "Residuals")
- mypka-bot (write on 6 vdhict repos) can push a workflow and run code in the job VM.
- The waker, its pin and its plist sit in `$HOME` under the shared uid 501.
- **New:** agent root on vdhwslin01 is reachable from myPKA through the Mini's agent key (uid 501). See evidence 63.
- The 30-day narrow-route deadline starts at waker go-live.
