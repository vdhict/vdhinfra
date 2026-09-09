# MQTT broker anonymous-auth posture — Argus's open gap, now CLOSED

Argus could not verify this (macOS Local Network Privacy blocked his probe) and
explicitly did not claim it. I reached it from **inside the cluster** via kubectl exec,
which bypasses the host-level Local Network restriction entirely.

Method: **passive config read, not an active probe.** I deliberately did NOT open an
unauthenticated MQTT CONNECT against the broker — active probing is Pan's remit and
requires its own approval. Reading the broker's own effective configuration is
definitive and needs no probe.

Service: `home-automation/mosquitto`, LoadBalancer **172.16.2.244:1883**.
Pod `mosquitto-74d9cd9cb-n928f`, up since 2026-06-15, **restartCount=0** (so the running
process is using exactly this config — no drift between configmap and running broker).

Effective `mosquitto.conf`:
```
per_listener_settings false
listener 1883
allow_anonymous false            <-- ANSWER
password_file /mosquitto/external_config/mosquitto_pwd
```

`/mosquitto/external_config/mosquitto_pwd` exists, is non-empty, and contains exactly
**one** account: `mosquitto`. (Usernames only were read; no hashes captured.)

## Verdict
**Anonymous MQTT auth is DISABLED and a password file is actually in force.** The
firewall hole `Allow IoT to MQTT broker -> 172.16.2.244:1883/tcp` therefore does not
expose an unauthenticated broker. Argus's worst case does not obtain.

## Residual, lower severity (report only, no change made)
- `/mosquitto/external_config/` is mode **0777** and `mosquitto_pwd` is **0644**
  (world-readable within the pod), alongside plaintext `username` / `password` files
  projected from the ExternalSecret. Impact is confined to anyone with exec into that
  pod, who could read the secret anyway. Worth tightening `defaultMode` on the volume
  at some point; not urgent, and NOT part of this change. Owner: k8s-engineer / ha-engineer.
- The 10 Shellys do NOT use MQTT at all (`MQTT.GetConfig enable=false` on 10/10), so
  they are not consumers of this broker and the IoT->MQTT firewall hole is not used by them.
