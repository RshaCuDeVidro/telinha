#!/usr/bin/env python3
# Roteador UPnP de mentira (só em 127.0.0.1): responde ao M-SEARCH, serve a
# descrição e aceita AddPortMapping/DeletePortMapping, anotando tudo no log.
# uso: mockigd.py UDP_PORT HTTP_PORT LOG [EXT_IP]
import socket, sys, threading, http.server

udp_port, http_port, log_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ext_ip = sys.argv[4] if len(sys.argv) > 4 else "203.0.113.7"

def log(s):
    with open(log_path, "a") as f:
        f.write(s + "\n")

def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", udp_port))
    while True:
        data, addr = s.recvfrom(1500)
        log("SSDP " + data.decode(errors="replace").split("\r\n")[0])
        reply = ("HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"
                 f"LOCATION: http://127.0.0.1:{http_port}/rootDesc.xml\r\n\r\n")
        s.sendto(reply.encode(), addr)

DESC = ("<?xml version=\"1.0\"?><root><device><serviceList><service><serviceType>"
        "urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL>"
        "</service></serviceList></device></root>")

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        log("GET " + self.path)
        self.send(200, DESC)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n).decode(errors="replace")
        action = self.headers.get("SOAPAction", "")
        log("POST " + action + " " + body)
        if "GetExternalIPAddress" in action:
            self.send(200, f"<s:Envelope><s:Body><u:R><NewExternalIPAddress>{ext_ip}</NewExternalIPAddress></u:R></s:Body></s:Envelope>")
        else:
            self.send(200, "<s:Envelope><s:Body><u:R/></s:Body></s:Envelope>")

threading.Thread(target=udp, daemon=True).start()
http.server.ThreadingHTTPServer(("127.0.0.1", http_port), H).serve_forever()
