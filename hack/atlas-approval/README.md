# Signed approvals for Atlas — the verifier side

Atlas accepts a high-risk approval only from the user actor. Until now that meant
Sander typing into Atlas's session. On 2026-09-15 a prompt-suggestion line in that
session offered `Approved, add the two records` — the exact consent Atlas was
waiting for, on the exact change — seven times across the day, each time
proposing whatever action had just been discussed. **Typed text in that box proves
nothing about who typed it.** A signature from a key that only works after Touch ID
does.

myPKA (Mack) designed the scheme and built the Mac-side `approve` command.
Atlas owns everything here: the verifier, the trust anchors, the policy.

## How it fits together

```
MacBook                              Mini (this repo)
-------                              ----------------
Secure Enclave key, -t bio           /usr/local/etc/atlas-approval/   root:wheel
  |                                    allowed_signers, revoked_keys
  | ssh-keygen -Y sign                         ^
  | namespace atlas-approval                   | pinned, unwritable by uid 501
  v                                            |
~/atlas-approvals/inbox/  ------------> atlas-approval-verify.py (root LaunchDaemon)
  <chg>.<nonce>.approval + .sig                |
  (uid 501, untrusted input)                   v
                                       /usr/local/var/atlas-approval/granted/
                                         <chg>.<nonce>.json   <-- THE AUTHORITY
```

## The three properties that matter

**The authority is not a file we can write.** `ops/changes.jsonl` is append-only
by convention and writable by uid 501 in fact, so anything running as Atlas can
forge an `approved` line. The verifier therefore writes a root-owned grant record
containing the decision *and the exact proposal bytes it verified*, and the
execution gate reads that. The log event is a record; the grant is the authority.

**Atlas never runs the verifier.** It is a root daemon polling every 15 s. Atlas's
integrity does not decide whether an approval is genuine. It still decides whether
one is honoured — that part is irreducible — but only that part.

**Every outcome is announced out of band.** Accept and refuse both push to
Sander's handset. A refusal says so in words: if he did not just sign, someone
tried to forge an approval. Silent rejection into a folder is how probing goes
unnoticed.

## Install

Read `INSTALL-for-sander.sh`, then `sudo bash INSTALL-for-sander.sh`. Once
installed Atlas cannot modify any of it, which is the point and which means that
review is the only one.

`--require-uv` is deliberately off until the first real signature tells us whether
the `bio` key sets the user-verification bit. `allowed_signers` has no
`verify-required` option, so ssh-keygen cannot enforce it for us; the verifier
parses the flags byte itself and records it.

## The honest limit

A signature binds Sander's consent to **Atlas's description** of a change, not to
the action Atlas then takes. Nothing here catches a benign plan followed by a
different execution. Two things raise the ceiling: `planned` events must carry the
exact method rather than prose, and the execution gate must diff what is about to
run against the proposal bytes in the grant. A plan worth signing is a
specification, not a summary.
