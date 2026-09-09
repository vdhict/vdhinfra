"""
!! READ THIS FIRST !!

This module contains TWO things and only ONE of them represents what shipped.

  replay_old(...)  -- VALIDATED. Models the logic that chg-2026-09-08-003 shipped.
                      Reproduces reality: 17 service calls, 9 on/off transitions,
                      matching the real light.kantoor logbook to within 1.3 s.
                      Use this as the baseline. It is the trustworthy half.

  replay_new(...)  -- SUPERSEDED. DO NOT CITE. This models an INTERMEDIATE gate
                      design (OFF=800 / ON=400 / dwell) that was explored during
                      chg-2026-09-09-004 and then REJECTED, because it left the
                      user in a dim office unlit for 12-65 minutes. It is NOT the
                      shipped 10%-floor design and its numbers do not describe
                      the installed automation.

  For the SHIPPED design use newlogic.py in this same directory (written by
  change-qa/Themis, independently re-implemented branch-by-branch from the
  installed YAML; it reproduces the published table exactly:
  kappa 0.73 -> 9 calls/3 transitions/0 dark, 1.1 -> 10/3/0, 2.0 -> 10/3/0).

Run `python3 replay.py` for the OLD-logic validation.
"""

import sys, datetime as dt
sys.path.insert(0, '/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/2ac34ba5-b5fe-4aff-880a-a3a46c85be6f/scratchpad')
from luxlib import load, lux_series

T0 = dt.datetime(2026, 9, 9, 0, 0, tzinfo=dt.timezone.utc)
T1 = dt.datetime(2026, 9, 9, 12, 59, 43, tzinfo=dt.timezone.utc)

def bezet_at(bz, t):
    s = 'off'
    for tt, v in bz:
        if tt <= t: s = v
        else: break
    return s

def build_events(lux, bz):
    """(time, kind) merged event stream: lux reports, presence changes, /10 ticks."""
    ev = [(t, 'lux') for t, _ in lux]
    ev += [(t, 'bezet') for t, _ in bz]
    t = T0
    while t <= T1:
        ev.append((t, 'tick')); t += dt.timedelta(minutes=10)
    ev.sort(key=lambda x: x[0])
    return [e for e in ev if T0 <= e[0] <= T1]

def curve(ambient, span=600.0):
    a = max(0.0, min(ambient, span))
    return round(100 * (1 - a / span) ** 1.2)

# ---------------------------------------------------------------- OLD logic
def replay_old(lux, bz, kappa=None, ambient_true=None):
    """If ambient_true is None -> open loop on the recorded lux (what happened)."""
    ev = build_events(lux, bz)
    lv = {t: v for t, v in lux}
    on, br = False, 0
    calls, trans, brhist = [], [], []
    cur = 0.0
    for t, kind in ev:
        if kind == 'lux':
            cur = lv[t]
        meas = cur if ambient_true is None else ambient_true(t) + kappa * br
        b = bezet_at(bz, t)
        br_now = br if on else 0
        ambient = min(max(meas - 0.6 * br_now, 0), 600)
        target = max(curve(ambient), 10)
        aan_houden = ambient < (600 if on else 550)
        act = None
        if meas < 0:
            pass
        elif b == 'off':
            if on: act = ('off', 0)
        elif not aan_houden:
            if on: act = ('off', 0)
        elif not on:
            act = ('on', target)
        elif abs(target - br_now) >= 10:
            act = ('on', target)
        if act:
            calls.append((t, act[0], act[1], kind))
            if act[0] == 'off' and on: trans.append((t, 'off'))
            if act[0] == 'on' and not on: trans.append((t, 'on'))
            on = (act[0] == 'on'); br = act[1] if on else 0
        brhist.append((t, br if on else 0))
    return calls, trans, brhist

