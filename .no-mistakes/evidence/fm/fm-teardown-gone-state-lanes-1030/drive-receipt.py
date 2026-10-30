import os,pathlib,subprocess as sp,json,shutil,threading,http.server,ssl,sys,socket,select
R=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M66J43JFVBFMC5S2DQNZTSTE'); B=R/'.live-receipt'; B.mkdir()
results=[]
for scenario in sys.argv[1:]:
 C=B/scenario; C.mkdir(); H=C/'home'; log=[]; server=None; thread=None; proxy=None; proxythread=None; sock=E/'receipt-tmux.sock'
 env=os.environ.copy()
 for k in list(env):
  if k.startswith(('FM_','GH_','GITHUB_')) or k in ['TMUX','TMUX_PANE']: env.pop(k,None)
 env.update(FM_HOME=str(H),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
 def cmd(args,cwd=None,ok=True):
  p=sp.run([str(a) for a in args],cwd=cwd or R,env=env,stdout=sp.PIPE,stderr=sp.STDOUT,text=True,timeout=60)
  log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+f'[exit {p.returncode}]\n')
  if ok and p.returncode: raise RuntimeError(f'command failed: {args}: {p.returncode}')
  return p
 try:
  cmd(['bin/fm-lab-home.sh','create',H]); (H/'config/supervision-host').touch(); (H/'state/.last-watcher-beat').touch()
  P=C/'project'; O=C/'origin.git'
  cmd(['git','init','-q','--bare','--initial-branch=main',O]); cmd(['git','clone','-q',O,P])
  (P/'deliverable').write_text('synthetic landed work\n'); cmd(['git','add','.'],P); cmd(['git','commit','-qm','landed head'],P); cmd(['git','push','-qu','origin','main'],P); cmd(['git','push','-q','origin','HEAD:refs/pull/7/head'],P)
  head=cmd(['git','rev-parse','HEAD'],P).stdout.strip()
  cert=C/'server.pem'; key=C/'server.key'
  cmd(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',key,'-out',cert,'-subj','/CN=localhost','-addext','subjectAltName=DNS:fm-lab.invalid,DNS:localhost,IP:127.0.0.1'])
  class API(http.server.BaseHTTPRequestHandler):
   def do_POST(self):
    query=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode(); log.append('LOCAL FORGE REQUEST '+self.path+' '+query+'\n')
    state='OPEN' if scenario=='open-force' else 'MERGED'
    forge_head='a'*40 if scenario=='forge-mismatch' else head
    body=json.dumps({'data':{'repository':{'pullRequest':{'state':state,'headRefOid':forge_head,'url':url}}}}).encode()
    self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
   def log_message(self,*args): pass
  server=http.server.HTTPServer(('127.0.0.1',0),API)
  context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key); server.socket=context.wrap_socket(server.socket,server_side=True)
  url='https://fm-lab.invalid/owner/repo/pull/7'
  thread=threading.Thread(target=server.serve_forever); thread.start()
  class Proxy(http.server.BaseHTTPRequestHandler):
   def do_CONNECT(self):
    if self.path!='fm-lab.invalid:443': self.send_error(403); return
    upstream=socket.create_connection(('127.0.0.1',server.server_port))
    self.send_response(200); self.end_headers()
    try:
     while True:
      ready,_,_=select.select([self.connection,upstream],[],[],10)
      if not ready: break
      for source in ready:
       data=source.recv(65536)
       if not data: return
       (upstream if source is self.connection else self.connection).sendall(data)
    finally: upstream.close()
   def log_message(self,*args): pass
  proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy); proxythread=threading.Thread(target=proxy.serve_forever); proxythread.start()
  env.update(HTTPS_PROXY=f'http://127.0.0.1:{proxy.server_port}',https_proxy=f'http://127.0.0.1:{proxy.server_port}',NO_PROXY='',no_proxy='',GH_HOST='fm-lab.invalid',GH_ENTERPRISE_TOKEN='disposable-local-emulator-token',GH_TOKEN='disposable-local-emulator-token',SSL_CERT_FILE=str(cert),GH_CONFIG_DIR=str(C/'gh-config'))
  tools=C/'tools'; tools.mkdir()
  # Isolate unrelated optional integrations, but execute the real gh CLI against local HTTPS.
  for name in ['gh-axi','no-mistakes']:
   f=tools/name; f.write_text('#!/bin/sh\nexit 1\n'); f.chmod(0o755)
  env['PATH']=str(tools)+':'+env['PATH']
  dummy=C/'shared'; dummy.mkdir(); (dummy/'precious').write_text('shared data must survive\n')
  cmd(['tmux','-f','/dev/null','-S',sock,'new-session','-d','-s','unrelated','sleep 300']); env['TMUX']=str(sock)+',0,0'
  meta=H/'state/receipt-lane.meta'
  recorded='b'*40 if scenario=='record-mismatch' else head
  meta.write_text(f'project={P}\nkind=ship\nmode=no-mistakes\nrecord_only=yes\nendpoint_task_id=receipt-lane\nworktree={dummy}\npr={url}\npr_head={recorded}\n')
  cmd(['gh','pr','view',url,'--json','state,headRefOid,url','-q','.state + "\\t" + .headRefOid + "\\t" + .url'],P,ok=False)
  log.append('No background or gate receipt exists. No owned endpoint exists. lsof available='+str(bool(shutil.which('lsof',path=env['PATH'])))+'\n')
  p=cmd(['bin/fm-teardown.sh','receipt-lane']+(['--force'] if scenario.endswith('force') else []),ok=False)
  refuse=scenario!='merged-endpointless'
  assert p.returncode==(1 if refuse else 0),f'unexpected exit {p.returncode}'
  assert meta.exists()==refuse,'incorrect record retention'
  cmd(['tmux','-S',sock,'has-session','-t','unrelated'])
  assert (dummy/'precious').read_text()=='shared data must survive\n'
  bundles=list((H/'data/bundles').glob('*.bundle')) if (H/'data/bundles').exists() else []
  if not refuse:
   assert len(bundles)==1,'no backup'; cmd(['git','bundle','verify',bundles[0]],P); assert head in cmd(['git','bundle','list-heads',bundles[0]],P).stdout
  else:
   assert not bundles,'unexpected backup'
   expected={'record-mismatch':'PR now heads','forge-mismatch':'not the recorded','open-force':'is not merged'}[scenario]
   assert expected in p.stdout, 'refusal did not reach intended guard'
  log.append('OBSERVED: '+('refused with record retained' if refuse else 'receipt-less record retired with verified head backup')+'; shared dummy path unchanged; unrelated private tmux session survived.\n')
  results.append({'name':scenario,'result':'pass'})
 except Exception as ex:
  log.append('ERROR '+str(ex)+'\n'); results.append({'name':scenario,'result':'fail','error':str(ex)})
 finally:
  if proxy: proxy.shutdown(); proxy.server_close()
  if proxythread: proxythread.join()
  if server: server.shutdown(); server.server_close()
  if thread: thread.join()
  cmd(['tmux','-S',sock,'kill-server'],ok=False); sock.unlink(missing_ok=True)
  (E/('receipt-'+scenario+'.log')).write_text(''.join(log)); shutil.rmtree(C)
B.rmdir(); (E/'receipt-results.json').write_text(json.dumps(results,indent=2)); print(json.dumps(results,indent=2)); sys.exit(any(r['result']=='fail' for r in results))
