# ops/evidence — what to commit, and what never to commit

Evidence must be the **artefact**, not a description of it. That rule stands. This
file exists because of how it was implemented: raw API responses were being saved
verbatim into a repository whose remote is **public**, and one of them
(`chg-2026-09-08-001/stat-device-raw.json`) turned out to be a dump of every UniFi
device's authentication keys. See `inc-2026-09-15-004`.

## Never commit

- Raw `stat/device`, `rest/user`, `wlanconf`, `networkconf` or `core.config_entries`
  responses. They carry `x_authkey`, `syslog_key`, `x_vwirekey`, `guest_token`,
  `x_passphrase`, `x_iapp_key`, `private_preshared_keys`, config-entry passwords.
- Anything read out of a Kubernetes `Secret`, 1Password, or a SOPS file.
- Talos machine configs or anything from `clusterconfig/`.
- Full `.storage/*` files from Home Assistant.

## Commit instead

**1. A field-level fingerprint, to prove nothing else changed.** Hash the fields
that matter across every row, before and after, and show the two hashes identical.
This proves "no other row was mutated" without committing any row:

```python
fields = ('_id','key','record_type','value','enabled')          # config fields only
fp = hashlib.sha256(json.dumps(
        [[r.get(f) for f in fields] for r in sorted(rows, key=lambda r: r['_id'])],
        sort_keys=True).encode()).hexdigest()
```

**Exclude volatile fields.** `last_seen`, `uptime`, `last_uplink_mac`,
`last_uplink_name`, `tx_bytes` and friends drift between two reads with no write at
all — include them and you will report normal churn as tampering. That happened on
`chg-2026-09-16-001`; a control of two reads 20 s apart with no write is the way to
find out which fields drift.

**2. The specific rows you touched**, read back and diffed field by field against
what you sent. UniFi silently drops fields; the diff is the point.

**3. Counts and negative controls.** `74 -> 74 unchanged`, `35 -> 36 (+1 exactly)`,
`0 AAAA records`, `console still responding`.

**4. Real command output**, with secrets masked at capture time — not a summary
written afterwards.

## Before committing evidence

```bash
gitleaks git --redact --no-banner -c <default-rules> --log-opts="origin/main..HEAD" .
```

and read the field names of anything you are about to add. A file named
`*-redacted.json` is only redacted if you have checked that it is.
