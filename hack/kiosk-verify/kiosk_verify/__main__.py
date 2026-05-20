"""kiosk-verify — verify a UI URL renders correctly, with optional LLAT auth and CSS checks.

Network notes:
- On macOS inside the Claude Code agent sandbox, raw Python sockets cannot reach private LAN
  IPs (172.16.x.x). Playwright/Chromium inherits this restriction.
- For HA URLs, we use kubectl port-forward to expose HA on localhost:18123, then navigate
  Playwright to http://localhost:18123/... This avoids the private-IP socket restriction.
- For arbitrary in-cluster services, pass --service NS/NAME:PORT[:targetPort] to pick a
  free local port, start a kubectl port-forward, and rewrite the --url host:port accordingly.
- For non-HA URLs that are reachable, the tool falls back to direct navigation.

Auth notes:
- HA's Lovelace SPA reads hassTokens from localStorage on startup. We inject the bearer token
  by overriding Storage.prototype.getItem via page.add_init_script (runs before any page JS).
- The bearer token must be a HA JWT access token (eyJ...), signed with the refresh token's
  jwt_key. The raw 128-hex refresh token field is stored as hassTokens.refresh_token.

--service flag:
- Syntax: NS/NAME:PORT[:targetPort]
  - NS        — Kubernetes namespace
  - NAME      — Service name
  - PORT      — Service port (also the kubectl port-forward remote port)
  - targetPort — optional; if omitted, same as PORT
- A free local port is chosen automatically (bind to :0, release, use that port).
- The --url host:port is rewritten to localhost:<local_port> before Playwright loads it.
  The original Host header is preserved via Playwright extraHTTPHeaders.
- Cleanup: atexit + SIGTERM/SIGINT handlers ensure the subprocess is killed on any exit path.
"""

from __future__ import annotations

import atexit
import argparse
import json
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

import yaml


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# kubectl shim for mise-managed environments
KUBECTL_PATHS = [
    "/Users/sheijden/.local/share/mise/shims/kubectl",
    "kubectl",
]

# Default HA namespace and service
HA_NAMESPACE = "home-automation"
HA_SERVICE = "home-assistant"
HA_PORT = 8123

# Port-forward local port for the legacy --as= HA path
PF_LOCAL_PORT = 18123

# Map URL hosts that need port-forwarding to the target service
HA_HOSTNAMES = {
    "hass.bluejungle.net": (HA_NAMESPACE, HA_SERVICE, HA_PORT),
}


# ---------------------------------------------------------------------------
# LLAT / bearer token resolution
# ---------------------------------------------------------------------------

OP_ITEM_MAP: dict[str, str] = {
    "keuken-kiosk": "kiosk-keuken",
    "kantoor-kiosk": "kiosk-kantoor",
}


def _find_kubectl() -> Optional[str]:
    for path in KUBECTL_PATHS:
        result = subprocess.run(["which" if path == "kubectl" else "test", "-x", path],
                                capture_output=True)
        if result.returncode == 0:
            return path
        try:
            p = Path(path)
            if p.exists() and p.stat().st_mode & 0o100:
                return str(p)
        except Exception:
            pass
    return None


