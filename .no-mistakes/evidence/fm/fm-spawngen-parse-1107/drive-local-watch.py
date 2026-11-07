import os, pathlib, subprocess, time, signal, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6T9TGZV54Y99W0ZP9ZZ1BN0')
lab=root/'.fm-spawn-gen-live'
lab.mkdir()
results=[]
url='https://gitlab.example.invalid/group/project/-/merge_requests/1'
head='0123456789abcdef0123456789abcdef01234567'
base=f'kind=ship\nmode=no-mistakes\npr={url}\npr_head={head}\n'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','HERDR_ENV','HERDR_SESSION','HERDR_PANE_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env.update(FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(root),HOME=str(lab),XDG_CONFIG_HOME=str(lab/'config'),FM_BACKEND='tmux',TMUX=str(lab/'no-server')+',0,0',FM_CHECK_INTERVAL='0',FM_POLL='0.1',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0',GH_CONFIG_DIR=str(lab/'config'/'gh'),GH_TOKEN='',GITHUB_TOKEN='',TMPDIR=str(lab/'tmp'))
try:
 subprocess.run(['bin/fm-lab-home.sh','create',str(lab)],check=True,env=env)
 (lab/'tmp').mkdir()
 for name,tail,accepted in [('control','',True),('spawn-gen','spawn_gen=3\n',True),('unknown-tail','spawn_gen=3\nevil=1\n',False),('duplicate-pr',f'spawn_gen=3\npr={url}\n',False)]:
  state=lab/'state'
  for p in state.iterdir():
   if p.is_dir(): shutil.rmtree(p)
   else: p.unlink()
  meta=state/'task-a.meta'
  meta.write_text(base)
  arm='source bin/fm-pr-lib.sh; fm_pr_poll_prepare "$FM_HOME/state" task-a gitlab "$1" gitlab.example.invalid group/project 1 "$PWD/bin/fm-pr-poll.sh" && fm_pr_poll_publish_prepared'
  subprocess.run(['bash','-c',arm,'bash',url],env=env,check=True)
  # Mutate the existing task record as a relaunch does; keep the poll generation.
  meta.write_text(base+tail)
  shutil.copyfile(meta,evidence/(name+'.meta'))
  out=open(evidence/(name+'.watch.stdout'),'w'); err=open(evidence/(name+'.watch.stderr'),'w')
  proc=subprocess.Popen(['bin/fm-watch.sh'],env=env,stdout=out,stderr=err,start_new_session=True)
  observed=False
  try:
   deadline=time.monotonic()+20
   while time.monotonic()<deadline:
    if accepted and (state/'.last-check').exists():
     observed=True; time.sleep(.3); break
    if proc.poll() is not None: break
    time.sleep(.05)
   running=proc.poll() is None
  finally:
   if proc.poll() is None: proc.terminate()
   try: rc=proc.wait(timeout=8)
   except subprocess.TimeoutExpired:
    os.killpg(proc.pid,signal.SIGKILL); rc=proc.wait()
   # Stop and await any remaining non-detached children in the owned group.
   try: os.killpg(proc.pid,signal.SIGTERM)
   except ProcessLookupError: pass
   out.close();err.close()
  stdout=(evidence/(name+'.watch.stdout')).read_text()
  stderr=(evidence/(name+'.watch.stderr')).read_text()
  rejected='rejected unauthenticated state checks' in stdout
  ok=(observed and running and not rejected) if accepted else (rc==0 and rejected)
  # Retain the product's durable wake records, if any.
  for p in state.iterdir():
   if p.is_file() and ('wake' in p.name or p.name=='.last-check'):
    shutil.copyfile(p,evidence/(name+'.'+p.name.replace('/','_')))
  result=dict(scenario=name,metadata=base+tail,expected='authenticated poll remains accepted without false rejection wake' if accepted else 'reject unsafe poll and surface rejection wake',observed_check_cycle=observed,running_after_cycle=running,watcher_exit=rc,stdout=stdout,stderr=stderr,result='pass' if ok else 'fail')
  results.append(result)
  print(json.dumps(result),flush=True)
finally:
 shutil.rmtree(lab)
 (evidence/'local-watch-results.json').write_text(json.dumps(results,indent=2)+'\n')
assert len(results)==4 and all(r['result']=='pass' for r in results)
