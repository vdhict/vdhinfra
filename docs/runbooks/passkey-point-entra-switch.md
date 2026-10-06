# Passkey Point: switch the lab from MOCK to the Entra dev tenant (2026-10-07)

chg-2026-10-05-009. Owner: Heph (k8s-engineer). Demo rehearsal 09:30, meeting 10:15.

| Commit | What |
|---|---|
| `a9a0114` | MOCK on the pod network. This is the fallback demo |
| `<delta-sha>` | ENTRA delta (gated). Scoped SecretStore, per-workload key files, roster sync, portal route, Entra egress, allow-list renderer, B2 guard. The ConfigMaps are PLACEHOLDERS without the guard key |
| `<render-sha>` | `chore(lab-passkey): render entra env`. Exactly the four `env-*.yaml`, written by `render-env.py` |

**B2 guard.** Every Deployment reads `PP_ENV_RENDERED_FROM` from its ConfigMap with `optional: false`. Only
the renderer writes that key. A push of the placeholders therefore stops each pod with
`CreateContainerConfigError` before any supplier code runs.

## Timeline (Themis C5; all times CEST, 2026-10-07)

| By | What | Who |
|---|---|---|
| 08:00 | Owner 1Password actions 1-3 and Mack step A done, each with a timestamp. The four `.env` files and the portal key are delivered | owner, Mack, Larry |
| 08:20 | Render commit made and validated (step 1) | Heph |
| **08:30** | **HARD CUT-OFF.** If the render is not committed, there is no entra push before the meeting, and MOCK (if live) is the demo | Atlas |
| 08:40 | Themis delta gate on the pair (M1-M11) and the Argus verdict on the render commit | Themis, Argus |
| 08:45 | Push (step 3). The 01:00-06:00 window also works if the inputs are in: silent heartbeats only, no sound or vibration 23:00-07:00 | Heph |
| 08:55 | Pods Ready, ES 7/7, store Valid, R6/R7 read-back done | Heph |
| 08:55-09:25 | E2E (step 5) | owner, Larry, Heph |
| | TAP issuance no earlier than step A + 20 min. Both timestamps go in the evidence | |

**C6, never concurrent with MOCK.** One push at a time under the single lock `k8s.ns.lab-passkey`. Before
the delta push, one of these must hold:

- `a9a0114` is live AND `flux get ks lab-passkey-app` is Ready (mock has settled); or
- `a9a0114` was never pushed. The delta push then carries it as an ancestor, and mock never runs.

Never push `a9a0114` once the render commit exists, unless the entra push is abandoned for the day. No
push while any lab-passkey reconcile is in progress.

## 0. Preconditions (each one recorded with a timestamp, Themis M7)

1. 1Password vault `passkey-point-lab` exists. Item `passkey-point-lab` is MOVED into it with all 7 fields:
   - `web-entra-key`, `api-entra-key`, `roster-sync-entra-key`, `portal-entra-key`;
   - `PP_PORTAL_MAC_KEY`;
   - `registry-username`, `registry-token`. The registry token is a Forgejo token with `read:package` ONLY.
2. The Connect server `security/onepassword-connect` has access to vault `passkey-point-lab`.
3. A Connect token with READ on vault `passkey-point-lab` only is stored in home-infra item
   `op-connect-token-passkey-point-lab`, field `credential` (to confirm).
