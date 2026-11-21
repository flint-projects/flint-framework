"""Exercise real localhost OTLP acknowledgement and retry behavior."""

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import socket
import subprocess
from threading import Thread
import time


def check(executable, retry):
    requests = []

    class Collector(BaseHTTPRequestHandler):
        def do_POST(self):
            assert self.headers.get_content_type() == "application/json"
            size = int(self.headers["Content-Length"])
            assert 0 < size <= 2 * 1024 * 1024
            body = self.rfile.read(size)
            data = json.loads(body)
            assert self.path in ("/v1/traces", "/v1/metrics")
            field = "resourceSpans" if self.path.endswith("traces") else "resourceMetrics"
            assert len(data[field]) == 1
            previous = sum(path == self.path for path, _, _ in requests)
            requests.append((self.path, time.monotonic(), body))
            status = 200
            extra = {}
            response = b"{}"
            if self.path == "/v1/traces":
                if not retry:
                    response = b'{"partialSuccess":{"rejectedSpans":"negative"}}'
                elif previous == 0:
                    status = 503
                    extra = {"Retry-After": "1"}
                else:
                    response = b'{"partialSuccess":{"rejectedSpans":"2","errorMessage":"fixture"}}'
            elif retry and previous == 0:
                response = b'{"partialSuccess":{"rejectedDataPoints":3}}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            for key, value in extra.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(response)

    with HTTPServer(("127.0.0.1", 0), Collector) as receiver:
        serving = Thread(target=receiver.serve_forever)
        serving.start()
        try:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            endpoint = f"http://127.0.0.1:{receiver.server_port}"
            mode = "retry" if retry else "invalid-ack"
            subprocess.run([executable, endpoint, str(port), mode], check=True, timeout=12)
        finally:
            receiver.shutdown()
            serving.join()

    traces = [(at, body) for path, at, body in requests if path == "/v1/traces"]
    assert len(traces) == (2 if retry else 1)
    if retry:
        elapsed = traces[1][0] - traces[0][0]
        assert elapsed >= 0.99
        assert traces[0][1] == traces[1][1]
        print(f"retry_after_elapsed_seconds={elapsed:.3f} identical_trace_bytes={len(traces[0][1])}")
    else:
        print("invalid_acknowledgement_rejected=1 trace_attempts=1")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    args = parser.parse_args()
    check(args.executable, retry=True)
    check(args.executable, retry=False)
