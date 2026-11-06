import os, pathlib, subprocess, json, shutil
ROOT=pathlib.Path.cwd(); BASE=ROOT/'.test-live-teardown'; E=pathlib.Path('~/.no-mistakes/evidence/01M6RGKRQZ9ZCNFJ28Q4WG9Y3V')
def cmd(args,cwd=None,env=None,check=True):
 p=subprocess.run(list(map(str,args)),cwd=cwd or ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}')
 return p

def setup(name,old=True):
 d=BASE/name; d.mkdir(); home=d/'home'; cmd(['bin/fm-lab-home.sh','create',home]); (home/'config/supervision-host').touch()
 env=os.environ.copy()
 for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_ROOT','TMUX']: env.pop(k,None)
 env.update(FM_HOME=str(home),TREEHOUSE_ROOT=str(d/'pools'),GIT_CONFIG_GLOBAL=str(d/'gitconfig'),GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
 (d/'gitconfig').touch(); pr=d/'project'; origin=d/'origin.git'
 cmd(['git','init','-q','--bare','--initial-branch=main',origin],env=env)
 cmd(['git','clone','-q',origin,pr],env=env)
 (pr/'tracked.txt').write_text('base\n'); cmd(['git','add','.'],pr,env); cmd(['git','commit','-qm','base'],pr,env); cmd(['git','push','-q','origin','main'],pr,env)
 cmd(['git','remote','set-head','origin','main'],pr,env)
 p=cmd(['treehouse','get','--lease','--json','--no-fetch','-b','fm/task-x1'],pr,env)
 lease=json.loads(p.stdout[p.stdout.index('{'):]); wt=pathlib.Path(lease['path'])
 if old: cmd(['git','config','--file',d/'gitconfig',f'url.file://{origin}.insteadOf',origin],env=env)
 sockdir=cmd(['bin/fm-lab-home.sh','tmux-dir',home]).stdout.strip()
 sock=sockdir+'/lab.sock'
 cmd(['tmux','-S',sock,'new-session','-d','-s','fm-lab','-n','anchor','sleep 300'],env=env)
 cmd(['tmux','-S',sock,'new-window','-t','fm-lab','-n','fm-task-x1','sleep 300'],env=env)
 env['TMUX']=sock+',1,0'
 env['LAB_SOCKET']=sock
 (home/'state/task-x1.meta').write_text(f'window=fm-lab:fm-task-x1\nendpoint_task_id=task-x1\nspawn_gen=lab-task-x1\nworktree={wt}\nproject={pr}\nkind=ship\nmode=no-mistakes\nlease_id={lease["lease_id"]}\n')
 (home/'state/.last-watcher-beat').touch()
 (wt/'.claude').mkdir(); (wt/'.claude/settings.local.json').write_text('{}\n')
 return d,home,pr,wt,env,lease

def run(case,force=False):
 d,h,pr,wt,env,lease=case
 p=cmd([ROOT/'bin/fm-teardown.sh','task-x1']+(['--force'] if force else []),pr,env,False)
 text=f'COMMAND: FM_HOME=<disposable lab> bin/fm-teardown.sh task-x1'+(' --force' if force else '')+f'\nexit={p.returncode}\n'+p.stdout
 text+='\nPOST git status:\n'+cmd(['git','status','--porcelain','--untracked-files=all'],wt,env).stdout
 text+='POST branch: '+cmd(['git','branch','--show-current'],wt,env).stdout
 text+='POST task record exists: '+str((h/'state/task-x1.meta').exists())+'\n'
 (E/(d.name+'.log')).write_text(text); print(text,flush=True)
 cmd(['tmux','-S',env['LAB_SOCKET'],'kill-server'],env=env,check=False)
 cmd(['bin/fm-lab-home.sh','teardown',h])
 return p
if __name__=='__main__':
 c=setup('old-happy-3'); p=run(c); assert p.returncode==0; assert not (c[1]/'state/task-x1.meta').exists(); print('RESULT PASS')
