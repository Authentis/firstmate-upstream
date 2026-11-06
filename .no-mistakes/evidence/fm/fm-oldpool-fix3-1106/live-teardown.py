import os, pathlib, subprocess, tempfile, shutil, json, sys, time
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('~/.no-mistakes/evidence/01M6R6HWJ6ZA7KXKPWASQ2Y2NM')
BASE=pathlib.Path(tempfile.mkdtemp(prefix='live-teardown-', dir=ROOT/'.test-tmp'))
TH=shutil.which('treehouse')
SOCKET=ROOT/'.live-socket'
server_env=dict(os.environ, HOME=str(BASE))
server_env.pop('TMUX',None)
subprocess.run(['tmux','-S',str(SOCKET),'-f','/dev/null','new-session','-d','-s','fm-lab-test','-n','control','sleep 600'],env=server_env,check=True)
log=open(EVID/'live-teardown.log','w', buffering=1)
def emit(s):
 print(s, flush=True); log.write(s+'\n')
def run(args, env, cwd=ROOT, ok=True):
 p=subprocess.run([str(a) for a in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
 emit('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'[exit '+str(p.returncode)+']')
 if ok and p.returncode: raise RuntimeError('command failed')
 return p

def setup(name, old=True):
 d=BASE/name; d.mkdir(); home=d/'home'
 run(['bin/fm-lab-home.sh','create',home],dict(os.environ))
 (d/'tools').mkdir(); (d/'tools/treehouse').symlink_to(TH)
 user=d/'user'; user.mkdir(); (d/'tmp').mkdir()
 env={k:v for k,v in os.environ.items() if k in ('LANG','TERM','NO_MISTAKES_GATE')}
 env.update(HOME=str(user),FM_HOME=str(home),PATH=str(d/'tools')+':/usr/bin:/bin',TMPDIR=str(d/'tmp'),TREEHOUSE_ROOT=str(d/'pools'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=str(d/'gitconfig'),GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMUX=str(SOCKET)+',999,0')
 run(['git','init','-q','-b','main',d/'project'],env)
 (d/'project/notes.txt').write_text('pushed base\n')
 run(['git','add','.'],env,d/'project');run(['git','commit','-qm','baseline'],env,d/'project')
 run(['git','clone','-q','--bare',d/'project',d/'origin.git'],env)
 run(['git','remote','add','origin',str(d/'origin.git')],env,d/'project')
 run(['git','fetch','-q','origin'],env,d/'project')
 lease=json.loads(run(['treehouse','get','--lease','--json','--no-fetch','-b','fm/task-x1'],env,d/'project').stdout)
 slot=pathlib.Path(lease['path']); pool=slot.parent.parent
 run(['git','push','-q','origin','fm/task-x1'],env,slot)
 (slot/'.claude').mkdir(exist_ok=True);(slot/'.claude/settings.local.json').write_text('{}\n')
 meta=home/'state/task-x1.meta'
 meta.write_text(f'window=fm-lab-test:fm-task-x1\nendpoint_task_id=task-x1\nworktree={slot}\nproject={d}/project\nkind=ship\nmode=no-mistakes\nspawn_gen=live-test-task-x1\nlease_id={lease["lease_id"]}\n')
 (home/'state/.last-watcher-beat').touch()
 if old:
  run(['git','config','--file',d/'gitconfig',f'url.file://{d}/origin.git.insteadOf',str(d/'origin.git')],env)
 run(['treehouse','status','--json'],env,d/'project')
 emit('POOL STATE BEFORE: '+(pool/'treehouse-state.json').read_text())
 return d,home,env,slot,pool,meta,lease

def drive(c, force=False):
 d,home,env,slot,pool,meta,lease=c
 return run([ROOT/'bin/fm-teardown.sh','task-x1']+(['--force'] if force else []),env,ok=False)

results=[]
def check(v, text):
 emit(('VERIFIED: ' if v else 'FAILED: ')+text)
 if not v: raise AssertionError(text)
def preserve(c, path=None, expected=None):
 d,home,env,slot,pool,meta,lease=c
 check(meta.exists(),'refusal retains task record')
 check((slot/'.claude/settings.local.json').exists(),'refusal retains generated hooks')
 check(run(['git','branch','--show-current'],env,slot).stdout.strip()=='fm/task-x1','refusal retains checked-out task branch')
 check(json.loads((pool/'treehouse-state.json').read_text())['worktrees'][0].get('lease_id')==lease['lease_id'],'refusal retains original lease')
 if path: check(path.read_text()==expected,'uncommitted content remains byte-identical')

def clean_case(old):
 c=setup(('old' if old else 'current')+'-clean',old)
 p=drive(c)
 check(p.returncode==0,'ordinary teardown succeeds without --force or a recovery/bypass flag')
 check(not c[5].exists(),'successful teardown removes live task record')
 state=json.loads((c[4]/'treehouse-state.json').read_text());emit('POOL STATE AFTER: '+json.dumps(state))
 check(not state['worktrees'][0].get('leased',False),'real Treehouse released original lease')
 check(run(['git','status','--porcelain','--untracked-files=all'],c[2],c[3]).stdout=='','returned worktree is clean')
 if old:
  bundles=list((c[1]/'data/bundles').glob('*.bundle'))
  check(bool(bundles),'old-pool teardown creates backup bundles')
  for b in bundles: run(['git','bundle','verify',b],c[2],c[3])
 results.append({'case':('old' if old else 'current')+' clean','result':'pass'})

def dirty_case(old,force,kind):
 name=f'{"old" if old else "current"}-dirty-{kind}-{force}'
 c=setup(name,old);d,home,env,slot,pool,meta,lease=c
 path=slot/('notes.txt' if kind=='tracked' else '.claude/user-work.md' if kind=='claude' else 'user-work.txt')
 expected='USER WORK MUST SURVIVE\n';path.write_text(expected)
 p=drive(c,force)
 check(p.returncode!=0,'uncommitted work refuses '+name)
 preserve(c,path,expected)
 emit('REFUSAL OUTPUT: '+p.stdout+p.stderr)
 results.append({'case':name,'result':'pass'})

def unlanded_case(old,force):
 name=f'{"old" if old else "current"}-unlanded-{force}'
 c=setup(name,old);d,home,env,slot,pool,meta,lease=c
 (slot/'unlanded.txt').write_text('not on remote\n')
 run(['git','add','unlanded.txt'],env,slot);run(['git','commit','-qm','unlanded work'],env,slot)
 head=run(['git','rev-parse','HEAD'],env,slot).stdout
 p=drive(c,force);check(p.returncode!=0,'unlanded commits refuse '+name)
 preserve(c);check(run(['git','rev-parse','HEAD'],env,slot).stdout==head,'unlanded head preserved')
 results.append({'case':name,'result':'pass'})

def race_case():
 c=setup('old-released-and-released');d,home,env,slot,pool,meta,lease=c
 # Forward all jq calls unchanged. Pause only AFTER the unlocked pool-state read,
 # letting a real Treehouse allocator return and re-lease the actual slot.
 shim=d/'tools/jq';read_event=d/'read-event';done=d/'allocator-done'
 shim.write_text('#!/usr/bin/python3\nimport subprocess,sys,pathlib,time\np=subprocess.run(["/usr/bin/jq"]+sys.argv[1:]);\nif sys.argv[-1]=='+repr(str(pool/'treehouse-state.json'))+' and not pathlib.Path('+repr(str(read_event))+').exists():\n pathlib.Path('+repr(str(read_event))+').touch()\n deadline=time.monotonic()+30\n while not pathlib.Path('+repr(str(done))+').exists() and time.monotonic()<deadline: time.sleep(.02)\nsys.exit(p.returncode)\n');shim.chmod(0o755)
 child=subprocess.Popen([str(ROOT/'bin/fm-teardown.sh'),'task-x1'],env=env,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  deadline=time.monotonic()+30
  while not read_event.exists() and child.poll() is None and time.monotonic()<deadline: time.sleep(.02)
  check(read_event.exists(),'teardown completed initial unlocked old-pool lease read')
  allocator=dict(env,GIT_CONFIG_GLOBAL='/dev/null')
  run(['treehouse','return','--force','--if-lease-id',lease['lease_id'],slot],allocator,d/'project')
  new=json.loads(run(['treehouse','get','--lease','--json','--no-fetch','-b','fm/new-holder'],allocator,d/'project').stdout)
  check(new['path']==str(slot),'real allocator reuses identical pool slot')
  check(new['lease_id']!=lease['lease_id'],'real allocator creates different lease identity')
  (slot/'.claude').mkdir(exist_ok=True);(slot/'.claude/settings.local.json').write_text('{"new-holder":true}\n')
  head=run(['git','rev-parse','HEAD'],env,slot).stdout
  done.touch();out,err=child.communicate(timeout=90)
  emit('$ fm-teardown.sh task-x1 [paused after real jq state read]\n'+out+err+'[exit '+str(child.returncode)+']')
  check(child.returncode!=0 and 'lease changed' in out+err,'locked reconfirmation refuses reassigned lease')
  check(run(['git','branch','--show-current'],env,slot).stdout.strip()=='fm/new-holder','new holder branch remains attached')
  check(run(['git','rev-parse','HEAD'],env,slot).stdout==head,'new holder HEAD unchanged')
  check((slot/'.claude/settings.local.json').read_text()=='{"new-holder":true}\n','new holder hooks byte-identical')
  check(meta.exists(),'old task record retained after reassignment refusal')
  check(json.loads((pool/'treehouse-state.json').read_text())['worktrees'][0]['lease_id']==new['lease_id'],'new holder lease remains active')
  results.append({'case':'actual old-pool return/re-lease between read and lock','result':'pass'})
 finally:
  done.touch()
  if child.poll() is None: child.terminate();child.communicate(timeout=10)

def worker_case(old):
 name=f'{"old" if old else "current"}-no-lsof-writer'
 c=setup(name,old);d,home,env,slot,pool,meta,lease=c
 check(shutil.which('lsof',path=env['PATH']) is None,'lsof genuinely absent, not mocked')
 worker=subprocess.Popen(['/usr/bin/python3','-c','import pathlib,time; pathlib.Path("worker-ready").touch(); time.sleep(300)'],env=env,cwd=slot)
 try:
  deadline=time.monotonic()+10
  while not (slot/'worker-ready').exists() and time.monotonic()<deadline: time.sleep(.02)
  # Remove the readiness file so the initial dirty-work proof really passes.
  (slot/'worker-ready').unlink()
  p=drive(c,True)
  check(p.returncode!=0 and 'writer shutdown cannot be verified' in p.stdout+p.stderr,'forced ship refuses missing writer-shutdown proof')
  check(worker.poll() is None,'actual non-tmux worker remains live, confirming missing shutdown capability')
  preserve(c)
  results.append({'case':name,'result':'pass'})
 finally:
  worker.terminate();worker.wait(timeout=10)

try:
 for old in (True,False): clean_case(old)
 race_case()
 for old in (True,False):
  for force in (False,True):
   for kind in ('tracked','untracked'): dirty_case(old,force,kind)
   if old: dirty_case(old,force,'claude')
   unlanded_case(old,force)
  worker_case(old)
 emit('ALL LIVE CASES COMPLETED: '+json.dumps(results))
finally:
 (EVID/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
 subprocess.run(['tmux','-S',str(SOCKET),'kill-server'],env=server_env)
 SOCKET.unlink(missing_ok=True)
 shutil.rmtree(BASE)
 log.close()
