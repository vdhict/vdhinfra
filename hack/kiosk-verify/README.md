# kiosk-verify

A small CLI that loads a URL in a headless Chromium browser and verifies:
- The page loaded successfully
- CSS custom property values match expected values
- The background luminance matches a dark/light expectation
- Optionally saves a full-page PNG screenshot

Used by Atlas/Hestia/Iris/Heph as the **final verification step** before reporting any UI-visible change as "done".

---

## Install

### Prerequisites

- Python 3.11+ (managed by mise)
- `uv` (managed by mise or Homebrew)

### One-time setup

```bash
# From repo root:
cd hack/kiosk-verify

# Install dependencies and Playwright's Chromium browser
uv sync
uv run playwright install chromium
```

Verify the install:

```bash
uv run kiosk-verify --help
```

---

## Usage

```
kiosk-verify <url> [--as=<persona>] [--service=NS/NAME:PORT] [--header=KEY:VALUE] [--check-css=<var=value>] [--check-bg=<dark|light>] [--screenshot=<path>] [--wait=<ms>]
```

### Arguments

| Flag | Description |
|---|---|
| `<url>` | Required. URL to load (any internal URL). |
| `--as=<persona>` | Optional. Inject a LLAT for this kiosk persona. See personas below. Automatically port-forwards HA if the URL host is `hass.bluejungle.net`. |
| `--service=NS/NAME:PORT[:targetPort]` | Optional. Port-forward any in-cluster Service and rewrite the URL host:port to `localhost:<chosen>`. Format: `observability/grafana:80`. The original `Host` header is preserved so reverse proxies route correctly. Picks a free ephemeral port automatically. |
| `--header=KEY:VALUE` | Optional, repeatable. Add an extra HTTP header to every Playwright request. Useful for Basic-Auth: `--header 'Authorization: Basic <base64>'`. |
| `--check-css=VAR=VALUE` | Optional, repeatable. Reads `getComputedStyle(document.documentElement).getPropertyValue(VAR)` and asserts it equals VALUE. |
| `--check-bg=dark\|light` | Optional. Reads `getComputedStyle(document.body).backgroundColor`, computes luminance. `dark` requires luminance < 0.2; `light` requires > 0.8. |
| `--screenshot=<path>` | Optional. Save a full-page PNG at this path. |
| `--wait=<ms>` | Optional, default 4000. Milliseconds to wait after `domcontentloaded` before sampling (allows JS app hydration). |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | All checks passed (or no checks specified — just loaded + screenshotted) |
| 1 | One or more checks failed (value mismatch) |
| 2 | Runtime error (LLAT not found, page failed to load, etc.) |

### Example

```bash
# Check keuken dashboard is dark + save screenshot (--as= path, auto port-forwards HA)
uv run kiosk-verify \
    https://hass.bluejungle.net/dashboard-keuken/keuken \
    --as=keuken-kiosk \
    --check-bg=dark \
    --screenshot=/tmp/keuken.png

# Also check specific CSS variable (HA uses --primary-background-color, not --md-sys-color-surface)
uv run kiosk-verify \
    https://hass.bluejungle.net/dashboard-keuken/keuken \
    --as=keuken-kiosk \
    --check-css=--primary-background-color=#1c1c1c \
    --check-bg=dark \
    --screenshot=/tmp/keuken.png

# Load it-tools via --service (no auth — demonstrates port-forward + URL-rewrite)
uv run kiosk-verify \
    https://it-tools.bluejungle.net/ \
    --service tools/it-tools:80 \
    --screenshot=/tmp/it-tools.png \
    --wait=3000

# Load any service with Bearer auth (e.g. Grafana service account token via /render/ API)
# Note: Grafana uses OAuth SSO (auth.basic=false) — Basic-Auth does NOT work for the web UI.
# Use a Grafana service account token for API/render endpoints instead:
#   TOKEN=$(kubectl -n observability exec deploy/grafana -- \
#       curl -s -X POST http://localhost:3000/api/serviceaccounts ... | jq -r '.tokens[0].key')
uv run kiosk-verify \
    https://grafana.bluejungle.net/render/d-solo/energy-pv-v1 \
    --service observability/grafana:80 \
    --header "Authorization: Bearer ${TOKEN}" \
    --screenshot=/tmp/grafana-render.png \
    --wait=5000
```

### How `--service` works

1. Parses `NS/NAME:PORT` to identify the target Service and port.
2. Picks a free local port by binding to `:0` (OS picks, then releases it).
3. Starts `kubectl -n NS port-forward svc/NAME LOCAL:PORT` as a background subprocess.
4. Polls `localhost:LOCAL` with a TCP connect attempt (max 10 s) — no blind sleep.
5. Rewrites the `--url` host:port to `localhost:LOCAL`; injects the original host as a
   `Host` header so virtual-hosting / reverse proxies work correctly.
6. Runs Playwright against `http://localhost:LOCAL/...`.
7. On any exit path (success, failure, `Ctrl-C`, `SIGTERM`), the port-forward subprocess
   is killed via `atexit` + signal handlers. No orphaned processes.

