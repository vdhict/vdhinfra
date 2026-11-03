# vdhwslin01: Forgejo runner on Sander's workstation (chg-2026-10-05-031)

Owner: k8s-engineer (Heph). Decisions: Larry for the owner, 2026-10-13 (AGR-114 on demand,
AGR-115 shared workstation). Argus verdicts on this change: 2026-10-13T08:33:05Z, 09:10:07Z.

## Pieces

| Piece | Where | Runs as |
|---|---|---|
| `provision.sh` (generated, self-contained) | Sander runs it once with sudo on vdhwslin01 | root |
| `provision.in.sh` + `src/` | sources; `./build.sh` regenerates `provision.sh` | - |
| VM dispatcher `forgejo-runner-vm.service` | box | `runner` (no sudo, nologin, group kvm) |
| `idle-poweroff.timer` | box, every 5 min | root |
| `vdh-teamboot` initramfs wrapper | box initramfs (encryptssh login shell) | root (initramfs) |
| waker (since 2026-11-03) | `mini/vdhwslin01-waker.py`, installed by `mini/install-waker.sh <commit on origin/main>` to `~/.local/libexec/vdhwslin01-waker/` with a generated launchd plist (sha256 self-pin, absolute kubectl, pinned change log) | Atlas's user on the Mini |
| HA webhook package | `ha/vdhwslin01_wake.yaml`, installed by Hestia | HA |
| (retired) cluster CronJob + `collect-waker-events.py` + `mint-waker-forge-token.py` | removed from main c9c4b881 (14-10); kept only as history | - |

## Runner mechanism (Argus R5, R7)

`forgejo-runner one-job --wait` runs on the HOST and keeps the runner token there
(`/var/lib/forgejo-runner/.runner`, 0600). Per job the dispatcher boots a fresh qcow2 overlay on the
read-only, sha256-pinned golden image (Debian 13 cloud image, sha512-pinned, plus docker) under
unprivileged qemu/KVM. It forwards the VM's docker socket over ssh to the same path that the VM uses,
`/run/forgejo-runner/docker.sock`. So the runner drives the VM's dockerd, and the socket it mounts into
job containers is the VM's own. After the job the VM and its overlay are destroyed.

- No virtiofs, 9p, vsock or USB.
- No host docker socket.
- User-mode networking only.
- The service sandbox hides `/home`, `/root` and `/run/user`.

libvirt is deliberately not used, because `qemu:///system` would make `runner` root-equivalent.

## DEVIATION for Argus: CLIENT-VLAN, host-enforced isolation (R4, R6, R9, R11, R14)

The box stays Sander's workstation on CLIENT-VLAN (172.16.3.205). There is no LAB-VLAN 60 move, so the
isolation that R4 and R6 put in the VLAN is enforced on the host instead. `table inet vdh_runner` is
added on top of the host's own firewall and never flushes it.

- **Everything uid `runner` sends** (qemu/VMs and the runner) may go to:
  - tcp 80/443 on public addresses;
  - tcp 443 on envoy-forge;
  - DNS through the host resolver.

  It may not reach RFC1918/CGNAT/link-local/multicast, IPv6, or any other host port.
- **Inbound 22/2222** is accepted only from:
  - the Mini .201 (the waker; the cluster workers .81–.83 were dropped on 2026-11-03);
  - Sander's MacBook: 172.16.3.108 and 172.16.3.23 on the LAN, 192.168.12.6 and 192.168.4.6 as WireGuard peers.
- **Residual risks:**
  - DNS tunnelling through the resolver: Argus M2 accepted this with zero secrets.
  - The initramfs dropbear on 2222 is open to the whole CLIENT-VLAN while the box sits at the unlock
    prompt, because no nftables runs that early. That is Sander's own setup.
  - A VM escape lands as uid `runner` on his workstation, inside the systemd sandbox.

## H2: owner risk acceptance

