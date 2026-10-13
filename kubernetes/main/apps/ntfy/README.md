# ntfy (self-hosted push, chg-2026-10-13-005)

This is the self-hosted ntfy server. The owner's phone pushes run on it, so they don't depend on the shared ntfy.sh anonymous quota (250 messages/day per public IP).

- **Reachability:** LAN and WireGuard only, through envoy-internal at `ntfy.${SECRET_DOMAIN}`. There is no public path: the tunnel was decommissioned in chg-2026-10-05-020.
- **Topic `alerts`:**
  - write-only: `alertmanager` (in-cluster, Secret `observability/ntfy-alertmanager-token`) and `pka-alert` (the Macs);
  - read-only: `owner-phone` (ntfy Android app, `Authorization: Bearer` custom header).
- **Auth:** `auth-default-access: deny-all`. Users and tokens are provisioned on every start from the SOPS Secret `ntfy-auth` in `ntfy/app/secret.sops.yaml`. **That Secret is the source of truth.**
- **Account API:** closed at Envoy (404 for `/v1/account*`). Run `hack/ntfy/prune-tokens.sh` (dry run) and `--apply` after any rotation; the script header has the rotation steps.
- **No egress at all** (CNP). `upstream-base-url` is unset, so ntfy.sh gets zero calls. If an iOS phone ever needs instant delivery, every message would cost one ntfy.sh poll request from the shared IP, and the CNP would need a `toFQDNs ntfy.sh:443` rule.

## Rate limits are per source IP, not per user (Argus F3)

ntfy keys a "visitor" on the user only when that user has a tier, and we define no tiers. So `visitor-message-daily-limit` (500) and the request bucket apply per source IP:
- **Through Envoy:** the source is the `X-Forwarded-For` address, which is the Cilium-SNATed node IP. LAN senders that land on the same node share one bucket.
- **Alertmanager:** it goes straight to the Service, so it is keyed on its own pod IP.

To get real per-user limits, add tiers (`ntfy tier add` + `ntfy user change-tier`); that is not declarative in v2.30.0.
