import os, pathlib, subprocess as sp
root=pathlib.Path.cwd(); lab=root/'.live'; home=lab/'home'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M6RHM2JQW9BM9XGMAER4ZDRF')
env=dict(os.environ,FM_HOME=str(home),HOME=str(lab/'user'),TMUX=f'{lab}/s,0,0',TREEHOUSE_ROOT=str(lab/'pool'))
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS']:env.pop(k,None)
f=(evidence/'live-attach.log').open('w',buffering=1)
def run(args,cwd=root,rc=0):
 p=sp.run(args,env=env,cwd=cwd,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=150)
 f.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'\nexit={p.returncode}\n')
 if rc is not None: assert p.returncode==rc,p.stdout
 return p.stdout.strip()
def git(*args,cwd=lab/'project',rc=0):return run(['git','-C',str(cwd),*args],rc=rc)
# Use a source clone the product has never fetched; oracle is its saved commit and bytes.
pub=lab/'publisher'; git('clone','-q',str(lab/'project'),str(pub))
git('checkout','-q','-b','preserved-source',cwd=pub)
(pub/'preserved.txt').write_text('saved bundle work; independent oracle\n')
git('add','preserved.txt',cwd=pub);git('-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','saved bundle',cwd=pub)
head=git('rev-parse','HEAD',cwd=pub)
bundle=home/'data/bundles/preserved work.bundle';bundle.parent.mkdir(parents=True,exist_ok=True)
git('bundle','create',str(bundle),'HEAD',cwd=pub)
run(['git','-C',str(lab/'project'),'cat-file','-e',head+'^{commit}'],rc=None)
# The preceding command must fail: the project lacks the saved commit until the real attach.
assert sp.run(['git','-C',str(lab/'project'),'cat-file','-e',head+'^{commit}'],env=env,stderr=sp.DEVNULL).returncode!=0

def brief(id,branch):
 d=home/'data'/id;d.mkdir(exist_ok=True)
 (d/'brief.md').write_text(f'# Task\n## Captain\'s intent\nDo not change files; report preserved state.\n## Firstmate spec\nShip branch: {branch}\n')

def spawn(id,branch,want=head,extra=None,rc=0):
 brief(id,branch)
 return run([str(root/'bin/fm-spawn.sh'),id,str(lab/'project'),'--mode','local-only','--yolo','off','--harness','codex','--attach-branch',branch,'--attach-head',want]+(extra or []),cwd=home,rc=rc)

# Relative path with a space, resolved from operational home, not project or pool.
id='gatebundle21'; branch='fm/'+id
spawn(id,branch,extra=['--attach-bundle','data/bundles/preserved work.bundle'])
meta=(home/'state'/f'{id}.meta').read_text();f.write('Published metadata:\n'+meta)
wt=pathlib.Path(dict(line.split('=',1) for line in meta.splitlines() if '=' in line)['worktree'])
assert git('rev-parse','HEAD',cwd=wt)==head
assert git('symbolic-ref','--short','HEAD',cwd=wt)==branch
assert (wt/'preserved.txt').read_text()=='saved bundle work; independent oracle\n'
f.write('Oracle: supplied bundle restored exact saved commit, exact branch, and saved file bytes.\n')
run(['tmux','capture-pane','-p','-t',f'lab:fm-{id}'])

# No bundle: branch already exists locally at requested head, never move it.
id='gatebundle22';branch='fm/'+id;initial=git('rev-parse','main')
git('branch',branch,initial); before=git('for-each-ref','--format=%(refname) %(objectname)','refs/heads')
spawn(id,branch,want=initial)
meta=(home/'state'/f'{id}.meta').read_text();f.write('Published metadata:\n'+meta)
wt=pathlib.Path(dict(line.split('=',1) for line in meta.splitlines() if '=' in line)['worktree'])
assert git('rev-parse','HEAD',cwd=wt)==initial
assert git('symbolic-ref','--short','HEAD',cwd=wt)==branch
assert git('for-each-ref','--format=%(refname) %(objectname)','refs/heads')==before
f.write('Oracle: existing branch checked out at original commit with no ref changes.\n')

# A branch at a different head, and a head absent from the bundle, must be refused before endpoint or metadata.
id='gatebundle23';branch='fm/'+id;git('branch',branch,initial)
for label,want in [('conflicting branch',head),('head not in bundle','0123456789abcdef0123456789abcdef01234567')]:
 before=git('for-each-ref','--format=%(refname) %(objectname)','refs/heads')
 out=spawn(id,branch,want=want,extra=['--attach-bundle','data/bundles/preserved work.bundle'],rc=1)
 assert ('already exists at' if label=='conflicting branch' else 'is not a head of bundle') in out
 assert not (home/'state'/f'{id}.meta').exists()
 assert f'fm-{id}' not in run(['tmux','list-windows','-a','-F','#{window_name}'])
 assert git('for-each-ref','--format=%(refname) %(objectname)','refs/heads')==before
 f.write(f'Oracle: {label} refused without moving refs, publishing metadata, or creating endpoint.\n')

# Recover missing window in an existing session, also preserving dirty work.
meta=home/'state/gateattach12.meta';text=meta.read_text();meta.write_text(text.replace('gone-session:', 'lab:'))
wt=lab/'wtparent/gateattach12';before=git('rev-parse','HEAD',cwd=wt);dirty=(wt/'saved.txt').read_bytes()
run([str(root/'bin/fm-control.sh'),'gateattach12','relaunch','--note','Continue the saved task'],rc=0)
assert git('rev-parse','HEAD',cwd=wt)==before and (wt/'saved.txt').read_bytes()==dirty
f.write('Oracle: missing-window recovery in existing session preserved committed and unfinished work.\n')
f.close()
