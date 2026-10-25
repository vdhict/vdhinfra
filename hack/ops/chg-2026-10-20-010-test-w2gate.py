#!/usr/bin/env python3
"""chg-2026-10-20-010 offline tests of the W2 hard gate in chg-2026-10-20-010-golive.sh (--gate-only).

    python3 -I hack/ops/chg-2026-10-20-010-test-w2gate.py [<scratch-dir>]

Every case gets its own scratch VDH_REPO (changes.jsonl + ops/evidence/chg-2026-10-20-010/), so the real change
log and evidence directory are never read or written. Synthetic values only: no key, no hint characters, no
personal data. Deletes nothing (AGR-121): scratch dirs stay under <scratch-dir> (default: a fresh mktemp dir).
Exit 0 only when every case gives the expected exit code AND reason.
"""
import datetime as dt, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GOLIVE = os.path.join(HERE, "chg-2026-10-20-010-golive.sh")
CHG = "chg-2026-10-20-010"
BASE = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="c010-w2gate-")
os.makedirs(BASE, exist_ok=True)
NOW = dt.datetime.now(dt.timezone.utc)
Z = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
EVENT_TS = "2026-10-25T12:00:00Z"
GOOD_PREPAID = {
    "captured_utc": Z(NOW - dt.timedelta(hours=1)),
    "auto_reload": "off",
    "purchased_balance_usd": 0,
    "invoicing": "none",
    "org_monthly_limit_usd": 200,
    "key_scope": "organization",
    "key_hint_match": True,
    "promo_credit_usd": 200,
    "promo_credit_expires_utc": Z(NOW + dt.timedelta(days=10)),
}
PP = "prepaid_autoreload_off_purchased_usd=0_org_limit_usd="


