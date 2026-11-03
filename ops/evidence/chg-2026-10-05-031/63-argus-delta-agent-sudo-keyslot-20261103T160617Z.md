# chg-2026-10-05-031: Argus delta packet: standing agent sudo + team LUKS keyslot (Heph, measured 2026-11-03T16:06:17Z)

**Owner decisions, 2026-11-03** (Larry 165632, relayed from Sander's MacBook session):
1. B5 = a: an extra team LUKS keyslot with a random passphrase. The waker uses only that one, and the owner's own
   passphrase file leaves the Mini.
2. Standing sudo for `agent` on vdhwslin01, visible and logged. Runner jobs stay as `runner` in the per-job KVM VM.

**Baseline:** your verdicts of 2026-11-03 (qa_failed 13:40Z, re-review that closed B3/B4/C6).

**State:** nothing has run on the box, which was only read (survey 15:58Z). The bundle is at commit
**bfdcfafa79ccfb264567070f4d2d2b26ac689e2e** on main.

## Files (at bfdcfafa)

| File | sha256 |
|---|---|
| `hack/forgejo-runner/vdhwslin01/owner/owner-session.sh` (Sander runs it) | **2e7923700d48077b26ae7e90c31682bdf5cadc43f0ff909f937b5e221872ec4f** (raw GitHub blob at bfdcfafa: same) |
| `mini/teamkey-pull.sh` | see the commit |
| `mini/team-stage.sh` | see the commit |
| `provision.sh` | 8420c0727d83011f6bef6221b99b3829f6768c4e3452e7b0ee82e93ac72591b5 (unchanged) |

**Tests:** `62-owner-session-container-20261103T160311Z.txt`, **45/0**, in a throwaway Arch pod (PSA baseline,
default capabilities; namespace deleted and read back). Covered:
- the real LUKS2 image file: dry run changes nothing;
- refusals: run as agent, no SUDO_USER, a foreign drop-in;
- the real run: packages, drop-in 0440, `visudo -c`, `sudo -l` shows NOPASSWD ALL, sudo logfile, I/O log root 0700,
  `sudoreplay` lists the session;
- the keyslot: 1→2, the team key opens the recorded slot and the owner passphrase still opens slot 0;
- no temp copies left, and neither the key nor the owner passphrase appears in the output;
- an idempotent re-run;
- an agent-planted symlink for the key dir is refused and /etc is untouched;
- the team pull: 0400 copy, same sha, box copy shredded, the pulled key opens the slot, a second pull refuses;
- revoke: removing the drop-in leaves no sudo, and `luksKillSlot` removes only the team slot.

Two earlier runs are kept as history: a 0400 file can't be shredded without chmod, and the Arch base image lacks
`cmp`, which failed closed and now uses sha256. The offline suite (run-all) is ALL GREEN.

## K: the keyslot design

- **K1 generation, on the box as root:** 48 chars `[A-Za-z0-9]` from /dev/urandom, into a root-only `mktemp` in
  /root (umask 077).
- **K2 add:** `cryptsetup luksAddKey <dev> <tempfile> </dev/tty`. cryptsetup asks the owner for his EXISTING
  passphrase at the terminal, so it never touches a file or a pipe.
  - The device is auto-detected, and exactly one `crypto_LUKS` device is required. Measured: `nvme0n1p2`.
  - Read-back: keyslots +1, and `--test-passphrase --key-file` names the slot. The slot goes to
    `/etc/vdh-runner/team-keyslot` with its revoke line.
- **K3 hand-over:**
  - `runuser -u agent -- sh -c 'umask 377; set -C; cat > ~agent/.vdh-teamkey/team-luks.key'` with root supplying only
    stdin. The key dir is created BY agent; a symlink is refused (the F1 pattern).
  - The root temp is shredded.
  - The key is never printed. There is no sudo in the pull path, so nothing reaches the sudo I/O log.
- **K4 pull** (`mini/teamkey-pull.sh`, on the Mini as Atlas):
  - `ssh vdhwslin01 cat` (pinned host key) into `~/.config/vdhwslin01/team-luks.key.new` with noclobber, then 0400;
  - format check, then sha256 compared in-script (only "match" is printed);
  - `mv -n` into place;
  - then on the box: chmod 0600, `shred -u` and `rmdir`, read back absent. This is a reviewed deletion in a repo
    script (AGR-121).
- **K5 use:**
  - The waker reads only `team-luks.key`; a test asserts it never names `luks-passphrase`.
  - **C8, attended:** first reboot unlocks with the team key (`PASSFILE=… ~/bin/vdhwslin01-unlock-and-wait.sh`),
    then the owner moves his own Mini file to the Trash (command below).
- **K6 revoke:** `cryptsetup luksKillSlot <dev> <slot>`, which needs a remaining passphrase. The owner slot is never
  touched.
- **Residuals:**
  - The team key sits on the Mini under uid 501, shared with myPKA: anyone there can unlock the disk. That equals the
    situation since 27-10 (the owner passphrase file was there). What improves: the owner's passphrase leaves the
    Mini, and the team slot can be revoked alone.
  - B5's "out of TM/cloud sync": exclude `~/.config/vdhwslin01/` from Time Machine on the Mini
    (`tmutil addexclusion`), as a team step. Snapshots of the owner file taken before the move still exist until they
    expire. That is the owner's to judge.

## S: standing sudo for agent

**Drop-in `/etc/sudoers.d/50-agent-team`** (fixed name), installed only by `owner-session.sh`:
- checked with `visudo -cf` before install, then `visudo -c` after;
- a foreign file with the same name is refused;
- rules:
  ```
  Defaults:agent log_output
  Defaults:agent !log_input
  Defaults:agent iolog_dir=/var/log/sudo-io/%{user}
  Defaults:agent logfile=/var/log/sudo-agent.log
  agent ALL=(ALL:ALL) NOPASSWD: ALL
  ```

**Logging (AGR-099):**
- every command goes to journald (sudo's default syslog) and `/var/log/sudo-agent.log`;
- terminal output of every session goes to `/var/log/sudo-io/agent` (root 0700), replayable with `sudoreplay`.
- **Input is deliberately not logged:** the registration token is typed through expect into a `read -s` prompt, so
  it must not land in a log. Rule for the team: never run a command through sudo that prints a secret (runbook).

**Revoke:** `sudo rm /etc/sudoers.d/50-agent-team` (owner or team).

**The 3 h window kit is retired** (`install-window.sh`, `90-agent-provision`; kept in Git as history). Staging
(`mini/team-stage.sh <commit>`) still takes provision.sh and the wrapper from a commit on origin/main, checks the sha
on the box, and runs the unchanged fixed-argument wrapper. The sha pin and the fixed args now guard against mistakes,
no longer against agent.

**The new residual (please rule on it).** Root on vdhwslin01 is root on Sander's **workstation**: his desktop
session, his home, browser profiles, and his own sudo user. That reopens your 13-10 H1, dual use. Who can become that
root:
- anyone who can use an agent ssh key;
- the **Mini key** (`from=172.16.2.201`), readable by uid 501 = **Atlas and myPKA**. So myPKA can become root on
  Sander's workstation;
- the **MacBook key `agent-login@vdhmbp01`**, which measured **without any `from=` restriction** (15:58Z): usable
  from any address that reaches 22, and the nft allow list is not active until provisioning.

**Proposed mitigations** (M1–M4 cheap, team-side; M5 is the real fix):

| # | Mitigation | Effect | Who / when |
|---|---|---|---|
| M1 | `from=` on the MacBook agent key: `172.16.3.108,172.16.3.23,192.168.12.6,192.168.4.6` | a stolen MacBook key only works from the MacBook's addresses | team, through agent itself (no sudo), before the sudo goes live |
| M2 | `restrict,pty` on both agent keys | no agent/port/X11 forwarding: an agent session cannot be used as a pivot into the CLIENT-VLAN | team, same step |
| M3 | ship box journald (sudo lines) off the box: journald → Vector/Loki (syslog over the LAN), plus a daily posture-scan line listing agent sudo sessions and their source IP | misuse is visible even if root wipes local logs | team, within 7 days |
| M4 | a 30-day review of the standing sudo, with a revoke one-liner in the runbook | it does not silently become permanent | Atlas, calendar |
| M5 | a **separate macOS user on the Mini** for host-root material (vdhwslin01 agent key + team LUKS key + unlock key), not readable by uid 501 (myPKA). The waker runs under that user | breaks the myPKA → root-on-workstation path, and myPKA → disk-unlock | owner decision (estate change; myPKA containment line). Proposed, not built |
| M6 | (not proposed) a forced command on the Mini key | impossible: agent's Mini key is also used for general work (builds), and sudo cannot be bound to an ssh key | - |

Without M5 the honest statement is: **myPKA can obtain root on Sander's workstation, and could already unlock its
disk.** M1–M4 reduce the other paths and make use visible; only M5 or no standing sudo closes this path.

## T: tailscale

Install only, in the owner session (`tailscaled` stays disabled; read back). Enable and `tailscale up` with a
single-use pre-auth key is a later team step under chg-2026-11-02-012 S4, reviewed there.

## Sander's commands (copy-paste)

```
# 1. on the MacBook
ssh -t sheijden@vdhwslin01

# 2. on vdhwslin01, as yourself
cd ~ && curl -fsSLo owner-session.sh https://raw.githubusercontent.com/vdhict/vdhinfra/bfdcfafa79ccfb264567070f4d2d2b26ac689e2e/hack/forgejo-runner/vdhwslin01/owner/owner-session.sh
echo '2e7923700d48077b26ae7e90c31682bdf5cadc43f0ff909f937b5e221872ec4f  owner-session.sh' | sha256sum -c -
sudo bash owner-session.sh --dry-run
sudo bash owner-session.sh        # cryptsetup asks ONCE for your disk passphrase: type it
#    if pacman fails with a 404: sudo pacman -Syu, then the last line again
#    copy the block under "SEND THIS BACK" to Larry, then:
exit

# 3. LATER, only after the team says "team key unlocked the box" (C8), from the MacBook:
ssh sheijden@vdhmini01 'mkdir -p ~/.Trash && mv ~/.config/vdhwslin01/luks-passphrase ~/.Trash/vdhwslin01-luks-passphrase-$(date +%Y%m%d)'
#    then empty the Mini's Trash when convenient. Optional, the MacBook copy: move ~/.config/vdhwslin01/luks-passphrase to the Trash there too.
```

## Ask

- Pass or fail K1–K6 and S.
- Rule on the new residual: is standing sudo acceptable with M1–M4 and M5 as an owner follow-up, or only after M5?
- M1/M2 can be done before the owner session, through agent itself, if you want them as a condition.
