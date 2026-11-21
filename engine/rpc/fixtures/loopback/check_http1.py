"""Verify the SSE and RFC 6455 interfaces with independent wire clients."""
import http.client
import socket
import subprocess
import sys
import time


def exact(reader, count):
    data = reader.read(count)
    assert len(data) == count, (count, data)
    return data


def frame(opcode, payload, final=True):
    assert 0 <= len(payload) < 126
    mask = bytes([1, 2, 3, 4])
    return bytes([(128 if final else 0) | opcode, 128 | len(payload)]) + mask + bytes(
        item ^ mask[index % 4] for index, item in enumerate(payload))


def received(reader):
    first, second = exact(reader, 2)
    assert first & 128 and not second & 128
    return first & 15, exact(reader, second)


def upgrade(port, path='/socket', version='13', suffix=b''):
    connection = socket.create_connection(('127.0.0.1', port), timeout=7)
    connection.sendall((f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
                        'Connection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n'
                        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
                        f'Sec-WebSocket-Version: {version}\r\n\r\n').encode() + suffix)
    reader = connection.makefile('rb')
    status = reader.readline().decode()
    fields = {}
    while True:
        line = reader.readline()
        if line == b'\r\n':
            break
        name, value = line.split(b':', 1)
        fields[name.lower()] = value.strip()
    return connection, reader, status, fields


def websocket(port):
    rocket = '🚀'.encode()
    prefetched = frame(1, rocket[:2], final=False) + frame(9, b'ping') + frame(0, rocket[2:])
    connection, reader, status, fields = upgrade(port, suffix=prefetched)
    with connection, reader:
        assert ' 101 ' in status, status
        assert fields[b'sec-websocket-accept'] == b's3pPLMBiTxaQ9kYGzzhZRbK+xOo='
        assert received(reader) == (10, b'ping')
        assert received(reader) == (1, rocket)
        binary = bytes(range(16))
        connection.sendall(frame(2, binary))
        assert received(reader) == (2, binary)
        connection.sendall(frame(8, b'\x03\xe8finished'))
        assert received(reader) == (8, b'\x03\xe8finished')
        assert reader.read(1) == b''

    connection, reader, status, fields = upgrade(port, version='12')
    with connection, reader:
        assert ' 426 ' in status and fields[b'sec-websocket-version'] == b'13'
    connection, reader, status, _ = upgrade(port, suffix=b'\x81\x00')
    with connection, reader:
        assert ' 101 ' in status
        assert received(reader) == (8, b'\x03\xea')
    connection, reader, status, _ = upgrade(port, '/close')
    with connection, reader:
        assert ' 101 ' in status
        assert received(reader) == (8, b'\x03\xe8done')
        started = time.monotonic()
        assert reader.read(1) == b''
        elapsed = time.monotonic() - started
        assert 4.0 <= elapsed < 6.0, elapsed


def sse(port):
    with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
        client.sendall(b'GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n')
        with http.client.HTTPResponse(client) as response:
            response.begin()
            assert response.status == 200
            assert response.getheader('Content-Type') == 'text/event-stream'
            assert response.getheader('Transfer-Encoding') == 'chunked'
            expected = ['event: update\n', 'id: id-42\n', 'retry: 600\n', 'data: first\n',
                        'data: second🚀\n', '\n', ': ready\n', '\n']
            assert [response.readline().decode() for _ in expected] == expected
            client.shutdown(socket.SHUT_RDWR)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        check = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
        check.request('GET', '/observed')
        data = check.getresponse().read()
        check.close()
        if data == b'cancelled':
            return
        time.sleep(.01)
    raise AssertionError(('disconnect did not cancel the event handler', data))


def main():
    with socket.socket() as scratch:
        scratch.bind(('127.0.0.1', 0))
        port = scratch.getsockname()[1]
    server = subprocess.Popen([sys.argv[1], str(port), 'h1'])
    try:
        start = time.monotonic()
        while True:
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                if server.poll() is not None or time.monotonic() - start > 4:
                    raise
                time.sleep(.02)
        websocket(port)
        sse(port)
        print('H1 upgrade, coalesced masked fragments, ping/pong, graceful close, 5s close timeout, SSE and disconnect passed')
    finally:
        server.terminate()
        server.wait(5)


if __name__ == '__main__':
    main()
