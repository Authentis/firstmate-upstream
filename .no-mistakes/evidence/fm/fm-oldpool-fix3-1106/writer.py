from drive import *
import time
for old in [False,True]:
 c=setup('writer-'+('old' if old else 'current'),old);d,h,pr,wt,env,lease=c
 # A real non-tmux process owns the worktree cwd. It is intentionally idle
 # until teardown returns, to prove absence of lsof cannot stand in for shutdown.
 worker=subprocess.Popen(['python3','-c','import time; time.sleep(120)'],cwd=wt,env=env)
 try:
  p=run(c,True)
  assert p.returncode!=0
  assert 'lsof is unavailable' in p.stdout
  assert worker.poll() is None
  assert (h/'state/task-x1.meta').exists()
  assert (wt/'.claude/settings.local.json').exists()
  assert cmd(['git','branch','--show-current'],wt,env).stdout.strip()=='fm/task-x1'
  (wt/'late-worker.txt').write_text('work still writable and retained\n')
  with open(E/(d.name+'.log'),'a') as f:f.write('Independent check: non-tmux worker remains alive; branch, generated hooks and task record retained; subsequent user file preserved.\n')
 finally:
  worker.terminate(); worker.wait(timeout=10)
