"""Exercise all gRPC message shapes and flow-credit scheduling with an independent H2 client."""
from collections import defaultdict
import socket
import subprocess
import sys
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, TrailersReceived
from h2.settings import SettingCodes


def record(payload):
    return b'\0' + len(payload).to_bytes(4, 'big') + payload


def records(wire):
    result = []
    while wire:
        assert len(wire) >= 5 and wire[0] == 0
        end = 5 + int.from_bytes(wire[1:5], 'big')
        assert end <= len(wire)
        result.append(wire[5:end])
        wire = wire[end:]
    return result


class Client:
    def __init__(self, sock):
        self.socket = sock
        self.protocol = H2Connection(H2Configuration(client_side=True, header_encoding='ascii'))
        self.headers = {}
        self.trailers = defaultdict(list)
        self.bodies = defaultdict(bytearray)
        self.done = set()
        self.reset = set()
        self.protocol.initiate_connection()
        self.protocol.update_settings({SettingCodes.INITIAL_WINDOW_SIZE: 4096})
        self.flush()

    def flush(self):
        outgoing = self.protocol.data_to_send()
        if outgoing:
            self.socket.sendall(outgoing)

    def pump(self):
        wire = self.socket.recv(131_072)
        assert wire
        for event in self.protocol.receive_data(wire):
            stream = getattr(event, 'stream_id', 0)
            if isinstance(event, DataReceived):
                self.bodies[stream] += event.data
                self.protocol.acknowledge_received_data(event.flow_controlled_length, stream)
            elif isinstance(event, ResponseReceived):
                self.headers[stream] = dict(event.headers)
            elif isinstance(event, TrailersReceived):
                self.trailers[stream].append(dict(event.headers))
            elif isinstance(event, StreamEnded):
                self.done.add(stream)
            elif isinstance(event, StreamReset):
                self.reset.add(stream)
        self.flush()

    def open(self, stream, method, headers=()):
        self.protocol.send_headers(stream, [
            (':method', 'POST'), (':path', '/flint.rpc.fixture.Echo/' + method),
            (':scheme', 'http'), (':authority', 'loopback'),
            ('content-type', 'application/grpc'), ('te', 'trailers'), *headers])
        self.flush()

    def send(self, stream, wire, end=False):
        while wire:
            credit = self.protocol.local_flow_control_window(stream)
            count = min(len(wire), credit, self.protocol.max_outbound_frame_size)
            if count <= 0:
                self.pump()
                continue
            self.protocol.send_data(stream, wire[:count])
            wire = wire[count:]
            self.flush()
        if end:
            self.protocol.end_stream(stream)
            self.flush()

    def expect(self, stream, payloads, status=0, message=None):
        until = time.monotonic() + 8
        while stream not in self.done:
            assert stream not in self.reset, (stream, self.headers, self.reset)
            assert time.monotonic() < until, (stream, self.headers, self.reset)
            self.pump()
        assert self.headers[stream][':status'] == '200'
        assert self.headers[stream]['content-type'] == 'application/grpc'
        expected = {'grpc-status': str(status)}
        if message is not None:
            expected['grpc-message'] = message
        assert self.trailers[stream] == [expected], self.trailers
        assert records(self.bodies[stream]) == payloads


def exercise(sock):
    peer = Client(sock)
    peer.open(1, 'Unary')
    packed = record(b'one')
    peer.send(1, packed[:2])
    peer.send(1, packed[2:], end=True)
    peer.expect(1, [b'one'])

    peer.open(3, 'ClientStream')
    peer.send(3, record(b'one') + record(b'two') + record(b'three'), end=True)
    peer.expect(3, [b'three'])

    peer.open(5, 'ServerStream')
    peer.send(5, record(b'repeat'), end=True)
    peer.expect(5, [b'repeat'] * 3)

    peer.open(7, 'Bidi')
    peer.open(9, 'Bidi')
    one = bytes(range(256)) * 256
    two = one[::-1]
    # Both messages exceed an initial receive window. The independent streams take turns.
    peer.send(7, record(one)[:32_768])
    peer.send(9, record(two)[:30_000])
    peer.send(7, record(one)[32_768:])
    peer.send(9, record(two)[30_000:])
    peer.send(7, record(two), end=True)
    peer.send(9, record(one), end=True)
    peer.expect(7, [one, two])
    peer.expect(9, [two, one])

    peer.open(11, 'Unary', [('grpc-timeout', '20m')])
    peer.expect(11, [], status=4)
    peer.protocol.end_stream(11)
    peer.flush()

    peer.open(13, 'Unary')
    peer.protocol.reset_stream(13)
    peer.flush()
    peer.open(15, 'Unary')
    peer.send(15, record(b'final'), end=True)
    peer.expect(15, [b'final'])

    peer.open(17, 'Unary')
    peer.send(17, b'\1\0\0\0\0', end=True)
    peer.expect(17, [], status=12)

    peer.open(19, 'Unary')
    peer.send(19, record(b'abc')[:-1], end=True)
    peer.expect(19, [], status=3)

    peer.open(21, 'Status')
    peer.send(21, b'', end=True)
    peer.expect(21, [], status=10, message='10%25 %F0%9F%9A%80')



def main():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    process = subprocess.Popen([sys.argv[1], str(port), 'h2'])
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                socket_connection = socket.create_connection(('127.0.0.1', port), timeout=2)
                break
            except OSError:
                if process.poll() is not None or time.monotonic() > deadline:
                    raise
                time.sleep(.02)
        with socket_connection:
            exercise(socket_connection)
        print('gRPC all four message shapes, two duplex 64-KiB streams, deadlines, terminal trailers and reset passed')
    finally:
        process.terminate()
        process.wait(5)


if __name__ == '__main__':
    main()
