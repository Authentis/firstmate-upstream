import os, sys, json, subprocess as sp, pathlib as P, time, signal, fcntl, traceback
ROOT=P.Path.cwd(); E=P.Path('~/.no-mistakes/evidence/01M6RAYB5N0KERA06ATB89TSR3'); BASE=ROOT/'.live-validation/cases'; BASE.mkdir(parents=True,exist_ok=True)
results=[]
class Case:
 def __init__(self,name,old=False,lsof=True):
  self.name=name; self.d=BASE/name; self.d.mkdir(); self.log=open(E/(name+'.log'),'w',buffering=1); self.children=[]; self.server=False
  self.env=os.environ.copy()
  for key in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TMUX','TREEHOUSE_ROOT']:
   self.env.pop(key,None)
  for p in ['home','tmp']: (self.d/p).mkdir()
  self.env.update(HOME=str(self.d/'home'),TMPDIR=str(self.d/'tmp'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=str(self.d/'gitconfig'),TREEHOUSE_ROOT=str(self.d/'pools'),FM_HOME=str(self.d/'fmhome'))
  if lsof: self.env['PATH']=str(ROOT/'.live-validation/tools/extracted/usr/bin')+':'+self.env['PATH']
  self.run(['git','config','--global','user.name','Lab']); self.run(['git','config','--global','user.email','lab@example.invalid'])
  self.run([str(ROOT/'bin/fm-lab-home.sh'),'create',str(self.d/'fmhome')]); self.fm=self.d/'fmhome'; self.meta=self.fm/'state/task-x1.meta'
  self.run(['git','init','-q','--bare','--initial-branch=main',str(self.d/'origin.git')]); self.proj=self.d/'project'
  self.run(['git','clone','-q',str(self.d/'origin.git'),str(self.proj)])
  (self.proj/'tracked.txt').write_text('baseline\n'); self.git('add','.'); self.git('commit','-qm','baseline'); self.git('push','-q','origin','main')
  self.lease=json.loads(self.run(['treehouse','get','--lease','--json','--no-fetch','-b','fm/task-x1'],cwd=self.proj)); self.wt=P.Path(self.lease['path']); self.pool=self.wt.parent.parent
  (self.wt/'.claude').mkdir(); (self.wt/'.claude/settings.local.json').write_text('{}\n')
  self.meta.write_text(f'window=lab:fm-task-x1\nendpoint_task_id=task-x1\nworktree={self.wt}\nproject={self.proj}\nkind=ship\nmode=no-mistakes\nspawn_gen=live-lab\nlease_id={self.lease["lease_id"]}\n')
  (self.fm/'state/.last-watcher-beat').touch()
  self.run(['tmux','-S',str(ROOT/'.lv-socket'),'new-session','-d','-s','lab','-n','keep','sleep 1000']); self.server=True; self.env['TMUX']=str(ROOT/'.lv-socket')+',0,0'
  if old:
   self.run(['git','clone','-q','--bare',str(self.d/'origin.git'),str(self.d/'rewritten.git')])
   self.git('config','--global','url.'+str(self.d/'rewritten.git')+'.insteadOf',str(self.d/'origin.git'))
   assert json.loads(self.run(['treehouse','status','--json'],cwd=self.proj))==[], 'rewrite must select a different current pool'
 def run(self,args,cwd=None,ok=True):
  self.log.write('$ '+ ' '.join(map(str,args))+'\n'); p=sp.run(list(map(str,args)),cwd=cwd or ROOT,env=self.env,text=True,stdout=sp.PIPE,stderr=sp.PIPE,timeout=120)
  self.log.write(p.stdout+p.stderr+f'[exit {p.returncode}]\n')
  if ok and p.returncode: raise RuntimeError(f'command failed {args}: {p.stderr}')
  return p.stdout if ok else p
 def git(self,*args,wt=False): return self.run(['git','-C',str(self.wt if wt else self.proj),*args])
 def teardown(self,force=False): return self.run([str(ROOT/'bin/fm-teardown.sh'),'task-x1']+(['--force'] if force else []),ok=False)
 def state(self): return json.loads((self.pool/'treehouse-state.json').read_text())
 def preserved(self,path=None,content=None,branch='fm/task-x1'):
  assert self.meta.exists(),'record was removed'
  assert self.git('symbolic-ref','--short','HEAD',wt=True).strip()==branch,'branch changed'
  assert (self.wt/'.claude/settings.local.json').read_text()=='{}\n','generated hook changed'
  state=self.state(); row=next(w for w in state['worktrees'] if w['path']==str(self.wt)); assert row['lease_id']==self.lease['lease_id'] and row['leased'],'lease changed'
  if path: assert (self.wt/path).read_text()==content,'work lost'
  self.log.write('OBSERVED: record, branch, hook, lease and tested work preserved.\n')
 def worker(self,late=False):
  ready=self.d/'worker-ready'
  script='import os,signal,time,pathlib\n'
  script+=('def stop(s,f):\n pathlib.Path("late-work.txt").write_text("work written during shutdown\\n")\n raise SystemExit(0)\nsignal.signal(signal.SIGTERM,stop)\n' if late else '')
  script+=f'pathlib.Path({str(ready)!r}).touch()\nwhile True: time.sleep(0.1)\n'
  p=sp.Popen([sys.executable,'-c',script],cwd=self.wt,env=self.env,start_new_session=True,stdout=self.log,stderr=self.log); self.children.append(p)
  end=time.monotonic()+5
  while not ready.exists() and time.monotonic()<end: time.sleep(.02)
  assert ready.exists(); return p
 def cleanup(self):
  for p in self.children:
   if p.poll() is None:
    try: os.killpg(p.pid,signal.SIGCONT); os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError: pass
   try:p.wait(timeout=10)
   except Exception: pass
  if self.server:self.run(['tmux','-S',str(ROOT/'.lv-socket'),'kill-server'],ok=False)
  self.log.close()
def scenario(name,old,fn,lsof=True):
 c=None
 try:
  c=Case(name,old,lsof); fn(c); results.append({'name':name,'result':'pass','evidence':str(E/(name+'.log'))}); print('PASS',name,flush=True)
 except Exception as e:
  if c:c.log.write(traceback.format_exc())
  results.append({'name':name,'result':'fail','error':str(e),'evidence':str(E/(name+'.log'))}); print('FAIL',name,str(e),flush=True)
 finally:
  if c:c.cleanup()
  (E/'live-results.json').write_text(json.dumps(results,indent=2))
def clean(c,force=False):
 p=c.teardown(force); assert p.returncode==0,p.stdout+p.stderr
 assert not c.meta.exists(); row=next(w for w in c.state()['worktrees'] if w['path']==str(c.wt)); assert not row.get('leased',False)
 assert not c.git('status','--porcelain',wt=True).strip()
 bundles=list((c.fm/'data').rglob('*.bundle'))
 for bundle in bundles:c.run(['git','bundle','verify',str(bundle)],cwd=c.proj)
 if 'old' in c.name:assert bundles,'old-pool bundle missing'
 c.log.write('OBSERVED: teardown succeeded, record removed, slot available and clean; old-pool bundle verified when applicable.\n')
def dirty(c,kind,force):
 path={'tracked':'tracked.txt','untracked':'notes.txt','claude':'.claude/precious-work.md'}[kind]; content='irreplaceable uncommitted work\n'; (c.wt/path).write_text(content)
 p=c.teardown(force); assert p.returncode!=0,'dirty teardown succeeded'; assert 'uncommitted' in p.stdout+p.stderr
 c.preserved(path,content)
def unpushed(c,force):
 (c.wt/'tracked.txt').write_text('unpushed commit\n'); c.git('add','tracked.txt',wt=True); c.git('commit','-qm','unpushed',wt=True); head=c.git('rev-parse','HEAD',wt=True)
 p=c.teardown(force); assert p.returncode!=0,'unpushed teardown succeeded'; assert c.git('rev-parse','HEAD',wt=True)==head; c.preserved('tracked.txt','unpushed commit\n')
def missing(c):
 assert sp.run(['bash','-c','command -v lsof'],env=c.env,stdout=sp.PIPE).returncode!=0
 worker=c.worker(); p=c.teardown(True); assert p.returncode!=0; assert 'writer shutdown cannot be verified' in p.stdout+p.stderr; assert worker.poll() is None,'worker unexpectedly killed'; c.preserved()
 c.log.write('OBSERVED: without lsof forced ship teardown refused before cleanup; real non-tmux worker remained alive.\n')
def late(c):
 worker=c.worker(True); p=c.teardown(True); assert p.returncode!=0; worker.wait(timeout=10); assert worker.returncode==0,'worker did not finish its TERM handler'; c.preserved('late-work.txt','work written during shutdown\n')
 c.log.write('OBSERVED: real lsof shutdown terminated writer; post-shutdown dirt refused cleanup and late write survived.\n')
def stale(c):
 # Keep the real allocator flock held until teardown has completed its initial read.
 lock=open(c.pool/'treehouse-state.lock','a'); fcntl.flock(lock,fcntl.LOCK_EX)
 out=open(E/'old-stale-race-teardown.log','w',buffering=1)
 p=sp.Popen([str(ROOT/'bin/fm-teardown.sh'),'task-x1'],env=c.env,stdout=out,stderr=sp.STDOUT,start_new_session=True); c.children.append(p); holder=None
 try:
  end=time.monotonic()+20
  while time.monotonic()<end:
   children=sp.run(['ps','-o','pid=,comm=','--ppid',str(p.pid)],capture_output=True,text=True).stdout
   for line in children.splitlines():
    fields=line.split()
    if len(fields)==2 and fields[1]=='perl':holder=int(fields[0]); break
   if holder:break
   assert p.poll() is None,'teardown exited before pool lock'; time.sleep(.05)
  assert holder,'no pool flock holder found'; os.kill(holder,signal.SIGSTOP); fcntl.flock(lock,fcntl.LOCK_UN); lock.close()
  # Real Treehouse, not a rewritten state fixture, returns and reallocates the lease.
  (c.wt/'.claude/settings.local.json').unlink()
  c.run(['treehouse','return','--if-lease-id',c.lease['lease_id'],str(c.wt)],cwd=c.proj)
  allocator_config=c.d/'allocator-gitconfig'; allocator_config.write_text('[user]\n name = Lab\n email = lab@example.invalid\n')
  saved_config=c.env['GIT_CONFIG_GLOBAL']; c.env['GIT_CONFIG_GLOBAL']=str(allocator_config)
  try:new=json.loads(c.run(['treehouse','get','--lease','--json','--no-fetch','-b','fm/new-holder'],cwd=c.proj))
  finally:c.env['GIT_CONFIG_GLOBAL']=saved_config
  assert new['path']==str(c.wt) and new['lease_id']!=c.lease['lease_id']
  (c.wt/'.claude').mkdir(exist_ok=True); (c.wt/'.claude/settings.local.json').write_text('new holder hook\n'); (c.wt/'new-holder.txt').write_text('new holder work\n')
  worker=c.worker(); os.kill(holder,signal.SIGCONT); p.wait(timeout=30); out.close()
  c.log.write((E/'old-stale-race-teardown.log').read_text()); assert p.returncode!=0,'stale teardown succeeded'; assert 'lease changed' in (E/'old-stale-race-teardown.log').read_text()
  assert worker.poll() is None,'stale teardown killed new writer'; assert c.meta.exists(); assert c.git('symbolic-ref','--short','HEAD',wt=True).strip()=='fm/new-holder'; assert (c.wt/'.claude/settings.local.json').read_text()=='new holder hook\n'; assert (c.wt/'new-holder.txt').read_text()=='new holder work\n'
  assert next(w for w in c.state()['worktrees'] if w['path']==str(c.wt))['lease_id']==new['lease_id']
  c.log.write('OBSERVED: actual return/re-lease raced locked reconfirmation; stale teardown refused; new holder branch, hook, work, worker and lease untouched.\n')
 finally:
  if not lock.closed:fcntl.flock(lock,fcntl.LOCK_UN);lock.close()
  if holder:
   try:os.kill(holder,signal.SIGCONT)
   except ProcessLookupError:pass
  if not out.closed:out.close()
if __name__=='__main__':
 retry='--retry-setup' in sys.argv
 if retry:
  import shutil
  previous=json.loads((E/'live-results.json').read_text())
  results.extend(r for r in previous if r['result']=='pass')
  for r in previous:
   if r['result']!='pass':shutil.rmtree(BASE/r['name'])
 for old in [False,True]:
  pool='old' if old else 'current'
  scenario(pool+'-clean-unforced',old,lambda c:clean(c))
  scenario(pool+'-clean-forced',old,lambda c:clean(c,True))
  if retry:continue
  for kind in ['tracked','untracked','claude']:
   for force in [False,True]:
    # The old-pool proof tightens the ordinary .claude allowance; current-pool forced proof does too.
    if kind=='claude' and not old and not force:continue
    scenario(pool+'-'+kind+('-forced' if force else '-unforced'),old,lambda c,k=kind,f=force:dirty(c,k,f))
  for force in [False,True]:scenario(pool+'-unpushed'+('-forced' if force else '-unforced'),old,lambda c,f=force:unpushed(c,f))
  scenario(pool+'-missing-lsof',old,missing,lsof=False)
  scenario(pool+'-late-writer',old,late)
 scenario('old-stale-race',True,stale)
 sys.exit(1 if any(r['result']!='pass' for r in results) else 0)
