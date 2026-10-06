# Passkey Point: switch the lab from MOCK to the Entra dev tenant (2026-10-07)

chg-2026-10-05-009. Owner: Heph (k8s-engineer). Demo rehearsal 09:30, meeting 10:15.
Fallback at every step: the MOCK deployment (a9a0114), which stays live until step 3. `<delta-sha>` = the entra delta commit recorded on chg-009.

| Commit | What |
|---|---|
| `a9a0114` | MOCK on the pod network (live once the pull fields exist; the fallback) |
| `<delta-sha>` (this commit) | ENTRA delta: scoped SecretStore, per-workload key files, roster sync, portal route, Entra egress. ConfigMaps are PLACEHOLDERS |
| render commit | `chore(lab-passkey): render entra env` from Mack's four `.env` files. Pushed together with the delta, never alone |

## 0. Preconditions (each one checked and recorded before step 4)

Owner / Mack / Larry (values never pass through Git or chat):

1. 1Password vault `lab-passkey` exists. Item `passkey-point-lab` is MOVED into it with the fields
   `web-entra-key`, `api-entra-key`, `roster-sync-entra-key`, `portal-entra-key`, `PP_PORTAL_MAC_KEY`,
   `registry-username`, `registry-token`. The registry token is a Forgejo token with `read:package` ONLY.
   It is not the mypka tenant token and not the forgejo admin.
2. The Connect server `security/onepassword-connect` has access to vault `lab-passkey`.
3. A Connect token scoped to vault `lab-passkey` (read) is stored in home-infra item
   `onepassword-connect-lab-passkey`, field `token`.
4. Entra app registrations (Mack step A, Sander's sign-in):
   - web: redirect `https://passkey-point-lab.bluejungle.net/auth/callback`, post-logout `/signed-out`.
   - portal: redirect `https://passkey-point-portal-lab.bluejungle.net/auth/callback`, post-logout `/signin`.
   - `devtenant verify` 0 FAIL. The synthetic accounts' passkeys are registered (>= 20 min after apply).
5. Mack's `out/lab/passkey-point.lab.{web,api,roster-sync,portal}.env` are handed over (non-secret).
6. `./ops/ops freeze status` shows no freeze. chg-2026-10-05-012 is not mid-step.

## 1. Render the env ConfigMaps (about 5 min)

```bash
cd /Users/sheijden/Code/homelab-migration/vdhinfra-passkey-entra
# the four files go into the session scratchpad, NEVER into the repo
python3 hack/passkey-point/render-env.py <scratch>/env --check   # must print 4x OK, exit 0
python3 hack/passkey-point/render-env.py <scratch>/env
git diff --stat                                                   # only env-{web,api,roster,portal}.yaml
```

Cross-check the printed ids against Mack's table: tenant `95cf7dac…`, web `8106de83…`, api `97b351a0…`,
roster-sync `682f5851…`, plus the portal app and population AU from his portal file.

Any `FAIL` means stop. The script refuses secrets, NODE_ENV, wrong key paths, wrong origins and
ungranted egress. Fix the input with Mack; never edit the script to let a file through.

Commit as `chore(lab-passkey): render entra env (chg-2026-10-05-009)`. Then validate:
kustomize, kubeconform, server dry-run (scripts in `ops/evidence/chg-2026-10-05-009/day2-entra/`).

## 2. Gate (target 15 min)

Themis gates the pair (delta + render) and checks that every rendered value is non-secret. Argus C4
covers the scoped store, toFQDNs egress, forward-auth on both routes and the grype result. Both
verdicts must exist before step 3.

## 3. Push (09:00-09:15)

```bash
git fetch origin
git merge-base --is-ancestor origin/main <render-sha>     # must be true (fast-forward), else rebase + re-gate
./ops/ops lock acquire k8s.ns.lab-passkey --by k8s-engineer --reason chg-2026-10-05-009
git push origin <render-sha>:refs/heads/main               # GitHub App token via http.extraheader
git cat-file -e origin/main:kubernetes/main/apps/lab-passkey/passkey-point/app/roster.yaml
```

## 4. Watch the roll (target 10 min)

- `flux get ks lab-passkey-network-policies lab-passkey-app` shows Ready.
- `kubectl -n lab-passkey get secretstore,externalsecret`: the store is Valid and all 7 ES are SecretSynced.
- web, api, roster and portal are Running with restartCount 0.
- The logs have no `ConfigError` and no exit 78. The app refuses a bad config at start.
- api may restart once until the roster sync has created `roster.db` in pp-roster (self-heals).
- `hubble observe -n lab-passkey`: FORWARDED to login.microsoftonline.com / graph.microsoft.com, no DROPPED on an allowed path.

## 5. End-to-end on the real path (Sander, with Larry; about 15 min)

Use a private browser window with no Authelia session (Argus PP-F1). Secure DNS off. LAN or WireGuard.

1. https://passkey-point-portal-lab.bluejungle.net: sign in as `list-owner-a` with the key, stage the
   import and `todays-list-2026-10-07.csv`. Then sign in as `list-owner-b` and approve both batches.
2. Wait for one sync run, or `kubectl -n lab-passkey rollout restart deploy/passkey-point-roster`.
3. https://passkey-point-lab.bluejungle.net: sign in as `sander-dev` (Trusted Person) with the passkey.
   Today's list shows the synthetic workers. Do an ID check, issue a TAP for a synthetic worker, and
   register that worker's security key with it.
4. Evidence:
   - screenshots;
   - the api audit log line for the TAP;
   - Entra sign-in log entries for the synthetic user (Mack);
   - hubble flows;
   - T3 negatives re-run: no egress except the two Entra hosts, web cannot reach graph, 1.1.1.1 fails,
     example.com is refused.

Synthetic people only. No real names or IDs are ever typed in.

## 6. Rollback = back to MOCK (target 5 min, any time)

```bash
git revert --no-edit <render-sha> <delta-sha>   # restores the a9a0114 tree
git push origin HEAD:refs/heads/main          # explicit SHA, after a fetch
```

pp-data then holds entra-mode SQLite data that MOCK would open. Before Flux brings MOCK back:

1. `flux suspend ks lab-passkey-app`
2. `kubectl -n lab-passkey delete deploy --all`
3. `kubectl -n lab-passkey delete pvc pp-data pp-roster` (synthetic lab data only; pre-approved for this
   rollback in the gate record)
4. `flux resume ks lab-passkey-app`

Break-glass instead of a revert: `flux suspend ks lab-passkey-app lab-passkey-network-policies`, then
`kubectl delete ns lab-passkey`. cluster-apps recreates an EMPTY namespace until the revert lands, and
that is expected.

## 7. After the demo

- Record `validated` on chg-009 with the evidence.
- Rewrite the CMDB entries `k8s.ns.lab-passkey` and `app.passkey-point-lab` (Themis C7).
- Teardown by 2026-10-31: remove the directory, the 1Password vault and item, and the Entra apps
  (`devtenant` teardown).
- Follow-up: move to a ClusterSecretStore with namespace conditions so the Connect token leaves the
  namespace (see `secretstore.yaml`).
