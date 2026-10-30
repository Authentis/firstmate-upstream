import os, subprocess as sp, pathlib as P, json, shutil, ssl, http.server, threading
ROOT=P.Path.cwd(); E=P.Path('~/.no-mistakes/evidence/01M66SP85FD02H77E5Y3S66BGJ'); LAB=ROOT/'.lab/a'
BASE=os.environ.copy()
for k in list(BASE):
 if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','TREEHOUSE_ROOT']: BASE.pop(k,None)
def cmd(args,env=None,cwd=None,check=True):
 r=sp.run([str(a) for a in args],env=env,cwd=cwd or ROOT,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
 if check and r.returncode: raise RuntimeError(f'{args}: {r.returncode}\n{r.stdout}')
 return r

def setup():
 if LAB.exists(): shutil.rmtree(LAB)
 cmd(['bin/fm-lab-home.sh','create',LAB])
 env=BASE.copy(); env.update(FM_HOME=str(LAB),HOME=str(LAB),XDG_CONFIG_HOME=str(LAB/'config'),TREEHOUSE_ROOT=str(LAB/'pool'),TMUX_TMPDIR=str(LAB/'t'),GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
 (LAB/'t').mkdir(); (LAB/'tools').mkdir()
 for tool in 'awk bash basename cat chmod cksum cp cut date dirname env find git grep head hostname id ln mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs jq tmux treehouse gh python3'.split():
  path=shutil.which(tool)
  if path: (LAB/'tools'/tool).symlink_to(path)
 env['PATH']=str(LAB/'tools')
 (LAB/'config/backlog-backend').write_text('manual\n'); (LAB/'state/.last-watcher-beat').touch()
 proj=LAB/'project'; origin=LAB/'origin.git'
 cmd(['git','init','-q','-b','main',proj],env)
 (proj/'base.txt').write_text('base\n'); cmd(['git','-C',proj,'add','.'],env); cmd(['git','-C',proj,'commit','-qm','baseline'],env)
 cmd(['git','clone','-q','--bare',proj,origin],env); cmd(['git','-C',proj,'remote','add','origin',str(origin)],env);cmd(['git','-C',proj,'fetch','-q','origin'],env);cmd(['git','-C',proj,'remote','set-head','origin','main'],env)
 cmd(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','lab','-n','unrelated','sleep 300'],env)
 return env,proj,origin

def teardown(env):
 cmd(['tmux','-L','fm-lab','kill-server'],env,check=False)
 shutil.rmtree(LAB)

def run_pool(name):
 env,proj,origin=setup(); log=[]
 try:
  alloc=cmd(['treehouse','get','--lease','--json','--no-fetch','-b','fm/lane'],env,proj); log+=['Acquire real Treehouse slot:',alloc.stdout]; a=json.loads(alloc.stdout.strip().splitlines()[-1]); wt=P.Path(a['path']); lease=a['lease_id']
  (wt/'feature.txt').write_text('lane work\n'); cmd(['git','-C',wt,'add','.'],env);cmd(['git','-C',wt,'commit','-qm','feature'],env)
  head=cmd(['git','-C',wt,'rev-parse','HEAD'],env).stdout.strip()
  if name!='unpushed-force': cmd(['git','-C',wt,'push','-q','origin','fm/lane'],env)
  if name.startswith('gone') or name in ['dirty-force','unpushed-force','backup-blocked']:
   env['TREEHOUSE_ROOT']=str(LAB/'empty-pool')
  elif name in ['null','null-force','foreign']:
   cmd(['treehouse','return','--if-lease-id',lease,wt],env,proj)
   cmd(['git','-C',wt,'checkout','-q','fm/lane'],env)
   if name=='foreign': log+=['Re-lease:',cmd(['treehouse','lease','1','--json'],env,proj).stdout]
  if name=='pool-unreadable':
   (LAB/'blocked').write_text('not a directory\n');env['TREEHOUSE_ROOT']=str(LAB/'blocked')
  if name=='backup-blocked': (LAB/'data/bundles').write_text('not a directory\n')
  if name=='dirty-force': (wt/'scratch.txt').write_text('do not discard\n')
  if name=='missing-copy': shutil.move(wt,str(wt)+'-saved')
  meta=LAB/'state/lane.meta';meta.write_text(f'window=lab:fm-lane\nendpoint_task_id=lane\nworktree={wt}\nproject={proj}\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-lane\nlease_id={lease}\n')
  log+=['Real pool status before teardown:',cmd(['treehouse','status','--json'],env,proj,False).stdout]
  args=['bin/fm-teardown.sh','lane'];
  if name.endswith('force'):args+=['--force']
  r=cmd(args,env,check=False);log += ['Teardown stdout/stderr:',r.stdout,f'exit={r.returncode}']
  expected=1 if name in ['dirty-force','unpushed-force','foreign','pool-unreadable','backup-blocked'] else 0
  assert r.returncode==expected
  assert meta.exists()==(expected!=0)
  bundle=LAB/'data/bundles/lane.bundle'
  if expected==0 and name!='missing-copy':
   log += ['Bundle heads:',cmd(['git','bundle','list-heads',bundle],env).stdout]; assert head in log[-1];cmd(['git','-C',proj,'bundle','verify',bundle],env)
  else: assert not bundle.exists()
  if name!='missing-copy':
   br=cmd(['git','-C',wt,'symbolic-ref','--short','HEAD'],env).stdout.strip(); assert br=='fm/lane';assert cmd(['git','-C',wt,'rev-parse','HEAD'],env).stdout.strip()==head
   log += [f'Copy retained on branch {br} at {head}']
  if name=='dirty-force':assert (wt/'scratch.txt').read_text()=='do not discard\n'
  cmd(['tmux','-L','fm-lab','has-session','-t','lab'],env);log+=['Unrelated private tmux pane survived.','Record retained.' if meta.exists() else 'Task record removed.','PASS']
 finally:
  (E/f'live-{name}.log').write_text('\n'.join(log)); teardown(env)

if __name__=='__main__':
 import sys
 for name in sys.argv[1:]:
  run_pool(name); print(name,'PASS',flush=True)