# ---------------------------------------------------------------- NEW logic
def replay_new(lux, bz, kappa, ambient_true, W=600, OFF=800, ON=400,
               DWELL=300, MININT=300, BEZET_FOR=600, DEAD=10,
               DWELL_ON=None, ON_FREE=False):
    if DWELL_ON is None: DWELL_ON = DWELL
    ev = build_events(lux, bz)
    lv = {t: v for t, v in lux}
    on, br = False, 0
    calls, trans = [], []
    cur = 0.0
    hist = []                 # (t, measured) for the trailing filter
    since_off = since_on = None
    last_cmd = None
    bezet_off_since = None
    for t, kind in ev:
        if kind == 'lux':
            cur = lv[t]
        meas = ambient_true(t) + kappa * br
        hist.append((t, meas))
        # time-weighted trailing moving average over W seconds
        lo = t - dt.timedelta(seconds=W)
        num = den = 0.0
        for j in range(len(hist) - 1, -1, -1):
            tt, vv = hist[j]
            end = hist[j + 1][0] if j + 1 < len(hist) else t
            if end <= lo: break
            w = (end - max(tt, lo)).total_seconds()
            if w > 0: num += vv * w; den += w
        sm = num / den if den > 0 else meas

        b = bezet_at(bz, t)
        bezet_off_since = (bezet_off_since or t) if b == 'off' else None
        br_now = br if on else 0
        ambient = min(max(sm - 0.6 * br_now, 0), OFF)
        target = max(curve(ambient), 10)

        # sustained gate crossings
        since_off = (since_off or t) if ambient >= OFF else None
        since_on  = (since_on  or t) if ambient <  ON  else None
        want_off = since_off is not None and (t - since_off).total_seconds() >= DWELL
        want_on  = since_on  is not None and (t - since_on ).total_seconds() >= DWELL_ON

        free = last_cmd is None or (t - last_cmd).total_seconds() >= MININT
        act = None
        if sm < 0:
            pass
        elif b == 'off' and bezet_off_since and (t - bezet_off_since).total_seconds() >= BEZET_FOR:
            if on: act = ('off', 0)
        elif b == 'off':
            pass
        elif on and want_off:
            act = ('off', 0)
        elif (not on) and want_on:
            act = ('on', target)
        elif on and abs(target - br_now) >= DEAD:
            act = ('on', target)
        if act and (free or (ON_FREE and act[0]=='on' and not on)):
            calls.append((t, act[0], act[1], kind))
            if act[0] == 'off' and on: trans.append((t, 'off'))
            if act[0] == 'on' and not on: trans.append((t, 'on'))
            on = (act[0] == 'on'); br = act[1] if on else 0
            last_cmd = t
            since_off = since_on = None
    return calls, trans


if __name__ == "__main__":
    # Driver: reproduce the OLD-logic validation that underwrites everything else.
    import itertools
    lux = lux_series(); bz = load("binary_sensor.kantoor_bezet")
    calls, trans, brh = replay_old(lux, bz)
    real = [(t, v) for t, v in load("light.kantoor")
            if t > dt.datetime(2026, 9, 9, 0, 30, tzinfo=dt.timezone.utc)]
    EXO = {("08:32:41", "on"), ("08:32:55", "off")}   # exogenous Hue group artefact
    real_auto = [(t, v) for t, v in real
                 if (t.strftime("%H:%M:%S"), v) not in EXO]
    print("OLD-logic replay of the real 2026-09-09 stream")
    print("  service calls      : %d   (expected 17)" % len(calls))
    print("  on/off transitions : %d   (expected 9)" % len(trans))
    worst = max(abs((p[0] - r[0]).total_seconds())
                for p, r in zip(trans, real_auto)) if trans else 0
    print("  worst timing delta vs real logbook: %.1f s (expected <= 1.3)" % worst)
    ok = (len(calls) == 17 and len(trans) == 9 and worst <= 1.5
          and all(p[1] == r[1] for p, r in zip(trans, real_auto)))
    print("  VERDICT:", "PASS" if ok else "FAIL")
