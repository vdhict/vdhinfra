# Larry: vdhwslin01 remote provisioning through the sudo window

Change chg-2026-10-05-031; conditions C1–C8 from Argus's verdict of 2026-10-13T21:52:27Z.

## Not part of this window
- **No LUKS passphrase file**, in any form (Argus R1: rejected). If one exists, Sander deletes it himself.
- **The controller keyslot is deferred.** Later, Sander types it at `/dev/tty` himself, with the controller passphrase from the sanctioned pipe.
- **The wrapper never runs the keyslot step.** Its `--steps` list is fixed and leaves keyslot out.

## Order of work
1. **Sander opens the window** at the box, as himself: `bash install-window.sh` in the folder with the four files (see the bundle). It checks `agent` has no wheel/sudo, verifies every hash, runs `visudo -cf`, installs the 0440 drop-in, and starts a 3 h backstop that removes the drop-in.
2. **Mint the registration token straight to a 0600 file** (C5). The API reply goes to disk with `curl -o`, never to stdout. Your API credential comes from a header file, so it never sits on argv either.
   ```
   umask 077; mkdir -p ~/.vdh && cd ~/.vdh
   # api-auth.hdr (0600) holds one line: "Authorization: token <a short-lived mypka-bot token,
   #   repository-restricted to mypka-bot/passkey-point-dotnet, scope write:repository>"
   curl -sS -o regtoken.json -H @api-auth.hdr \
     https://forge.bluejungle.net/api/v1/repos/mypka-bot/passkey-point-dotnet/actions/runners/registration-token
   python3 -c 'import json,os; t=json.load(open("regtoken.json"))["token"]; fd=os.open("regtoken",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,t.encode()); os.close(fd)'
   ```
   - Never widen token 31 (the waker's: read:repository, one repo) for this.
   - Delete the short-lived API token afterwards and read back 404 on it.
3. **Drive the wrapper with expect.** The token is read inside the script, `log_user 0` is set around `send`, there is no `-d`/`exp_internal`/`log_file`, and ssh runs with `-t`:
   ```
   expect provision-expect.exp dry
   expect provision-expect.exp real ~/.vdh/regtoken
   expect provision-expect.exp c4
   ```
   - **C8:** if `real` exits non-zero, run `expect provision-expect.exp uninstall`.
   - Do NOT reboot the box. Console unlock is unchanged, and the initramfs step dies before the boot path changes if the image check fails.
4. **Close the window in the same session** (C4):
   - `expect provision-expect.exp revoke`. Its output is the root-side read-back: the drop-in is gone and `/etc/sudoers.d` is listed.
   - Then, as agent on the box: `bash verify-revoked.sh`. It writes the write-once evidence file `vdhwslin01-sudo-revoked-<ts>.txt`; copy that file to Atlas.
5. **Sweep, count-only** (C7). This prints counts, never matches. Expect a total of 0, then delete the token files.
   ```
   bash sweep-count.sh ~/.vdh/regtoken <Larry session jsonl dir> ~/.zsh_history <captured expect output>
   ```
   - The on-box part (`journalctl -b`, `/var/log/vdh-runner-initramfs-*.log`, `/var/log/vdh-provision-*.log`) needs root. Sander runs it, or it goes in the next window.
6. **R7:** Heph rotates the registration token from the Mini right after the run: `post-run-checks.sh rotate` (nothing printed).

## Tested on 2026-10-14 (on the Mini, fake ssh)
- The token arrives intact.
- The token appears 0 times in the captured output.
- The sweep counts a planted leak as 1.
- It refuses a token file that is not 0600, and a bad mode.
