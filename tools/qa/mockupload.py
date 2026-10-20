"""gofile.io / webhook de mentira: recebe o POST multipart do log de depuração,
guarda o corpo e responde como o serviço de verdade.
uso: mockupload.py porta gofile|webhook pasta"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, MODE, OUT = int(sys.argv[1]), sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)
count = 0


class H(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        global count
        n = int(self.headers.get("content-length", "0"))
        body = b""
        while len(body) < n:
            chunk = self.rfile.read(n - len(body))
            if not chunk:
                break
            body += chunk
        count += 1
        with open(os.path.join(OUT, f"post{count}.bin"), "wb") as f:
            f.write(body)
        print(f"POST {self.path} {len(body)} bytes {self.headers.get('content-type')}", flush=True)
        if MODE == "gofile":
            out = json.dumps({"status": "ok", "data": {"downloadPage": f"https://gofile.io/d/teste{count}", "code": f"teste{count}"}}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        else:
            # Discord responde 204 sem ?wait=true
            self.send_response(204)
            self.end_headers()

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
