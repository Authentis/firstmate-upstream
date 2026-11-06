from drive import *
import fcntl,time
c=setup('old-lock-race');d,h,pr,wt,env,lease=c
pool=wt.parent.parent
lock=open(pool/'treehouse-state.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
log=open(E/'old-lock-race.log','w')
p=subprocess.Popen([str(ROOT/'bin/fm-teardown.sh'),'task-x1'],cwd=pr,env=env,stdout=log,stderr=subprocess.STDOUT)
try:
 deadline=time.monotonic()+15
 while time.monotonic()<deadline:
  if 'confirming lease' in (E/'old-lock-race.log').read_text():break
  if p.poll() is not None:raise RuntimeError('teardown exited before pool confirmation')
  time.sleep(.05)
 else:raise RuntimeError('confirmation never reached')
 time.sleep(.5)
 # Competing allocator holds the real pool flock; perform its real conditional
 # return/get after releasing our lock, before teardown can acquire it by
 # retaining the flock in this process while writing the allocator state.
 # State mutation is synthetic scheduling input, not a fake Treehouse CLI.
 state=json.loads((pool/'treehouse-state.json').read_text())
 for row in state['worktrees']:
  if row['path']==str(wt): row['lease_id']='new-holder-lease'; row['leased']=True
 (pool/'treehouse-state.json').write_text(json.dumps(state))
 fcntl.flock(lock,fcntl.LOCK_UN);lock.close()
 rc=p.wait(timeout=30);log.close()
 assert rc!=0
 assert 'lease changed' in (E/'old-lock-race.log').read_text()
 assert (h/'state/task-x1.meta').exists()
 assert (wt/'.claude/settings.local.json').exists()
 assert cmd(['git','branch','--show-current'],wt,env).stdout.strip()=='fm/task-x1'
 with open(E/'old-lock-race.log','a') as f:f.write(f'\nexit={rc}; competing lease retained; task record, branch and hook all preserved\n')
 print((E/'old-lock-race.log').read_text())
finally:
 if p.poll() is None:p.terminate();p.wait(timeout=10)
 if not lock.closed:lock.close()
 if not log.closed:log.close()
 cmd(['tmux','-S',env['LAB_SOCKET'],'kill-server'],env=env,check=False)
 cmd(['bin/fm-lab-home.sh','teardown',h])
