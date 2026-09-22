import yaml,json,subprocess,re,sys,ast
Y='/Users/sheijden/Code/homelab-migration/vdhinfra/ops/evidence/chg-2026-09-09-006/kantoor-screen-zonwering.v2.yaml'
A=yaml.safe_load(open(Y))[0]
T=open('/Users/sheijden/Code/homelab-migration/config/hasskey').read().strip()
def render(tpl):
    r=subprocess.run(['curl','-sS','-X','POST','-H',f'Authorization: Bearer {T}','-H','Content-Type: application/json',
        'http://172.16.2.237:8123/api/template','-d',json.dumps({'template':tpl})],capture_output=True,text=True)
    return r.stdout.strip()
def lit(v):
    return repr(v) if not isinstance(v,bool) else ('true' if v else 'false')
def conv(s):
    s=s.strip()
    if s in ('True','False'): return s=='True'
    try: return float(s)
    except: return s
VARS=A['actions'][0]['variables']
def evalvars(subst={}, override={}, nowshift=None):
    ctx={}
    for k,tpl in VARS.items():
        if k in override: ctx[k]=override[k]; continue
        t=tpl
        for a,b in subst.items(): t=t.replace(a,b)
        if nowshift and k=='wind_age': t=t.replace('now()',f'(now() + timedelta(minutes={nowshift}))')
        pre=''.join(f'{{% set {n} = {lit(v)} %}}' for n,v in ctx.items())
        out=render(pre+t)
        if out.startswith('{') or 'Error' in out or 'error' in out.lower(): ctx[k]='ERR:'+out[:160]
        else: ctx[k]=conv(out)
    return ctx
GUARDS=[(i,s['if'][0]['value_template'],s) for i,s in enumerate(A['actions'][1:]) ]
def guards(ctx,trig='tick'):
    pre=''.join(f'{{% set {n} = {lit(v)} %}}' for n,v in ctx.items() if not str(v).startswith('ERR'))+f"{{% set trigger = {{'id':'{trig}'}} %}}"
    return [render(pre+g).strip() for _,g,_ in GUARDS]
names=['0 extern_open','1 wind_retract','2 evening_reset','3 auto_off','4 interlock','5 close','6 open_dull','7 open_edge']
def show(tag,ctx,trig='tick'):
    g=guards(ctx,trig); first=next((names[i] for i,x in enumerate(g) if x=='True'),'none -> run ends')
    print(f'### {tag}\n  vars: '+', '.join(f'{k}={v}' for k,v in ctx.items()))
    print('  guards: '+' '.join(f'[{n.split()[1]}={x}]' for n,x in zip(names,g)))
    print('  FIRST TRUE GUARD (terminates via stop): '+first)
if __name__=='__main__':
    live=evalvars(); show('LIVE now',live)
    show('NEG helper 15m+45m missing', evalvars({'sensor.kantoor_zon_pv_15m':'sensor.kantoor_zon_pv_15m_missing','sensor.kantoor_zon_pv_45m':'sensor.kantoor_zon_pv_45m_missing'}))
    show('NEG wind entity missing', evalvars({'sensor.openweathermap_windsnelheid':'sensor.openweathermap_windsnelheid_missing'}))
    show('NEG wind stale (+200 min on last_reported)', evalvars(nowshift=200))
    show('NEG gust entity missing', evalvars({'sensor.openweathermap_windvlaag_snelheid':'sensor.gust_missing'}))
    show('NEG cover.screen missing', evalvars({'cover.screen':'cover.screen_missing'}))
    show('NEG handmatig helper missing (pre-install state)', evalvars({'input_boolean.kantoor_screen_handmatig':'input_boolean.kantoor_screen_handmatig'}))
    # scenario renders: same templates, key inputs overridden, derived vars recomputed by HA
    base=dict(az=180.0,el=35.0,pv15=2100.0,pv45=1500.0,wind=10.0,wind_age=8.0,gust=0.0,bezet=True,auto=True,auto_dicht=False,hold=False,cur='open',since=60.0)
    def sc(tag,trig='tick',**kw):
        o=dict(base); o.update(kw); show(tag,evalvars(override=o),trig)
    sc('SCN sunny in beam, open -> expect 5 close')
    sc('SCN sunny but pv15=1999 -> expect none', pv15=1999.0)
    sc('SCN sunny but hold (manually re-opened) -> expect none', hold=True)
    sc('SCN sunny, wind 38 -> expect none (marginal)', wind=38.0)
    sc('SCN sunny, gust 50 -> expect none', gust=50.0)
    sc('SCN sunny, since 30 -> expect 4 interlock', since=30.0)
    sc('SCN auto off -> expect 3', auto=False)
    sc('SCN ours closed, dull 650, occupied, since 90 -> expect none (dwell)', cur='closed',auto_dicht=True,pv45=650.0,pv15=400.0,since=90.0)
    sc('SCN ours closed, dull 650, occupied, since 125 -> expect 6', cur='closed',auto_dicht=True,pv45=650.0,pv15=400.0,since=125.0)
    sc('SCN ours closed, pv45 missing(-1), occupied -> expect none', cur='closed',auto_dicht=True,pv45=-1.0,pv15=-1.0,since=200.0)
    sc('SCN ours closed, az 250 el 15 -> expect 7', cur='closed',auto_dicht=True,az=250.0,el=15.0,since=200.0)
    sc('SCN user closed (not ours), az 250 -> expect none', cur='closed',auto_dicht=False,az=250.0,el=15.0,since=200.0)
    sc('SCN wind 46, closed by user -> expect 2', cur='closed',wind=46.0)
    sc('SCN gust 60, closed by schedule at dusk el 3 -> expect 2', cur='closed',gust=60.0,el=3.0,az=265.0)
    sc('SCN stale wind, closed by USER -> expect none', cur='closed',wind_age=200.0)
    sc('SCN stale wind, closed by US -> expect 2', cur='closed',wind_age=200.0,auto_dicht=True)
    sc('SCN dusk el 5, ours still flagged -> expect 1 reset', cur='closed',auto_dicht=True,el=5.0,az=262.0)
    sc('SCN dusk el 5, stale wind, ours flagged -> expect 1 reset BEFORE 2', cur='closed',auto_dicht=True,el=5.0,az=262.0,wind_age=300.0)
    sc('SCN extern open of ours -> expect 0', trig='extern_open', cur='open',auto_dicht=True,since=0.0)
    sc('SCN extern open, not ours -> expect 0 (inner no-op, stop)', trig='extern_open', cur='open',auto_dicht=False,since=0.0)
    sc('SCN auto off + gust 65 + closed -> expect 2 (wind ignores auto)', cur='closed',gust=65.0,auto=False)
    sc('SCN auto off + ours flagged at dusk -> expect 1 (reset not blocked by auto off)', cur='closed',auto_dicht=True,auto=False,el=4.0,az=260.0)