4. Entra (Mack step A, Sander's sign-in), Argus R3 and R4:
   - All four apps are single-tenant and use certificate credentials only, with no client secrets.
   - web redirect URIs: exactly `https://passkey-point-lab.bluejungle.net/auth/callback` and `/signed-out`.
   - portal redirect URIs: exactly `https://passkey-point-portal-lab.bluejungle.net/auth/callback` and `/signin`.
   - No localhost and no wildcard redirect URIs.
   - A dev-tenant Conditional Access policy targets auth context `c1` with phishing-resistant strength.
   - The api app's TAP role is scoped to the population AU (Argus R2).
   - `devtenant verify` shows 0 FAIL.
5. Mack's `out/lab/passkey-point.lab.{web,api,roster-sync,portal}.env`. They are non-secret, but they stay
   out of the repo.
6. `./ops/ops freeze status` shows no freeze. inc-2026-10-06-004 is unchanged: no drain or reboot is
   needed (M11). The C1 lock-holder acknowledgement for BOTH routes is on chg-2026-09-21-002.

## 1. Render (by 08:20)

```bash
cd /Users/sheijden/Code/homelab-migration/vdhinfra-passkey-entra
shasum -a 256 hack/passkey-point/render-env.py           # = the gated sha256 (M2)
python3 hack/passkey-point/render-env.py <scratch>/env --check   # 4x OK, exit 0, no FAIL
python3 hack/passkey-point/render-env.py <scratch>/env
git add kubernetes/main/apps/lab-passkey/passkey-point/app/env-*.yaml
git commit -m "chore(lab-passkey): render entra env (chg-2026-10-05-009)"
```

- **Eyeball every rendered value (Argus R5).** They must be only GUIDs, 64-hex thumbprints, `c1`,
  `app`, `entra` and the sites JSON. The renderer cannot recognise a short secret under an odd key name.
- Cross-check the ids against Mack's table (M4): tenant `95cf7dac…`, web `8106de83…`, api `97b351a0…`,
  roster-sync `682f5851…`, plus the portal app and the population AU.
- `PP_SITES` campaignFrom/campaignUntil must cover 2026-10-07 08:45-11:00 CEST (M5).
- Any `FAIL` means stop. Fix the input with Mack. Never edit the renderer to let a file through: that
  is a new gate.

## 2. Pre-push checks (Themis B2/M1-M6, Argus R5)

```bash
D=<delta-sha>; R=<render-sha>
for w in web api roster portal; do
  git show "$R:kubernetes/main/apps/lab-passkey/passkey-point/app/env-$w.yaml" | grep -q '^  PP_ENV_RENDERED_FROM: "sha256:' \
    && echo "guard ok $w" || echo "GUARD MISSING $w"
done                                                      # 4x "guard ok"
git diff --name-only "$D" "$R"                            # EXACTLY the four env-{web,api,roster,portal}.yaml
git rev-parse "$R^"                                       # = the gated delta SHA
mise x aqua:gitleaks/gitleaks@8.30.1 -- gitleaks git --log-opts "$D..$R" --no-banner   # "no leaks found"
```

Then rerun kustomize, yamllint, kubeconform and the server dry-run (with PSA) on the pair. Leftover `${`
must be 0. The evidence goes to `ops/evidence/chg-2026-10-05-009/day2-entra/`.

## 3. Push (08:45)

```bash
git fetch origin
git merge-base --is-ancestor origin/main "$R"            # true, else rebase -> NEW SHA -> re-gate (M10)
./ops/ops lock acquire k8s.ns.lab-passkey --by k8s-engineer --reason chg-2026-10-05-009
git push origin "$R:refs/heads/main"                     # GitHub App token via http.extraheader
git cat-file -e origin/main:kubernetes/main/apps/lab-passkey/passkey-point/app/roster.yaml
```

## 4. Watch and read back (by 08:55)

- `flux get ks lab-passkey-network-policies lab-passkey-app` shows Ready.
- `kubectl -n lab-passkey get secretstore,externalsecret`: the store is Valid and the ES are 7/7 SecretSynced.
- The 4 pods are Running with restartCount 0. The logs show no `ConfigError` and no exit 78. The api may
  restart once, until the roster sync has created `roster.db`.
- **R6 read-back:**
  - the api's `roster` mount is `readOnly: true`;
  - every secret volume has `defaultMode: 288` (0440);
  - each pod's env shows `PP_ENV_RENDERED_FROM` equal to the rendered sha256 (Themis C3);
  - no pod mounts or references `onepassword-connect-lab-passkey`. Only `secretstore.yaml` uses it.
- **R7:** the scoped token can read vault `passkey-point-lab` only (1P token detail, or the Connect `/v1/vaults`
  listing via that token). The SecretStore is Ready.
- **C3:** the ConfigMaps have fixed names. After ANY re-render: commit, re-gate, push, then
  `kubectl -n lab-passkey rollout restart deploy/<affected>`. Then confirm the pods' `PP_ENV_RENDERED_FROM`
  equals the new sha256.
- **C4 Multi-Attach:** if the api lands on another node than roster/portal (a Multi-Attach error on
  pp-data or pp-roster after a reschedule), delete the roster and portal pods TOGETHER. Never drain a node
  (inc-2026-10-06-004).

## 5. End-to-end on the real path (08:55-09:25)

Browser (Argus PP-F1, ruling 5): use a private window or a profile that has NEVER signed in to Authelia.
The cookie jar must be empty, and the browser state goes in the evidence. Nobody opens either hostname in a
normal household browser. Secure DNS off. LAN or WireGuard. Synthetic people only.

1. **Portal:** https://passkey-point-portal-lab.bluejungle.net. Sign in as `list-owner-a` with the key,
   then stage the import and `todays-list-2026-10-07.csv`. Sign out, sign in as `list-owner-b` and approve
   both batches. Take a kiosk-verify (fresh profile) screenshot of the portal sign-in.
2. **Sync:** wait for one sync run, or `kubectl -n lab-passkey rollout restart deploy/passkey-point-roster`.
3. **Web:** https://passkey-point-lab.bluejungle.net. Sign in as `sander-dev` with the passkey. Today's list
   shows the synthetic workers. Do an ID check and issue a TAP for a synthetic worker (at least step A + 20
   min). Register that worker's key with it. Take a kiosk-verify (fresh profile) screenshot of the web
   Trusted Person sign-in.
4. **T3 entra mode (Argus R8, Themis C2)**, in ONE run, with hubble DROPPED and FORWARDED lines as artefacts.

   Must fail:
   - web -> graph.microsoft.com:443;
   - any pod -> monitor.azure.com:443, example.com (DNS refused), 1.1.1.1:443;
   - any pod -> the LAN (HA :8123, 172.16.2.1:443, NAS :445), 10.43.0.1:443;
   - any pod -> the envoy-internal Service :443, LB :443 and pods :10443;
   - roster or portal -> api:8443;
   - ingress to web, api or roster from a pod in `tools`.

   Must work (positive controls, same run):
   - web -> login.microsoftonline.com;
   - api, roster and portal -> login.microsoftonline.com and graph.microsoft.com;
   - web -> api:8443.
5. **T4 DNS for BOTH hostnames** (`run-kit/t4-dns.sh`, twice):
   - public DoH returns NXDOMAIN;
   - the UDM answers 172.16.2.241;
   - Hermod: exactly ONE A record per hostname (2 in total), written by external-dns-unifi, no AAAA, no manual record;
   - no Cloudflare record.
6. **Evidence:**
   - both screenshots;
   - the api audit line for the TAP;
   - the Entra sign-in log entries (Mack);
   - the hubble flows;
   - the step A and TAP timestamps;
   - the browser state.

## 6. Rollback = back to MOCK (Themis B3 + Argus; volume deletion approved by Atlas, logged with `rolled_back`)

Order matters. The suspend comes BEFORE the revert push, so Flux never starts MOCK on top of entra data.

1. **Export evidence first.**
   - Copy the api audit trail and the TAP audit line from pp-data, plus the row counts of `roster.db` and
     the pp-data databases, to `ops/evidence/chg-2026-10-05-009/day2-entra/rollback-<ts>/`.
   - For a SECURITY rollback, copy the whole pp-data audit trail.
   - Read via `kubectl exec` into the api or roster pod (the supplier image's own tools), never by running
     supplier code on vdhmini01.
2. `flux suspend ks lab-passkey-app`
3. `kubectl -n lab-passkey delete deploy --all`
4. `kubectl -n lab-passkey delete pvc pp-data pp-roster` (synthetic lab data only. Team decision under
   the 2026-10-05 Spelregels: Atlas-approved, logged)
5. Revert and push by explicit SHA:
   - `git fetch origin`
   - `git revert --no-edit a9a0114..<render-sha>` (reverts render, docs, fix and delta, newest first; tree = a9a0114, push the resulting HEAD SHA)
   - check the fast-forward
   - `git push origin <revert-sha>:refs/heads/main`
6. `flux resume ks lab-passkey-app`. MOCK comes back with fresh PVCs. Re-run T0/T1 of the MOCK plan.
7. `./ops/ops change event chg-2026-10-05-009 rolled_back ...` with the evidence path, then release the lock.

Break-glass if Flux itself is impaired:

1. `flux suspend ks lab-passkey-app lab-passkey-network-policies`
2. Do step 1 above (evidence), if the pods still run.
3. `kubectl delete ns lab-passkey`. cluster-apps recreates an EMPTY namespace until the revert lands. That
   is expected.

## 7. After the demo, and teardown (by 2026-10-31)

- Record `validated` on chg-009. Rewrite the CMDB entries `k8s.ns.lab-passkey` and
  `app.passkey-point-lab` (Themis C7).
- Teardown, in this order:
  1. Remove the directory (one commit).
  2. Remove the four certificate credentials from the Entra app registrations (Mack, `devtenant` teardown).
  3. Revoke the `passkey-point-lab` Connect token, and delete the home-infra item `op-connect-token-passkey-point-lab`.
  4. Delete vault `passkey-point-lab`.
  5. Revoke the read:package Forgejo token.
- Follow-ups: F-A (ClusterSecretStore with conditions, plus `lab-passkey` in the NotIn list of
  `onepassword-connect`), F-B (portal needs its own read-only directory app, supplier PP-F3), F-C
  (Authelia cookie domain).

## Kept easy to change (pending Argus)

- **Portal mounting the roster-sync key:** it is the `entra` volume in `portal.yaml`, plus the
  `ROSTER_SYNC_*` keys in the portal's allow-list in `render-env.py`. A separate read-only directory app
  means changing that one volume's secretName, one ExternalSecret and the portal's allow-list entries.
- **Tenant and client IDs in the public repo:** they live only in the four rendered ConfigMaps. The
  alternative is to keep them in vault `passkey-point-lab` and feed them through per-workload ExternalSecrets
  (`envFrom: secretRef`). Same keys, same allow-list check run before writing to 1Password; only the
  render target changes.
