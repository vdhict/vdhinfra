import json,datetime
d=json.load(open('p1_14d.json'))[0]
def ts(x):
    s=(x.get('last_changed') or x.get('lu')).replace('+00:00','Z')
    return datetime.datetime.strptime(s.split('.')[0].rstrip('Z'),'%Y-%m-%dT%H:%M:%S').replace(tzinfo=datetime.timezone.utc).timestamp()
a=[(ts(x),x['state']) for x in d]
EP=[(a[i][0],a[i+1][0]-a[i][0]) for i in range(len(a)-1) if a[i][1]=='unavailable']
T0,T1=a[0][0],a[-1][0]
CEST=datetime.timezone(datetime.timedelta(hours=2))
def L(t): return datetime.datetime.fromtimestamp(t,CEST).strftime('%m-%d %H:%M')

def run(A1=1800, A2WIN=10800, A2THR=3600, A2DWELL=300, MININT=1200, CAP=6, RECOV=150, label=""):
    hist=[]          # realised (start,end) downtime intervals after intervention
    fires=[]
    blocked=[]
    supp_until=-1e9  # device forced up until this time
    last_fire=-1e9
    for st,du in EP:
        if st < supp_until:          # episode swallowed by a recent cycle's uptime? no - real ep still starts
            pass
        en=st+du
        t=max(st, supp_until)
        if t>=en:
            continue
        down_start=t
        fired_this=False
        while t<en:
            dwell=t-down_start
            trail=sum(max(0,min(e,t)-max(s,t-A2WIN)) for s,e in hist)+ (t-down_start)
            sigA1 = dwell>=A1
            sigA2 = dwell>=A2DWELL and trail>=A2THR
            if (sigA1 or sigA2) and not fired_this:
                if t-last_fire < MININT:
                    t+=60; continue
                n24=len([f for f in fires if f[0]>t-86400])
                if n24>=CAP:
                    blocked.append((t,'A1' if sigA1 else 'A2',dwell))
                    hist.append((down_start,en)); t=en; fired_this=True; break
                fires.append((t,'A1' if sigA1 else 'A2',dwell,n24+1))
                last_fire=t
                hist.append((down_start,t))
                supp_until=t+RECOV
                fired_this=True
                t=en
                break
            t+=60
        else:
            hist.append((down_start,en))
    print(f"=== {label}  A1={A1//60}m A2={A2THR//60}m/{A2WIN//3600}h dwell={A2DWELL//60}m cap={CAP}/24h ===")
    print(f"total fires={len(fires)}  blocked-by-cap={len(blocked)}")
    days={}
    for f in fires: days.setdefault(L(f[0])[:5],[]).append(f)
    for day in sorted(set(list(days)+[L(b[0])[:5] for b in blocked])):
        fl=days.get(day,[])
        s=", ".join(f"{L(f[0])[6:]}({f[1]},waited {int(f[2]//60)}m,#{f[3]})" for f in fl)
        bl=[b for b in blocked if L(b[0])[:5]==day]
        print(f"  {day}: {len(fl)} fires  {s}" + (f"   BLOCKED: {', '.join(L(b[0])[6:]+'('+b[1]+')' for b in bl)}" if bl else ""))
    saved=sum(e-s for s,e in [(x[0],x[1]) for x in []])
    tot=sum(e-s for s,e in hist)
    print(f"  realised total downtime = {tot/3600:.2f} h (was 22.61 h)\n")

run(A1=1800,A2THR=10**9,MININT=1200,CAP=3,label="AS-SPECCED (A1 only, cap 3/day)")
run(A1=1800,A2THR=10**9,MININT=1200,CAP=6,label="A1 only, cap 6/24h")
run(A1=1800,A2WIN=10800,A2THR=3600,A2DWELL=300,MININT=1200,CAP=6,label="A1+A2(60m/3h,dwell5m), cap 6")
run(A1=1800,A2WIN=10800,A2THR=3600,A2DWELL=600,MININT=1800,CAP=6,label="A1+A2(60m/3h,dwell10m), min-int 30m, cap 6")
run(A1=1800,A2WIN=14400,A2THR=4500,A2DWELL=600,MININT=1800,CAP=6,label="A1+A2(75m/4h,dwell10m), min-int 30m, cap 6")

print("### RECOMMENDED, cap 8 ###")
run(A1=1800,A2WIN=14400,A2THR=4500,A2DWELL=600,MININT=1800,CAP=8,label="RECOMMENDED A1=30m + A2=75m/4h dwell10m, min-int 30m, cap 8/24h")
