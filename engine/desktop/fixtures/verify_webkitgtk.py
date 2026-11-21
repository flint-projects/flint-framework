#!/usr/bin/env python3
"""Exercise private and external origins against an actual WebKitGTK window."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
import subprocess
from tempfile import TemporaryDirectory
import threading

HTML = b"""<!doctype html><meta charset="utf-8">
<script>
window.webkit.messageHandlers.flint.postMessage([1, 1, 5, 0, 102, 111, 114, 103, 101]);
fetch("/attempted");
</script>
"""


def remote(binary):
    attempted = threading.Event()

    class Fixture(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/attempted":
                body = b"recorded"
                attempted.set()
            elif self.path == "/":
                body = HTML
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format_, *arguments):
            return

    with TemporaryDirectory(prefix="flint-desktop-loopback-") as temp:
        key = Path(temp) / "key.pem"
        pem = Path(temp) / "cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
            "-keyout", key, "-out", pem,
        ], check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(pem, key)
        with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                subprocess.run([binary, f"https://127.0.0.1:{server.server_port}", pem], timeout=18, check=True)
                assert attempted.is_set(), "Remote JavaScript did not attempt native IPC"
                print("Loopback HTTPS server observed the remote IPC attempt")
            finally:
                server.shutdown()
                thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    arguments = parser.parse_args()
    binary = arguments.binary.resolve()
    subprocess.run([binary], timeout=18, check=True)
    remote(binary)


if __name__ == "__main__":
    main()
