import os, subprocess as sp, pathlib as P, json, hashlib, time
root=P.Path.cwd(); lab=root/'.l'; ev=P.Path('~/.no-mistakes/evidence/01M6RCPJC6ZQDQE7REYF4YF7C2')
env=os.environ.copy()
for k in list(env):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k=='FM_GATE_REFUSE_BYPASS' or k.startswith('HERDR_'): env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(lab/'user'),CLAUDE_CONFIG_DIR=str(lab/'user/.claude'),TMUX_TMPDIR=str(lab/'tmux'),TMUX=(lab/'socket').read_text().strip()+',0,0',TREEHOUSE_ROOT=str(lab/'pool'))
log=open(ev/'live-scenarios.log','w',buffering=1)
def run(args,code=0,cwd=root,e=env):
    log.write('\n$ '+ ' '.join(map(str,args))+'\n')
    p=sp.run(list(map(str,args)),cwd=cwd,env=e,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=120)
    log.write(p.stdout+f'\nexit={p.returncode}\n')
    if code is not None: assert p.returncode==code, p.stdout
    return p.stdout

def tm(*args,code=0): return run(['tmux',*args],code)
def git(*args): return run(['git','-C',lab/'worker',*args]).strip()
def meta(): return (lab/'state/recover1106.meta').read_text()
def snap():
    return dict(head=git('rev-parse','HEAD'),branch=git('symbolic-ref','HEAD'),refs=run(['git','-C',lab/'projects/demo','for-each-ref','--format=%(refname) %(objectname)','refs/heads']).strip(),status=git('status','--porcelain'),staged=git('diff','--cached','--binary'),dirty=git('diff','--binary'),files={n:hashlib.sha256((lab/'worker'/n).read_bytes()).hexdigest() for n in ['task.txt','staged.txt','untracked.txt']})
def record(label):
    log.write('\n### '+label+'\n')
def refuse(fragment):
    before=meta(); windows=tm('list-windows','-a','-F','#{session_name}:#{window_name}')
    for args in [['bin/fm-control.sh','recover1106','exit'],['bin/fm-control.sh','recover1106','relaunch','--note','Preserve work'],['bin/fm-spawn.sh','recover1106','--relaunch','--harness','claude']]:
        out=run(args,1); assert fragment in out, out; assert before==meta()
    assert windows==tm('list-windows','-a','-F','#{session_name}:#{window_name}')
    log.write('Oracle: all three entrypoints refused; metadata and window inventory unchanged.\n')

# Re-run the successful recovery with an independently saved oracle.
tm('kill-window','-t','primary:fm-recover1106',code=None)
(lab/'state/recover1106.status').write_text('test approval parked: preserve this status history\n')
status_before=(lab/'state/recover1106.status').read_bytes()
before=snap()
record('Missing window: recover recorded task on existing branch/worktree')
run(['bin/fm-control.sh','recover1106','relaunch','--note','Resume the preserved task; validation only, do not edit files'])
assert snap()==before
assert (lab/'state/recover1106.status').read_bytes().startswith(status_before)
assert 'window=primary:fm-recover1106\n' in meta()
assert 'worktree='+str(lab/'worker')+'\n' in meta()
tm('list-windows','-a','-F','#{session_name}:#{window_name} #{window_id} #{pane_current_command} #{pane_current_path}')
log.write('Persisted task metadata:\n'+meta()); log.write('Oracle: HEAD, branch, refs, staged/unstaged diff, untracked file bytes and status history preserved.\n')
tm('capture-pane','-p','-t','primary:fm-recover1106')
tm('kill-window','-t','primary:fm-recover1106')
# Make the stored session absent, not just the window.
p=lab/'state/recover1106.meta'; p.write_text(meta().replace('window=primary:fm-recover1106','window=vanished1106:fm-recover1106'))
record('Duplicate guard: same task window moved to another session on same server')
tm('new-session','-d','-s','other1106','-n','fm-recover1106','-c',str(root),'sleep 300')
refuse('window named')
tm('kill-session','-t','other1106')
record('Duplicate guard: foreign socket process has cwd inside the recorded worktree')
# A second isolated socket, never the operator socket.
tm('-L','fm-foreign','new-session','-d','-s','foreign1106','-x','120','-y','35','-c',str(root))
tm('-L','fm-foreign','send-keys','-t','foreign1106','cd '+str(lab/'worker')+'; exec sleep 300','Enter')
time.sleep(0.3)
try: refuse('working in the recorded worktree')
finally: tm('-L','fm-foreign','kill-server')
record('Duplicate guard: foreign socket process names task while cwd is elsewhere')
tm('-L','fm-foreign','new-session','-d','-s','foreign1106','-x','120','-y','35','-c',str(root),"bash -c 'exec -a fm-recover1106 sleep 300'")
try: refuse('names the task')
finally: tm('-L','fm-foreign','kill-server')
record('Pre-publication abort: real invalid Claude trust store; cleanup then retry')
store=lab/'user/.claude/.claude.json'; oldstore=store.read_bytes() if store.exists() else None
store.write_text('invalid json\n'); oldmeta=meta(); windows=tm('list-windows','-a','-F','#{session_name}:#{window_name} #{window_id}')
try:
    out=run(['bin/fm-control.sh','recover1106','relaunch','--note','Recover from the missing session'],1)
    assert 'could not pre-register Claude workspace trust' in out
    assert meta()==oldmeta
    assert tm('list-windows','-a','-F','#{session_name}:#{window_name} #{window_id}')==windows
    log.write('Oracle: failed launch retained old record and removed only its unused replacement; primary window survives.\n')
finally:
    if oldstore is None: store.unlink(missing_ok=True)
    else: store.write_bytes(oldstore)
run(['bin/fm-control.sh','recover1106','relaunch','--note','Retry missing-session recovery; do not edit files'])
assert 'window=primary:fm-recover1106\n' in meta()
assert snap()==before
log.write('Oracle: same recovery immediately succeeds on retry, work preserved.\n')
# Record real CLI surface: this is deliberately not an authenticated model proof.
time.sleep(1)
text=tm('capture-pane','-p','-t','primary:fm-recover1106')
(ev/'claude-local-onboarding.txt').write_text(text)
tm('kill-window','-t','primary:fm-recover1106')
record('Dead server: exit proof and recovery after private server is restarted')
tm('kill-server')
# The real primary launch command, clean environment and explicit nonzero grid.
e=env.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX']: e.pop(k,None)
run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','35','-c',root,'-e','FM_HOME='+str(lab),'-e','HOME='+str(lab/'user'),'-e','CLAUDE_CONFIG_DIR='+str(lab/'user/.claude'),'claude'],e=e)
run(['bin/fm-control.sh','recover1106','exit'])
run(['bin/fm-spawn.sh','recover1106','--relaunch','--harness','claude'])
assert snap()==before
assert 'window=primary:fm-recover1106\n' in meta()
log.write('Oracle: after server loss, exit reports endpoint-gone; direct relaunch recreates endpoint and preserves work.\n')
tm('kill-window','-t','primary:fm-recover1106')
log.write('\nALL LOCAL RECOVERY AND GUARD SCENARIOS PASSED\n')
