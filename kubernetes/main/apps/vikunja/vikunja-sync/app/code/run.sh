#!/bin/sh
# One CronJob run of the vault <-> Vikunja sync, on the vendor image python:3.13.15-bookworm
# (stdlib Python, git, openssh-client; no image build). The code and this script come from a
# ConfigMap at /srv/sync; the two deploy keys and config.json from the Secret at /secrets (ESO,
# 1Password item "vikunja-sync"); VIKUNJA_TOKEN from ESO (item "vikunja"). Nothing here echoes a
# secret. VAULT_TASKS_URL / INTENTS_URL are ssh:// URLs on the INTERNAL Forgejo SSH service;
# the host key is checked under the fixed alias "forgejo-ssh" (known_hosts in the ConfigMap),
# so the service name can change without touching the pin.
# Exit status is the alert signal: non-zero fails the Job (backoffLimit 0), and the cluster's
# kube-state-metrics rules watch Job outcomes. 78 = configuration error.
set -eu
: "${VAULT_TASKS_URL:?}" "${INTENTS_URL:?}"
W=/work
K=/tmp/keys
rm -rf "$W/vault" "$W/intents" "$K"
umask 077
mkdir -p "$K"
# Copy each key to a file only this user can read, ending in a newline (a mounted Secret is
# group-readable under fsGroup, which ssh refuses, and a stored value can lose its last newline).
for k in vault_tasks_key intents_key; do
  [ -s "/secrets/$k" ] || { echo "{\"service\":\"vikunja-sync\",\"event\":\"config_error\",\"detail\":\"key $k missing\"}"; exit 78; }
  { cat "/secrets/$k"; echo; } | sed '/^$/d' > "$K/$k"
done
export GIT_TERMINAL_PROMPT=0
ssh_for() {
  echo "ssh -F /dev/null -i $K/$1 -o IdentitiesOnly=yes -o BatchMode=yes -o HostKeyAlias=forgejo-ssh" \
       "-o UserKnownHostsFile=/srv/sync/known_hosts -o GlobalKnownHostsFile=/dev/null" \
       "-o StrictHostKeyChecking=yes -o ConnectTimeout=15"
}
GIT_SSH_COMMAND="$(ssh_for vault_tasks_key)" git clone -q --depth 1 "$VAULT_TASKS_URL" "$W/vault"
GIT_SSH_COMMAND="$(ssh_for intents_key)" git clone -q "$INTENTS_URL" "$W/intents"
git -C "$W/intents" config core.sshCommand "$(ssh_for intents_key)"
exec python3 -I /srv/sync/vikunja_sync.py --vault "$W/vault" --intents "$W/intents" \
     --state /state/state.json --config /secrets/config.json
