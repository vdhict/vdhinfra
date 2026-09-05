#!/usr/bin/env python3
"""chg-2026-09-05-001 backtest. Replays the woonkamer_avond_uit state machine over
recorded history. SINGLE midnight-aligned minute grid for every figure, so the
window subtotal and the full-day total are computed identically (this reconciles the
624-vs-631 discrepancy in the first validated event: 624 came from a grid phase-aligned
to sunset-1h, 631 from a midnight-aligned grid; same quantity, different sampling phase).
Authoritative figure = midnight-aligned."""
import json,subprocess,datetime as dt,os,math
from urllib.parse import quote
from zoneinfo import ZoneInfo
TZ=ZoneInfo("Europe/Amsterdam"); LAT,LON=51.8582341,4.4838181
TOK=open(os.path.expanduser("~/Code/homelab-migration/config/hasskey")).read().strip()
FP2,FP300,TV="binary_sensor.presence_sensor_fp2_f08e_presence_sensor_3","binary_sensor.presence_woonkamer","media_player.tv_woonkamer_2"
SONOS=["media_player.woonkamer","media_player.woonkamer_platenspeler","media_player.keuken","media_player.bar_2"]
LAMPS=["light.woonkamer","light.woonkamer_lamp","light.woonkamer_lamp_2"]
ENT=[FP2,FP300,TV]+SONOS+LAMPS
DIM_MIN,OFF_MIN=10,20
def sunset(d):
    n=d.toordinal()-dt.date(2000,1,1).toordinal()+0.0008; Js=n-LON/360.0
    M=math.radians((357.5291+0.98560028*Js)%360)
    C=1.9148*math.sin(M)+0.02*math.sin(2*M)+0.0003*math.sin(3*M)
    lam=math.radians((math.degrees(M)+C+180+102.9372)%360)
    Jt=2451545.0+Js+0.0053*math.sin(M)-0.0069*math.sin(2*lam)
    decl=math.asin(math.sin(lam)*math.sin(math.radians(23.4397)))
    cw=(math.sin(math.radians(-0.833))-math.sin(math.radians(LAT))*math.sin(decl))/(math.cos(math.radians(LAT))*math.cos(decl))
    Js2=Jt+math.degrees(math.acos(max(-1,min(1,cw))))/360.0
    return dt.datetime.fromtimestamp((Js2-2440587.5)*86400.0,dt.timezone.utc).astimezone(TZ)-dt.timedelta(minutes=4)
def P(t): return dt.datetime.fromisoformat(t.replace("Z","+00:00")).astimezone(TZ)
def hist(s,e):
    u=("http://172.16.2.237:8123/api/history/period/%s?end_time=%s&minimal_response&filter_entity_id=%s"
       %(quote(s.isoformat()),quote(e.isoformat()),",".join(ENT)))
    r=subprocess.run(["curl","-fsS","-H","Authorization: Bearer "+TOK,u],capture_output=True,text=True)
    return json.loads(r.stdout or "[]")
now=dt.datetime.now(TZ); rows=[]; T=dict(fb=0,fa=0,wb=0,wa=0,day=0,aft=0,dim=0,off=0,cx=0,utv=0,uso=0,ufp=0,n=0)
for d in range(6,0,-1):
    date=(now-dt.timedelta(days=d)).date()
    s=dt.datetime.combine(date,dt.time(0,0),TZ)
    ser={}
    for arr in hist(s,s+dt.timedelta(days=1)):
        if arr and arr[0].get("entity_id"):
            ser[arr[0]["entity_id"]]=[(P(x.get("last_changed") or x["last_updated"]),x["state"]) for x in arr if x.get("state")]
    if not ser: continue
    def at(e,t):
        v="unknown"
        for ts,st in ser.get(e,[]):
            if ts<=t: v=st
            else: break
        return v
    ac=lambda t:(at(FP2,t)=="off" and at(FP300,t)=="off" and at(TV,t) not in ("on","playing") and all(at(x,t)!="playing" for x in SONOS))
    lit=lambda t:any(at(x,t)=="on" for x in LAMPS)
    w0=sunset(date)-dt.timedelta(hours=1); w1=dt.datetime.combine(date,dt.time(23,0),TZ)
    fb=fa=wb=wa=dayt=aft=0; ndim=noff=ncx=utv=uso=ufp=0; streak=0; forced=dimmed=False
    for i in range(1440):                      # ONE midnight-aligned grid for everything
        t=s+dt.timedelta(minutes=i); inwin=w0<=t<w1; a=ac(t); L=lit(t)
        if inwin:
            if a: streak+=1
            else:
                if dimmed: ncx+=1
                streak=0; dimmed=forced=False
            if L and not forced:
                if streak==DIM_MIN and not dimmed: dimmed=True; ndim+=1
                if streak>=OFF_MIN: 
                    if not forced: noff+=1
                    forced=True
            if forced and not L: forced=False
        else:
            streak=0; dimmed=forced=False
        if a and L:
            fb+=1
            if inwin: wb+=1
            elif t<w0: dayt+=1
            else: aft+=1
        if a and L and not forced:
            fa+=1
            if inwin: wa+=1
        if forced:
            if at(TV,t) in ("on","playing"): utv+=1
            if any(at(x,t)=="playing" for x in SONOS): uso+=1
            if at(FP300,t)=="on": ufp+=1
    rows.append((date,w0.strftime("%H:%M"),fb,wb,wa,dayt,aft,ndim,noff,ncx))
    for k,v in dict(fb=fb,fa=fa,wb=wb,wa=wa,day=dayt,aft=aft,dim=ndim,off=noff,cx=ncx,utv=utv,uso=uso,ufp=ufp).items(): T[k]+=v
    T['n']+=1
print("empty-but-lit minutes, single midnight-aligned grid")
print(f"{'day':11s}{'win':>7s}{'FULLDAY':>9s}{'in-win':>8s}{'in-win AFTER':>14s}{'daytime':>9s}{'>23:00':>8s}{'dims':>6s}{'offs':>6s}{'cancels':>9s}")
for r in rows: print(f"{str(r[0]):11s}{r[1]:>7s}{r[2]:>9d}{r[3]:>8d}{r[4]:>14d}{r[5]:>9d}{r[6]:>8d}{r[7]:>6d}{r[8]:>6d}{r[9]:>9d}")
print(f"{'TOTAL':11s}{'':>7s}{T['fb']:>9d}{T['wb']:>8d}{T['wa']:>14d}{T['day']:>9d}{T['aft']:>8d}{T['dim']:>6d}{T['off']:>6d}{T['cx']:>9d}")
n=max(1,T['n'])
print(f"\nin-window empty-but-lit: {T['wb']} -> {T['wa']} min  ({round(T['wb']/n)} -> {round(T['wa']/n)} min/day, -{round(100*(T['wb']-T['wa'])/max(1,T['wb']))}%)")
print(f"ownership: in-window {T['wb']}/{T['fb']} = {round(100*T['wb']/max(1,T['fb']))}% of all empty-but-lit; daytime {T['day']}; after 23:00 {T['aft']} (B's grace)")
print(f"residual explained: {T['off']} auto-offs x {OFF_MIN} min arming grace = {T['off']*OFF_MIN} of the {T['wa']} remaining minutes")
print("\nSAFETY (minutes sim held lamps OFF while an occupancy signal was active):")
print(f"  TV on/playing   : {T['utv']}  (MUST be 0)")
print(f"  Sonos playing   : {T['uso']}  (MUST be 0)")
print(f"  FP300 presence  : {T['ufp']}  (MUST be 0)")
