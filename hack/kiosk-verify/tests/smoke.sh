#!/usr/bin/env bash
# smoke.sh — bootstrap test for kiosk-verify
#
# Test 1 (regression): keuken HA dashboard is rendering in dark mode via --as= path.
# Test 2 (new --service): it-tools via --service tools/it-tools:80, no auth needed.
#
# For Grafana specifically: Grafana uses OAuth SSO (generic_oauth, auth.basic=false),
# so --header "Authorization: Basic ..." does NOT work for the web UI. Use a Grafana
# service account token injected as a Bearer header for API endpoints, or load a page
# that doesn't require auth (e.g. the public /login page).
#
# NOTE on HA URL: the keuken dashboard URL on hass.bluejungle.net is:
#   /dashboard-keuken/keuken
# The tool rewrites this to http://localhost:18123/ via kubectl port-forward.
# The old /lovelace/keuken path redirects to /dashboard-keuken/keuken on HA 2026.5+.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(dirname "$SCRIPT_DIR")"
HA_SCREENSHOT="/tmp/keuken-dark.png"
ITTOOLS_SCREENSHOT="/tmp/it-tools-service.png"

echo "=== kiosk-verify smoke test ==="
echo "Tool dir: $TOOL_DIR"
echo ""

# ---------------------------------------------------------------------------
# Test 1: HA keuken dashboard regression
# ---------------------------------------------------------------------------
echo "--- Test 1: HA keuken dark-mode regression (--as= path) ---"
echo "Screenshot: $HA_SCREENSHOT"
echo ""

uv run --project "$TOOL_DIR" kiosk-verify \
    "https://hass.bluejungle.net/dashboard-keuken/keuken" \
    --as=keuken-kiosk \
    --check-bg=dark \
    --screenshot="$HA_SCREENSHOT"

T1_EXIT=$?

echo ""
if [ $T1_EXIT -eq 0 ]; then
    echo "--- Test 1: PASS ---"
else
    echo "--- Test 1: FAIL (exit $T1_EXIT) ---"
fi

# ---------------------------------------------------------------------------
# Test 2: it-tools via --service port-forward (no auth needed)
# Skip if SKIP_SERVICE env var is set
# ---------------------------------------------------------------------------
SKIP_SERVICE="${SKIP_SERVICE:-}"
T2_EXIT=0

if [ -n "$SKIP_SERVICE" ]; then
    echo ""
    echo "--- Test 2: SKIPPED (SKIP_SERVICE set) ---"
else
    echo ""
    echo "--- Test 2: it-tools via --service tools/it-tools:80 ---"
    echo "Screenshot: $ITTOOLS_SCREENSHOT"
    echo ""

    uv run --project "$TOOL_DIR" kiosk-verify \
        "https://it-tools.bluejungle.net/" \
        --service "tools/it-tools:80" \
        --screenshot="$ITTOOLS_SCREENSHOT" \
        --wait=3000 || T2_EXIT=$?

    echo ""
    if [ $T2_EXIT -eq 0 ]; then
        echo "--- Test 2: PASS ---"
    elif [ $T2_EXIT -eq 1 ]; then
        echo "--- Test 2: FAIL (checks did not pass) ---"
    else
        echo "--- Test 2: ERROR (runtime error, exit $T2_EXIT) ---"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
if [ $T1_EXIT -eq 0 ] && [ $T2_EXIT -eq 0 ]; then
    echo "=== SMOKE TEST: ALL PASS ==="
    exit 0
else
    echo "=== SMOKE TEST: FAIL (T1=$T1_EXIT T2=$T2_EXIT) ==="
    exit 1
fi
