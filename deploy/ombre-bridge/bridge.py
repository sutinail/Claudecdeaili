#!/usr/bin/env python3
"""记忆桥：守在 Ombre Brain 旁边，让 Lumi 的 API 窗口（浏览器）能直接连 OB 的 /mcp。

OB 自己不回浏览器要的 CORS 头，手机网页就连不上它。这里只做两件事：
回答浏览器的预检请求，再把 /mcp 请求原样转给本机的 OB（鉴权还是 OB 自己的 token）。
只用 Python 标准库。
"""
import http.client
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT = int(os.environ.get("BRIDGE_PORT", "18002"))
UPSTREAM = urlsplit(os.environ.get("BRIDGE_UPSTREAM", "http://127.0.0.1:18001"))
ORIGINS = {o.strip().rstrip("/") for o in os.environ.get("BRIDGE_ORIGINS", "https://chat.gpt1126.top").split(",") if o.strip()}
FORWARD = ["authorization", "content-type", "accept", "mcp-session-id", "mcp-protocol-version", "last-event-id"]
EXPOSE = ["content-type", "mcp-session-id", "mcp-protocol-version"]


class Bridge(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # 回完就关连接，流式响应不用自己拼 chunked
    server_version = "ombre-bridge"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def cors(self):
        origin = (self.headers.get("Origin") or "").rstrip("/")
        if origin in ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", ", ".join(FORWARD))
            self.send_header("Access-Control-Expose-Headers", ", ".join(EXPOSE))
            self.send_header("Access-Control-Max-Age", "86400")

    def plain(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            return self.plain(200, "ok")
        self.proxy()

    def do_POST(self):
        self.proxy()

    def do_DELETE(self):
        self.proxy()

    def proxy(self):
        if not (self.path == "/mcp" or self.path.startswith("/mcp/") or self.path.startswith("/mcp?")):
            return self.plain(404, "only /mcp")
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4 * 1024 * 1024:
            return self.plain(413, "too large")
        body = self.rfile.read(length) if length else None
        headers = {k: self.headers[k] for k in FORWARD if self.headers.get(k)}
        try:
            conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=300)
            conn.request(self.command, self.path, body=body, headers=headers)
            up = conn.getresponse()
        except OSError as e:
            return self.plain(502, "记忆库连不上: %s" % e)
        self.send_response(up.status)
        self.cors()
        for k in ("content-type", "mcp-session-id", "mcp-protocol-version", "cache-control"):
            v = up.getheader(k)
            if v:
                self.send_header(k, v)
        self.end_headers()
        try:
            while True:
                chunk = up.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    print("记忆桥 :%d → %s://%s:%s  允许 %s" % (PORT, UPSTREAM.scheme, UPSTREAM.hostname, UPSTREAM.port, ", ".join(sorted(ORIGINS))), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Bridge).serve_forever()