Sander accepted on 2026-10-13 that autologin opens his desktop on a team boot ("the machine is in my
own office, low risk"). There is no screen-lock hook. `/run/team-boot` stays, because idle-poweroff needs
it.

## Runner egress guard (Argus F3)

- `forgejo-runner-vm.service` has `ExecStartPre=+nft-guard check`, so it never starts without a complete
  `table inet vdh_runner`.
- `vdh-runner-nft-guard.timer` checks every minute and stops the service (and with it the job VM) when the
  table is gone or flushed.
- F4: the service also has `ProtectProc=invisible` and `ProcSubset=pid`.

## Re-runs never let `runner` steer root (Argus F1)

provision.sh never creates, chowns, chmods or writes into a path that `runner` controls:

- Runner-owned dirs are created by `runner` itself. An existing one is only checked (a directory, not a
  symlink, owned by runner).
- The base image is staged in root-owned `/var/lib/vdh-runner-stage`.
- The golden image and its VM host key are promoted by reading them AS runner (`runuser -u runner -- cat`)
  into root-owned paths. The host key lines are validated.
- Registration is one call by root over the normal LAN path (forge via envoy-internal), so it works
  before envoy-forge exists. It writes `.runner` in root-only `/var/lib/vdh-runner-stage/reg`. Runner
  then writes its own `.runner` from it (umask 077, noclobber), the staged copy is removed, and root only
  checks the result. Jobs never use the LAN path: the runner service and the VMs reach the forge only via
  envoy-forge (hosts pin + nftables).
- The dispatcher boots no VM until the forge answers `/api/healthz` via envoy-forge, so it costs no CPU
  before then.
- `write_file` refuses symlink destinations.
- idle-poweroff never follows symlinks in `/run/forgejo-runner`.
- `tests/arch-container.sh` section G attacks each of these paths.

## Team boot vs Sander boot (AGR-115)

encryptssh makes `/bin/cryptsetup_shell` the login shell of the initramfs ssh server. The wrapper writes
`/run/team-boot` (`started_by=team`, `boot_id`) only when that ssh session opened the disk. A console
unlock never passes through it. switch_root carries `/run` into the booted system.

- **Team boot:** the controller unlocks, or Larry uses his unlock key.
- **idle-poweroff:** acts only when the marker carries THIS boot's id and:
  - uptime is at least 2 h;
  - no job is running, and the last job ended at least 60 min ago;
  - seat0, and every user session except agent/runner, has been idle for at least 60 min;
  - no logind block inhibitor is held.

  Anything it cannot read means it keeps the box on.

## Waker (Mini, since 2026-11-03)

The in-cluster controller of 13-10 was removed on 14-10. It is replaced by `mini/vdhwslin01-waker.py`, which keeps
its decision logic and fail-closed rules. There is no cluster component, so no passphrase or unlock key is in the
cluster.

- **Every 2 min (launchd):**
  - probes 22/2222 with `nc`;
  - reads the forge queue: waiting and running jobs of org vdhict whose `runs_on` is a subset of
    `docker,x86-linux`. This is a read-only SQL query (`default_transaction_read_only`) on the forge-pg primary via
    the Mini's kubectl. Every forge API route that lists jobs needs org-owner rights, so no forge token is used
    (Argus D2).
- **When jobs wait and the box is off:**
  1. POST the local-only HA webhook. HA presses WoL and caps it at 4/day.
  2. Wait for 2222 (ssh alias `vdhwslin01-unlock`, pinned host key, StrictHostKeyChecking yes; no pin = refuse).
  3. Send `~/.config/vdhwslin01/luks-passphrase` as ssh stdin. The vdh-teamboot wrapper echoes the boot_id.
  4. Wait for 22.
  5. Write one change-log line.
- **Never:** it never touches a running box, and never unlocks a prompt it did not cause.
- **A failed wake is never silent.** Each failure writes one `executed` line with result `wake_failed` plus one ntfy
  message. The message has priority 1 and a `[night]` title from 23:00 to 07:00 (AGR-074). While the reason persists,
  the line and message repeat at most hourly. Reasons:
  - `no_unlock_prompt`, `passphrase_rejected`, `no_ssh_after_unlock`;
  - `cap_reached`, `no_host_key`, `webhook_error`, `queue_unreadable`;
  - `foreign_prompt_jobs_waiting`, `jobs_stuck_box_up`.
- **Secrets:**
  - the webhook id (`~/.config/vdhwslin01/ha-webhook-id`, from `mini/make-webhook-id.sh`) and the ntfy topic reach
    curl via `-K -` on stdin;
  - the passphrase reaches ssh via stdin;
  - none of them is ever printed or placed on argv.
- **Install (Argus B4):** `mini/install-waker.sh <commit>` takes the waker from a commit on origin/main (never the
  working tree), pins its sha256, the absolute kubectl and the change-log path in the plist, and loads nothing unless
  `--load` is given. Load only after Argus, Hestia's webhook, the HA cap readback (`mini/ha-cap-readback.sh`) and
  C8 (first attended reboot proves 2222 + /run/team-boot).
- **Queue read:** `kubectl --context admin@vdhinfra-local` (C6). The narrow route (CNPG select-only view + ConfigMap
  + one-resource SA) is designed in `docs/design/vdhwslin01-waker-queue-narrow-route.md`, due within 30 days.
- **Rollback:** `launchctl bootout gui/$(id -u)/net.vdhict.vdhwslin01-waker`.

## Tests

- Offline: `tests/run-all.sh`, which covers shellcheck, build sync, the idle-poweroff unit tests, the remote-unlock
  fixtures (incl. the box's measured HOOKS line), the Mini waker tests (`tests/test_waker_mini.py`, on /usr/bin/python3
  3.9 and python3), the revive invariants and the secret scan.
- Real Arch userland: `tests/arch-container.sh` in a throwaway Arch pod. It runs the dry-run, the real
  container-capable steps, idempotency, the built initramfs, the wrapper under the initramfs busybox, and
  the F1 attacks.
- Real kernel nftables: `tests/nft-kernel.sh` in a throwaway pod with NET_ADMIN in its own netns. It
  covers `nft -c`, the load, behaviour as runner vs root, and the guard against the real `nft list`
  (delete or flush -> stop).
- **Box-only (after Sander's run):**
  - R5: run two jobs back to back. The second sees no file from the first, and mount/lsblk/virtio are clean.
  - R6/C8: T2–T5 as a workflow job.
  - First team wake: `/run/team-boot` plus the boot_id in the controller event.
  - A Sander boot: `journalctl -t vdh-teamboot` says `started_by=sander`.
  - An ssh over WireGuard shows the peer IP as source in `journalctl -u sshd`.

## Rollback

- Box: `sudo ./provision.sh --uninstall`. Then kill the LUKS keyslot by hand (it asks for a remaining
  passphrase) and delete the runner on the forge.
- Mini: `launchctl bootout gui/$(id -u)/net.vdhict.vdhwslin01-waker`, then move the plist to
  `~/Library/LaunchAgents.retired/`.
