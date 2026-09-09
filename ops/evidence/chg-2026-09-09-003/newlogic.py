import sys, datetime as dt, bisect
sys.path.insert(0,'/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/2ac34ba5-b5fe-4aff-880a-a3a46c85be6f/scratchpad')
sys.path.insert(0,'/Users/sheijden/Code/homelab-migration/vdhinfra/ops/evidence/chg-2026-09-09-003')
from luxlib import load, lux_series
import replay as R

T0,T1 = R.T0, R.T1
lux=[x for x in lux_series() if T0<=x[0]<=T1]
bz=load('binary_sensor.kantoor_bezet')
_,_,brh = R.replay_old(lux,bz)          # OLD lamp trajectory (open loop = reality)
bt=[t for t,_ in brh]; bv=[v for _,v in brh]
def br_old(t):
    i=bisect.bisect_right(bt,t)-1
    return bv[i] if i>=0 else 0
lt=[t for t,_ in lux]; lvv=[v for _,v in lux]
def recorded(t):
    i=bisect.bisect_right(lt,t)-1
    return lvv[i] if i>=0 else 0.0
def make_ambient_true(k):
    return lambda t: max(recorded(t)-k*br_old(t), 0.0)

def curve(a):
    return round(100*(1-min(max(a,0),600)/600)**1.2)

def replay_shipped(kappa, W=600, MININT=300, DEAD=15, BODEM=10,
                   FEL=1500, FEL_TERUG=1200, FELDWELL=900, BEZET_FOR=600):
    at = make_ambient_true(kappa)
    # event stream: lux reports + presence + /10 ticks (fel injected dynamically)
    ev=[(t,'lux') for t,_ in lux]+[(t,'bezet') for t,_ in bz]
    t=T0
    while t<=T1: ev.append((t,'tick')); t+=dt.timedelta(minutes=10)
    ev=sorted([e for e in ev if T0<=e[0]<=T1])
    on, br = False, 0
    calls, trans = [], []
    hist=[]; last_upd=None; bezet_off_since=None
    fel_since=None; fel_armed=True   # numeric_state trigger: one fire per crossing
    pending=[]
    i=0
    darkmin=0
    while i < len(ev) or pending:
        if pending and (i>=len(ev) or pending[0][0] <= ev[i][0]):
            t,kind = pending.pop(0)
        else:
            t,kind = ev[i]; i+=1
        meas = at(t) + kappa*br
        hist.append((t,meas))
        lo=t-dt.timedelta(seconds=W); num=den=0.0
        for j in range(len(hist)-1,-1,-1):
            tt,vv=hist[j]
            end = hist[j+1][0] if j+1<len(hist) else t
            if end<=lo: break
            w=(end-max(tt,lo)).total_seconds()
            if w>0: num+=vv*w; den+=w
        sm = num/den if den>0 else meas
        # numeric_state trigger 'fel': damped > 1500 for 15 min
        if sm > FEL:
            if fel_since is None: fel_since=t
            if fel_armed and (t-fel_since).total_seconds()>=FELDWELL:
                pending.append((t,'fel')); pending.sort(); fel_armed=False
        else:
            fel_since=None; fel_armed=True
        b = R.bezet_at(bz,t)
        bezet_off_since = (bezet_off_since or t) if b=='off' else None
        br_now = br if on else 0
        ambient = max(sm - 0.6*br_now, 0)
        target = max(curve(ambient), BODEM)
        sinds = 9999 if last_upd is None else (t-last_upd).total_seconds()
        mag = sinds >= MININT
        act=None; why=None
        if sm < 0:                                                    # branch 0
            pass
        elif b=='off' and bezet_off_since and (t-bezet_off_since).total_seconds()>=BEZET_FOR:
            if on: act=('off',0); why='presence'                      # branch 1
        elif b=='off':                                                # branch 2
            pass
        elif not mag:                                                 # branch 3
            pass
        elif kind=='fel' and on:                                      # branch 4
            act=('off',0); why='daylight'
        elif (not on) and ambient < FEL_TERUG:                        # branch 5
            act=('on',target); why='daylight' if kind!='bezet' else 'presence'
        elif on and abs(target-br_now)>=DEAD:                         # branch 6
            act=('on',target); why='dim'
        if act:
            calls.append((t,act[0],act[1],kind,why))
            if act[0]=='off' and on: trans.append((t,'off',why))
            if act[0]=='on' and not on: trans.append((t,'on',why))
            on = act[0]=='on'; br = act[1] if on else 0
            last_upd = t
    # dark & unlit: occupied minutes with true ambient < 400 and lamp off
    st=[]; onv=False
    tl=T0
    lampon=[]
    cur=False
    idx=0
    # rebuild lamp on/off timeline from transitions
    tr=[(T0,False)]+[(t,d=='on') for t,d,_ in trans]
    def lamp_at(t):
        s=False
        for tt,v in tr:
            if tt<=t: s=v
            else: break
        return s
    t=T0
    while t<=T1:
        if R.bezet_at(bz,t)=='on' and at(t)<400 and not lamp_at(t): darkmin+=1
        t+=dt.timedelta(minutes=1)
    return calls,trans,darkmin

if __name__=='__main__':
    for k in (0.73,1.1,2.0):
        c,tr,dm = replay_shipped(k)
        dl=sum(1 for _,_,w in tr if w=='daylight')
        print("kappa %-5s calls %2d  transitions %d  (daylight %d, presence %d)  dark&unlit %d"
              % (k,len(c),len(tr),dl,len(tr)-dl,dm))
        for t,d,w in tr: print("      ",t.strftime('%H:%M:%S'),d,w)