def case(name, want_rc, want_msg, doc=None, payload=None, actor="infra-ops", evname="w2a-test.json",
         raw=None, write_event=True, write_file=True, settings={"budget_usd": 200}):
    d = os.path.join(BASE, "case-%02d" % (len(results) + 1))
    evdir = os.path.join(d, "ops", "evidence", CHG)
    os.makedirs(evdir)
    if write_file:
        with open(os.path.join(evdir, evname), "w") as fh:
            fh.write(raw if raw is not None else json.dumps(doc))
    pl = {"w2_evidence": "ops/evidence/%s/%s" % (CHG, evname), "w2_readback_by": "atlas",
          "w2a": "no_payment_method_no_autoreload"}
    pl.update(payload or {})
    pl = {k: v for k, v in pl.items() if v is not None}
    with open(os.path.join(d, "changes.jsonl"), "w") as fh:
        if write_event:
            fh.write(json.dumps({"actor": actor, "chg": CHG, "event": "executed", "payload": pl, "ts": EVENT_TS}) + "\n")
    sp = os.path.join(d, "settings.json")   # stands in for the bundle's family-cloud/settings.json
    if settings is not None:
        with open(sp, "w") as fh:
            fh.write(settings if isinstance(settings, str) else json.dumps(settings))
    env = dict(os.environ, VDH_REPO=d, C010_CHANGES=os.path.join(d, "changes.jsonl"), C010_EVIDENCE_DIR=evdir,
               C010_SETTINGS=sp)
    p = subprocess.run(["bash", GOLIVE, "--gate-only", "0" * 40, "--w2-event", EVENT_TS], cwd=HERE, env=env,
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    ok = p.returncode == want_rc and want_msg in out
    line = [l for l in out.splitlines() if "REFUSED" in l or "W2 gate:" in l]
    results.append((ok, name, p.returncode, (line[-1] if line else out.strip()[-160:])))


results = []
old = {"captured_utc": Z(NOW - dt.timedelta(hours=1))}
# --- the 9 original refusals + 2 acceptances (6897df84), unchanged behaviour
case("old: no infra-ops event at ts", 2, "no infra-ops event", old, write_event=False)
case("old: stale evidence 30 h", 2, "re-measure the console", {"captured_utc": Z(NOW - dt.timedelta(hours=30))})
case("old: w2a workspace_limit_usd=250", 2, "w2a must be", old, {"w2a": "workspace_limit_usd=250"})
case("old: w2a unlimited", 2, "w2a must be", old, {"w2a": "unlimited"})
case("old: readback by larry", 2, "w2_readback_by must be", old, {"w2_readback_by": "larry"})
case("old: path escape ../", 2, "not an existing file directly in", old, {"w2_evidence": "ops/evidence/../../changes.jsonl"})
case("old: no UTC stamp", 2, "no UTC timestamp field", {"note": "x"})
case("old: evidence file missing", 2, "not an existing file directly in", old, write_file=False)
case("old: wrong actor", 2, "no infra-ops event", old, actor="k8s-engineer")
case("old: accept no_payment_method_no_autoreload", 0, "RESULT gate-only GREEN", old)
case("old: accept workspace_limit_usd=200", 0, "RESULT gate-only GREEN", old, {"w2a": "workspace_limit_usd=200"})
# --- prepaid w2a (Argus 25-10 09:42:10Z pre-go item 1)
case("prepaid: accept n=200; cut-off time = the JSON's expiry", 0, "promo_credit_expires_utc=" + GOOD_PREPAID["promo_credit_expires_utc"], GOOD_PREPAID, {"w2a": PP + "200"})
odd = Z(NOW + dt.timedelta(days=3, hours=5, minutes=17, seconds=41))   # not a constant: an arbitrary instant
case("prepaid: cut-off time follows the JSON (arbitrary expiry %s)" % odd, 0, "promo_credit_expires_utc=" + odd, dict(GOOD_PREPAID, promo_credit_expires_utc=odd), {"w2a": PP + "200"})
hm = (NOW + dt.timedelta(days=2)).strftime("%Y-%m-%dT%H:%MZ")
case("prepaid: expiry without seconds is normalised to :00Z", 0, "promo_credit_expires_utc=" + hm[:-1] + ":00Z", dict(GOOD_PREPAID, promo_credit_expires_utc=hm), {"w2a": PP + "200"})
case("prepaid: refuse budget_usd 200 against a USD 100 grant", 2, "budget_usd 200 > promo_credit_usd 100", dict(GOOD_PREPAID, promo_credit_usd=100), {"w2a": PP + "200"})
case("prepaid: accept budget_usd 100 against a USD 100 grant", 0, "budget_usd 100 <= promo 100", dict(GOOD_PREPAID, promo_credit_usd=100), {"w2a": PP + "200"}, settings={"budget_usd": 100})
case("prepaid: refuse budget_usd 100.01 against 100", 2, "the cap must follow the grant", dict(GOOD_PREPAID, promo_credit_usd=100), {"w2a": PP + "200"}, settings={"budget_usd": 100.01})
case("prepaid: refuse bundle settings missing", 2, "budget_usd unreadable", GOOD_PREPAID, {"w2a": PP + "200"}, settings=None)
case("prepaid: refuse budget_usd \"200\" (string)", 2, "budget_usd unreadable", GOOD_PREPAID, {"w2a": PP + "200"}, settings={"budget_usd": "200"})
case("prepaid: refuse settings without budget_usd", 2, "budget_usd unreadable", GOOD_PREPAID, {"w2a": PP + "200"}, settings={"model": "x"})
case("prepaid: accept n=150 with limit 150", 0, "RESULT gate-only GREEN", dict(GOOD_PREPAID, org_monthly_limit_usd=150), {"w2a": PP + "150"})
case("prepaid: refuse n=200.01", 2, "w2a must be", dict(GOOD_PREPAID, org_monthly_limit_usd=200.01), {"w2a": PP + "200.01"})
case("prepaid: refuse n=0", 2, "w2a must be", dict(GOOD_PREPAID, org_monthly_limit_usd=0), {"w2a": PP + "0"})
case("prepaid: refuse n=-5 (no sign)", 2, "w2a must be", GOOD_PREPAID, {"w2a": PP + "-5"})
case("prepaid: refuse purchased 0.01", 2, "purchased_balance_usd is not 0", dict(GOOD_PREPAID, purchased_balance_usd=0.01), {"w2a": PP + "200"})
case("prepaid: refuse purchased false (bool)", 2, "purchased_balance_usd missing or not a finite number", dict(GOOD_PREPAID, purchased_balance_usd=False), {"w2a": PP + "200"})
case("prepaid: refuse purchased \"0\" (string)", 2, "purchased_balance_usd missing or not a finite number", dict(GOOD_PREPAID, purchased_balance_usd="0"), {"w2a": PP + "200"})
case("prepaid: refuse auto_reload on", 2, "auto_reload is not 'off'", dict(GOOD_PREPAID, auto_reload="on"), {"w2a": PP + "200"})
case("prepaid: refuse invoicing on", 2, "invoicing is not 'none'", dict(GOOD_PREPAID, invoicing="on"), {"w2a": PP + "200"})
case("prepaid: refuse limit mismatch (doc 200, w2a 150)", 2, "does not equal the w2a limit", GOOD_PREPAID, {"w2a": PP + "150"})
case("prepaid: refuse limit NaN", 2, "org_monthly_limit_usd missing or not a finite number", None, {"w2a": PP + "200"},
     raw=json.dumps(GOOD_PREPAID).replace('"org_monthly_limit_usd": 200', '"org_monthly_limit_usd": NaN'))
case("prepaid: refuse key_scope workspace", 2, "key_scope is not 'organization'", dict(GOOD_PREPAID, key_scope="workspace"), {"w2a": PP + "200"})
case("prepaid: refuse key_hint_match false", 2, "key_hint_match is not true", dict(GOOD_PREPAID, key_hint_match=False), {"w2a": PP + "200"})
case("prepaid: refuse key_hint_match \"true\" (string)", 2, "key_hint_match is not true", dict(GOOD_PREPAID, key_hint_match="true"), {"w2a": PP + "200"})
case("prepaid: refuse key_hint_match 1 (int)", 2, "key_hint_match is not true", dict(GOOD_PREPAID, key_hint_match=1), {"w2a": PP + "200"})
case("prepaid: refuse promo 0", 2, "promo_credit_usd is not > 0", dict(GOOD_PREPAID, promo_credit_usd=0), {"w2a": PP + "200"})
case("prepaid: refuse expired credit", 2, "promotional credit expired", dict(GOOD_PREPAID, promo_credit_expires_utc=Z(NOW - dt.timedelta(minutes=1))), {"w2a": PP + "200"})
case("prepaid: refuse expiry not ...Z", 2, "promo_credit_expires_utc is not a UTC timestamp", dict(GOOD_PREPAID, promo_credit_expires_utc="2026-11-14T00:00:00+01:00"), {"w2a": PP + "200"})
case("prepaid: refuse stale capture 30 h", 2, "re-measure the console", dict(GOOD_PREPAID, captured_utc=Z(NOW - dt.timedelta(hours=30))), {"w2a": PP + "200"})
case("prepaid: refuse ts_utc instead of captured_utc", 2, "captured_utc missing",
     dict({k: v for k, v in GOOD_PREPAID.items() if k != "captured_utc"}, ts_utc=GOOD_PREPAID["captured_utc"]), {"w2a": PP + "200"})
for k in GOOD_PREPAID:
    want = {"captured_utc": "no UTC timestamp field"}.get(k, k)
    case("prepaid: refuse missing " + k, 2, want, {x: v for x, v in GOOD_PREPAID.items() if x != k}, {"w2a": PP + "200"})

bad = 0
for ok, name, rc, line in results:
    bad += not ok
    print("%s  rc=%d  %-52s %s" % ("PASS" if ok else "FAIL", rc, name, line.split("] ")[-1][:150]))
print("RESULT %d/%d PASS (scratch %s)" % (len(results) - bad, len(results), BASE))
sys.exit(1 if bad else 0)
