# 0011 — Chase client fence: one work contact without a term (accepted, count 1)

Status: accepted
Date: 2026-11-24
Decision-makers: team via Larry (AGR-120), recorded by Atlas (chg-2026-11-24-002, tsk-2026-11-24-103 C1)
Register entry: `ops/accepted_risks.yaml` ar-021

## Context

The chase round (pka-chase) only sends text to a model after the client fence has loaded: a keyed
(HMAC) list of client terms built from the CRM by `build_client_terms.py`. Since chase 11087df a lone
first name, or a one-word name or alias, only becomes a term from 4 letters; shorter single words gave
too many false hits on ordinary text. Chase 088fb44 makes the builder and the rotator count work
contacts that end up with no term at all (count only, never a name).

On the real CRM that count is 1: one work contact is known only by a 3-letter first name, with no
surname and no alias.

## Decision

Accept that this one contact has no client term. A 3-letter first name on its own identifies the
person only weakly, and adding it as a term would make the fence fire on ordinary words.

No name is recorded here, in the register or in any evidence.

## Consequences

- The builder prints "N work contacts without a term" and the rotator `uncovered_work_contacts=N`.
  The accepted value is 1. Any higher count means a new uncovered contact and needs its own decision.
- The acceptance lapses when the contact gets a surname or alias in the CRM (then it is a term again),
  when the count rises above 1, or at the review date (2027-05-24).
- Not covered: any other gap in the fence. Argus's follow-up card (more synthetic short-name forms in
  the repo tests) is separate and not blocking.
