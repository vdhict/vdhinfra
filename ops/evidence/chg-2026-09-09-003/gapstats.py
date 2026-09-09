import json,sys,statistics,datetime as dt
ent = sys.argv[1]; hours = sys.argv[2]
d = json.load(sys.stdin)
if not d or not d[0]:
    print("no history"); raise SystemExit
rows = []
for s in d[0]:
    ts = s.get("last_changed") or s.get("last_updated")
    rows.append((dt.datetime.fromisoformat(ts.replace("Z", "+00:00")), s["state"]))
rows.sort()
print("entity=%s window=%sh samples=%d" % (ent, hours, len(rows)))
gaps = []; prev = None
for t, v in rows:
    g = (t - prev).total_seconds() if prev else None
    if g is not None:
        gaps.append(g)
    print("%sZ  %8s  gap=%s" % (t.strftime("%Y-%m-%d %H:%M:%S"), v, "" if g is None else int(g)))
    prev = t
if gaps:
    span = (rows[-1][0] - rows[0][0]).total_seconds()
    print("\nGAPS n=%d min=%d median=%d mean=%d max=%d" % (
        len(gaps), min(gaps), statistics.median(gaps), statistics.mean(gaps), max(gaps)))
    print("span=%ds reports_per_hour=%.2f" % (span, len(gaps) / (span / 3600)))
