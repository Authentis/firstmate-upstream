import os, pathlib, subprocess as sp, json, shutil, sys
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M66J43JFVBFMC5S2DQNZTSTE'); BASE=ROOT/'.live-teardown'
BASE.mkdir(exist_ok=True)
results=[]
def run(args,cwd=None,env=None,ok=True):
 p=sp.run([str(x) for x in args],cwd=cwd or ROOT,env=env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=60)
 if ok and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}')
 return p
for scenario in sys.argv[1:]:
 case=BASE/scenario; case.mkdir(); lab=case/'home'
 env=os.environ.copy()
 for k in list(env):
  if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','TREEHOUSE_ROOT']: env.pop(k,None)
 env.update(FM_HOME=str(lab),TREEHOUSE_ROOT=str(case/'pool'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
 log=[]; socket=E/'live-tmux.sock'
 def cmd(args,cwd=None,ok=True):
  p=run(args,cwd,env,ok); log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n'); return p
 try:
  cmd(['bin/fm-lab-home.sh','create',lab]); (lab/'config/supervision-host').touch(); (lab/'state/.last-watcher-beat').touch()
  # Prevent any external forge or pipeline reads. These boundaries are NOT real forge validation.
  tools=case/'tools'; tools.mkdir()
  for name in ['gh','gh-axi','no-mistakes']:
   f=tools/name; f.write_text('#!/bin/sh\nexit 1\n'); f.chmod(0o755)
  env['PATH']=str(tools)+':'+env['PATH']
  origin=case/'origin.git'; project=case/'project'
  cmd(['git','init','-q','--bare','--initial-branch=main',origin]); cmd(['git','clone','-q',origin,project])
  (project/'README').write_text('seed\n'); cmd(['git','add','README'],project); cmd(['git','commit','-qm','seed'],project); cmd(['git','push','-qu','origin','main'],project)
  allocation=json.loads(next(line for line in cmd(['treehouse','get','--lease','--json','--no-fetch','-b','fm/lab-lane'],project).stdout.splitlines() if line.startswith('{')))
  log.append('allocation='+repr(allocation)+'\n')
  wt=pathlib.Path(allocation['path']); lease=allocation['lease_id']; head=cmd(['git','rev-parse','HEAD'],wt).stdout.strip()
  cmd(['git','push','-q','origin','fm/lab-lane'],wt)
  cmd(['tmux','-f','/dev/null','-S',socket,'new-session','-d','-s','lab','-n','unrelated','sleep 300'])
  cmd(['tmux','-S',socket,'new-window','-d','-t','lab','-n','fm-lab-lane','sleep 300'])
  cmd(['tmux','-S',socket,'set-option','-w','-t','lab:fm-lab-lane','@fm_task_id','lab-lane'])
  cmd(['tmux','-S',socket,'set-option','-w','-t','lab:fm-lab-lane','@fm_spawn_gen','live-lab-gen'])
  env['TMUX']=str(socket)+',0,0'
  meta=lab/'state/lab-lane.meta'
  meta.write_text(f'window=lab:fm-lab-lane\nendpoint_task_id=lab-lane\nworktree={wt}\nproject={project}\nkind=ship\nmode=no-mistakes\nspawn_gen=live-lab-gen\nlease_id={lease}\n')
  if scenario.startswith('gone'):
   env['TREEHOUSE_ROOT']=str(case/'empty-pool'); (case/'empty-pool').mkdir()
  elif scenario.startswith('lease-gone'):
   # Release with the real consumer, then reattach the preserved clean branch.
   cmd(['treehouse','return','--if-lease-id',lease,wt],project)
   cmd(['git','checkout','-q','fm/lab-lane'],wt)
  elif scenario=='foreign-lease':
   cmd(['treehouse','return','--if-lease-id',lease,wt],project)
   cmd(['treehouse','lease','1','--json'],project)
  if 'dirty' in scenario: (wt/'precious.txt').write_text('must survive\n')
  if 'unpushed' in scenario:
   (wt/'precious.txt').write_text('unlanded work\n'); cmd(['git','add','precious.txt'],wt); cmd(['git','commit','-qm','unlanded'],wt)
  if scenario=='gone-missing': shutil.move(wt,str(wt)+'-moved')
  if scenario=='gone-backup-blocked': (lab/'data/bundles').write_text('block backup directory creation\n')
  cmd(['treehouse','status','--json'],project)
  before=cmd(['git','rev-parse','HEAD'],wt,False).stdout.strip() if wt.exists() else None
  p=cmd(['bin/fm-teardown.sh','lab-lane']+(['--force'] if 'force' in scenario else []),ok=False)
  refuse=any(x in scenario for x in ['dirty','unpushed','foreign','missing','backup-blocked'])
  assert p.returncode==(1 if refuse else 0), f'unexpected teardown code {p.returncode}'
  assert meta.exists()==refuse, 'wrong metadata retention'
  assert cmd(['tmux','-S',socket,'has-session','-t','lab']).returncode==0
  assert cmd(['tmux','-S',socket,'list-windows','-t','lab','-F','#{window_name}']).stdout.splitlines().count('unrelated')==1
  bundles=list((lab/'data/bundles').glob('*.bundle')) if (lab/'data/bundles').is_dir() else []
  if not refuse:
   assert len(bundles)==1, 'missing backup'
   cmd(['git','bundle','verify',bundles[0]],project)
   assert head in cmd(['git','bundle','list-heads',bundles[0]],project).stdout
  else: assert not bundles, 'refusal created backup'
  if before:
   assert cmd(['git','rev-parse','HEAD'],wt).stdout.strip()==before
   if scenario!='foreign-lease': assert cmd(['git','symbolic-ref','--short','HEAD'],wt).stdout.strip()=='fm/lab-lane'
  if 'dirty' in scenario: assert (wt/'precious.txt').read_text()=='must survive\n'
  log.append('OBSERVED: record '+('retained; refusal preserved work' if refuse else 'removed; verified backup; branch and copy preserved')+'; unrelated private tmux window survived.\n')
  results.append(dict(name=scenario,result='pass'))
 except Exception as e:
  log.append('ERROR: '+str(e)+'\n'); results.append(dict(name=scenario,result='fail',error=str(e)))
 finally:
  run(['tmux','-S',socket,'kill-server'],env=env,ok=False)
  socket.unlink(missing_ok=True)
  (E/(scenario+'.log')).write_text(''.join(log)); shutil.rmtree(case)
(E/'local-results.json').write_text(json.dumps(results,indent=2)); BASE.rmdir()
print(json.dumps(results,indent=2))
sys.exit(1 if any(r['result']=='fail' for r in results) else 0)
