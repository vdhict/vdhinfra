# Screenshot redaction — chg-2026-09-16-003

`tablet-after-browser-restart.png` (the original, unredacted 2560x1600 capture) is
**deliberately not in git**. This repository is public
(`github.com/vdhict/vdhinfra`, `"visibility": "public"`).

The keuken dashboard renders, in the same frame as the evidence:

- the first names of two children in the household,
- their per-day school timetables,
- their individual bedroom temperature and humidity readings.

That is personal data about private individuals and does not belong in a public
repository, regardless of the change it evidences.

`tablet-after-browser-restart.REDACTED.png` is committed in its place. It preserves
the evidentiary content — the rendered wall clock reading `Woensdag 16 september ·
23:40`, which is what makes the artefact self-authenticating, and the fact that the
dashboard rendered at all after the browser restart — with the two personal-data
regions blacked out.

The unredacted original is kept outside the repo at
`~/.local/evidence-private/chg-2026-09-16-003/`.

**Note on the camera cards.** The three picture-entity cards (Achtertuin, Voorkant,
Voordeur) are blank in this capture — they did not render. Had they rendered, this
screenshot would have carried live interior/exterior imagery of the house and could
not have been published even redacted. Treat any future dashboard screenshot as
personal data by default and check it before staging.

Convention: see `ops/evidence/README.md`.
