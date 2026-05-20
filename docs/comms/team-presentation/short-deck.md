# Short-form slide deck — "A house that runs itself (almost)"

**Format**: 5 slides for a 3-minute coffee-chat introduction
**Audience**: Anyone Sander is talking to who asks "what is it you actually do at home?"
**Author**: Hermes (comms-engineer)
**Date**: 2026-05-19
**Status**: DRAFT

**Design note for Apollo**: This deck is a cut-down, not a redesign. The five slides should
reuse the visual language of the long deck but be self-contained. Larger text, fewer words,
one key visual per slide.

---

## Slide 1 — The setup

**Title**: Our house has 66 pieces of software running at the same time

**Headline**: Here's how we stop them from tripping over each other

**Talking points**:
- Smart lights, heating, solar, EV charger, media, security — each has its own software stack.
- Most homes run this with no oversight. We run it like a production system.

**Image need**: The house-with-dots infographic from the long deck (Slide 2), scaled up, minimal text.

**Spoken script** (30 seconds):
"Our house has 66 active software components — lights, heating, the car charger, the media server, the backup system. It sounds like a lot, but every home with smart devices is getting there. The difference is how you manage it. Let me show you quickly."

---

## Slide 2 — The team

**Title**: Eleven specialists. One principle.

**Headline**: Nobody executes a change without a plan and a check.

**Talking points**:
- Atlas orchestrates. Hestia owns home automation. Iris runs the network. Hephaestus runs the cluster.
- Themis: the QA gate. Her job is to say no until the plan is right.
- None of them write to production without a change record.

**Image need**: The team deity grid from the long deck, slightly reduced. Just the icons and names — no long descriptions at this size.

**Spoken script** (30 seconds):
"There's a team of eleven AI specialists managing this. Each one has a domain, a set of authorities, and things they're not allowed to do. The change review process is the same one a software company would use. The difference is that the team is available 24 hours a day and never has a bad day."

---

## Slide 3 — The stack in one sentence

**Title**: Six computers. One brain. Sixty apps. One notebook.

**Headline**: If a machine dies tonight, we're back up from the same code.

**Talking points**:
- Six mini PCs in the rack — three coordinators, three workers.
- Home Assistant: the house automation brain. Connected to 200+ devices.
- All configuration is code in a Git repository. Flux (a robot) keeps the live system matching the code.
- Restore scenario: new machine, point robot at notebook, wait 20 minutes.

**Image need**: The three-step GitOps diagram from the long deck (Slide 12). Clean, centred.

**Spoken script** (30 seconds):
"Every setting, every app, every routing rule is a file in a shared code repository. A piece of software reads that repository and applies it to the cluster. If a node fails and has to be replaced, you restore the OS, point the robot at the code, and wait twenty minutes. That's it."

---

## Slide 4 — One example: the car charger

**Title**: The car charges when it's cheapest — or free from the roof

**Headline**: Solar surplus + live grid price → automatic charge timing

**Talking points**:
- Solar inverter feeds output into evcc (the charge controller).
- Live Zonneplan electricity price feeds in too.
- evcc decides: charge now (solar surplus), charge tonight (cheap hour), or wait.
- No manual action. No app to open.

**Image need**: The three-source diagram from long-deck Slide 17: [Solar] + [Grid price] → [evcc] → [Car]. Larger, centred.

**Spoken script** (30 seconds):
"The most satisfying one: the car charges itself at the cheapest moment of the day, or for free from the solar panels. On a sunny afternoon it charges for nothing. On an overcast winter day it waits for 3 a.m. when prices drop. The system decides. Nobody opens an app."

---

## Slide 5 — The one thing

**Title**: Every change is deliberate, recorded, and reversible.

**Headline**: "And reviewed by someone whose only job is to say no when it isn't ready."

**Talking points**:
- No bullets. Land the sentence.

**Image need**: Typography-only. The headline sentence, large, centred. Same visual as long-deck Slide 25.

**Spoken script** (30 seconds):
"That's the whole thing. When something goes wrong — and it does, sometimes — we know exactly what changed, when, and why. And we know how to reverse it. Most home setups just reboot and hope. We don't have to."

---

## Delivery notes

- 5 slides, 3 minutes. 30 seconds per slide, no pad.
- Keep all five visible as a handout on a phone screen if needed — make sure the font is readable at 375px wide.
- Ideal context: someone asks "so what do you actually run at home?" at a meetup, a dinner, or an interview. This answers the question without losing the room.
