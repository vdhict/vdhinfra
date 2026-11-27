#!/bin/sh
# ha-zones runner (wq-097 C7, chg-2026-11-23-012) on the vendor image python:3.13.15-bookworm
# (stdlib Python, git, openssh-client; no image build). Mounted from ConfigMap ha-zones-runner
# at /srv/job, next to the pinned forge host key (known_hosts, alias forgejo-ssh).
#
#   run.sh fetch         init container: the two read-only clones into /work. Has the deploy
#                        keys, has NO HA token.
#   run.sh dry           zones_apply dry run (records digest + time in the state file).
#   run.sh apply         dry run, then the live run of that same file (the CronJob default).
#   run.sh rollback-dry  how many zones this job made are still present (would_delete).
#   run.sh rollback      delete exactly those (state-file ids only).
#
# The apply container has the HA token as env and NO deploy key. Nothing here echoes a secret,
# a coordinate or a zone name; zones_apply logs counts only (Argus C4/Z7).
# Exit status is the alert signal: non-zero fails the Job (backoffLimit 0).
# 78 = configuration error, 128 = fetch error, 1 = zones_apply refused or failed.
set -eu
MODE="${1:-apply}"
W=/work
log() { printf '{"service":"ha-zones","event":"%s","detail":"%s"}\n' "$1" "$2"; }

if [ "$MODE" = fetch ]; then
  : "${EXCHANGE_URL:?}" "${SOURCE_URL:?}" "${SOURCE_REF:?}"
  # /tmp here is the init-ONLY RAM volume fetch-tmp (Argus C7 B1); the apply container never mounts it.
  K=/tmp/keys
  umask 077
  mkdir -p "$K"
  # Copy each key to a 0600 file ending in a newline (a mounted Secret is group-readable under
  # fsGroup, which ssh refuses, and a stored value can lose its last newline).
  for k in exchange_key source_key; do
    [ -s "/secrets/$k" ] || { log config_error "key $k missing"; exit 78; }
    { cat "/secrets/$k"; echo; } | sed '/^$/d' > "$K/$k"
  done
  export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  ssh_for() {
    echo "ssh -F /dev/null -i $K/$1 -o IdentitiesOnly=yes -o BatchMode=yes -o HostKeyAlias=forgejo-ssh" \
         "-o UserKnownHostsFile=/srv/job/known_hosts -o GlobalKnownHostsFile=/dev/null" \
         "-o StrictHostKeyChecking=yes -o ConnectTimeout=15"
  }
  # Argus F2: core.symlinks=false on both checkouts, so a symlink committed to either repo is
  # written as a small plain file holding the link text and can never point at a pod file.
  GIT_SSH_COMMAND="$(ssh_for exchange_key)" \
    git -c core.symlinks=false clone -q -c core.symlinks=false --depth 1 --single-branch \
        --branch main --no-tags "$EXCHANGE_URL" "$W/exchange" \
    || { log fetch_error "exchange clone failed"; exit 128; }
  # trip-autopilot at the reviewed commit ONLY; verified after checkout.
  git -c core.symlinks=false init -q "$W/ta"
  git -C "$W/ta" config core.symlinks false
  git -C "$W/ta" remote add origin "$SOURCE_URL"
  export GIT_SSH_COMMAND="$(ssh_for source_key)"
  git -C "$W/ta" fetch -q --depth 1 --no-tags origin "$SOURCE_REF" 2>/dev/null \
    || git -C "$W/ta" fetch -q --no-tags origin '+refs/heads/*:refs/remotes/origin/*' \
    || { log fetch_error "source fetch failed"; exit 128; }
  git -C "$W/ta" -c advice.detachedHead=false checkout -q --detach "$SOURCE_REF" \
    || { log fetch_error "pinned commit not found"; exit 128; }
  [ "$(git -C "$W/ta" rev-parse HEAD)" = "$SOURCE_REF" ] \
    || { log fetch_error "HEAD is not the pinned commit"; exit 128; }
  log fetched "exchange $(git -C "$W/exchange" rev-parse --short=12 HEAD) source $(git -C "$W/ta" rev-parse --short=12 HEAD)"
  exit 0
fi

: "${HA_URL:?}"
# Argus C7 B1: the apply container must never see a deploy key.
if [ -e /tmp/keys ] || [ -e /secrets ]; then log config_error "deploy key path visible in apply container"; exit 78; fi
STATE=/state/state.json
WANTED="$W/exchange/zones/ha-zones-wanted.json"
cd "$W/ta"
# -B: no bytecode (read-only checkout); -E: ignore PYTHON* env; -s: no user site. -m puts the cwd (the pinned checkout) on sys.path.
za() { python3 -B -E -s -m pka_trip_autopilot.zones_apply "$@"; }

case "$MODE" in
  dry|apply)
    # F2: the wanted file must be a regular file, not a link (belt to core.symlinks=false).
    if [ ! -f "$WANTED" ] || [ -L "$WANTED" ]; then log config_error "wanted file missing or not a regular file"; exit 78; fi
    za "$WANTED" --state "$STATE"
    [ "$MODE" = dry ] && exit 0
    exec python3 -B -E -s -m pka_trip_autopilot.zones_apply "$WANTED" --state "$STATE" --no-dry-run ;;
  rollback-dry)
    exec python3 -B -E -s -m pka_trip_autopilot.zones_apply --rollback --state "$STATE" ;;
  rollback)
    exec python3 -B -E -s -m pka_trip_autopilot.zones_apply --rollback --no-dry-run --state "$STATE" ;;
  *)
    log config_error "unknown mode"; exit 78 ;;
esac
