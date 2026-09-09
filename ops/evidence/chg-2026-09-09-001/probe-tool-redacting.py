#!/usr/bin/env python3
"""Redacting Shelly RPC collector. Strips credential-bearing keys AT CAPTURE."""
import json, subprocess, sys, time

REDACT_KEYS = {"pass","password","psk","sae_psk","x_passphrase","key","secret","token",
               "user","client_secret","apikey","api_key","ssid_pass","wifi_pass"}

def scrub(o):
    if isinstance(o, dict):
        return {k: ("<REDACTED>" if k.lower() in REDACT_KEYS and o[k] not in (None,"",False)
                    else scrub(v)) for k,v in o.items()}
    if isinstance(o, list):
        return [scrub(x) for x in o]
    return o

def rpc(ip, method, body=None, timeout=8):
    cmd = ["curl","-s","--max-time",str(timeout), f"http://{ip}/rpc/{method}"]
    if body is not None:
        cmd = ["curl","-s","--max-time",str(timeout),"-X","POST",
               "-H","Content-Type: application/json",
               "-d", json.dumps(body), f"http://{ip}/rpc/{method}"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return {"_error": f"curl rc={p.returncode} {p.stderr.strip()[:120]}"}
    try:
        return scrub(json.loads(p.stdout))
    except Exception as e:
        return {"_error": f"parse: {e}", "_raw": p.stdout[:200]}

if __name__ == "__main__":
    ips = [f"172.16.4.{n}" for n in range(20,30)]
    methods = ["Shelly.GetDeviceInfo","WiFi.GetConfig","WiFi.GetStatus",
               "Cloud.GetConfig","Cloud.GetStatus","Sys.GetConfig","Sys.GetStatus",
               "MQTT.GetConfig","Ws.GetConfig"]
    if len(sys.argv) > 1:
        methods = sys.argv[1].split(",")
    out = {}
    for ip in ips:
        out[ip] = {m: rpc(ip, m) for m in methods}
        time.sleep(0.15)
    print(json.dumps(out, indent=1))
