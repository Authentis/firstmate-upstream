#!/usr/bin/env python3
"""Drive the public, deterministic quota chooser with synthetic snapshot inputs.
Oracle: required >10,000 floor, weekly-only Codex all_models exemption,
review decisions preserving sibling vetoes and partial quota semantics.
No quota service, resolver, harness, or credentials are replaced or invoked.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path.cwd()
evidence = Path(__file__).parent
results = []
weekly = {'scope':'all_models','status':'known','effectivePercentRemaining':0,
          'runway':{'status':'exhausted_now','limitingWindowId':'weekly'}}
base = {'generatedAt':'2030-01-01T00:00:00Z','schemaVersion':5,'providers':[
    {'provider':'codex','quotaSemantics':{'status':'known','effectiveAvailability':[weekly]}}]}
with tempfile.TemporaryDirectory(prefix='.credit-live-', dir=root) as d:
    lab = Path(d)
    home = lab/'home'
    (home/'data').mkdir(parents=True)
    reading = home/'data/codex-credits.readings'
    def drive(name, snapshot=base, credits='1793336034 62397 latest\n', candidate='codex:gpt-6.1-terra', expected=('codex gpt-6.1-terra', 0)):
        if credits is None:
            reading.unlink(missing_ok=True)
        else:
            reading.write_text(credits)
        payload = snapshot if isinstance(snapshot, str) else json.dumps(snapshot)
        snap = lab/'quota.snapshot'
        snap.write_text(payload)
        env = dict(os.environ, FM_HOME=str(home))
        command = ['bash', str(root/'bin/fm-quota-choose.sh'), '--snapshot', str(snap), '--candidate', candidate]
        p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
        passed = (p.stdout.strip(), p.returncode) == expected
        result = dict(name=name, command=command, credit_readings=credits, snapshot=payload,
                      expected_stdout=expected[0], expected_exit=expected[1], stdout=p.stdout,
                      stderr=p.stderr, exit_code=p.returncode, passed=passed)
        results.append(result)
        print(f"{'PASS' if passed else 'FAIL'} {name}: stdout={p.stdout.strip()!r}, exit={p.returncode}", flush=True)
    drive('62,397 credits open exhausted weekly Codex')
    drive('Codex cover also reaches omp openai-codex routing', candidate='omp:openai-codex/gpt-6.1-terra', expected=('omp openai-codex/gpt-6.1-terra',0))
    for balance in ['9999','10000','10000.01']:
        drive('Strict credit floor '+balance, credits='1793336034 '+balance+' boundary\n', expected=('codex gpt-6.1-terra',0) if balance=='10000.01' else ('none',1))
    drive('Newest appended low balance closes previously covered pool', credits='1793336000 62397 old\n1793336034 9999 newest\n', expected=('none',1))
    drive('Newest appended high balance opens pool despite comments and invalid lines', credits='1793336000 9999 old\n1793336034 62397 newest\n# comment\ninvalid input\n\n')
    drive('Absent credit reading preserves exhausted rejection',credits=None,expected=('none',1))
    drive('Malformed-only credit reading preserves exhausted rejection',credits='not a reading\n# comment\n',expected=('none',1))
    for windows in ['five_hour',None,['weekly','five_hour'],['five_hour','weekly'],['weekly'],'weekly']:
        q=copy.deepcopy(base)
        row=q['providers'][0]['quotaSemantics']['effectiveAvailability'][0]
        row['runway'].pop('limitingWindowId')
        if isinstance(windows,list) or windows=='weekly':
            row['limitingWindowIds']=windows
        elif windows:
            row['runway']['limitingWindowId']=windows
        drive('JSON limiting windows '+repr(windows),snapshot=q,expected=('codex gpt-6.1-terra',0) if windows==['weekly'] else ('none',1))
    for scope in ['model:gpt-6.1-terra','product:gpt-6.1-terra','all_products']:
        for status in ['exhausted_now','through_reset']:
            q=copy.deepcopy(base)
            q['providers'][0]['quotaSemantics']['effectiveAvailability'].append({'scope':scope,'status':'known','effectivePercentRemaining':0,'runway':{'status':status}})
            drive('Sibling veto '+scope+' '+status,snapshot=q,expected=('none',1))
    q=copy.deepcopy(base)
    q['providers'][0]['provider']='claude'
    drive('Credits never open exhausted Claude',snapshot=q,candidate='claude:sonnet',expected=('none',1))
    for scope in ['model:sonnet','product:sonnet','all_products']:
        q={'generatedAt':'2030-01-01T00:00:00Z','schemaVersion':5,'providers':[{'provider':'claude','quotaSemantics':{'status':'partial','effectiveAvailability':[
            {'scope':'all_models','status':'known','effectivePercentRemaining':80,'runway':{'status':'through_reset'}},
            {'scope':scope,'status':'unknown','runway':{'status':'unknown'}}]}}]}
        drive('Partial known quota tolerates unknown '+scope,snapshot=q,credits=None,candidate='claude:sonnet',expected=('claude sonnet',0))
        q['providers'][0]['quotaSemantics']['effectiveAvailability'][1]['runway']['status']='exhausted_now'
        drive('Partial quota still rejects exhausted '+scope,snapshot=q,credits=None,candidate='claude:sonnet',expected=('none',1))
    def toon(window, identity='codex,codex-home,all_models'):
        return '\n'.join(['bin: quota-axi','generatedAt: "2030-01-01T00:00:00Z"',
            'quota[1]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:',
            '  codex,codex-home,all_models,0,-1,exhausted_now,high,weekly,2030-01-02T00:00:00Z',
            'exhaustion[1]{provider,accountKey,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:',
            '  '+identity+',0,2030-01-01T00:00:00Z,'+window, 'attention[0]:',''])
    drive('Schema6 TOON weekly matched account opens',snapshot=toon('weekly'))
    drive('Schema6 TOON five-hour exhaustion rejects',snapshot=toon('five_hour'),expected=('none',1))
    for identity in ['codex,other,all_models','claude,codex-home,all_models','codex,codex-home,model:other']:
        drive('TOON foreign identity cannot lend cover '+identity,snapshot=toon('weekly',identity),expected=('none',1))
    both=toon('weekly').replace('exhaustion[1]', 'exhaustion[2]').replace('attention[0]:','  codex,codex-home,all_models,0,2030-01-01T00:00:00Z,five_hour\nattention[0]:')
    drive('TOON mixed weekly and five-hour evidence rejects',snapshot=both,expected=('none',1))
(evidence/'chooser-live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Disposable home and snapshots removed.',flush=True)
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
