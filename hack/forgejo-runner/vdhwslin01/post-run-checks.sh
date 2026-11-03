#!/usr/bin/env bash
# After Sander's provision.sh run (chg-2026-10-05-031). Run from the Mini.
#   post-run-checks.sh c1 <file with his SEND THIS BACK block>
#   post-run-checks.sh c6        # from a CONTROL-PLANE pod (SNAT .84-.86 = NOT allow-listed; since 2026-11-03 no node is)
#   post-run-checks.sh rotate    # R7: new org vdhict registration token, old one invalid; nothing printed
#   post-run-checks.sh scope     # forge read-only: runner vdhwslin01 is org vdhict (repo 0), labels, online
#   post-run-checks.sh waker     # one Mini waker --dry-run, print its decision (no side effects)
#   post-run-checks.sh writers   # B3 read-only: vdhict members, teams, collaborators, fork-PR trust (names + counts)
#   post-run-checks.sh prereg [--apply]   # B2, BEFORE registering: rotate the org vdhict registration token
#                                # (kills id 1) and soft-delete stale runner id 1; default = dry (plan + read-back only)
# Every kubectl call pins --context admin@vdhinfra-local and an absolute kubectl (Argus C6).
# C4 (delete the nft table -> runner stops) needs sudo ON the box: Sander or
# Larry runs the two lines printed by `post-run-checks.sh c4`.
# shellcheck disable=SC2015  # ok/FAIL report idiom: echo cannot fail
set -uo pipefail
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
eval "$(mise env -s bash -C "$REPO" 2>/dev/null)"
BOX=172.16.3.205
KUBECTL="${KUBECTL:-$(command -v kubectl)}"; [[ "$KUBECTL" == /* ]] || { echo "kubectl not found as an absolute path" >&2; exit 2; }
K=("$KUBECTL" --context admin@vdhinfra-local)
pgq() { # pgq <sql...>: read-only psql on the forge-pg primary
  local p; p=$("${K[@]}" -n devtools get pod -l cnpg.io/cluster=forge-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
  local a=(); for x in "$@"; do a+=(-c "$x"); done
  "${K[@]}" -n devtools exec "$p" -c postgres -- psql -X -q -At -F' | ' -v ON_ERROR_STOP=1 -U postgres -d forgejo -c "SET default_transaction_read_only = on" "${a[@]}"
}
pgw() { # pgw <sql>: ONE write statement in its own transaction (prereg --apply only)
  local p; p=$("${K[@]}" -n devtools get pod -l cnpg.io/cluster=forge-pg,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
  "${K[@]}" -n devtools exec "$p" -c postgres -- psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d forgejo -c "$1"
}
ORG_ID="(SELECT id FROM \"user\" WHERE lower_name='vdhict')"
case "${1:-}" in
  c1)
    f="${2:?report file}"; rc=0
    want="$(shasum -a 256 "$REPO/hack/forgejo-runner/vdhwslin01/provision.sh" | cut -d' ' -f1)"
    grep -q "provision.sh sha256: ${want}" "$f" && echo "ok   C1 sha256 matches the released script ${want}" || { echo "FAIL C1 sha256 (want ${want})"; rc=1; }
    grep -qE 'runner groups: runner kvm$' "$f" && echo "ok   C1 runner groups exactly 'runner kvm'" || { echo "FAIL C1 runner groups: $(grep 'runner groups' "$f")"; rc=1; }
    grep -q 'runner registered: yes' "$f" && echo "ok   runner registered" || echo "WARN runner not registered"
    grep -q 'luks keyslot: none' "$f" && echo "ok   no extra LUKS keyslot (by design since 2026-11-03)" || { echo "FAIL a keyslot was added: $(grep 'luks keyslot' "$f")"; rc=1; }
    grep -q 'registration scope expected: org vdhict' "$f" && echo "ok   bundle expects org vdhict" || { echo "FAIL scope line"; rc=1; }
    grep -E 'vdh-runner-nft.service|vdh-runner-nft-guard.timer|forgejo-runner-vm.service|idle-poweroff.timer' "$f" | sed 's/^/     /'
    exit $rc ;;
  c6)
    # Pod on a control-plane node: egress SNATs to .84-.86, which are NOT on the allow-list.
    "${K[@]}" -n default run vdhwslin01-c6-probe --restart=Never --quiet \
      --image=docker.io/library/python:3.13.15-bookworm@sha256:227b6570d6ee07061ae6ca2eb04dedfb6d2b34045835f343065b9869e4d427ea \
      --overrides='{"spec":{"automountServiceAccountToken":false,"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}' \
      -- python3 -c '
import socket
for port in (22, 2222):
    s=socket.socket(); s.settimeout(5)
    try: s.connect(("'"$BOX"'", port)); print("port", port, "OPEN from non-allow-listed node (C6 FAIL if box is up)")
    except socket.timeout: print("port", port, "dropped (timeout): C6 ok")
    except OSError as e: print("port", port, "refused/unreachable:", e)
    finally: s.close()'
    "${K[@]}" -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/vdhwslin01-c6-probe --timeout=60s >/dev/null
    echo "node: $("${K[@]}" -n default get pod vdhwslin01-c6-probe -o jsonpath='{.spec.nodeName}')"
    "${K[@]}" -n default logs vdhwslin01-c6-probe
    "${K[@]}" -n default delete pod vdhwslin01-c6-probe --wait=false >/dev/null
    echo "C6 2222 auth methods (Mini is allow-listed; run while the box waits at the unlock prompt):"
    ssh -o BatchMode=yes -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p 2222 root@"$BOX" true 2>&1 | tail -1 ;;
  c4)
    echo "On vdhwslin01 as Sander (sudo), then wait 70 s:"
    echo "  sudo nft delete table inet vdh_runner; sleep 70; systemctl is-active forgejo-runner-vm; journalctl -t nft-guard -n 3"
    echo "Expect 'inactive' + 'STOPPED forgejo-runner-vm'. Restore:"
    echo "  sudo systemctl restart vdh-runner-nft forgejo-runner-vm && systemctl is-active forgejo-runner-vm" ;;
  rotate)
    "${K[@]}" -n devtools exec deploy/forgejo -c forgejo -- sh -c \
      'forgejo actions generate-runner-token --scope vdhict >/dev/null && echo rotated' ;;
  scope)
    pgq "SELECT r.id, r.name, coalesce(u.lower_name,'-') AS owner, r.repo_id, r.agent_labels, r.version, to_timestamp(r.last_online) FROM action_runner r LEFT JOIN \"user\" u ON u.id=r.owner_id WHERE r.deleted IS NULL ORDER BY r.id" \
        "SELECT t.id, coalesce(u.lower_name,'-'), t.repo_id, t.is_active FROM action_runner_token t LEFT JOIN \"user\" u ON u.id=t.owner_id ORDER BY t.id"
    echo "expect: one runner 'vdhwslin01' owner=vdhict repo_id=0 labels docker,x86-linux; stale id 1 deleted; org token rotated (only the newest active)" ;;
  writers)
    echo "# org members (login|is_admin)";   pgq "SELECT u.lower_name, u.is_admin FROM org_user ou JOIN \"user\" u ON u.id=ou.uid WHERE ou.org_id=$ORG_ID ORDER BY 1"
    echo "# teams (name|authorize|all_repos|repos|units>=write)"; pgq "SELECT t.lower_name, t.authorize, t.includes_all_repositories, t.num_repos, (SELECT string_agg(tu.type||':'||tu.access_mode, ',' ORDER BY tu.type) FROM team_unit tu WHERE tu.team_id=t.id AND tu.access_mode>=2) FROM team t WHERE t.org_id=$ORG_ID ORDER BY 1"
    echo "# team members (team|login)";    pgq "SELECT t.lower_name, u.lower_name FROM team_user tu JOIN team t ON t.id=tu.team_id JOIN \"user\" u ON u.id=tu.uid WHERE tu.org_id=$ORG_ID ORDER BY 1,2"
    echo "# collaborators (login|mode|repos|org member)"; pgq "SELECT u.lower_name, c.mode, count(*), EXISTS(SELECT 1 FROM org_user ou WHERE ou.org_id=$ORG_ID AND ou.uid=u.id) FROM collaboration c JOIN repository r ON r.id=c.repo_id JOIN \"user\" u ON u.id=c.user_id WHERE r.owner_id=$ORG_ID GROUP BY 1,2,4 ORDER BY 1"
    echo "# fork-PR explicit trust entries on vdhict (expect 0) | forks of vdhict repos (expect 0)"
    pgq "SELECT count(*) FROM action_user au JOIN repository r ON r.id=au.repo_id WHERE r.owner_id=$ORG_ID" \
        "SELECT count(*) FROM repository f JOIN repository b ON b.id=f.fork_id WHERE b.owner_id=$ORG_ID" ;;
  prereg)
    # B2 (Argus 2026-11-03): before ANY registration on vdhwslin01. Never prints a token.
    apply=0; [[ "${2:-}" == --apply ]] && apply=1
    echo "# before: vdhict runners (id|name|repo|last_online|deleted) and registration tokens (id|active)"
    pgq "SELECT r.id, r.name, r.repo_id, r.last_online, coalesce(r.deleted::text,'-') FROM action_runner r WHERE r.owner_id=$ORG_ID ORDER BY r.id" \
        "SELECT t.id, t.is_active FROM action_runner_token t WHERE t.owner_id=$ORG_ID ORDER BY t.id"
    if (( ! apply )); then
      echo "# DRY: would (1) forgejo actions generate-runner-token --scope vdhict >/dev/null (Forgejo 15 NewRunnerToken deactivates every older vdhict token, incl. id 1);"
      echo "#      (2) UPDATE action_runner SET deleted=<now> WHERE id=1 AND name='forgejo-runner-vdhict' AND last_online=0 AND deleted IS NULL (guarded, exactly 1 row)."
      echo "# re-run with --apply to do it."; exit 0
    fi
    "${K[@]}" -n devtools exec deploy/forgejo -c forgejo -- sh -c 'forgejo actions generate-runner-token --scope vdhict >/dev/null && echo "token rotated (value discarded)"'
    n=$(pgw "UPDATE action_runner SET deleted = extract(epoch FROM now())::bigint WHERE id=1 AND name='forgejo-runner-vdhict' AND owner_id=$ORG_ID AND last_online=0 AND deleted IS NULL RETURNING id" | grep -c . || true)
    echo "runner id 1 soft-deleted rows: $n (expect 1, or 0 if already deleted)"
    echo "# after (read-back)"
    pgq "SELECT r.id, r.name, coalesce(r.deleted::text,'-') FROM action_runner r WHERE r.owner_id=$ORG_ID ORDER BY r.id" \
        "SELECT t.id, t.is_active FROM action_runner_token t WHERE t.owner_id=$ORG_ID ORDER BY t.id"
    act=$(pgq "SELECT count(*) FROM action_runner_token t WHERE t.owner_id=$ORG_ID AND t.is_active")
    one=$(pgq "SELECT count(*) FROM action_runner_token WHERE id=1 AND is_active")
    live1=$(pgq "SELECT count(*) FROM action_runner WHERE id=1 AND deleted IS NULL")
    if [[ "$act" == 1 && "$one" == 0 && "$live1" == 0 ]]; then echo "PREREG PASS: 1 active vdhict token (not id 1), runner id 1 deleted"
    else echo "PREREG FAIL: active=$act id1_active=$one runner1_live=$live1"; exit 1; fi ;;
  waker)
    /usr/bin/python3 -I "${WAKER:-$HOME/.local/libexec/vdhwslin01-waker/vdhwslin01-waker.py}" --dry-run ;;
  *) sed -n '2,14p' "$0" ;;
esac