### HA dashboard URL format

HA 2026.5+ uses `/dashboard-<slug>/<view>` for custom dashboards, not `/lovelace/<slug>`.
The keuken dashboard URL is `/dashboard-keuken/keuken`, not `/lovelace/keuken`.

| Dashboard | URL |
|---|---|
| Keuken | `https://hass.bluejungle.net/dashboard-keuken/keuken` |
| Ruimtes | `https://hass.bluejungle.net/dashboard-ruimtes/...` |
| TSV | `https://hass.bluejungle.net/dashboard-tsv/...` |

### Example output (PASS — dark mode confirmed)

```
url:       https://hass.bluejungle.net/dashboard-keuken/keuken
as:        keuken-kiosk (eyJhbGci…)
loaded:    OK in 4.2s
checks:
  background luminance                  expected dark          got 0.04 (dark)               ✓
screenshot: /tmp/keuken.png  (1280×800, 87 KB)
result: PASS
```

### Example output (FAIL — still light)

```
url:       https://hass.bluejungle.net/dashboard-keuken/keuken
as:        keuken-kiosk (eyJhbGci…)
loaded:    OK in 4.1s
checks:
  background luminance                  expected dark          got 0.96 (light)              ✗ FAIL
screenshot: /tmp/keuken.png  (1280×800, 486 KB)
result: FAIL
```

---

## LLAT storage

The tool resolves LLATs using two methods, tried in order:

### Option A: 1Password CLI (`op`) — preferred

Store a 1Password item with:
- **Item name**: `kiosk-<persona>` (e.g. `kiosk-keuken` for `keuken-kiosk`)
- **Field name**: `llat`
- **Value**: the long-lived access token

The tool calls `op item get kiosk-<persona> --field llat`. If `op` is unauthenticated or the item does not exist, it falls back to Option B.

### Option B: Local config file — fallback

Create `~/.config/kiosk-verify/llats.yaml` with mode 0600:

```yaml
personas:
  keuken-kiosk:
    llat: <your-llat-token>
  kantoor-kiosk:
    llat: <your-llat-token>
```

```bash
mkdir -p ~/.config/kiosk-verify
chmod 700 ~/.config/kiosk-verify
# create/edit llats.yaml
chmod 600 ~/.config/kiosk-verify/llats.yaml
```

The tool warns if the file has loose permissions (group/world readable).

### Why this design

1Password is preferred because the token never touches the filesystem. The local file fallback ensures the tool works on machines without an `op` session (e.g. during CI-like flows on the Mac mini when the desktop is locked). Never commit `llats.yaml` to git — it is listed in `.gitignore`.

---

## Personas

| Persona name | Device | HA user |
|---|---|---|
| `keuken-kiosk` | Pixel Tablet in kitchen (172.16.3.17) | Keuken Dashboard (`7773346390a44410abfdbc39bcbb1ffb`) |
| `kantoor-kiosk` | ThinkSmartView in office (172.16.3.100, currently off) | Kantoor Dashboard (`407a220828364af9bf264760424f3a40`) |

---

## Running the bootstrap / smoke test

```bash
tests/smoke.sh
```

The smoke test runs two checks:

- **Test 1** (regression): keuken HA dashboard is dark — confirms the existing `--as=` path still works.
- **Test 2** (`--service`): `it-tools` via `--service tools/it-tools:80` (no auth required) —
  confirms the port-forward + URL-rewrite mechanism works end-to-end. Set `SKIP_SERVICE=1`
  to skip Test 2 explicitly.

```bash
# Run only Test 1 (HA regression):
SKIP_SERVICE=1 tests/smoke.sh

# Run both tests:
tests/smoke.sh
```

Both tests exit 0 on PASS, 1 on FAIL, 2 on runtime error.

**Note on Grafana auth:** Grafana in this cluster uses OAuth SSO (`[auth.basic] enabled = false`).
The `--header "Authorization: Basic ..."` pattern does NOT work for Grafana's web UI because all
`/d/*` paths redirect to OAuth login. To browser-test Grafana dashboards, use either:
1. A Grafana service account Bearer token with the `/render/` API.
2. A full OAuth session (Playwright browser login flow — outside scope of this tool).

---

## Network architecture

On the Mac Mini agent host, raw Python sockets and Chromium cannot reach private LAN IPs
(172.16.x.x) due to the macOS network sandbox around the Claude Code process. System `curl`
is exempt from this restriction.

To work around this, `kiosk-verify` uses `kubectl port-forward` to expose HA on
`localhost:18123` before launching Playwright. Chromium can reach localhost freely.

This means:
- `kubectl` must be available (via mise shims or `$PATH`)
- Your kubeconfig must be configured and the HA pod running
- The tool automatically starts and stops the port-forward for each run

For non-HA URLs that are directly reachable from the host, no port-forward is used.

## .gitignore

Screenshots (`*.png`) and the local LLAT config (`llats.yaml`) are excluded from git via the root `.gitignore`.
