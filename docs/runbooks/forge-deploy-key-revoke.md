# Revoke a forge push deploy key (chg-2026-11-13-002 L7)

The forge push deploy keys are listed in `hack/ops/forge-push/deploy-keys.json`: one write key per repo, held on
vdhmini01 only. This runbook takes one key out of service and proves it is gone. Revocation is reversible:
creating a new key needs Sander's explicit yes again.

## When (any one is enough, revoke at once, no window needed)

- **Pin guard red.** Triggers: a CI run on main, the `pin_guard_live` or `pin_guard_ci` finding in the daily posture
  scan, or a GitHub issue "PIN-GUARD RED".
- **L5 forge push audit high finding.** One of:
  - a push without an L4 line, unless that line exists locally and only has to be pushed;
  - a refused push attempt by a key;
  - a key with write access outside its repo.
- **The push script's control probe was ACCEPTED** ("CONTROL PROBE ACCEPTED").
- **A key file is found off the Mini,** outside an accepted Time Machine copy.
- **uid separation for myPKA is done.** Reissue the keys to Atlas's uid only.
- **A repo gains a workflow tree** (`.forgejo`, `.gitea` or `.github`), or **forge SSH is exposed beyond the
  LAN/VPN.**
- **The review date in deploy-keys.json (`review_by`) has passed** without a fresh Argus review.

## Steps

1. Dry run. It shows the target ids and deletes nothing:

   ```bash
   python3 hack/ops/forge-push/revoke-deploy-key.py <chg-id> VDHICT/<repo>
   ```

2. Revoke. Uses a short-lived admforgejo token, which is deleted after use:

   ```bash
   python3 hack/ops/forge-push/revoke-deploy-key.py <chg-id> VDHICT/<repo> --execute
   ```

   Expected: `DELETE deploy key -> HTTP 204`, then `REVOKED`. It needs three readbacks:
   - the API key list of the repo no longer has the `deploy_key_id`;
   - SQL `deploy_key`/`public_key` rows for the `public_key_id` are `0|0`;
   - `git ls-remote` with the key file is refused.

   The script writes one `executed` line to `ops/changes.jsonl`. `REVOKE-INCOMPLETE` means: stop and read the
   readback fields.

3. Set the entry's `status` to `revoked` in `deploy-keys.json` and commit it. The push script then refuses the repo.

4. Move the private key file aside with `mv` to `~/.ssh/revoked/`, never `rm` (AGR-121). Leave the decision to
   shred it to a reviewed script.

5. For a security trigger (the L5 audit, the probe, a key found off the Mini), open an incident.
   - Check the range on the repo since the last good L4 line: `git log <last-good>..<forge main>`.
   - Treat every commit pushed with the key as untrusted until Argus has reviewed the range (L6).

6. If more than one key may be affected (a pin guard red, uid separation), repeat for every `active` entry.

## Not covered

- Branch and tag protection rules stay as they are.
- The commit pin in `kubernetes/main/apps/mypka/wires/source/gitrepository.yaml` stays as it is. A pushed commit
  runs only after a reviewed pin move.
