#!/usr/bin/env python3
"""Measure real HTTP/2 stream credit through Flint while its application withholds reads."""
from pathlib import Path
import socket
import subprocess
import sys
import threading

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, RequestReceived


class Transfer:
    def __init__(self, total):
        self.total = total
        self.sent = 0
        self.max_credit = 0
        self.stream = None
        self.error = None
        self.snapshot = threading.Lock()
        self.done = threading.Event()

    def serve(self, listener):
        try:
            with listener.accept()[0] as peer:
                peer.settimeout(23)
                route = H2Connection(H2Configuration(client_side=False))
                route.initiate_connection()
                peer.sendall(route.data_to_send())
                while not self.done.is_set():
                    wire = peer.recv(65536)
                    if not wire:
                        break
                    for event in route.receive_data(wire):
                        if isinstance(event, RequestReceived):
                            assert self.stream is None
                            self.stream = event.stream_id
                            route.send_headers(self.stream, [(b":status", b"200")])
                        elif isinstance(event, DataReceived):
                            route.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    if self.stream is not None:
                        self.produce(route)
                    packet = route.data_to_send()
                    if packet:
                        peer.sendall(packet)
        except BaseException as exc:
            self.error = exc

    def produce(self, route):
        with self.snapshot:
            credit = route.local_flow_control_window(self.stream)
            self.max_credit = max(self.max_credit, credit)
            while self.sent < self.total and credit > 0:
                next_count = min(credit, route.max_outbound_frame_size, self.total - self.sent)
                self.sent += next_count
                credit -= next_count
                route.send_data(self.stream, b"a" * next_count, end_stream=self.sent == self.total)


def verify(client, rate, total):
    with socket.create_server(("127.0.0.1", 0)) as listener:
        address, port = listener.getsockname()
        transfer = Transfer(total)
        server = threading.Thread(target=transfer.serve, args=(listener,), daemon=True)
        server.start()
        with subprocess.Popen([client, f"http://{address}:{port}/flow", str(rate), str(total)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as proc:
            try:
                assert proc.stdout.readline().strip() == "held"
                with transfer.snapshot:
                    held = transfer.sent
                    peak = transfer.max_credit
                    assert 0 < held < total
                    assert held <= min(2 * rate + 65536, 1024 * 1024), (rate, held, peak)
                proc.stdin.write("\n")
                proc.stdin.flush()
                output, _ = proc.communicate(timeout=24)
                assert proc.returncode == 0 and output.strip() == f"drained={total}", output
                print(f"rate={rate} paused_received={held} largest_pre_drain_stream_credit={peak} drained={total}")
            finally:
                transfer.done.set()
                if proc.poll() is None:
                    proc.kill()
        server.join(timeout=2)
        if transfer.error:
            raise transfer.error


if __name__ == "__main__":
    sys.path.insert(0, str(Path.cwd()))
    binary = Path(sys.argv[1]).resolve()
    verify(binary, 32 * 1024, 128 * 1024)
    verify(binary, 256 * 1024, 640 * 1024)
