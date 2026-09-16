# stat-device-raw.json — REMOVED from history 2026-09-16

This file was the raw `stat/device` response for all 16 UniFi devices, committed
as change evidence on 2026-09-08 in `c9e2d59`. **It contained live device
credentials** and has been removed from this branch's history.

What it held, by field:

```
x_authkey          16/16 devices   device inform authentication keys
syslog_key         16/16 devices
x_vwirekey          6/16 devices
guest_token         7/16 devices
x_inform_authkey    1/16 devices
inform_url          16/16 devices
```

**It was never published.** Verified before removal: the commit existed on zero
remote refs and `raw.githubusercontent.com` returned 404 for the path on both
`main` and the working branch. It never left the Mac mini. Tracked as
`inc-2026-09-15-004`.

Removal was authorised by Sander on 2026-09-16 and performed with
`git filter-branch --index-filter` over `c9e2d59^..HEAD`. All 46 commits were
preserved; only this path was dropped. The rest of the change's evidence —
`01-baseline-and-diagnosis.md`, `02-write-and-readback.txt`,
`03-all-shellys-audit.txt`, `04-recommendations.json`, `wlanconf-redacted.json`
and the `stat-sta-*` captures — is intact and was verified free of credentials.

## Why it happened, and what replaces it

The `ops/evidence/` convention said "attach the artefact, not a description". That
is right, and I implemented it by saving raw API responses verbatim. A raw
`stat/device` response *is* a credential dump. The convention and the repository's
public remote were in direct conflict and nobody had noticed.

**The replacement convention is in `ops/evidence/README.md`.** In short: prove the
negative with a field-level fingerprint rather than by committing the payload.
Themis demonstrated it during `chg-2026-09-15-002` — hash the fields that matter
across every row, show the hash identical before and after, and "nothing else was
mutated" is proven without a single secret entering the repo.
