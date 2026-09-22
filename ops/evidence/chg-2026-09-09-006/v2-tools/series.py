import sys,bisect,datetime
sys.path.insert(0,'/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/743312b1-6b9e-4bf4-bf26-d4504d06a737/scratchpad')
from load import *
from sun import sunpos
from collections import deque
class Step:
    def __init__(s,e,num=True):
        r=rows(e,num); s.t=[x[0] for x in r]; s.v=[x[1] for x in r]; s.raw=r
    def at(s,t):
        i=bisect.bisect_right(s.t,t)-1
        return (s.v[i], s.t[i]) if i>=0 else (None,None)
def recon(rowsx,W):  # 09-09 method: arithmetic mean of recorder rows in window
    out={};dq=deque();sm=0.0
    for t,v,_ in rowsx:
        if v is None: continue
        dq.append((t,v)); sm+=v
        while dq and (t-dq[0][0]).total_seconds()>W*60: sm-=dq.popleft()[1]
        out[t]=sm/len(dq)
    return out
def ticks(day):  # 5-min ticks local day
    t0=datetime.datetime(day.year,day.month,day.day,5,0,tzinfo=TZ)
    return [t0+datetime.timedelta(minutes=5*i) for i in range(int(16*12))]
