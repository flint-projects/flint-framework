#!/usr/bin/env python3
"""Exercise the identical body admission rule over llhttp and nghttp2."""

import http.client
import socket
import subprocess
import sys
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset

ORDINARY = 1_048_576
LARGER = 4 * 1024 * 1024
BODY = b'a' * (ORDINARY + 1)


def request_h1(port, path, body=b'', length=None, method='POST'):
    with socket.create_connection(('127.0.0.1', port), timeout=8) as connection:
        connection.sendall(
            (f'{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
             f'Content-Length: {len(body) if length is None else length}\r\n\r\n').encode()
        )
        if body:
            connection.sendall(body)
        response = http.client.HTTPResponse(connection)
        response.begin()
        return response.status, response.read()


def request_h2(port, path, body=b'', method='POST'):
    with socket.create_connection(('127.0.0.1', port), timeout=8) as connection:
        client = H2Connection(config=H2Configuration(header_encoding='ascii'))
        client.initiate_connection()
        client.send_headers(1, [
            (':method', method), (':authority', 'localhost'), (':scheme', 'http'), (':path', path),
            ('content-length', str(len(body))),
        ], end_stream=not body)
        remaining = memoryview(body)
        status = None
        received = bytearray()
        while True:
            if remaining:
                window = client.local_flow_control_window(1)
                while window > 0 and remaining:
                    count = min(window, client.max_outbound_frame_size, len(remaining))
                    client.send_data(1, remaining[:count], end_stream=count == len(remaining))
                    remaining = remaining[count:]
                    window -= count
            connection.sendall(client.data_to_send())
            data = connection.recv(65536)
            if not data:
                raise AssertionError(f'EOF before stream {path} completed')
            for event in client.receive_data(data):
                if isinstance(event, ResponseReceived):
                    status = int(dict(event.headers)[':status'])
                elif isinstance(event, DataReceived):
                    received.extend(event.data)
                    client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, StreamReset):
                    return 'reset', event.error_code
                elif isinstance(event, StreamEnded):
                    return status, bytes(received)


def local_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def run(executable, mode):
    port = local_port()
    with subprocess.Popen([executable, str(port), mode]) as instance:
        try:
            for _ in range(200):
                try:
                    socket.create_connection(('127.0.0.1', port), timeout=0.1).close()
                    break
                except OSError:
                    if instance.poll() is not None:
                        raise RuntimeError(f'{mode} server exited: {instance.returncode}')
                    time.sleep(0.01)
            else:
                raise RuntimeError(f'{mode} server did not listen')
            if mode == 'h1':
                assert request_h1(port, '/ordinary', length=len(BODY))[0] == 413
                assert request_h1(port, '/large', BODY) == (200, b'large request accepted')
                assert request_h1(port, '/large', b'a' * LARGER) == (200, b'large request accepted')
                assert request_h1(port, '/large', length=LARGER + 1)[0] == 413
                assert request_h1(port, '/ordinary', BODY[:ORDINARY])[0] == 204
                assert request_h1(port, '/shutdown', method='GET')[0] == 204
            else:
                assert request_h2(port, '/ordinary', BODY)[0] == 'reset'
                assert request_h2(port, '/large', BODY) == (200, b'large request accepted')
                assert request_h2(port, '/large', b'a' * LARGER) == (200, b'large request accepted')
                assert request_h2(port, '/large', b'a' * (LARGER + 1))[0] == 'reset'
                assert request_h2(port, '/ordinary', BODY[:ORDINARY])[0] == 204
                assert request_h2(port, '/shutdown', method='GET')[0] == 204
            assert instance.wait(timeout=10) == 0
            print(f'{mode}: ordinary 1 MiB, streaming-only 4 MiB, above-limit rejection, clean shutdown')
        finally:
            if instance.poll() is None:
                instance.kill()


if __name__ == '__main__':
    executable = sys.argv[1]
    for mode in ('h1', 'h2'):
        run(executable, mode)
