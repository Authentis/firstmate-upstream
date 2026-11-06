import subprocess as sp,pathlib,os,signal,time,shutil
r=pathlib.Path.cwd();l=r/'.live';e=pathlib.Path('~/.no-mistakes/evidence/01M6RHM2JQW9BM9XGMAER4ZDRF')
with (e/'live-teardown.log').open('w',buffering=1) as f:
 p=sp.run(['tmux','-S',str(l/'s'),'list-panes','-a','-F','#{pane_pid}'],text=True,stdout=sp.PIPE,check=True)
 panes={int(x) for x in p.stdout.split()}; rows=sp.check_output(['ps','-A','-o','pid=','-o','ppid='],text=True)
 children={int(a):int(b) for a,b in (x.split() for x in rows.splitlines())};owned=set(panes)
 while True:
  new=owned|{p for p,pp in children.items() if pp in owned}
  if new==owned:break
  owned=new
 f.write(f'Private lab pane/process ids before teardown: {sorted(owned)}\n')
 # Capture all final terminal surfaces before stopping the private server.
 captures=[]
 windows=sp.check_output(['tmux','-S',str(l/'s'),'list-windows','-a','-F','#{session_name}:#{window_name}'],text=True).splitlines()
 for target in windows:
  captures.append('$ tmux -S <private-lab-socket> capture-pane -p -t '+target+'\n'+sp.check_output(['tmux','-S',str(l/'s'),'capture-pane','-p','-t',target],text=True))
 (e/'final-panes.log').write_text('\n'.join(captures))
 for pid in owned-panes:
  try:os.kill(pid,signal.SIGTERM)
  except ProcessLookupError:pass
 p=sp.run(['tmux','-S',str(l/'s'),'kill-server']);f.write(f'Private tmux kill-server exit={p.returncode}\n');assert p.returncode==0
 def alive(pid):
  try:
   stat=pathlib.Path(f'/proc/{pid}/stat').read_text();return stat.split(') ',1)[1][0] not in 'ZX'
  except FileNotFoundError:return False
 for _ in range(30):
  if not any(alive(p) for p in owned):break
  time.sleep(.1)
 for pid in owned:
  if alive(pid):os.kill(pid,signal.SIGKILL)
 time.sleep(.2)
 remaining=[p for p in owned if alive(p)]
 f.write(f'Remaining live lab processes: {remaining}\n');assert not remaining
 p=sp.run(['tmux','-S',str(l/'s'),'list-sessions'],text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
 f.write(f'Private tmux post-stop probe: exit={p.returncode} {p.stdout}');assert p.returncode!=0
 for name in ['setup.sh','guards.py','attach.py','cleanup.py']:shutil.copyfile(l/name,e/name)
 # Remove toolchain-created task scratch for this lab, never any operator task.
 for id in ['gateattach11','gateattach12','gateattach13','gatebundle21','gatebundle22','gatebundle23','gateflags24']:
  for path in pathlib.Path('/tmp').glob('fm-'+id+'*'):
   if path.is_dir() and not path.is_symlink():shutil.rmtree(path,ignore_errors=True)
   elif path.is_file() or path.is_symlink():path.unlink(missing_ok=True)
 def onerror(func,path,exc):
  os.chmod(path,0o700);func(path)
 shutil.rmtree(l,onerror=onerror)
 pathlib.Path('tests/.gate-focused-attach.sh').unlink()
 f.write('Disposed lab home, project, pool, CLI caches, task scratch, and temporary test selector.\n')
