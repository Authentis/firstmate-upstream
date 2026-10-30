from drive import *
import socket, select, socketserver
class Proxy(http.server.BaseHTTPRequestHandler):
 def do_CONNECT(self):
  with socket.create_connection(('127.0.0.1',self.server.target_port)) as target:
   self.send_response(200);self.end_headers()
   while True:
    ready,_,_=select.select([self.connection,target],[],[],5)
    if not ready:return
    for source in ready:
     data=source.recv(65536)
     if not data:return
     (target if source is self.connection else self.connection).sendall(data)
 def log_message(self,*a):pass
class ProxyServer(socketserver.ThreadingMixIn,http.server.HTTPServer):
 daemon_threads=True
class Server(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
  self.server.requests.append(body)
  data={'data':{'repository':{'pullRequest':{'number':7,'state':self.server.state,'headRefOid':self.server.head,'url':self.server.url,'merged':self.server.state=='MERGED'}}}}
  raw=json.dumps(data).encode(); self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 def log_message(self,*a):pass

def receipt(name):
 env,proj,origin=setup();log=[];server=None;thread=None;proxy=None;proxy_thread=None
 try:
  (proj/'feature.txt').write_text('landed feature\n');cmd(['git','-C',proj,'add','.'],env);cmd(['git','-C',proj,'commit','-qm','land feature'],env)
  head=cmd(['git','-C',proj,'rev-parse','HEAD'],env).stdout.strip();cmd(['git','-C',proj,'push','-q','origin','HEAD:main','HEAD:refs/pull/7/head'],env)
  cert=LAB/'cert.pem';key=LAB/'key.pem'
  cmd([shutil.which('openssl'),'req','-x509','-newkey','rsa:2048','-nodes','-keyout',key,'-out',cert,'-days','1','-subj','/CN=fm-lab.invalid','-addext','subjectAltName=DNS:fm-lab.invalid'])
  server=http.server.HTTPServer(('127.0.0.1',0),Server);ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key);server.socket=ctx.wrap_socket(server.socket,server_side=True)
  host='fm-lab.invalid';url=f'https://{host}/example/repo/pull/7';server.url=url;server.head=head;server.state='MERGED';server.requests=[]
  thread=threading.Thread(target=server.serve_forever);thread.start()
  proxy=ProxyServer(('127.0.0.1',0),Proxy);proxy.target_port=server.server_port
  proxy_thread=threading.Thread(target=proxy.serve_forever);proxy_thread.start()
  env.update(HTTPS_PROXY=f'http://127.0.0.1:{proxy.server_port}',NO_PROXY='',no_proxy='',GH_HOST=host,GH_ENTERPRISE_TOKEN='disposable-local-emulator-token',GH_TOKEN='disposable-local-emulator-token',SSL_CERT_FILE=str(cert),GH_CONFIG_DIR=str(LAB/'gh-config'))
  # Drive the actual gh binary through a local HTTPS GraphQL boundary, not a CLI stub.
  g=cmd(['gh','pr','view',url,'--json','state,headRefOid,url','-q','.state + "\t" + .headRefOid + "\t" + .url'],env,proj,False);log+=['Real gh / local HTTPS emulator probe:',g.stdout,f'gh exit={g.returncode}'];assert g.returncode==0
  if name=='mismatch': recorded='a'*40
  else:recorded=head
  if name=='open-force':server.state='OPEN'
  if name=='forge-mismatch':server.head='b'*40
  dummy=LAB/'dummy';dummy.mkdir();(dummy/'sentinel').write_text('shared work\n')
  meta=LAB/'state/lane.meta';meta.write_text(f'endpoint_task_id=lane\nproject={proj}\nkind=ship\nmode=no-mistakes\nyolo=off\nbranch=fm/bg\nrecord_only=yes\ngate_receipt_source=missing:data/gate-receipts/7.json\npr={url}\npr_head={recorded}\n'+('' if name=='no-worktree' else f'worktree={dummy}\n'))
  # No window/backend field; ambient private tmux pane is unrelated.
  assert not shutil.which('lsof',path=env['PATH'])
  log+=['No lsof on product PATH. No receipt file. No owned endpoint.']
  r=cmd(['bin/fm-teardown.sh','lane']+(['--force'] if name in ['open-force','receipt-force'] else []),env,check=False)
  log+=['Actual fm-teardown output:',r.stdout,f'exit={r.returncode}']
  expected=1 if name in ['mismatch','open-force','forge-mismatch'] else 0;assert r.returncode==expected
  assert meta.exists()==(expected!=0)
  bundle=LAB/'data/bundles/lane.bundle'
  if expected==0:
   cmd(['git','-C',proj,'bundle','verify',bundle],env);heads=cmd(['git','bundle','list-heads',bundle],env).stdout;assert head in heads;log+=['Verified bundle heads:',heads]
  else:assert not bundle.exists()
  assert (dummy/'sentinel').read_text()=='shared work\n';assert not (dummy/'.git').exists()
  cmd(['tmux','-L','fm-lab','has-session','-t','lab'],env)
  log+=['Shared dummy sentinel unchanged.','Unrelated private tmux pane alive after endpointless cleanup.','Record retained.' if meta.exists() else 'Task record removed.','PASS']
 finally:
  if proxy:proxy.shutdown();proxy.server_close();proxy_thread.join()
  if server:server.shutdown();server.server_close();thread.join();log+=['GraphQL requests observed by local emulator:',*server.requests]
  (E/f'live-receipt-{name}.log').write_text('\n'.join(log));teardown(env)
if __name__=='__main__':
 import sys
 for name in sys.argv[1:]:receipt(name);print(name,'PASS',flush=True)
