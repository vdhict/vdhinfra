import yaml,re,json,subprocess,sys
SCR="/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/067296ef-a629-43fb-af0a-d1c37698e019/scratchpad"
B={a['id']:a for a in yaml.safe_load(open(SCR+"/automations.yaml"))}['1753005600008']
AC=[c for c in B['conditions'] if c.get('condition')=='template'][0]['value_template']
AC=re.sub(r'\s+',' ',AC).strip()
inner=AC[2:-2].strip()  # strip {{ }}
# structure-preserving substitution: entity lookups -> literal state map
h=re.sub(r"is_state\('([^']+)','([^']+)'\)", r"(ST['\1'] == '\2')", inner)
h=re.sub(r"states\('([^']+)'\)", r"ST['\1']", h)
assert 'states(' not in h and 'is_state(' not in h, h
BASE={"binary_sensor.presence_sensor_fp2_f08e_presence_sensor_3":"off",
      "binary_sensor.presence_woonkamer":"off",
      "media_player.tv_woonkamer_2":"off",
      "media_player.woonkamer":"idle",
      "media_player.woonkamer_platenspeler":"idle",
      "media_player.keuken":"idle",
      "media_player.bar_2":"idle"}
def render(st):
    tpl="{%% set ST = %s %%}{{ %s }}"%(json.dumps(st),h)
    p=subprocess.run([SCR+"/hatpl.sh"],input=tpl,capture_output=True,text=True)
    return p.stdout.strip() or p.stderr.strip()
print("harness expr:",h[:110],"...\n")
cases=[("BASELINE all quiet, room empty",{},"True")]
for v in ["on","playing"]:
    cases.append((f"N1 TV tv_woonkamer_2={v} (presence OFF)",{"media_player.tv_woonkamer_2":v},"False"))
for mp in ["media_player.woonkamer","media_player.woonkamer_platenspeler","media_player.keuken","media_player.bar_2"]:
    cases.append((f"N2 Sonos {mp}=playing (presence OFF)",{mp:"playing"},"False"))
cases.append(("presence FP2 zone3=on",{"binary_sensor.presence_sensor_fp2_f08e_presence_sensor_3":"on"},"False"))
cases.append(("presence FP300 woonkamer=on",{"binary_sensor.presence_woonkamer":"on"},"False"))
cases.append(("FP2 zone3 unavailable (fail-safe)",{"binary_sensor.presence_sensor_fp2_f08e_presence_sensor_3":"unavailable"},"False"))
cases.append(("FP300 unavailable (fail-safe)",{"binary_sensor.presence_woonkamer":"unavailable"},"False"))
cases.append(("N2b Sonos paused/idle must NOT block",{"media_player.woonkamer":"paused","media_player.bar_2":"idle"},"True"))
ok=True
for name,ov,exp in cases:
    st=dict(BASE); st.update(ov); got=render(st)
    good = got==exp
    ok &= good
    print(f"{'PASS' if good else 'FAIL'}  {name:52s} -> {got:6s} (expect {exp})")
print("\nALL PASS" if ok else "\nSOME FAILED"); sys.exit(0 if ok else 1)
