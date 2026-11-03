# Argus verdict chg-2026-11-02-012 stage 2 (2026-11-03 ~13:12 local) on docs/design/headscale-stage2-public.md
qa_passed WITH CONDITIONS. Build may start; port forwards stay disabled until B1-B6 + C7 + V0 green.

Blockers:
B1 (before S2) tagOwners empty lists ("tag:agenthost": [] etc.): tags only via CLI-created pre-auth keys (validated).
B2 (before S3) canary grant narrowed: {"src":["tag:canary"],"dst":["tag:agenthost"],"ip":["tcp:22"]}; canary->Studio:22 is a T1 NEGATIVE; Studio/vdhwslin01 positives via T4 from vdhnblin01; canary SA get/update only its own Secret (resourceNames); auth key removed from Secret after first login.
B3 tailnet IP reuse: lost-device runbook removes the hosts entry with/before `nodes delete -i 1`; daily check asserts 100.64.0.1 == id 1 vdhnblin01.
B4 (before S3) CNP: fromEndpoints for the canary on 8443/TCP and 3478/UDP (pod->LB IP is seen as cluster endpoint).
B5 pre-auth key output never in transcript: umask 077; kubectl exec ... -o json > file; ship via ssh 'cat > path' < file; unused key -> preauthkeys expire immediately.
B6 (before S6) prove HeadscaleNodeRegistered alert fires on a real enrolment at S3/S4 and its text has no hskey-.
Conditions:
C7 S1 VolumeSnapshot via kubectl outside Flux paths; never revert 590dfc38; VolSync component within 7 days.
C8 auth register only for an id shown on a device being enrolled now, hostname matching.
C9 if T3 still shows remote= node IP: forward may stay, record probes/CNP split blind, fix within this change.
C10 Cloudflare Job: token stays in external-dns ns as header file, no set -x/argv; logs only record id + proxied=false; short ttlSecondsAfterFinished; record in ops/cmdb.yaml with decommission line.
C11 vdhmini01: owner ssh ForwardAgent no for the Mini; tailscaled without --operator=uid 501; test as 501 `tailscale set --advertise-routes=10.0.0.0/8` must fail.
C12 server nodes --accept-dns=false --accept-routes=false, no --ssh, no exit node; G1 asserts only the single /32 hosts value.
Rulings: Q1 own DERP only (urls fallback one line). Q2 DNS: ipv4 "", ipv6 "none"; G1 asserts placeholders gone. Q3 one-shot Job accepted under C10. Q4 only as narrowed by B2. Q5 accept surface today; 0 API keys at V0 + daily, no API key while forward live; D7; nginx path-allowlist sidecar follow-up within 14 days. Q6 Mini joins as destination only (tag:agenthost) under C11. Q7 node.expiry 180d in commit B; don't expire node 1. Q8 delete stale .249 reservation (S0), keep .249.
Minimum before forward live today: B1-B6, C7, V0 0 API keys, T1 negatives pass, T2 9090 closed + canary relays via headscale DERP, S5 read-back exact, auto-rollback script dry-run once against a forward created enabled=false.
Read-only checks by Argus: policy check of ACL text valid (and B1/B2 variants); live state matches design s1; v0.29.7 latest (2026-10-30), no GH advisories; trivy not run.
