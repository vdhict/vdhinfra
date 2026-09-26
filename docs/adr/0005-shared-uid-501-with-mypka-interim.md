# 0005 — Atlas and myPKA share uid 501 on vdhmini01 (interim, until 2026-10-31)

Status: accepted (interim, time-boxed)
Date: 2026-09-26
Decision-makers: user (Sander), recorded by Atlas

## Context

Argus reviewed the myPKA prikbord (chg-2026-09-23-005, qa_failed, finding B1 HIGH). On
vdhmini01, Atlas's session and myPKA's wires both run as uid 501 (`sheijden`). myPKA's own
MELDING mypka-20260923T135426Z-a8fa confirms this. Everything owned by that uid can therefore
be read or changed by either party:

- the prikbord SQLite database (rows can be inserted under any sender, without a token)
- the prikbord admin-hash file
- Atlas's prikbord token (`~/.config/atlas/prikbord.token`)
- this repository, including `CLAUDE.md`, `ops/changes.jsonl` and Atlas's memory directory

What uid 501 cannot forge:

- a root verifier grant (`/usr/local/var/atlas-approval/granted/`)
- Sander's sk signature

## Decision

Sander, 2026-09-26, in session: **accept the risk temporarily, until 2026-10-31.** The real
separation is planned as its own change. Sander asks that it consider **a separate macOS
account for Atlas** rather than for myPKA. Atlas is one session and one repo; myPKA runs more
than twenty wires.

B3 (answered by Sander): the prikbord admin token is held by myPKA. Larry issues tokens in
consultation with Sander.

## Consequences

- R9 may be activated before the separation exists, once the R10 test passes and the rule
  text is adopted. The mandate is then only as strong as "any uid-501 process". It is limited
  to low and medium risk.
- High risk is unaffected in principle, because it rests on the root verifier and Sander's key.
  In practice it is weakened, because the verifier does not enforce user verification
  (B4, see chg-2026-09-23-005).
- On or before 2026-10-31, either the separation is live, or R9 is suspended and Sander
  decides again.
