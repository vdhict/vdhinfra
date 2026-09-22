"""chg-2026-09-09-006 v2 replay. Inputs = REAL recorder series of the helpers that will run
(sensor.kantoor_zon_pv_15m/_45m), real OWM wind/gust, real binary_sensor.kantoor_bezet,
real cover.screen schedule moves (+ optionally Sander's manual moves). Sun from sun.py
(sun.sun is recorder-excluded; sun.py validated vs sun.sun to 0.3 deg on 09-09 and again 09-22).
Tick = the automation's own time_pattern /5 (every 5 min, local :00/:05...)."""
import sys,datetime
sys.path.insert(0,'/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/743312b1-6b9e-4bf4-bf26-d4504d06a737/scratchpad')
from series import *
UTC=datetime.timezone.utc
h15=Step('sensor.kantoor_zon_pv_15m'); h45=Step('sensor.kantoor_zon_pv_45m')
W=Step('sensor.openweathermap_windsnelheid'); G=Step('sensor.openweathermap_windvlaag_snelheid',num=False)
B=Step('binary_sensor.kantoor_bezet',num=False)
Z=lambda s: datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
SCHED=[(Z(t),s) for t,s in [
 ('2026-09-12T06:39:35.687607Z','open'),('2026-09-12T17:33:40.378018Z','closed'),
 ('2026-09-13T05:36:16.528380Z','open'),('2026-09-13T17:31:21.086035Z','closed'),
 ('2026-09-14T05:00:00.081058Z','open'),('2026-09-14T17:29:00Z','closed'),   # sunset-30 ran; no-op (already closed)
 ('2026-09-15T05:00:00.081739Z','open'),('2026-09-15T17:26:41.975997Z','closed'),
 ('2026-09-16T05:00:00.081530Z','open'),('2026-09-16T17:24:22.207993Z','closed'),
 ('2026-09-17T05:00:00.382645Z','open'),('2026-09-17T17:22:02.347015Z','closed'),
 ('2026-09-18T05:00:00.381855Z','open'),('2026-09-18T17:19:42.412155Z','closed'),  # trace; no-op in reality
 ('2026-09-19T07:18:43.955176Z','open'),('2026-09-19T17:17:22.440142Z','closed'),
 ('2026-09-20T07:12:08.360132Z','open'),('2026-09-20T17:15:02.450543Z','closed'),
 ('2026-09-21T05:00:00.382386Z','open'),('2026-09-21T17:12:42.482437Z','closed'),
 ('2026-09-22T05:00:00.382622Z','open'),('2026-09-22T17:10:22.557411Z','closed')]]
MANUAL=[(Z(t),s) for t,s in [
 ('2026-09-14T10:16:10.463381Z','closed'),('2026-09-15T09:47:25.166312Z','closed'),
 ('2026-09-15T14:30:54.131904Z','open'),('2026-09-18T11:21:55.234031Z','closed'),
 ('2026-09-21T13:07:21.622629Z','closed'),('2026-09-21T13:45:27.115879Z','open')]]
def fnum(x,d):
    try: return float(x)
    except: return d
