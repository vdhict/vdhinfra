#!/usr/bin/env python3
"""jellyfin-bootstrap (chg-2026-10-25-006): configure Jellyfin through its API.

Idempotent. Every step reads the current state first and only writes what
differs, so a re-run adds no duplicate tuner or listing provider.

  a. startup wizard (only while it is not complete)
  b. AuthenticateByName -> session token
  c. M3U tuner host = Dispatcharr's in-cluster /output/m3u: TunerCount 1,
     stream sharing on, AllowHWTranscoding
  d. XMLTV listing provider = Dispatcharr's in-cluster /output/epg
  e. hardware acceleration: QSV (or HWACCEL=vaapi) on /dev/dri/renderD128
  f. (idempotency is part of every step)
  g. network: remote access off, RFC1918 LAN subnets

LOGGING RULE: this script prints ONLY step names, HTTP status codes, counts
and booleans. It never prints a URL, a username, a password, a token or a
response body. Exceptions are reported by class name only, because Python
exception messages can contain the URL (e.g. "unknown url type: ...").

Jellyfin never talks to the IPTV provider: Dispatcharr (namespace
dispatcharr) is the only client of the provider, and Jellyfin reads
Dispatcharr's M3U and XMLTV outputs. Neither URL carries a credential.
Jellyfin does NOT read url-tvg from an M3U header, so the guide is a separate
listing provider.

Inputs (environment): JELLYFIN_ADMIN_USER, JELLYFIN_ADMIN_PASS (Secret
jellyfin-admin); TUNER_M3U_URL, GUIDE_XMLTV_URL (plain, in the Job spec).
Optional: JELLYFIN_URL, HWACCEL (qsv | vaapi), RENDER_DEVICE
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("JELLYFIN_URL", "http://jellyfin.jellyfin.svc.cluster.local:8096").rstrip("/")
HWACCEL = os.environ.get("HWACCEL", "qsv").strip().lower()
RENDER_DEVICE = os.environ.get("RENDER_DEVICE", "/dev/dri/renderD128")

# Our tuner is recognised by this FriendlyName; tuners added by hand under
# another name are never touched.
TUNER_NAME = "Dispatcharr"
LAN_SUBNETS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
# Tiger Lake (Gen12) decode capabilities.
HW_DECODE_CODECS = ["h264", "hevc", "mpeg2video", "vc1", "vp8", "vp9", "av1"]
AUTH_HEADER_BASE = 'MediaBrowser Client="jellyfin-bootstrap", Device="k8s-job", DeviceId="jellyfin-bootstrap-job", Version="1"'


class StepError(Exception):
    """A step failed. The message is a step name, never a value."""


def log(step, **fields):
    allowed = []
    for key, value in fields.items():
        if isinstance(value, bool) or isinstance(value, int) or value is None:
            allowed.append(f"{key}={value}")
        elif isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,40}", value):
            # short enum-like strings only (e.g. "added", "qsv")
            allowed.append(f"{key}={value}")
        else:
            allowed.append(f"{key}=<redacted>")
    print(f"[jellyfin-bootstrap] {step} " + " ".join(allowed), flush=True)


def env(name):
    value = os.environ.get(name, "")
    if not value:
        raise StepError(f"missing-env-{name}")
    return value


def api(method, path, body=None, token=None, query=None, timeout=60):
    """Call the Jellyfin API. Returns (status, parsed JSON or None)."""
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    auth = AUTH_HEADER_BASE + (f', Token="{token}"' if token else "")
    headers = {"Authorization": auth, "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as err:
        return err.code, None
    except Exception as err:  # noqa: BLE001 - class name only, see LOGGING RULE
        raise StepError(f"api-{type(err).__name__}") from None
    if not raw:
        return status, None
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, None


def fetch_head(url, limit, timeout=60):
    """GET an external URL, read at most `limit` bytes. Returns (status, bytes)."""
    request = urllib.request.Request(url, headers={"User-Agent": "Jellyfin-Bootstrap/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(limit)
    except urllib.error.HTTPError as err:
        return err.code, b""
    except Exception as err:  # noqa: BLE001
        log("fetch", ok=False, error=type(err).__name__)
        return 0, b""


def wait_for_jellyfin():
    deadline = time.time() + 900
    last = 0
    while time.time() < deadline:
        try:
            last, info = api("GET", "/System/Info/Public", timeout=10)
            if last == 200 and isinstance(info, dict):
                log("wait", status=last, ready=True)
                return info
        except StepError:
            last = 0
        time.sleep(10)
    log("wait", status=last, ready=False)
    raise StepError("wait")


def authenticate(user, password):
    status, data = api("POST", "/Users/AuthenticateByName", {"Username": user, "Pw": password})
    token = (data or {}).get("AccessToken") if isinstance(data, dict) else None
    is_admin = bool(((data or {}).get("User") or {}).get("Policy", {}).get("IsAdministrator")) if isinstance(data, dict) else False
    log("b.authenticate", status=status, token=bool(token), is_admin=is_admin)
    if status != 200 or not token or not is_admin:
        raise StepError("b.authenticate")
    return token


def step_wizard(info, user, password):
    if info.get("StartupWizardCompleted") is True:
        log("a.wizard", completed=True, skipped=True)
        return
    log("a.wizard", completed=False, skipped=False)
    # GET /Startup/User initialises the first user (StartupController).
    status, _ = api("GET", "/Startup/User")
    log("a.startup-user-init", status=status)
    if status != 200:
        raise StepError("a.startup-user-init")
    status, _ = api("POST", "/Startup/Configuration", {
        "ServerName": "jellyfin",
        "UICulture": "nl",
        "MetadataCountryCode": "NL",
        "PreferredMetadataLanguage": "nl",
    })
    log("a.startup-configuration", status=status)
    if status not in (200, 204):
        raise StepError("a.startup-configuration")
    status, _ = api("POST", "/Startup/User", {"Name": user, "Password": password})
    log("a.startup-user", status=status)
    if status == 403:
        # A previous run set the password but died before /Startup/Complete.
        # Only continue if OUR credentials own that user.
        authenticate(user, password)
        log("a.startup-user", resumed=True)
    elif status not in (200, 204):
        raise StepError("a.startup-user")
    status, _ = api("POST", "/Startup/Complete")
    log("a.startup-complete", status=status)
    if status not in (200, 204):
        raise StepError("a.startup-complete")
    status, info = api("GET", "/System/Info/Public")
    done = isinstance(info, dict) and info.get("StartupWizardCompleted") is True
    log("a.wizard-readback", status=status, completed=done)
    if not done:
        raise StepError("a.wizard-readback")


def get_named(token, key):
    status, data = api("GET", f"/System/Configuration/{key}", token=token)
    if status != 200 or not isinstance(data, dict):
        log(f"read-{key}", status=status)
        raise StepError(f"read-{key}")
    return data


def post_named(token, key, data, step):
    status, _ = api("POST", f"/System/Configuration/{key}", data, token=token)
    log(step, status=status)
    if status not in (200, 204):
        raise StepError(step)


def step_tuner(token, m3u_url):
    status, head = fetch_head(m3u_url, 64)
    log("c.m3u-probe", status=status, extm3u=head.upper().startswith(b"#EXTM3U"))
    if status != 200:
        raise StepError("c.m3u-probe")
    livetv = get_named(token, "livetv")
    ours = [t for t in (livetv.get("TunerHosts") or [])
            if str(t.get("Type", "")).lower() == "m3u" and t.get("FriendlyName") == TUNER_NAME]
    log("c.tuner-existing", count=len(ours))
    desired = {
        "Type": "m3u",
        "Url": m3u_url,
        "FriendlyName": TUNER_NAME,
        # ONE simultaneous stream. M3UTunerHost.GetChannelStream
        # throws LiveTvConflictException once the open live streams on this
        # tuner host reach TunerCount. TunerCount > 0 also turns off client
        # direct play, so every viewer goes through Jellyfin.
        "TunerCount": 1,
        "AllowHWTranscoding": True,
        # Same channel twice shares the one Dispatcharr stream.
        "AllowStreamSharing": True,
        "ImportFavoritesOnly": False,
        "EnableStreamLooping": False,
        "IgnoreDts": True,
        "ReadAtNativeFramerate": False,
    }
    keys = [k for k in desired if k != "Type"]
    if ours:
        current = ours[0]
        same = all(current.get(k) == desired[k] for k in keys)
        if same:
            log("c.tuner", action="unchanged", count=1)
        else:
            body = dict(current)
            body.update(desired)
            status, _ = api("POST", "/LiveTv/TunerHosts", body, token=token, timeout=180)
            log("c.tuner", action="updated", status=status)
            if status != 200:
                raise StepError("c.tuner")
        for extra in ours[1:]:
            status, _ = api("DELETE", "/LiveTv/TunerHosts", token=token, query={"id": extra.get("Id", "")})
            log("c.tuner-duplicate-removed", status=status)
    else:
        # SaveTunerHost validates by fetching the playlist, so 200 means the
        # M3U was reachable and parsed.
        status, _ = api("POST", "/LiveTv/TunerHosts", desired, token=token, timeout=180)
        log("c.tuner", action="added", status=status)
        if status != 200:
            raise StepError("c.tuner")
    livetv = get_named(token, "livetv")
    ours = [t for t in (livetv.get("TunerHosts") or [])
            if str(t.get("Type", "")).lower() == "m3u" and t.get("FriendlyName") == TUNER_NAME]
    ok = len(ours) == 1 and ours[0].get("TunerCount") == 1 and ours[0].get("Url") == m3u_url
    log("c.tuner-readback", count=len(ours), tuner_count_1=bool(ours and ours[0].get("TunerCount") == 1),
        url_matches=bool(ours and ours[0].get("Url") == m3u_url), allow_hw=bool(ours and ours[0].get("AllowHWTranscoding")))
    if not ok:
        raise StepError("c.tuner-readback")


def step_listing(token, guide_url):
    # Informational probe only: before channels are picked in Dispatcharr
    # its guide is (nearly) empty, which is still a valid answer.
    status, head = fetch_head(guide_url, 4096)
    log("d.guide-probe", status=status, bytes=len(head))
    if status != 200:
        raise StepError("d.guide-probe")

    def ours_of(cfg):
        return [p for p in (cfg.get("ListingProviders") or [])
                if str(p.get("Type", "")).lower() == "xmltv" and p.get("Path") == guide_url]

    livetv = get_named(token, "livetv")
    ours = ours_of(livetv)
    log("d.listing-existing", count=len(ours))
    desired = {"Type": "xmltv", "Path": guide_url, "EnableAllTuners": True}
    if ours and all(ours[0].get(k) == v for k, v in desired.items()):
        log("d.listing", action="unchanged")
    else:
        body = dict(ours[0]) if ours else {"EnabledTuners": []}
        body.update(desired)
        # SaveListingProvider also queues RefreshGuide.
        status, _ = api("POST", "/LiveTv/ListingProviders", body, token=token,
                        query={"validateListings": "true", "validateLogin": "false"}, timeout=300)
        log("d.listing", action="updated" if ours else "added", status=status)
        if status != 200:
            raise StepError("d.listing")
    for extra in ours[1:]:
        status, _ = api("DELETE", "/LiveTv/ListingProviders", token=token, query={"id": extra.get("Id", "")})
        log("d.listing-duplicate-removed", status=status)
    ours = ours_of(get_named(token, "livetv"))
    log("d.listing-readback", count=len(ours))
    if len(ours) != 1:
        raise StepError("d.listing-readback")


def step_encoding(token):
    if HWACCEL not in ("qsv", "vaapi"):
        raise StepError("e.hwaccel-value")
    enc = get_named(token, "encoding")
    desired = {
        "HardwareAccelerationType": HWACCEL,
        "VaapiDevice": RENDER_DEVICE,
        "QsvDevice": RENDER_DEVICE,
        "EnableHardwareEncoding": True,
        "HardwareDecodingCodecs": HW_DECODE_CODECS,
        "EnableDecodingColorDepth10Hevc": True,
        "EnableDecodingColorDepth10Vp9": True,
    }

    def norm(value):
        return value.lower() if isinstance(value, str) else value

    same = all(norm(enc.get(k)) == norm(v) if not isinstance(v, list) else sorted(enc.get(k) or []) == sorted(v)
               for k, v in desired.items())
    if same:
        log("e.encoding", action="unchanged", hwaccel=HWACCEL)
    else:
        enc.update(desired)
        post_named(token, "encoding", enc, "e.encoding")
    enc = get_named(token, "encoding")
    ok = norm(enc.get("HardwareAccelerationType")) == HWACCEL and enc.get("QsvDevice") == RENDER_DEVICE \
        and enc.get("VaapiDevice") == RENDER_DEVICE and enc.get("EnableHardwareEncoding") is True
    log("e.encoding-readback", hwaccel=str(norm(enc.get("HardwareAccelerationType"))), ok=ok)
    if not ok:
        raise StepError("e.encoding-readback")


def step_network(token):
    net = get_named(token, "network")
    subnets = list(net.get("LocalNetworkSubnets") or [])
    merged = subnets + [s for s in LAN_SUBNETS if s not in subnets]
    changed = net.get("EnableRemoteAccess") is not False or merged != subnets or net.get("EnableUPnP") is not False
    if changed:
        net["EnableRemoteAccess"] = False
        net["EnableUPnP"] = False
        net["LocalNetworkSubnets"] = merged
        post_named(token, "network", net, "g.network")
    else:
        log("g.network", action="unchanged")
    net = get_named(token, "network")
    ok = net.get("EnableRemoteAccess") is False and all(s in (net.get("LocalNetworkSubnets") or []) for s in LAN_SUBNETS)
    log("g.network-readback", remote_access=net.get("EnableRemoteAccess"), lan_subnets=len(net.get("LocalNetworkSubnets") or []), ok=ok)
    if not ok:
        raise StepError("g.network-readback")
    # This pod (10.42.0.0/16) must still be served as LAN with remote access
    # off. Envoy-internal's pods are in the same pod CIDR, so this is the
    # path every LAN and WireGuard client takes.
    time.sleep(5)
    status, _ = api("GET", "/System/Info", token=token)
    log("g.lan-still-allowed", status=status, ok=status == 200)
    if status != 200:
        raise StepError("g.lan-still-allowed")


def main():
    user = env("JELLYFIN_ADMIN_USER")
    password = env("JELLYFIN_ADMIN_PASS")
    m3u_url = env("TUNER_M3U_URL")
    guide_url = env("GUIDE_XMLTV_URL")
    log("inputs", admin_user=True, admin_pass_len=len(password))
    info = wait_for_jellyfin()
    step_wizard(info, user, password)
    token = authenticate(user, password)
    step_tuner(token, m3u_url)
    step_listing(token, guide_url)
    step_encoding(token)
    step_network(token)
    log("done", ok=True, hwaccel=HWACCEL)


if __name__ == "__main__":
    try:
        main()
    except StepError as err:
        log("FAILED", failed_step=str(err)[:40])
        sys.exit(1)
    except BaseException as err:  # noqa: BLE001 - class name only, no message, no traceback
        log("FAILED", error=type(err).__name__)
        sys.exit(1)
