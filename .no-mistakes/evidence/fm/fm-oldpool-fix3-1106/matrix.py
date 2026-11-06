from drive import *
results=[]
for old in [True,False]:
 for kind in ['tracked','untracked','claude','unpushed']:
  for force in [False,True]:
   name='verified-'+('old' if old else 'current')+'-'+kind+('-force' if force else '-plain')
   c=setup(name,old); d,h,pr,wt,env,lease=c
   path=wt/('tracked.txt' if kind=='tracked' else '.claude/research.md' if kind=='claude' else 'notes.txt')
   if kind=='unpushed':
    (wt/'commit.txt').write_text('unlanded\n');cmd(['git','add','commit.txt'],wt,env);cmd(['git','commit','-qm','unlanded'],wt,env)
   else: path.write_text('precious user work\n')
   before=cmd(['git','rev-parse','HEAD'],wt,env).stdout
   p=run(c,force)
   assert p.returncode!=0,(name,p.stdout)
   assert (h/'state/task-x1.meta').exists(),name
   if not (not old and kind=='claude' and not force):
    assert cmd(['git','branch','--show-current'],wt,env).stdout.strip()=='fm/task-x1',name
   assert cmd(['git','rev-parse','HEAD'],wt,env).stdout==before,name
   if kind!='unpushed': assert path.read_text()=='precious user work\n',name
   results.append(name+': refusal preserves user content, HEAD commit and task record')
(E/'matrix-results.log').write_text('\n'.join(results)+'\n')
print('\n'.join(results))
