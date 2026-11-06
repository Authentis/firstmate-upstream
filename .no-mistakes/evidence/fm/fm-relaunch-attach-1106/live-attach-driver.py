import os,subprocess as sp,pathlib as P,time
r=P.Path.cwd(); l=r/'.l'; evidence=P.Path('~/.no-mistakes/evidence/01M6RCPJC6ZQDQE7REYF4YF7C2')
e=os.environ.copy()
for k in list(e):
    if (k.startswith('FM_') and k.endswith('_OVERRIDE')) or k=='FM_GATE_REFUSE_BYPASS' or k.startswith('HERDR_'):e.pop(k,None)
e.update(FM_HOME=str(l),HOME=str(l/'user'),CLAUDE_CONFIG_DIR=str(l/'user/.claude'),TMUX_TMPDIR=str(l/'tmux'),TMUX=(l/'socket').read_text().strip()+',0,0',TREEHOUSE_ROOT=str(l/'pool'),TMPDIR=str(l/'tmp'))
(l/'tmp').mkdir(exist_ok=True)
f=open(evidence/'live-attach.log','w',buffering=1)
def run(args,c=0,cwd=r):
 f.write('\n$ '+' '.join(map(str,args))+'\n');p=sp.run(list(map(str,args)),env=e,cwd=cwd,stdout=sp.PIPE,stderr=sp.STDOUT,text=True,timeout=180); f.write(p.stdout+f'\nexit={p.returncode}\n');assert p.returncode==c,p.stdout;return p.stdout.strip()
def git(d,*args,c=0):return run(['git','-C',d,*args],c)
proj=l/'projects/attach'; pub=l/'publisher';bundle=l/'data/bundles/preserved work.bundle';bundle.parent.mkdir(exist_ok=True)
git(l/'projects','init','-q','-b','main',proj)
(proj/'base.txt').write_text('original base\n');git(proj,'add','base.txt');git(proj,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','base')
base=git(proj,'rev-parse','HEAD');run(['git','clone','-q',proj,pub]);git(pub,'checkout','-qb','saved1106');(pub/'preserved.txt').write_text('bundle-only preserved work\n');git(pub,'add','preserved.txt');git(pub,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','preserved');head=git(pub,'rev-parse','HEAD');git(pub,'bundle','create','-q',bundle,'HEAD');git(proj,'cat-file','-e',head+'^{commit}',c=128)
def brief(id):
 d=l/'data'/id;d.mkdir(exist_ok=True);(d/'brief.md').write_text("# Task\n## Captain's intent\nValidation only: do not edit any files or run tools. Wait.\n## Firstmate spec\nPreserve all work and wait for further instructions.\n# Setup\nShip branch: saved1106\nDelivery contract: mode=local-only yolo=off\n")
def windows():return run(['tmux','list-windows','-a','-F','#{session_name}:#{window_name}'])
# Contract guards must run before touching any endpoint or project ref.
brief('badattach1106');before=git(proj,'for-each-ref','--format=%(refname) %(objectname)');wins=windows()
args=[r/'bin/fm-spawn.sh','badattach1106',proj,'--mode','local-only','--yolo','off','--harness','claude','--attach-branch','saved1106','--attach-head','0123456789abcdef0123456789abcdef01234567','--attach-bundle','data/bundles/preserved work.bundle']
out=run(args,1,l);assert 'is not a head of bundle' in out;assert not (l/'state/badattach1106.meta').exists();assert before==git(proj,'for-each-ref','--format=%(refname) %(objectname)');assert wins==windows()
git(proj,'branch','saved1106',base)
args[args.index('0123456789abcdef0123456789abcdef01234567')]=head
out=run(args,1,l);assert 'already exists at' in out;assert not (l/'state/badattach1106.meta').exists();assert git(proj,'rev-parse','saved1106')==base;assert wins==windows();git(proj,'branch','-D','saved1106')
f.write('Oracle: missing bundle head and conflicting existing branch both refuse before endpoint/metadata mutation.\n')
brief('attach1106');args[1]='attach1106'
run(args,0,l)
meta=(l/'state/attach1106.meta').read_text();f.write('\nPublished metadata:\n'+meta)
m=dict(x.split('=',1) for x in meta.splitlines() if '=' in x);wt=P.Path(m['worktree'])
assert git(wt,'rev-parse','HEAD')==head
assert git(wt,'symbolic-ref','HEAD')=='refs/heads/saved1106'
assert (wt/'preserved.txt').read_text()=='bundle-only preserved work\n'
assert git(proj,'rev-parse','main')==base
f.write('Oracle: invocation-relative bundle with spaces restored its exact commit/content onto saved1106; main unchanged.\n')
time.sleep(1);run(['tmux','list-windows','-a','-F','#{session_name}:#{window_name} #{pane_current_command} #{pane_current_path}']);run(['tmux','capture-pane','-p','-t',m['window']]);run(['tmux','kill-window','-t',m['window']])
f.write('\nALL LOCAL FRESH-ATTACH SCENARIOS PASSED\n')
