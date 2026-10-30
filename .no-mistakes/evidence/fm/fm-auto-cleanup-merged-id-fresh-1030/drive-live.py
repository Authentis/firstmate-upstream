#!/usr/bin/env python3
"""Drive real fm-spawn CLI against synthetic persisted state, no tool mocks.
Oracle: author's merged-ID prohibition; guard boundaries documented by CLI.
Positive boundary cases intentionally stop at the next real safety gate,
not at agent dispatch: this proves guard scope, not full worker lifecycle.
"""
import os, pathlib, subprocess, time, shutil
ROOT = pathlib.Path.cwd()
E = pathlib.Path('~/.no-mistakes/evidence/01M669P6SGEX1KA9RR6KF1XNAG')
BASE = ROOT / '.test-scratch/live-driver'
BASE.mkdir()
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'CLAUDE_')) and k not in ('TMUX','TMUX_PANE')}
ENV['HOME'] = str(BASE / 'user')
pathlib.Path(ENV['HOME']).mkdir()
ENV['TMPDIR'] = str(BASE)
project = BASE / 'project'
subprocess.run(['git','init','-q',str(project)],env=ENV,check=True)
subprocess.run(['git','-C',str(project),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','initial'],env=ENV,check=True)

def setup(name, archive='ship', ledger=None, pending=False, scout=False):
    home = BASE / name
    subprocess.run(['bin/fm-lab-home.sh','create',str(home)],check=True,env=ENV,stdout=subprocess.DEVNULL)
    (home/'data'/name).mkdir()
    (home/'data'/name/'brief.md').write_text("# Task\n## Captain's intent\nValidate merged-ID refusal with disposable records.\n\n## Firstmate spec\nExercise the public spawn CLI.\n\n# Definition of done\n" + ('' if scout else 'Delivery contract: mode=no-mistakes\n'))
    if archive:
        (home/'data/lane-meta-archive').mkdir()
        (home/'data/lane-meta-archive'/f'{name}.meta').write_text(f'kind={archive}\n')
    if ledger is not None:
        (home/'state/fleet-ledger.jsonl').write_text(ledger)
    if pending:
        (home/'state'/f'{name}.backlog-close').write_text('intentional downstream safety sentinel\n')
    env = dict(ENV, FM_HOME=str(home))
    cmd = ['bash',str(ROOT/'bin/fm-spawn.sh'), name, str(project), '--backend','tmux','--harness','claude']
    cmd += ['--scout'] if scout else ['--mode','no-mistakes','--yolo','off']
    return home, env, cmd

def verify(name, home, rc, out, expected):
    print(f'=== {name} ===\nexit={rc}\n{out.strip()}')
    assert rc != 0 and expected in out, (name,rc,out)
    assert not (home/'state'/f'{name}.meta').exists()
    assert not list((home/'state').glob('.meta-*.lock'))
    assert not list((home/'state').glob('*lease*'))
    print('Observed: no task metadata, task meta lock, or lease remains. No worker launched.\n')

try:
    for name, archive, ledger, pending, scout, expected in [
        ('merged-proof','ship','not json "merged-proof"\n{"event":"task.merged","task":"merged-proof"}\n[1,"merged-proof"]\n"merged-proof"\n',False,False,'already merged'),
        ('prefix-only','ship','{"event":"task.merged","task":"prefix-only-2"}\n{"event":"task.dispatched","task":"prefix-only"}\n',True,False,'pending authoritative backlog close'),
        ('archive-only','ship',None,True,False,'pending authoritative backlog close'),
        ('ledger-only',None,'{"event":"task.merged","task":"ledger-only"}\n',True,False,'pending authoritative backlog close'),
        ('archived-scout','scout','{"event":"task.merged","task":"archived-scout"}\n',True,False,'pending authoritative backlog close'),
        ('scout-request','ship','{"event":"task.merged","task":"scout-request"}\n',True,True,'pending authoritative backlog close'),
    ]:
        home,env,cmd=setup(name,archive,ledger,pending,scout)
        r=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=40)
        verify(name,home,r.returncode,r.stdout+r.stderr,expected)
    name='merged-no-jq'
    home,env,cmd=setup(name,'ship',f'{{"event":"task.merged","task":"{name}"}}\n')
    tools=BASE/'tools-without-jq'; tools.mkdir()
    for tool in 'bash dirname readlink uname git sed tr grep cut mkdir date stat head tail awk basename sort wc touch ps realpath mktemp find chmod ln rm sleep cat id which env xargs perl cp mv python3 hostname tee claude node'.split():
        real=shutil.which(tool)
        if real: (tools/tool).symlink_to(real)
    env['PATH']=str(tools)
    r=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=40)
    verify(name,home,r.returncode,r.stdout+r.stderr,'jq is not installed')
    name='merge-during-wait'
    home,env,cmd=setup(name,None,f'{{"event":"task.merged","task":"{name}"}}\n')
    lock=home/'state'/f'.meta-{name}.lock'
    holder=subprocess.Popen(['bash','-c','. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; echo READY; read -r release; fm_lock_release "$2"', '_',str(ROOT),str(lock)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert holder.stdout.readline().strip()=='READY'
    trace=E/'lock-race.trace'
    child=None
    try:
        with trace.open('w') as f, (E/'lock-race-cli.log').open('w') as cli:
            traced_env=dict(env, BASH_XTRACEFD=str(f.fileno()))
            child=subprocess.Popen([cmd[0],'-x']+cmd[1:],env=traced_env,pass_fds=(f.fileno(),),stdout=cli,stderr=subprocess.STDOUT,text=True)
            deadline=time.monotonic()+35
            while time.monotonic()<deadline:
                text=trace.read_text()
                if 'fm_lock_acquire_wait '+str(lock) in text and 'sleep 0.1' in text: break
                if child.poll() is not None: raise AssertionError(text[-3000:])
                time.sleep(.1)
            else: raise AssertionError('spawn did not reach contended lock')
            (home/'data/lane-meta-archive').mkdir()
            (home/'data/lane-meta-archive'/f'{name}.meta').write_text('kind=ship\n')
            holder.stdin.write('release\n');holder.stdin.flush()
            assert holder.wait(timeout=10)==0,holder.stderr.read()
            rc=child.wait(timeout=30)
        out=(E/'lock-race-cli.log').read_text()
        print('Race setup: actual meta lock held by another live process; runtime trace confirmed spawn waiting before archive appeared; released actual lock.')
        verify(name,home,rc,out,'already merged')
    finally:
        if holder.poll() is None:
            holder.stdin.write('release\n');holder.stdin.flush();holder.wait(timeout=10)
        if child is not None and child.poll() is None:
            child.terminate();child.wait(timeout=10)
    print('All live CLI guard scenarios passed; each subprocess exit was awaited.')
finally:
    shutil.rmtree(BASE)
