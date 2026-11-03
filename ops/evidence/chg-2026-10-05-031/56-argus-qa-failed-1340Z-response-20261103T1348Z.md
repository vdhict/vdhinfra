# chg-2026-10-05-031: response to Argus qa_failed 2026-11-03T13:40Z (Heph, 13:48Z)

No production writes. The box, forge and HA were read only. Two throwaway test namespaces were created and deleted,
with a read-back (Atlas go).

| Item | Status | Where |
|---|---|---|
| B1 org secrets | **open: Larry/owner** | - |
| B2 rotate org token + delete runner id 1 before registering | **ready, not run** | `post-run-checks.sh prereg` (dry by default; `--apply` = generate-runner-token --scope vdhict, discarded; guarded 1-row soft delete of runner id 1; read-back `PREREG PASS`). Dry run 13:3xZ: runner 1 live, token 1 active. Runbook step 2 (`sudo-window/larry/LARRY-NOTE.md`) |
| B3 writers | **done, no trigger** | `54-b3-vdhict-writers-20261103T1337Z.md`. Writers are admforgejo (34), mypka-bot (6), docs-bot (1) and palamedes (1), all team. No client or outside writer, no forks, 0 explicit trust. Forgejo 15 fork-PR approval is built in (trust.go). Repeatable: `post-run-checks.sh writers` |
| B4 waker install | **done** | `mini/install-waker.sh <commit>`: fetch; refuse unless the commit is on origin/main; `git show` to `~/.local/libexec/vdhwslin01-waker/` 0555; plist generated with `--expect-sha256`, `--kubectl` (absolute) and `--changes-log` (absolute); INSTALLED record 0444; loads only with `--load`. The waker self-checks at start: a mismatch or a missing pin refuses (rc 3) and writes one `self_check_failed` line plus ntfy, hourly. It no longer executes `ops/ops`; it appends the identical line format itself (test: byte-identical). Negatives: a non-main commit and a relative kubectl are refused |
| B5 passphrase route | **open: owner** | - |
| C6 context | **done** | `--context admin@vdhinfra-local` on every kubectl in the waker, post-run-checks and run-in-pod (tests assert it in the waker). Narrow route: `docs/design/vdhwslin01-waker-queue-narrow-route.md` (CNPG role with SELECT on one view, a 1-min CronJob writing a ConfigMap, a Mini SA with get on that resourceName only), due within 30 d |
| C7 readback | **offline done; live after Hestia** | `tests/test_waker_mini.py` (46 tests, 3.9 + 3.15). Forced no_host_key through the REAL change-log writer and REAL ntfy path (stub curl): 3 ticks give exactly 1 line + 1 ntfy, the topic is only on stdin, and it is reported again after 1 h. HA cap: structure + 5-POST model (4 presses, 1 refusal). Live: `mini/ha-cap-readback.sh --run` (box must be up; refuses otherwise; resets the counter). Dry tick: live 13:27Z `action=stuck`. Mutations caught 6/6 |
| C8 attended first reboot | plan | the waker loads only after 2222 + `/run/team-boot` are proven on an attended reboot |
| C9–C11 box read-backs | after Sander's session | `post-run-checks.sh c1` + nft set / `id runner` / unit read-back |

**Pod suites (Atlas go 13:3xZ), evidence 53-*:**
- **`53-nft-kernel-20261103T133511Z.txt`: 18/0** on kernel 6.18.18-talos.
  - The namespace is PSA privileged only because baseline forbids added capabilities; the pod is not privileged and
    adds only NET_ADMIN, in its own netns.
  - New: K1 confirms no cluster worker is on the allow list (D5).
- **`53-arch-container-20261103T133905Z.txt`: 75/0** (PSA baseline, default capabilities, nothing added).
  - The B checks confirm the 13.2.1 pin, groups exactly runner+kvm (D6), and InaccessiblePaths.
  - G3c covers the real Debian 20261026-2643 download, sha512 verified.
  - New section H runs a real mkinitcpio build with the box's own remote-unlock hook files (sha256 in the header).
    The Mini key was already present, so nothing was appended; every image has vdh-teamboot, and the root shell is the
    wrapper.
- **The first run (`…133605Z`, 73/1) failed on a test bug**, not on the bundle: `dropbearkey` writes a `.pub` next to
  the host key, and the test now compares the dir before and after. It is kept as history.
- **`53-sudo-window-20261103T134352Z.txt`: 38/0.** It covers the sudo-window kit with the re-pinned wrapper
  (provision 8420c072, the Mini unlock pubkey, keyslot never run). This is a third suite on the same throwaway-pod
  terms, run because the wrapper pins changed; I'm flagging it to Atlas.
  - Two earlier attempts are kept as history: `…134255Z` (16/22) and `…134317Z` (37/1).
  - The first failed on a launcher bug: `sudo-window/` was not in the pod bundle.
  - The second failed on a same-second filename collision between the S5 pre-check and the real read-back. The
    write-once guard worked; the test now uses its own dir.
  - The test's hard-coded provision hash is now derived from the wrapper's pin (S0).
- **All throwaway namespaces were deleted and read back NotFound**, with 0 throwaway pods and namespaces left after
  every run.
- **Arch E `nft -c` is SKIPPED** (no user namespaces under RuntimeDefault seccomp). The nft-kernel suite covers it.

**Residual (yours):** the Mini unlock key line in `/etc/remote-unlock/authorized_keys` lacks `no-port-forwarding,…`
(low). The fix is an owner edit, plus `limine-mkinitcpio`. It can go in Sander's sudo session if you want it.
