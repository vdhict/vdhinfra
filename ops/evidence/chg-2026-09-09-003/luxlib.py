import json, datetime as dt
D='/Users/sheijden/Code/homelab-migration/vdhinfra/ops/evidence/chg-2026-09-09-003/'
def load(e):
    d=json.load(open(D+'fixture-%s.json'%e))[0]
    out=[]
    for s in d:
        t=dt.datetime.fromisoformat((s.get('last_changed') or s.get('last_updated')).replace('Z','+00:00'))
        out.append((t,s['state']))
    out.sort(); return out
def lux_series():
    return [(t,float(v)) for t,v in load('sensor.multisensor_illuminance')
            if v not in ('unknown','unavailable')]
def tsma(series, W):
    """Time-weighted trailing moving average over W seconds (HA filter
    'time_simple_moving_average' semantics): each sample holds its value until
    the next one, weights are the durations inside the window."""
    out=[]
    for i,(t,v) in enumerate(series):
        lo=t-dt.timedelta(seconds=W)
        num=den=0.0
        j=i
        while j>=0 and series[j][0]>=lo:
            tt,vv=series[j]
            end = series[j+1][0] if j+1<=i and j+1<len(series) else t
            if j==i: end=t
            w=(end-max(tt,lo)).total_seconds()
            if w>0: num+=vv*w; den+=w
            j-=1
        # include the sample straddling the window start
        if j>=0:
            tt,vv=series[j]
            end=series[j+1][0]
            w=(end-lo).total_seconds()
            if w>0: num+=vv*w; den+=w
        out.append((t, num/den if den>0 else v))
    return out
def crossings(series, off_t, on_t, dwell=0):
    """Count on/off gate flips. dwell = seconds the condition must hold
    continuously before the flip is committed (an HA `for:`)."""
    on=True; n=0; since=None
    for t,v in series:
        cond = (v>=off_t) if on else (v<on_t)
        if cond:
            if since is None: since=t
            if (t-since).total_seconds()>=dwell:
                on = not on; n+=1; since=None
        else:
            since=None
    return n
