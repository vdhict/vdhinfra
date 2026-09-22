import json,datetime
S='/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/743312b1-6b9e-4bf4-bf26-d4504d06a737/scratchpad'
TZ=datetime.timezone(datetime.timedelta(hours=2))
def P(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
def rows(e, num=True):
    seen={}; 
    for l in open(f'{S}/h/{e}.jsonl'):
        r=json.loads(l); t=P(r['lu'] or r['lc'])
        seen[(t,r['s'])]=r
    out=[]
    for (t,s),r in sorted(seen.items(), key=lambda x:x[0][0]):
        if num:
            try: v=float(s)
            except: v=None
        else: v=s
        out.append((t,v,r))
    # drop consecutive duplicates (slice-start synthetic rows)
    ded=[]
    for x in out:
        if ded and ded[-1][1]==x[1] and ded[-1][2]['lc']==x[2]['lc']: continue
        ded.append(x)
    return ded
