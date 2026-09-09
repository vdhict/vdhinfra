import json,datetime,sys
from collections import defaultdict,deque
sys.path.insert(0,'/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/2ac34ba5-b5fe-4aff-880a-a3a46c85be6f/scratchpad')
from sun import sunpos
S='/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/2ac34ba5-b5fe-4aff-880a-a3a46c85be6f/scratchpad'
TZ=datetime.timezone(datetime.timedelta(hours=2))
def load(f):
    out=[]
    for e in json.load(open(S+'/'+f))[0]:
        try: v=float(e['state'])
        except: continue
        out.append((datetime.datetime.fromisoformat((e.get('last_changed') or e.get('last_updated')).replace('Z','+00:00')),v))
    out.sort(); return out
pv=load('pv.json')
occ=[]
for e in json.load(open(S+'/binary_sensor_kantoor_bezet.json'))[0]:
    occ.append((datetime.datetime.fromisoformat((e.get('last_changed') or e.get('last_updated')).replace('Z','+00:00')),e['state']=='on'))
occ.sort()
def occ_at(t):
    v=False
    for ts,s in occ:
        if ts<=t: v=s
        else: break
    return v
def roll(rows,W):
    out={};dq=deque();s=0.0
    for t,v in rows:
        dq.append((t,v)); s+=v
        while dq and (t-dq[0][0]).total_seconds()>W*60: s-=dq.popleft()[1]
        out[t]=s/len(dq)
    return out
R15=roll(pv,15); R45=roll(pv,45)
AZ_LO,AZ_HI,EL_MIN=120,245,12
def inwin(t):
    el,az=sunpos(t); return el>EL_MIN and AZ_LO<=az<=AZ_HI
def run(HI,LOW,MINGAP,presence_reopen=True,verbose=True):
    byday=defaultdict(list); tot=0; days=0
    for t,v in pv: byday[t.astimezone(TZ).date()].append(t)
    for d in sorted(byday):
        pos='open'; mv=0; last=None; log=[]
        for t in byday[d]:
            want=None
            if inwin(t):
                if R15[t]>=HI: want='closed'
                elif R45[t]<=LOW and (occ_at(t) or not presence_reopen): want='open'
            else:
                if pos=='closed': want='open'
            if want is None or want==pos: continue
            if last and (t-last).total_seconds()<MINGAP*60 and inwin(t): continue
            pos=want; mv+=1; last=t; log.append((t,want))
        tot+=mv; days+=1
        if verbose:
            print(f'  {d} {mv:2} moves  '+'  '.join(f'{t.astimezone(TZ).strftime("%H:%M")}->{w}(az{sunpos(t)[1]:.0f})' for t,w in log))
    return tot/days
if __name__=='__main__':
    for HI,LOW,MG in ((1500,700,45),(1500,700,60),(1800,700,45),(1500,900,45)):
        print(f'=== HI(15min mean)={HI}W  LOW(45min mean)={LOW}W  mingap={MG}min  presence-gated reopen ===')
        a=run(HI,LOW,MG)
        print(f'  --> mean {a:.2f} motor moves/day\n')
    print('=== same but WITHOUT presence gating on reopen (control) ===')
    a=run(1500,700,45,presence_reopen=False)
    print(f'  --> mean {a:.2f} motor moves/day')
