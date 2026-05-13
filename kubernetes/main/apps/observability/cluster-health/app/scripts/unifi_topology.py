#!/usr/bin/env python3
"""UniFi topology + health adapter for the ops portal renderer.

Pulls a single quiet snapshot from the UniFi integration API (controller info
+ device list + per-device detail for uplinks) and writes it to JSON. Designed
to be hammered NEVER — one run per renderer cycle. The renderer caches.

Read-only. Never POST/PUT/DELETE. Never the legacy /api/... cookie endpoints.
Honours 429 with Retry-After. Bails on 5xx after one retry.

Endpoints used (all under https://172.16.2.1/proxy/network/integration/v1/):
  GET info                                  -> controller version
  GET sites/<sid>/devices?offset=&limit=    -> flat device list (no uplink)
  GET sites/<sid>/devices/<id>              -> per-device, has uplink.deviceId
  GET sites/<sid>/clients (probe only)      -> existence check, output unused

Output schema is documented in docs/design/topology-cmdb-extension.md and the
runbook the renderer consumes.
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

UDM_HOST = "172.16.2.1"
SITE_ID = "88f7af54-98f8-306a-a1c7-c9349722b1f6"
BASE = f"https://{UDM_HOST}/proxy/network/integration/v1"

LOCAL_KEY_PATH = "/Users/sheijden/Code/homelab-migration/config/unifi-api-key"
DEFAULT_OUT_CLUSTER = "/data/unifi-topology.json"

# Be kind to the controller. One request at a time, with a gap.
MIN_GAP_SEC = 1.0
HTTP_TIMEOUT_SEC = 8
MAX_RETRY_AFTER_SEC = 5  # if 429 says wait longer, give up

# Total budget; abort cleanly if we get close. Renderer prefers a partial
# snapshot with errors[] over a stuck adapter.
TOTAL_BUDGET_SEC = 28.0

# Lower-case substring -> CMDB id. First match wins, name checked before model.
# Keep the list narrow on purpose; Apollo handles unknowns.
CMDB_HINTS_BY_NAME: list[tuple[str, str]] = [
    ("udm", "net.udm"),
    ("vdhngfw", "net.udm"),  # router hostname in some installs
]
CMDB_HINTS_BY_MODEL: list[tuple[str, str]] = [
    ("udm pro max", "net.udm"),
    ("udm pro", "net.udm"),
    ("udm-pro-max", "net.udm"),
    ("udm-pro", "net.udm"),
]


# ── helpers ──────────────────────────────────────────────────────────────────

def now_iso_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def log(msg: str) -> None:
    print(f"[unifi_topology] {msg}", file=sys.stderr, flush=True)


def read_api_key() -> str | None:
    """Prefer env var (cluster), fall back to the local config file (laptop)."""
    env = os.environ.get("UNIFI_API_KEY", "").strip()
    if env:
        return env
    p = Path(LOCAL_KEY_PATH)
    if p.exists():
        return p.read_text().strip() or None
    return None


def _ssl_ctx() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


class Client:
    """One quiet HTTP client. Enforces inter-call gap and a total budget."""

    def __init__(self, api_key: str, deadline: float) -> None:
        self._key = api_key
        self._deadline = deadline
        self._last_call = 0.0
        self._ctx = _ssl_ctx()

    def _sleep_gap(self) -> None:
        delta = time.monotonic() - self._last_call
        if delta < MIN_GAP_SEC:
            time.sleep(MIN_GAP_SEC - delta)

    def budget_left(self) -> float:
        return self._deadline - time.monotonic()

    def get(self, path: str) -> Any:
        """GET <BASE><path>. Returns parsed JSON or raises a string-y RuntimeError.

        Single retry on 429 (honouring Retry-After up to MAX_RETRY_AFTER_SEC).
        Single retry on 5xx after a short wait. Anything else: raise.
        """
        if self.budget_left() <= 1.0:
            raise RuntimeError(f"budget exhausted before GET {path}")

        for attempt in (1, 2):
            self._sleep_gap()
            url = f"{BASE}{path}"
            req = urllib.request.Request(
                url,
                headers={"X-API-KEY": self._key, "Accept": "application/json"},
            )
            try:
                with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SEC, context=self._ctx) as r:
                    self._last_call = time.monotonic()
                    body = r.read().decode()
                    try:
                        return json.loads(body)
                    except json.JSONDecodeError as e:
                        raise RuntimeError(f"GET {path}: bad json ({e})") from None
            except urllib.error.HTTPError as e:
                self._last_call = time.monotonic()
                code = e.code
                if code == 429 and attempt == 1:
                    retry_after = 0
                    try:
                        retry_after = int(e.headers.get("Retry-After", "1"))
                    except (TypeError, ValueError):
                        retry_after = 1
                    if retry_after > MAX_RETRY_AFTER_SEC:
                        raise RuntimeError(
                            f"GET {path}: 429 Retry-After={retry_after}s exceeds cap"
                        ) from None
                    log(f"429 on {path}, sleeping {retry_after}s before single retry")
                    time.sleep(max(retry_after, 1))
                    continue
                if 500 <= code < 600 and attempt == 1:
                    log(f"{code} on {path}, brief backoff then single retry")
                    time.sleep(1.5)
                    continue
                raise RuntimeError(f"GET {path}: HTTP {code}") from None
            except urllib.error.URLError as e:
                self._last_call = time.monotonic()
                if attempt == 1:
                    log(f"URLError on {path} ({e.reason}); single retry")
                    time.sleep(1.0)
                    continue
                raise RuntimeError(f"GET {path}: URLError {e.reason}") from None
            except TimeoutError:
                self._last_call = time.monotonic()
                if attempt == 1:
                    log(f"timeout on {path}; single retry")
                    time.sleep(1.0)
                    continue
                raise RuntimeError(f"GET {path}: timeout") from None

        raise RuntimeError(f"GET {path}: exhausted retries")


# ── data shaping ─────────────────────────────────────────────────────────────

def cmdb_hint_for(name: str | None, model: str | None) -> str | None:
    n = (name or "").lower()
    for needle, cmdb_id in CMDB_HINTS_BY_NAME:
        if needle in n:
            return cmdb_id
    m = (model or "").lower()
    for needle, cmdb_id in CMDB_HINTS_BY_MODEL:
        if needle in m:
            return cmdb_id
    return None


def map_state(raw: str | None) -> str:
    """Lowercase the controller's enum. Keep unknowns verbatim so renderer
    can show them; "connected"/"disconnected" are the common ones the
    contract calls out."""
    if not raw:
        return "unknown"
    s = raw.strip().lower()
    # UniFi 10.x exposes ONLINE/OFFLINE/ADOPTING/UPDATING/...
    if s == "online":
        return "connected"
    if s == "offline":
        return "disconnected"
    return s


def map_type(features: Any, interfaces: Any, model: str | None) -> str:
    """Best-effort type bucket. The integration API doesn't expose the old
    `type` field, so we infer from features/interfaces/model."""
    feats = features if isinstance(features, list) else (
        list(features.keys()) if isinstance(features, dict) else []
    )
    feats = [str(f).lower() for f in feats]
    intfs = interfaces if isinstance(interfaces, list) else (
        list(interfaces.keys()) if isinstance(interfaces, dict) else []
    )
    intfs = [str(i).lower() for i in intfs]
    m = (model or "").lower()

    # Check UDM first — UDMs report features:["switching"] too, but the model
    # name disambiguates. Otherwise switches would shadow them.
    if "gateway" in feats or "udm" in m or "dream" in m:
        return "udm"
    if "accesspoint" in feats or "radios" in intfs or (m.startswith("u") and "ap" in m):
        return "uap"
    if "switching" in feats:
        return "usw"
    if "ports" in intfs and "radios" not in intfs:
        return "usw"
    return "unknown"


def device_record(flat: dict, detail: dict | None) -> dict:
    """Build one device entry. `detail` may be None if the per-device GET
    failed; the record still renders, just without uplink fields."""
    name = flat.get("name")
    model = flat.get("model")
    features = (detail or {}).get("features") or flat.get("features")
    interfaces = (detail or {}).get("interfaces") or flat.get("interfaces")

    uplink_id: str | None = None
    if detail:
        up = detail.get("uplink")
        if isinstance(up, dict):
            uplink_id = up.get("deviceId") or up.get("device_id")

    return {
        "id": flat.get("id"),
        "name": name,
        "model": model,
        "type": map_type(features, interfaces, model),
        "ip": flat.get("ipAddress") or flat.get("ip"),
        "mac": (flat.get("macAddress") or flat.get("mac") or "").lower() or None,
        "uplink_device_id": uplink_id,
        # The integration API does not expose the uplink port name for the
        # downstream end of the link in 10.x. Leave null per task contract.
        "uplink_port": None,
        "state": map_state(flat.get("state")),
        # No last_seen field on the integration API device shape. Leave null
        # so the renderer can decide how to display it.
        "last_seen_sec": None,
        "model_cmdb_id_hint": cmdb_hint_for(name, model),
    }


# ── fetch ────────────────────────────────────────────────────────────────────

def fetch_info(client: Client, errors: list[str]) -> dict:
    """Return controller dict per output schema. Errors append, never raise."""
    base = {
        "version": None,
        "firmware": None,
        "uptime_sec": None,
        "reachable": False,
    }
    try:
        j = client.get("/info")
        if isinstance(j, dict):
            base["version"] = j.get("applicationVersion") or j.get("version")
            # Some firmwares expose 'firmwareVersion' or 'osVersion'; map either.
            base["firmware"] = j.get("firmwareVersion") or j.get("osVersion")
            base["reachable"] = True
    except Exception as e:  # noqa: BLE001
        errors.append(f"info: {e}")
    return base


def fetch_device_list(client: Client, errors: list[str]) -> list[dict]:
    """Paginate /devices defensively. 14 devices today; cap at 200 to be safe."""
    out: list[dict] = []
    offset = 0
    page_size = 50
    safety_pages = 10
    for _ in range(safety_pages):
        try:
            j = client.get(
                f"/sites/{SITE_ID}/devices?offset={offset}&limit={page_size}"
            )
        except Exception as e:  # noqa: BLE001
            errors.append(f"devices page offset={offset}: {e}")
            break
        if not isinstance(j, dict):
            errors.append("devices: response not a dict")
            break
        data = j.get("data") or []
        if not isinstance(data, list):
            errors.append("devices: data not a list")
            break
        out.extend(data)
        total = j.get("totalCount")
        if total is None or len(out) >= total or not data:
            break
        offset += page_size
    return out


def fetch_device_detail(client: Client, dev_id: str, errors: list[str]) -> dict | None:
    try:
        j = client.get(f"/sites/{SITE_ID}/devices/{dev_id}")
        if isinstance(j, dict):
            return j
        errors.append(f"devices/{dev_id}: response not a dict")
    except Exception as e:  # noqa: BLE001
        errors.append(f"devices/{dev_id}: {e}")
    return None


def probe_clients_endpoint(client: Client, errors: list[str]) -> None:
    """Best-effort 'does it still exist' check. We do not use the payload in
    this iteration of the output schema, but the design doc anticipates we
    will. Record absence as a soft note in errors[] so the renderer (and
    Apollo) knows."""
    try:
        j = client.get(f"/sites/{SITE_ID}/clients?offset=0&limit=1")
        if not isinstance(j, dict) or "data" not in j:
            errors.append("clients: endpoint present but unexpected shape")
    except Exception as e:  # noqa: BLE001
        # Soft: an absent clients endpoint is acceptable.
        errors.append(f"clients (skipped): {e}")


# ── main ─────────────────────────────────────────────────────────────────────

def build_snapshot() -> dict:
    errors: list[str] = []
    snapshot: dict = {
        "ts": now_iso_utc(),
        "controller": {
            "version": None,
            "firmware": None,
            "uptime_sec": None,
            "reachable": False,
        },
        "devices": [],
        "errors": errors,
    }

    api_key = read_api_key()
    if not api_key:
        errors.append("no api key (UNIFI_API_KEY env unset and local file missing)")
        return snapshot

    deadline = time.monotonic() + TOTAL_BUDGET_SEC
    client = Client(api_key, deadline)

    snapshot["controller"] = fetch_info(client, errors)
    if not snapshot["controller"]["reachable"]:
        # No point hammering further if /info didn't even succeed.
        return snapshot

    raw_devices = fetch_device_list(client, errors)

    # Per-device detail loop, budget-aware.
    devices_out: list[dict] = []
    for flat in raw_devices:
        if client.budget_left() <= 1.5:
            errors.append(
                f"budget cut short device detail loop at {len(devices_out)}/{len(raw_devices)}"
            )
            # Add remaining as flat-only entries (uplink null) so renderer
            # has the full inventory even if it can't draw all edges.
            for remainder in raw_devices[len(devices_out):]:
                devices_out.append(device_record(remainder, None))
            break
        dev_id = flat.get("id")
        detail = fetch_device_detail(client, dev_id, errors) if dev_id else None
        devices_out.append(device_record(flat, detail))

    snapshot["devices"] = devices_out

    # Last (cheapest) thing: probe clients endpoint so the design-doc note in
    # errors[] is accurate even on full-budget runs. Skip if budget is tight.
    if client.budget_left() > 2.0:
        probe_clients_endpoint(client, errors)

    return snapshot


def resolve_out_path(arg_out: str | None) -> Path:
    if arg_out:
        return Path(arg_out)
    return Path(DEFAULT_OUT_CLUSTER)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out",
        default=None,
        help=f"Output JSON path. Defaults to {DEFAULT_OUT_CLUSTER} (cluster mode).",
    )
    args = parser.parse_args()

    out_path = resolve_out_path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    started = time.monotonic()
    try:
        snapshot = build_snapshot()
    except Exception as e:  # noqa: BLE001
        # Should not happen — build_snapshot catches its own — but the
        # renderer must always get a valid file.
        snapshot = {
            "ts": now_iso_utc(),
            "controller": {
                "version": None,
                "firmware": None,
                "uptime_sec": None,
                "reachable": False,
            },
            "devices": [],
            "errors": [f"fatal: {e}"],
        }
    elapsed = time.monotonic() - started
    log(
        f"snapshot: devices={len(snapshot['devices'])} "
        f"errors={len(snapshot['errors'])} "
        f"controller_reachable={snapshot['controller']['reachable']} "
        f"elapsed={elapsed:.1f}s -> {out_path}"
    )

    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(json.dumps(snapshot, indent=2, sort_keys=False))
    tmp.replace(out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
