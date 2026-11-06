import os, subprocess as sp, pathlib, json, time, ctypes
root=pathlib.Path.cwd(); lab=root/'.live'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M6RHM2JQW9BM9XGMAER4ZDRF')
env=dict(os.environ, FM_HOME=str(lab/'home'), HOME=str(lab/'user'), TMUX=f'{lab}/s,0,0')
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:
 env.pop(k,None)
f=(evidence/'live-guards.log').open('w', buffering=1)
def run(args, expected=None):
 p=sp.run(args,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=120)
 f.write('$ '+' '.join(args)+'\n'+p.stdout+f'\nexit={p.returncode}\n')
 if expected is not None: assert p.returncode==expected, p.stdout
 return p

def refused(label, expected):
 id='gateattach12'; meta=lab/'home/state'/f'{id}.meta'; before=meta.read_bytes()
 p=run(['bin/fm-control.sh',id,'relaunch','--note',label],1)
 assert expected in p.stdout, p.stdout
 assert before==meta.read_bytes(), 'Refusal changed metadata'
 f.write('Oracle: refusal left original task metadata byte-identical.\n')

# A task may still be running beyond the current server. Use a real second private server.
other=str(lab/'s2')
try:
 run(['tmux','-S',other,'-f','/dev/null','new-session','-d','-s','other','-x','120','-y','35','-c',str(root),'bash --noprofile --norc'])
 run(['tmux','-S',other,'new-window','-d','-n','unrelated','-c',str(lab/'wtparent/gateattach12'),'sleep 300'],0)
 refused('hidden server cwd adversary','working in the recorded worktree')
finally:
 run(['tmux','-S',other,'kill-server'])

p=sp.Popen(['bash','-c','exec -a fm-gateattach12 sleep 300'],cwd=root)
try:
 time.sleep(.2); refused('task argv adversary','names the task')
finally:
 p.terminate(); p.wait()

run(['tmux','new-session','-d','-s','collision','-n','fm-gateattach12','-x','120','-y','35','-c',str(root),'bash --noprofile --norc'],0)
try: refused('same window name adversary','still in the window inventory')
finally: run(['tmux','kill-session','-t','collision'],0)

# prctl(SET_DUMPABLE,0) creates a real same-user process with an unreadable cwd.
p=sp.Popen(['python3','-c','import ctypes,time; assert ctypes.CDLL(None).prctl(4,0)==0; print("ready",flush=True); time.sleep(300)'],cwd=root,stdout=sp.PIPE,text=True)
try:
 assert p.stdout.readline().strip()=='ready'
 try: os.readlink(f'/proc/{p.pid}/cwd'); raise AssertionError('cwd unexpectedly readable')
 except PermissionError: pass
 refused('unknown hidden process adversary',f'working directory of process {p.pid} could not be read')
finally:
 p.terminate(); p.wait(); p.stdout.close()

# A replacement created before Claude trust fails must not block retry.
meta=lab/'home/state/gateattach13.meta'; original=meta.read_text(); meta.write_text(original.replace('harness=codex','harness=claude'))
before=meta.read_bytes(); trust=lab/'user/.claude.json'; trust.write_text('{')
p=run(['bin/fm-spawn.sh','--relaunch','gateattach13'],1)
assert 'trust' in p.stdout.lower(),p.stdout
assert meta.read_bytes()==before
p=run(['tmux','list-windows','-a','-F','#{session_name}:#{window_name}'],0)
assert 'fm-gateattach13' not in p.stdout
f.write('Oracle: pre-publication failure preserved metadata and removed only the unused replacement.\n')
trust.unlink(); meta.write_text(original)
p=run(['bin/fm-control.sh','gateattach13','relaunch','--note','Retry after fixing trust setup'],0)
assert 'relaunched gateattach13' in p.stdout
f.write('Oracle: retry recovered successfully.\n')
f.close()
