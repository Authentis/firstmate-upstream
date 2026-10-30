import http.server,ssl,json,sys,socket
head=sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  query=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  print(json.dumps(query),flush=True)
  response={'data':{'repository':{'pullRequest':{'state':open(sys.argv[4]).read().strip(),'headRefOid':head,'url':'https://forge.test.invalid/example/repo/pull/7'}}}}
  body=json.dumps(response).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(sys.argv[2],sys.argv[3])
class LocalServer(http.server.HTTPServer):
 def get_request(self):
  sock,addr=self.socket.accept()
  request=b''
  while not request.endswith(b'\r\n\r\n'): request+=sock.recv(1)
  assert request.startswith(b'CONNECT forge.test.invalid:443 '),request
  sock.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
  return ctx.wrap_socket(sock,server_side=True),addr
s=LocalServer(('127.0.0.1',18443),Handler)
s.serve_forever()
