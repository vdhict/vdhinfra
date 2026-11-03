# chg-2026-10-05-031: final owner command list + Argus 16:12Z pre-session conditions (Heph, measured 2026-11-03T16:14:23Z)

## Owner script (pinned)

- **Commit:** f7817c9bd96669b774832b2aaecd4b5260c1fd87 (main)
- **File:** `hack/forgejo-runner/vdhwslin01/owner/owner-session.sh`
- **sha256:** `36bdcabec879efda331062f53662a69e2616f4e4c3fc39d2775ec8fd1667fc97`. The raw GitHub blob at f7817c9b gives
  the same value.
- **Tests:** `64-owner-session-container-20261103T161254Z.txt`, 54/0 (throwaway pod, namespace deleted and read back).

## Commands for Sander (MacBook)

```
# 1. on the MacBook
ssh -t sheijden@vdhwslin01

# READ THIS FIRST (Argus):
#   After this, the agent key on the Mini, which myPKA can also read (shared uid 501),
#   can become root on THIS workstation: your desktop session, browser profiles and home.
#   Revoke any time with: sudo rm /etc/sudoers.d/50-agent-team
# And this box must hold NO client data. The script asks you to type both confirmations.

# 2. on vdhwslin01, as yourself
cd ~ && curl -fsSLo owner-session.sh https://raw.githubusercontent.com/vdhict/vdhinfra/f7817c9bd96669b774832b2aaecd4b5260c1fd87/hack/forgejo-runner/vdhwslin01/owner/owner-session.sh
echo '36bdcabec879efda331062f53662a69e2616f4e4c3fc39d2775ec8fd1667fc97  owner-session.sh' | sha256sum -c -
sudo bash owner-session.sh --dry-run      # the last line must be: owner-session.sh: DRY RUN OK
sudo bash owner-session.sh                # type: I UNDERSTAND, then NO CLIENT DATA, then your disk passphrase once
# STOP LINE: if the last line is not exactly "owner-session.sh: OK", stop and send the whole output to Larry.
#   If pacman fails with a 404: sudo pacman -Syu, then the last line again.
#   Send the "SEND THIS BACK" block to Larry.
exit

# 3. LATER, only after the team says "the team key unlocked the box" (C8), from the MacBook:
ssh sheijden@vdhmini01 'mkdir -p ~/.Trash && mv ~/.config/vdhwslin01/luks-passphrase ~/.Trash/vdhwslin01-luks-passphrase-$(date +%Y%m%d)'
#    then empty the Mini's Trash when convenient. The MacBook copy (~/.config/vdhwslin01/luks-passphrase) can go the same way.
```

## Argus 16:12Z pre-session conditions

| # | Condition | Status / read-back |
|---|---|---|
| 1 | three-line consent warning | in the command list above AND printed by the script before any change; a typed `I UNDERSTAND` is required (test B4: a wrong answer changes nothing) |
| 2 | stop unless `owner-session.sh: OK` | the last line is printed only on success; the dry run prints `DRY RUN OK`, never the real line (tests A, C) |
| 3 | M1 `from=` on the MacBook key + M2 `restrict,pty` on both, live via agent | **done 16:10Z**, read-back and tests below |
| 4 | Time Machine | `tmutil addexclusion ~/.config/vdhwslin01` on the Mini: `[Included]` → `[Excluded]`. The Mini has **no TM destination configured** (`tmutil destinationinfo`). `teamkey-pull.sh` refuses unless the dir is excluded (tested on the Mini with a non-excluded home dir: refused rc 2; after the exclusion it passes to the ssh step) |
| 5 | owner confirms no client data | the script requires a typed `NO CLIENT DATA` before any change, recorded in the output (test B5) |
| note | other copies of the owner passphrase on the Mini | count-only search 16:13:45Z (`grep -rlIF -f`, paths only) in ~/.config, ~/bin, ~/Code, ~/Downloads, ~/Desktop, ~/Documents, ~/mypka-handoff, ~/.ssh, shell histories, ~/.local, ~/.claude/projects, the 2026-10-12 scratchpad backup and /private/tmp/claude-501: **0** outside its own file. **Not searched:** ~/Library (incl. keychains, mail, app data) and binary files |

## M1 + M2 read-back (box, as agent, 2026-11-03T16:10Z)

```
restrict,pty,from="172.16.3.108,172.16.3.23,192.168.12.6,192.168.4.6" ssh-ed25519 <key> agent-login@vdhmbp01
restrict,pty,from="172.16.2.201" ssh-ed25519 <key> vdhwslin01_agent_mini@vdhmini01-20261027
600 agent 327   (was 244 bytes; backup ~agent/.ssh/authorized_keys.bak-20261103T161012Z, 600 agent)
```

- **Where the MacBook addresses come from:** the Hermod read-back of 2026-10-13 (DHCP-reserved LAN .108/.23 and
  WireGuard peers 192.168.12.6/192.168.4.6, routed without NAT). The same list is in the Argus-passed nft allow list.
  wtmp shows agent pty logins from 172.16.3.23 only.
- **How the edit was made:** an ssh master session was kept open as the way back, the file was rewritten by an awk
  match on the exact two lines (it aborts on anything else), and every test used fresh connections.

**Tests after the change** (fresh connections, `ControlPath=none`):

| Test | Result |
|---|---|
| T1 login (Mini key) | `ok-agent` |
| T2 pty (`ssh -tt`, used by expect) | `/dev/pts/1` |
| T3 port forwarding through a real channel | no banner; ssh: `open failed: administratively prohibited` |
| T4 agent forwarding (`-A`) | `SSH_AUTH_SOCK=unset` |
| T5 stdin/stdout pipe (team-stage / teamkey-pull style) | sha `d4e4877bac97` on both ends |
| T6 teamkey-pull probe | exit 1 = reached the box, key file absent (expected before the owner session) |
| T7 source seen by the box | 172.16.2.201 |
| `team-stage.sh e2ac4209 --dry-run` | reached the box; refuses with "agent has no working sudo" (expected before the owner session) |
| waker dry tick (installed copy, pins from INSTALLED) | rc 0, `box=up jobs=18 action=stuck` |
| 2222 | closed (box up; untouched) |

The MacBook key cannot be tested from the Mini (its `from=` excludes the Mini). **Larry: one `ssh vdhwslin01 true`
from the MacBook proves it**; over Headscale it will need an added address.

## Within 7 days of the sudo going live (Heph's list)

- 6: M3 sudo journal to Loki, plus a daily scan.
- 7: a root-owned AuthorizedKeysFile.
- 8: an inventory of owner credentials on the box (a register write path makes M5 blocking; the owner decides).
- 9: a runbook rule: no untrusted code as agent.

Within 30 days:
- 10: the M4 review plus a revoke runbook (the volume key is readable by root; re-encrypt after misuse; mv, not rm).
- 11: M5 to the owner with a due date, with an accepted_risk entry meanwhile.
