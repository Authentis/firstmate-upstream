import http.server,json,os,sys
from pathlib import Path
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length',0))).decode()
  print('REQUEST',self.path,body,flush=True)
  cfg=json.loads(Path(sys.argv[2]).read_text())
  data={'data':{'repository':{'pullRequest':{'number':7,'state':cfg.get('state','MERGED'),'headRefOid':cfg['head'],'url':cfg['url'],'id':'PR_lab','baseRefName':'main','headRefName':'fm/task-live','isCrossRepository':False}}}}
  payload=json.dumps(data).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(payload)
 def do_GET(self):
  payload=b'{"data":{}}';self.send_response(200);self.end_headers();self.wfile.write(payload)
s=http.server.HTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(s.server_port))
import ssl
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('.forge/cert.pem','.forge/key.pem')
s.socket=ctx.wrap_socket(s.socket,server_side=True)
s.serve_forever()
