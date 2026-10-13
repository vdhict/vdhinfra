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
| waker CronJob | `kubernetes/main/apps/devtools/vdhwslin01-waker/` | uid 65534 |
| HA webhook package | `ha/vdhwslin01_wake.yaml`, installed by Hestia | HA |
| change-log bridge | `collect-waker-events.py`, on the Mini | Atlas |

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
  - cluster workers .81–.83;
  - the Mini .201;
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

## Controller (cluster)

- **Every 2 min:** reads the forge (`/repos/mypka-bot/passkey-point-dotnet/actions/runners/jobs?labels=docker,x86-linux`)
  and probes 22/2222.
- **When jobs are queued and the box is off:**
  1. POST to the local-only HA webhook. HA presses WoL and counts 4/day.
  2. Wait for 2222. The host key is pinned in `app/known_hosts`; while it is empty the controller
     refuses to wake.
  3. Send the keyslot passphrase. The wrapper echoes the boot_id back.
  4. Wait for 22.
  5. Record one event.
- **Never:** it does not touch a running box, and it does not unlock a prompt it did not cause.
- **Credentials:**
  - Keys and passphrase are generated in-cluster by ESO generators (`refreshPolicy: CreatedOnce`).
  - There is no PushSecret (Argus F2): the 1Password Connect token stays read-only. The passphrase
    reaches Sander as a stdin pipe from the Secret, and the webhook id reaches HA the same way. Neither
    is ever printed.
  - The private key never leaves the namespace.

**Forge token (Argus F5), and DR:** Secret `devtools/vdhwslin01-waker-forge` holds a mypka-bot token
with scope `read:repository`, restricted to the one repository `mypka-bot/passkey-point-dotnet`.
Forgejo tokens cannot expire, so the waker enforces `forge_token_expires` from the
`vdhwslin01-waker-config` ConfigMap itself:

- 14 days before that date it logs a warning event;
- after that date it stops querying the forge, so it fails closed.

To rotate (and for DR), run the command below, then bump the date (+90 d) in
`kubernetes/main/apps/devtools/vdhwslin01-waker/app/kustomization.yaml`:

```
hack/forgejo-runner/vdhwslin01/mint-waker-forge-token.py --delete-old <previous-token-name>
```

## Tests

- Offline: `tests/run-all.sh`, which covers shellcheck, build sync, the idle-poweroff unit tests and the
  secret scan, plus `python3 tests/test_controller.py`.
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
- Cluster: `git revert`. The unlock Secret and the state ConfigMap have prune disabled; delete them by hand
  if the box side is gone.
