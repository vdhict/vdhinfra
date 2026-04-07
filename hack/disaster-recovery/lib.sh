#!/usr/bin/env bash
# Shared helpers for the disaster recovery scripts.
# Source this file at the top of every script: source "$(dirname "$0")/lib.sh"

set -euo pipefail

# Color output
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()    { echo -e "${BLUE}[DR $(date +%H:%M:%S)]${NC} $*" >&2; }
ok()     { echo -e "${GREEN}[DR $(date +%H:%M:%S)] ✓${NC} $*" >&2; }
warn()   { echo -e "${YELLOW}[DR $(date +%H:%M:%S)] !${NC} $*" >&2; }
err()    { echo -e "${RED}[DR $(date +%H:%M:%S)] ✗${NC} $*" >&2; }
fatal()  { err "$*"; exit 1; }

# Print intent + require y/N confirmation. Skipped if FORCE=1 in env.
confirm() {
  local prompt="${1:-Continue?}"
  if [ "${FORCE:-0}" = "1" ]; then
    warn "FORCE=1 — skipping confirmation: $prompt"
    return 0
  fi
  read -r -p "$(echo -e "${YELLOW}>>>${NC} $prompt [y/N] ")" reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) fatal "Aborted by user" ;;
  esac
}

# Refuse to run against a healthy cluster (a workload still has running pods)
# unless FORCE=1.
require_workload_absent() {
  local ns="$1" sel="$2" what="$3"
  local n
  n=$(kubectl -n "$ns" get pod -l "$sel" -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ] && [ "${FORCE:-0}" != "1" ]; then
    fatal "$what is currently running ($n pod(s) match -n $ns -l $sel). \
This script is destructive and refuses to run against a healthy cluster. \
Set FORCE=1 to override (only do this if you're SURE you want to overwrite the current state)."
  fi
}

# Wait until a kubectl jsonpath query returns the expected value
wait_for() {
  local what="$1" cmd="$2" want="$3" timeout="${4:-300}"
  local start=$(date +%s) now actual
  log "waiting for $what == '$want' (timeout ${timeout}s)..."
  while true; do
    actual=$(eval "$cmd" 2>/dev/null || echo "")
    if [ "$actual" = "$want" ]; then
      ok "$what is '$want'"
      return 0
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      fatal "$what did not become '$want' within ${timeout}s (last value: '$actual')"
    fi
    sleep 5
  done
}

# Verify required tools are on PATH
require_tools() {
  local missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    fatal "missing required tools: ${missing[*]}. Run 'mise install' from the repo root."
  fi
}

# Verify cluster is reachable
require_cluster() {
  if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
    fatal "cannot reach Kubernetes API. Check KUBECONFIG and try 'kubectl get nodes'."
  fi
}

# The 7 apps protected by VolSync, in restore-priority order
VOLSYNC_APPS=(
  "home-automation:zwave-js-ui:config-zwave-js-ui-0"
  "home-automation:zigbee2mqtt:zigbee2mqtt-config"
  "home-automation:home-assistant:home-assistant-config"
  "home-automation:node-red:node-red-config"
  "home-automation:esphome:esphome-config"
  "home-automation:mealie:mealie"
  "media:radarr:radarr-config"
)
