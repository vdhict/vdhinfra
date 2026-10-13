#!/usr/bin/env bash
# After Sander's provision.sh run (chg-2026-10-05-031). Run from the Mini.
#   post-run-checks.sh c1 <file with his SEND THIS BACK block>
#   post-run-checks.sh c6        # from a CONTROL-PLANE pod (SNAT .84-.86 = NOT allow-listed)
#   post-run-checks.sh rotate    # R7: new repo registration token, old one invalid; nothing printed
#   post-run-checks.sh waker     # one manual waker run, print its decision
# C4 (delete the nft table -> runner stops) needs sudo ON the box: Sander or
# Larry runs the two lines printed by `post-run-checks.sh c4`.
set -uo pipefail
REPO=/Users/sheijden/Code/homelab-migration/vdhinfra
eval "$(mise env -s bash -C "$REPO" 2>/dev/null)"
BOX=172.16.3.205
case "${1:-}" in
  c1)
    f="${2:?report file}"; rc=0
    grep -q 'provision.sh sha256: ad0304513bbff75f0d6c71bd4afc065e75078660faeb0d0dc53ea1b5eee6de38' "$f" && echo "ok   C1 sha256 matches the released script" || { echo "FAIL C1 sha256"; rc=1; }
    grep -qE 'runner groups: runner kvm$' "$f" && echo "ok   C1 runner groups exactly 'runner kvm'" || { echo "FAIL C1 runner groups: $(grep 'runner groups' "$f")"; rc=1; }
    grep -q 'runner registered: yes' "$f" && echo "ok   runner registered" || echo "WARN runner not registered"
    grep -qE 'luks keyslot: [0-9]+' "$f" && echo "ok   controller keyslot $(grep -oE 'luks keyslot: [0-9]+' "$f")" || echo "WARN no keyslot"
    grep -E 'vdh-runner-nft.service|vdh-runner-nft-guard.timer|forgejo-runner-vm.service|idle-poweroff.timer' "$f" | sed 's/^/     /'
    exit $rc ;;
  c6)
    # Pod on a control-plane node: egress SNATs to .84-.86, which are NOT on the allow-list.
    kubectl -n default run vdhwslin01-c6-probe --restart=Never --quiet \
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
    kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/vdhwslin01-c6-probe --timeout=60s >/dev/null
    echo "node: $(kubectl -n default get pod vdhwslin01-c6-probe -o jsonpath='{.spec.nodeName}')"
    kubectl -n default logs vdhwslin01-c6-probe
    kubectl -n default delete pod vdhwslin01-c6-probe --wait=false >/dev/null
    echo "C6 2222 auth methods (Mini is allow-listed; run while the box waits at the unlock prompt):"
    ssh -o BatchMode=yes -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p 2222 root@"$BOX" true 2>&1 | tail -1 ;;
  c4)
    echo "On vdhwslin01 as Sander (sudo), then wait 70 s:"
    echo "  sudo nft delete table inet vdh_runner; sleep 70; systemctl is-active forgejo-runner-vm; journalctl -t nft-guard -n 3"
    echo "Expect 'inactive' + 'STOPPED forgejo-runner-vm'. Restore:"
    echo "  sudo systemctl restart vdh-runner-nft forgejo-runner-vm && systemctl is-active forgejo-runner-vm" ;;
  rotate)
    kubectl -n devtools exec deploy/forgejo -c forgejo -- sh -c \
      'forgejo actions generate-runner-token --scope mypka-bot/passkey-point-dotnet >/dev/null && echo rotated' ;;
  waker)
    j="vdhwslin01-waker-manual-$(date +%H%M%S)"
    kubectl -n devtools create job --from=cronjob/vdhwslin01-waker "$j" >/dev/null
    kubectl -n devtools wait --for=condition=complete "job/$j" --timeout=900s >/dev/null
    kubectl -n devtools logs "job/$j" ;;
  *) sed -n '2,9p' "$0" ;;
esac