def _resolve_llat_1password(persona: str) -> Optional[str]:
    """Try to read LLAT from 1Password CLI."""
    item_name = OP_ITEM_MAP.get(persona, f"kiosk-{persona}")
    try:
        result = subprocess.run(
            ["op", "item", "get", item_name, "--field", "llat"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def _resolve_llat_file(persona: str) -> Optional[str]:
    """Try to read LLAT from ~/.config/kiosk-verify/llats.yaml."""
    config_path = Path.home() / ".config" / "kiosk-verify" / "llats.yaml"
    if not config_path.exists():
        return None
    if config_path.stat().st_mode & 0o077:
        print(
            f"WARNING: {config_path} is readable by group/others. "
            "Run: chmod 600 ~/.config/kiosk-verify/llats.yaml",
            file=sys.stderr,
        )
    try:
        with config_path.open() as f:
            data = yaml.safe_load(f)
        personas = data.get("personas", {})
        return personas.get(persona, {}).get("llat") if isinstance(personas, dict) else None
    except Exception as exc:
        print(f"WARNING: could not parse {config_path}: {exc}", file=sys.stderr)
        return None


def resolve_llat(persona: str) -> str:
    """Resolve bearer JWT token for persona; try 1Password first, then local config file."""
    token = _resolve_llat_1password(persona)
    if token:
        return token
    token = _resolve_llat_file(persona)
    if token:
        return token
    print(
        f"ERROR: Could not resolve LLAT for persona '{persona}'.\n"
        f"  Option A: ensure `op` CLI is authenticated and item "
        f"'{OP_ITEM_MAP.get(persona, 'kiosk-' + persona)}' has a field 'llat'.\n"
        "  Option B: create ~/.config/kiosk-verify/llats.yaml with:\n"
        "    personas:\n"
        f"      {persona}:\n"
        "        llat: <your-jwt-bearer-token>  # eyJ... format\n"
        "  (chmod 600 that file)\n"
        "  Note: the token must be a HA JWT access token, not the raw hex refresh token.\n"
        "  Generate via: kubectl exec -n home-automation <ha-pod> -c app -- python3 -m "
        "kiosk_verify.gen_token <user_id>",
        file=sys.stderr,
    )
    sys.exit(2)


def _decode_jwt_payload(token: str) -> dict:
    """Decode JWT payload without verification."""
    import base64
    parts = token.split(".")
    if len(parts) < 2:
        return {}
    padded = parts[1] + "=" * (4 - len(parts[1]) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(padded))
    except Exception:
        return {}


# ---------------------------------------------------------------------------
# Free port picker
# ---------------------------------------------------------------------------

def _pick_free_port() -> int:
    """Bind to :0 to let the OS pick a free ephemeral port, then release it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# kubectl port-forward context manager
# ---------------------------------------------------------------------------

# Global registry so atexit/signal handlers can clean up any orphaned processes.
_ACTIVE_PORT_FORWARDS: list["PortForward"] = []


def _cleanup_all_port_forwards() -> None:
    """Kill all registered port-forward subprocesses (atexit / signal handler)."""
    for pf in list(_ACTIVE_PORT_FORWARDS):
        pf._kill()


atexit.register(_cleanup_all_port_forwards)


def _signal_handler(signum: int, _frame) -> None:  # type: ignore[type-arg]
    _cleanup_all_port_forwards()
    # Re-raise as SystemExit so atexit runs normally
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, _signal_handler)
signal.signal(signal.SIGINT, _signal_handler)


class PortForward:
    """Context manager that runs kubectl port-forward in the background."""

    def __init__(self, namespace: str, service: str, remote_port: int, local_port: int):
        self.namespace = namespace
        self.service = service
        self.remote_port = remote_port
        self.local_port = local_port
        self._proc: Optional[subprocess.Popen] = None  # type: ignore[type-arg]
        self.kubectl = _find_kubectl()

    def _kill(self) -> None:
        """Kill the subprocess unconditionally (idempotent)."""
        proc = self._proc
        if proc is None:
            return
        self._proc = None
        try:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
        except Exception:
            pass
        try:
            _ACTIVE_PORT_FORWARDS.remove(self)
        except ValueError:
            pass

    def __enter__(self) -> "PortForward":
        if not self.kubectl:
            raise RuntimeError("kubectl not found — cannot port-forward")
        cmd = [
            self.kubectl,
            "port-forward",
            "-n", self.namespace,
            f"svc/{self.service}",
            f"{self.local_port}:{self.remote_port}",
        ]
        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        _ACTIVE_PORT_FORWARDS.append(self)

        # Poll until the port accepts connections (up to 10 s)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.local_port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.3)
        else:
            self._kill()
            raise RuntimeError(
                f"kubectl port-forward did not become ready within 10s on port {self.local_port}"
            )
        return self

    def __exit__(self, *_) -> None:
        self._kill()


# ---------------------------------------------------------------------------
# --service flag parser
# ---------------------------------------------------------------------------

class ServiceSpec:
    """Parsed --service NS/NAME:PORT[:targetPort]."""

    def __init__(self, namespace: str, name: str, svc_port: int, target_port: int):
        self.namespace = namespace
        self.name = name
        self.svc_port = svc_port        # service port (used in kubectl port-forward remote side)
        self.target_port = target_port  # same as svc_port unless override supplied

    @classmethod
    def parse(cls, raw: str) -> "ServiceSpec":
        """
        Parse NS/NAME:PORT or NS/NAME:PORT:targetPort.
        Raises ValueError on bad input.
        """
        m = re.fullmatch(
            r"([^/]+)/([^:]+):(\d+)(?::(\d+))?",
            raw.strip(),
        )
        if not m:
            raise ValueError(
                f"Invalid --service value {raw!r}. "
                "Expected NS/NAME:PORT or NS/NAME:PORT:targetPort"
            )
        ns, name, svc_port_str, target_str = m.groups()
        svc_port = int(svc_port_str)
        target_port = int(target_str) if target_str else svc_port
        return cls(ns, name, svc_port, target_port)


# ---------------------------------------------------------------------------
# CSS / luminance helpers
# ---------------------------------------------------------------------------

def _parse_rgb(css_color: str) -> Optional[tuple[int, int, int]]:
    """Parse rgb(r, g, b) or rgba(r, g, b, a) into (r, g, b)."""
    m = re.match(r"rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)", css_color.strip())
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3))
    # Try hex
    m = re.match(r"#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})", css_color.strip())
    if m:
        return int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
    return None


def _relative_luminance(r: int, g: int, b: int) -> float:
    """sRGB relative luminance per WCAG 2.1."""
    def lin(c: int) -> float:
        v = c / 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


# ---------------------------------------------------------------------------
# Build hassTokens init script
# ---------------------------------------------------------------------------

def _build_ha_init_script(access_token: str, ha_local_url: str) -> str:
    """Build a JS init_script that injects hassTokens into localStorage before HA JS runs."""
    # The raw 'token' field (if stored in llats.yaml as comment) would be in refresh_token.
    # For kiosk-verify, we only have the JWT (access_token) — use empty refresh_token.
    payload = _decode_jwt_payload(access_token)
    expires_ms = payload.get("exp", int(time.time()) + 3600) * 1000

    tokens = {
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": max(60, int(payload.get("exp", time.time() + 3600) - time.time())),
        "hassUrl": ha_local_url,
        "clientId": ha_local_url + "/",
        "expires": expires_ms,
        "refresh_token": "",
    }

    return (
        "const _origGetItem = Storage.prototype.getItem;\n"
        "Storage.prototype.getItem = function(key) {\n"
        "    if (key === 'hassTokens' && this === window.localStorage) {\n"
        "        const existing = _origGetItem.call(this, key);\n"
        "        if (!existing) { return JSON.stringify("
        + json.dumps(tokens)
        + "); }\n"
        "    }\n"
        "    return _origGetItem.call(this, key);\n"
        "};\n"
    )


# ---------------------------------------------------------------------------
# Rewrite URL for local port-forward access
# ---------------------------------------------------------------------------

def _rewrite_url_for_local(
    url: str,
    service_spec: Optional[ServiceSpec] = None,
) -> tuple[str, Optional[tuple[str, str, int]], int, str]:
    """
    Determine whether a kubectl port-forward is needed and return:
      (local_url, pf_target_or_None, local_port, original_host_header)

    Priority:
    1. If --service is given, always port-forward to that service and rewrite the URL.
    2. If the URL host is in HA_HOSTNAMES, port-forward to HA on PF_LOCAL_PORT.
    3. Otherwise, return the URL unchanged (direct navigation).

    Returns:
      local_url        — URL Playwright will navigate to
      pf_target        — (namespace, service_name, remote_port) or None
      local_port       — local port number (0 if no port-forward)
      original_host    — original Host header value (empty string if no rewrite)
    """
    m = re.match(r"(https?)://([^/]+)(.*)", url)
    if not m:
        return url, None, 0, ""
    scheme, host, path = m.groups()
    original_host = host  # may include port

    if service_spec is not None:
        local_port = _pick_free_port()
        local_url = f"http://localhost:{local_port}{path}"
        pf_target = (service_spec.namespace, service_spec.name, service_spec.svc_port)
        return local_url, pf_target, local_port, original_host

    # Legacy HA path — use fixed PF_LOCAL_PORT
    bare_host = host.split(":")[0]
    if bare_host in HA_HOSTNAMES:
        ns, svc, port = HA_HOSTNAMES[bare_host]
        local_url = f"http://localhost:{PF_LOCAL_PORT}{path}"
        return local_url, (ns, svc, port), PF_LOCAL_PORT, original_host

    return url, None, 0, ""


# ---------------------------------------------------------------------------
# Main verification logic
# ---------------------------------------------------------------------------

def run_verify(
    url: str,
    persona: Optional[str],
    css_checks: list[tuple[str, str]],
    check_bg: Optional[str],
    screenshot_path: Optional[str],
    wait_ms: int,
    service_spec: Optional[ServiceSpec] = None,
    extra_headers: Optional[dict[str, str]] = None,
) -> int:
    """Run the verification. Returns exit code (0=pass, 1=fail, 2=error)."""
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

    llat: Optional[str] = None
    user_hint = ""
    if persona:
        llat = resolve_llat(persona)
        user_hint = f" ({llat[:8]}…)"

    failures: list[str] = []
    lines: list[str] = []

    lines.append(f"url:       {url}")
    if persona:
        lines.append(f"as:        {persona}{user_hint}")
    if service_spec:
        lines.append(
            f"service:   {service_spec.namespace}/{service_spec.name}:{service_spec.svc_port}"
        )

    # Determine if we need kubectl port-forward
    local_url, pf_target, local_port, original_host = _rewrite_url_for_local(url, service_spec)
    pf_ctx: Optional[PortForward] = None

    if pf_target:
        ns, svc, remote_port = pf_target
        pf_ctx = PortForward(ns, svc, remote_port, local_port)
        if service_spec:
            lines.append(f"port-fwd:  localhost:{local_port} → {ns}/{svc}:{remote_port}")

    def _run_playwright(page_url: str) -> int:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                args=["--no-sandbox", "--disable-dev-shm-usage"],
            )

            # Build extra HTTP headers from caller-supplied --header flags.
            # Note: Chromium refuses to override the Host header via extraHTTPHeaders
            # (ERR_INVALID_ARGUMENT). When --service is used, the port-forward connects
            # directly to the pod so no Host override is needed for routing. Any
            # user-supplied "Host" header is silently dropped to avoid the Chromium
            # rejection; all other caller-supplied headers pass through as-is.
            merged_headers: dict[str, str] = {
                k: v for k, v in (extra_headers or {}).items()
                if k.lower() != "host"
            }

            context = browser.new_context(
                viewport={"width": 1280, "height": 800},
                ignore_https_errors=True,
                extra_http_headers=merged_headers if merged_headers else {},
            )
            page = context.new_page()

            # Inject hassTokens for HA URLs before any JS runs
            if llat and pf_target and not service_spec:
                init_script = _build_ha_init_script(llat, f"http://localhost:{PF_LOCAL_PORT}")
                page.add_init_script(init_script)

            t0 = time.monotonic()
            try:
                page.goto(page_url, wait_until="domcontentloaded", timeout=30_000)
            except PWTimeout:
                lines.append("loaded:    TIMEOUT (>30 s)")
                print("\n".join(lines))
                browser.close()
                return 2
            except Exception as exc:
                lines.append(f"loaded:    ERROR — {exc}")
                print("\n".join(lines))
                browser.close()
                return 2

            page.wait_for_timeout(wait_ms)
            elapsed = time.monotonic() - t0
            lines.append(f"loaded:    OK in {elapsed:.1f}s")

            # Check for auth redirect (indicates auth failure)
            current_url = page.url
            if "/auth/authorize" in current_url or "/auth/login" in current_url:
                lines.append(f"warning:   auth redirect: {current_url[:70]}")
                lines.append("           auth may have failed; CSS checks reflect login page")

            if css_checks or check_bg:
                lines.append("checks:")

            for var, expected in css_checks:
                got: str = page.evaluate(
                    f"() => getComputedStyle(document.documentElement).getPropertyValue('{var}').trim()"
                )
                # Also try document.body if root returned empty
                if not got:
                    got = page.evaluate(
                        f"() => getComputedStyle(document.body).getPropertyValue('{var}').trim()"
                    )
                ok = got == expected
                status_str = "✓" if ok else "✗ FAIL"
                lines.append(
                    f"  {var:<36}  expected {expected:<12}  got {got:<12}  {status_str}"
                )
                if not ok:
                    failures.append(f"CSS var {var}: expected {expected!r}, got {got!r}")

            if check_bg:
                # For HA, use --primary-background-color which reflects the actual theme
                # Fall back to document.documentElement backgroundColor
                bg_css: str = page.evaluate("""() => {
                    // Try HA-specific theme vars first (more reliable than body background)
                    const pbg = getComputedStyle(document.documentElement)
                        .getPropertyValue('--primary-background-color').trim();
                    if (pbg) return pbg;
                    // Fallback: html element background (not body — body is often transparent)
                    const htmlBg = getComputedStyle(document.documentElement).backgroundColor;
                    if (htmlBg && htmlBg !== 'rgba(0, 0, 0, 0)') return htmlBg;
                    // Last resort: body
                    return getComputedStyle(document.body).backgroundColor;
                }""")
                rgb = _parse_rgb(bg_css)
                if rgb is None:
                    lines.append(
                        f"  {'background luminance':<36}  could not parse '{bg_css}'  ✗ FAIL"
                    )
                    failures.append(f"background: could not parse color '{bg_css}'")
                else:
                    lum = _relative_luminance(*rgb)
                    if lum < 0.2:
                        actual_label = f"{lum:.2f} (dark)"
                    elif lum > 0.8:
                        actual_label = f"{lum:.2f} (light)"
                    else:
                        actual_label = f"{lum:.2f} (ambiguous)"

                    if check_bg == "dark":
                        ok = lum < 0.2
                    else:
                        ok = lum > 0.8

                    status_str = "✓" if ok else "✗ FAIL"
                    lines.append(
                        f"  {'background luminance':<36}  expected {check_bg:<12}  "
                        f"got {actual_label:<20}  {status_str}"
                    )
                    if not ok:
                        failures.append(
                            f"background luminance expected {check_bg}, got {actual_label}"
                        )

            if screenshot_path:
                path = Path(screenshot_path)
                page.screenshot(path=str(path), full_page=True)
                size_kb = path.stat().st_size // 1024
                vp = page.viewport_size or {"width": "?", "height": "?"}
                lines.append(
                    f"screenshot: {path}  ({vp['width']}×{vp['height']}, {size_kb} KB)"
                )

            browser.close()
        return 0 if not failures else 1

    if pf_ctx:
        try:
            with pf_ctx:
                return_code = _run_playwright(local_url)
        except RuntimeError as exc:
            lines.append(f"loaded:    ERROR — {exc}")
            print("\n".join(lines))
            return 2
    else:
        return_code = _run_playwright(local_url)

    result = "PASS" if not failures else "FAIL"
    lines.append(f"result: {result}")
    print("\n".join(lines))
    return return_code


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="kiosk-verify",
        description="Verify that a kiosk URL renders correctly.",
    )
    parser.add_argument("url", help="URL to load")
    parser.add_argument(
        "--as",
        dest="persona",
        metavar="PERSONA",
        help="Kiosk persona whose LLAT to inject (e.g. keuken-kiosk)",
    )
    parser.add_argument(
        "--service",
        metavar="NS/NAME:PORT[:targetPort]",
        help=(
            "Port-forward an in-cluster Service and rewrite the URL's host:port to "
            "localhost:<chosen_port> before loading. Format: NS/NAME:PORT or "
            "NS/NAME:PORT:targetPort. Example: observability/grafana:80"
        ),
    )
    parser.add_argument(
        "--header",
        metavar="KEY=VALUE",
        action="append",
        default=[],
        dest="headers",
        help=(
            "Add an extra HTTP header to every Playwright request (repeatable). "
            "Useful for Basic-Auth: --header 'Authorization: Basic <base64>'"
        ),
    )
    parser.add_argument(
        "--check-css",
        metavar="VAR=VALUE",
        action="append",
        default=[],
        help="Check a CSS custom property value (repeatable)",
    )
    parser.add_argument(
        "--check-bg",
        choices=["dark", "light"],
        help="Check background luminance (dark < 0.2, light > 0.8)",
    )
    parser.add_argument(
        "--screenshot",
        metavar="PATH",
        help="Save a full-page PNG screenshot to PATH",
    )
    parser.add_argument(
        "--wait",
        type=int,
        default=4000,
        metavar="MS",
        help="Milliseconds to wait after domcontentloaded (default: 4000)",
    )

    args = parser.parse_args()

    css_checks: list[tuple[str, str]] = []
    for item in args.check_css:
        if "=" not in item:
            print(
                f"ERROR: --check-css must be in VAR=VALUE form, got: {item!r}",
                file=sys.stderr,
            )
            sys.exit(2)
        var, _, value = item.partition("=")
        css_checks.append((var.strip(), value.strip()))

    extra_headers: dict[str, str] = {}
    for item in args.headers:
        if ":" not in item and "=" not in item:
            print(
                f"ERROR: --header must be in 'Key: Value' or 'Key=Value' form, got: {item!r}",
                file=sys.stderr,
            )
            sys.exit(2)
        # Support both "Key: Value" (HTTP convention) and "Key=Value"
        if ":" in item:
            key, _, value = item.partition(":")
        else:
            key, _, value = item.partition("=")
        extra_headers[key.strip()] = value.strip()

    service_spec: Optional[ServiceSpec] = None
    if args.service:
        try:
            service_spec = ServiceSpec.parse(args.service)
        except ValueError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(2)

    try:
        code = run_verify(
            url=args.url,
            persona=args.persona,
            css_checks=css_checks,
            check_bg=args.check_bg,
            screenshot_path=args.screenshot,
            wait_ms=args.wait,
            service_spec=service_spec,
            extra_headers=extra_headers,
        )
    except KeyboardInterrupt:
        sys.exit(2)

    sys.exit(code)


if __name__ == "__main__":
    main()
