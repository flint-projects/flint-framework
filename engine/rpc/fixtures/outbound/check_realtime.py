#!/usr/bin/env python3
"""Serve deterministic HTTP/1 and WebSocket upgrade fixtures over local sockets."""
import base64
from hashlib import sha1
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import subprocess
import sys
import threading

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Server(ThreadingHTTPServer):
    failure = None

    def handle_error(self, request, addr):
        self.failure = sys.exc_info()[1]


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/events"):
            self.sse(self.path != "/events")
        else:
            self.websocket(self.path)

    def sse(self, invalid):
        assert self.headers["Accept"] == "text/event-stream"
        assert self.headers["Last-Event-ID"] == (None if invalid else "resume-6")
        records = (": heartbeat\r\nretry: 1500\n\nid: resume-7\revent: created\r\n"
                   "data: he⌛llo\r\ndata: world\r\n\r\ndata: next\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain" if invalid else "text/event-stream; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if invalid:
            self.wfile.write(b"0\r\n\r\n")
            return
        for value in records:
            self.wfile.write(b"1\r\n" + bytes([value]) + b"\r\n")
        self.wfile.write(b"0\r\n\r\n")

    def websocket(self, path):
        assert self.headers["Connection"].lower() == "upgrade"
        assert self.headers["Upgrade"].lower() == "websocket"
        assert self.headers["Sec-WebSocket-Version"] == "13"
        assert len(base64.b64decode(self.headers["Sec-WebSocket-Key"], validate=True)) == 16
        key = self.headers["Sec-WebSocket-Key"].encode("ascii")
        digest = base64.b64encode(sha1(key + GUID).digest())
        self.close_connection = True
        if path == "/bad-accept":
            digest = b"incorrect"
        extra = b"Sec-WebSocket-Extensions: permessage-deflate\r\n" if path == "/bad-extension" else b""
        initial = b"\x01\x03hi\xe2\x89\x04ping\x80\x02\x8c\x9b" if path == "/socket" else b""
        self.wfile.write(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: WebSocket\r\n"
                         b"Sec-WebSocket-Accept: " + digest + b"\r\n" + extra + b"\r\n" + initial)
        if path != "/socket":
            assert self.rfile.read(1) == b""
            return
        assert self.frame(10) == b"ping"
        assert self.frame(1) == "hi⌛".encode()
        assert self.frame(2) == bytes(range(126))
        close = self.frame(8)
        assert close == b"\x03\xe8finished"
        self.wfile.write(bytes([0x88, len(close)]) + close)

    def frame(self, expected):
        opcode, size = self.rfile.read(2)
        assert opcode == 0x80 | expected and size & 0x80
        size &= 0x7f
        if size == 126:
            size = int.from_bytes(self.rfile.read(2), "big")
        mask = self.rfile.read(4)
        payload = self.rfile.read(size)
        assert len(mask) == 4 and len(payload) == size
        return bytes(value ^ mask[index % 4] for index, value in enumerate(payload))


def check(client, certificate, key):
    for tls in (False, True):
        with Server(("127.0.0.1", 0), Peer) as server:
            if tls:
                identity = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                identity.load_cert_chain(certificate, key)
                server.socket = identity.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            address, port = server.server_address
            schemes = ("https", "wss") if tls else ("http", "ws")
            trust = [certificate] if tls else []
            try:
                for mode, scheme, path in (("sse", schemes[0], "/events"),
                                           ("sse-reject", schemes[0], "/events/wrong"),
                                           ("ws", schemes[1], "/socket"),
                                           ("ws-reject", schemes[1], "/bad-accept"),
                                           ("ws-reject", schemes[1], "/bad-extension")):
                    subprocess.run([client, mode, f"{scheme}://{address}:{port}{path}", *trust],
                                   check=True, timeout=14)
                    if server.failure is not None:
                        raise server.failure
                    print(f"{scheme} {path} {mode} passed", flush=True)
            finally:
                server.shutdown()
                thread.join(3)


if __name__ == "__main__":
    check(*(Path(arg).resolve() for arg in sys.argv[1:]))