def run(C=1800,O=700,GAP=45,R5GAP=45,AZ_LO_OCC=None,HOLD=False,V2=False,manual=False,stale_src='reported',EL_IN=12,AZ_LO=120,AZ_HI=245,AZ_EDGE=245,EL_EDGE=8,log=None):
    ev=sorted([(t,s,'sched') for t,s in SCHED]+([(t,s,'manual') for t,s in MANUAL] if manual else []))
    start=datetime.datetime(2026,9,12,0,0,tzinfo=TZ); end=datetime.datetime(2026,9,23,0,0,tzinfo=TZ)
    cur='closed'; lc=start-datetime.timedelta(hours=10); ad=False; hold=False; res=[]; ei=0; t=start
    while t<end:
        while ei<len(ev) and ev[ei][0]<=t:
            et,s,src=ev[ei]; ei+=1
            if s!=cur:
                if HOLD and s=='open' and ad: hold=True; ad=False   # external open of a screen WE closed
                cur=s; lc=et; res.append((et,s,src,None))
        el,az=sunpos(t.astimezone(UTC))
        p15=fnum(h15.at(t)[0],-1); p45=fnum(h45.at(t)[0],-1)
        wv,wlu=W.at(t); wind=fnum(wv,-1)
        # staleness: 'updated' = draft (last_updated). 'reported' = OWM polls every 10 min; recorder has no
        # last_reported history, so approximate reported-age by the poll period (10 min) => never stale here.
        wage=(t-wlu).total_seconds()/60 if (stale_src=='updated' and wlu) else 10
        gust=fnum(G.at(t)[0],0); bez=B.at(t)[0]=='on'
        since=(t-lc).total_seconds()/60
        in_beam= el>EL_IN and AZ_LO<=az<=AZ_HI; at_edge= az>AZ_EDGE and el>EL_EDGE
        stale= wind<0 or wage>180; bad= wind>=45 or gust>=60; marg= wind>=38 or gust>=50 or stale
        act=None
        if V2:
            if el<6 and (ad or hold): ad=False; hold=False
            elif cur=='closed' and (bad or (stale and ad)): act=('open','R2 wind'); ad=False
            elif since<GAP: pass
            elif in_beam and (AZ_LO_OCC is None or B.at(t)[0]=='off' or az>=AZ_LO_OCC) and p15>=C and not marg and not hold and cur=='open': act=('closed','R5 close'); ad=True
            elif in_beam and 0<=p45<=O and bez and since>=R5GAP and cur=='closed' and ad: act=('open','R6 dull+occupied'); ad=False
            elif at_edge and cur=='closed' and ad: act=('open','R7 edge'); ad=False
        else:
          if (bad or stale) and cur!='open' and (stale_src=='updated' or bad or ad): act=('open','R1 wind'); ad=False
          elif since<GAP: pass
          elif hold and el>0: pass
          elif in_beam and (AZ_LO_OCC is None or not bez or az>=AZ_LO_OCC) and p15>=C and not marg and cur=='open': act=('closed','R4 close'); ad=True
          elif in_beam and p45<=O and bez and cur=='closed' and ad and since>=R5GAP: act=('open','R5 dull+occupied'); ad=False
          elif at_edge and cur=='closed' and ad: act=('open','R6 edge'); ad=False
          elif el<=0 and (ad or hold): ad=False; hold=False
        if act:
            cur=act[0]; lc=t; res.append((t,act[0],'AUTO '+act[1],dict(az=round(az),el=round(el,1),p15=p15,p45=p45,wind=wind,gust=gust,bez=bez)))
        t+=datetime.timedelta(minutes=5)
    return res
def summary(res):
    days=[datetime.date(2026,9,d) for d in range(12,23)]
    per={d:[r for r in res if r[2].startswith('AUTO') and r[0].astimezone(TZ).date()==d] for d in days}
    n=[len(per[d]) for d in days]
    return per,n
if __name__=='__main__':
    import json
    C=int(sys.argv[1]) if len(sys.argv)>1 else 1800; O=int(sys.argv[2]) if len(sys.argv)>2 else 700
    for manual in (False,True):
        per,n=summary(run(C,O,manual=manual))
        print(f'=== C={C} O={O} manual_moves_included={manual}: mean {sum(n)/len(n):.2f}/day max {max(n)} zero-days {n.count(0)}')
        for d,rs in per.items():
            print(f'  {d} {len(rs)} ', '  '.join(f"{r[0].astimezone(TZ).strftime('%H:%M')} {r[1]} {r[2][5:]} az{r[3]['az']} el{r[3]['el']} p15={r[3]['p15']:.0f} p45={r[3]['p45']:.0f}" for r in rs))
