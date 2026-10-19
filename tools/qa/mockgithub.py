"""GitHub de mentira: responde a API de "última release" com a versão dada.
uso: mockgithub.py porta versão"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, TAG = int(sys.argv[1]), sys.argv[2]


class H(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = json.dumps({
            "tag_name": TAG,
            "html_url": f"https://github.com/teste/telinha/releases/tag/{TAG}",
            "assets": [{"name": "telinha-windows-x86_64.exe"}],
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        print(f"GET {self.path} {self.headers.get('user-agent')}", flush=True)

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
