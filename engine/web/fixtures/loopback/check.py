"""Exercise Web over actual sockets. The independent peer requires hyper-h2 4.4.1."""
from contextlib import ExitStack, closing
import http.client
import json
import socket
import ssl
import subprocess
import sys
import time

from h2 import config, connection, events, settings
from hyperframe.frame import WindowUpdateFrame

PAYLOAD = bytes(ord('a') + i % 23 for i in range(128 * 1024))
JSON = b'{"id":-9223372036854775808,"size":18446744073709551615}'
TARGET = '/typed/-9223372036854775808?size=18446744073709551615'

def listener(binary, mode, *options):
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    server = subprocess.Popen([binary, str(port), mode, *options])
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            if server.poll() is not None:
                raise RuntimeError(f'{mode} exited while starting with {server.returncode}')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                    return server, port
            except OSError:
                time.sleep(0.02)
        raise RuntimeError(f'{mode} never opened its listener')
    except BaseException:
        server.kill()
        server.wait()
        raise

def wait_until(condition):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.01)
    raise AssertionError('condition did not become true')

def request(client, method, path, body=None):
    client.request(method, path, body, {'content-type': 'application/json'} if body else {})
    answer = client.getresponse()
    return answer.status, answer.read()

def wait_observation(client, field, count):
    wait_until(lambda: json.loads(request(client, 'GET', '/observations')[1])[field] >= count)

def worker_cases(client, port):
    with socket.create_connection(('127.0.0.1', port), timeout=3) as pending:
        pending.sendall(b'GET /worker/3?slow=true HTTP/1.1\r\nHost: localhost\r\n\r\n')
        wait_until(lambda: json.loads(request(client, 'GET', '/worker-observations')[1])['admitted'] == 1)
    wait_until(lambda: request(client, 'GET', '/worker-canceled') == (200, b'1'))
    assert request(client, 'GET', TARGET) == (200, JSON)
    assert json.loads(request(client, 'GET', '/worker-observations')[1]) == {'admitted': 1, 'canceled': 0}
    assert request(client, 'GET', '/release-worker') == (204, b'')
    assert request(client, 'GET', '/worker/7') == (200, b'{"id":7,"bytes":14}')
    assert request(client, 'GET', '/worker/9') == (200, b'{"id":9,"bytes":16}')
    assert request(client, 'GET', '/worker/10?extra=' + 'x' * 4096)[0] == 413

def h1(binary):
    process, port = listener(binary, 'h1')
    try:
        with closing(http.client.HTTPConnection('127.0.0.1', port, timeout=4)) as client:
            assert request(client, 'GET', TARGET) == (200, JSON)
            original = client.sock
            for target in ('/typed/9223372036854775808?size=1', '/typed/-9223372036854775809?size=1',
                           '/typed/1?size=18446744073709551616', '/typed/1?size=1&s%69ze=2',
                           '/typed/1', '/typed/%2f?size=1', '/typed/%00?size=1', '/typed/%GG?size=1',
                           '/typed/1?size=1&unused=%GG'):
                assert request(client, 'GET', target)[0] == 400, target
            assert request(client, 'GET', '/typed/%31?s%69ze=%32') == (200, b'{"id":1,"size":2}')
            for missing in (b'{}', b'{"name":"  "}', b'{"name":"\xe2\x80\x83"}'):
                status, result = request(client, 'POST', '/post', missing)
                assert status == 400 and json.loads(result)['field'] == 'name', (status, result)
            assert request(client, 'POST', '/post', b'{"name":"Ada"}') == (201, b'{"name":"Ada"}')
            assert request(client, 'GET', '/conflict') == (409, b'{"error":"already exists"}')
            assert request(client, 'GET', '/large') == (200, PAYLOAD)
            assert client.sock is original
            worker_cases(client, port)

            with socket.create_connection(('127.0.0.1', port), timeout=3) as hold:
                hold.sendall(b'GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n')
                wait_observation(client, 'admitted', 1)
            wait_observation(client, 'canceled', 1)

            with socket.socket() as slow:
                slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                slow.settimeout(3)
                slow.connect(('127.0.0.1', port))
                slow.sendall(b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n' * 24)
                assert request(client, 'GET', TARGET) == (200, JSON)

            with socket.create_connection(('127.0.0.1', port), timeout=3) as malformed:
                malformed.sendall(b'POST /post HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n'
                                  b'Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n')
                assert malformed.recv(4096).startswith(b'HTTP/1.1 400')
                assert malformed.recv(1) == b''

            try:
                request(client, 'GET', '/shutdown')
            except (ConnectionError, http.client.RemoteDisconnected):
                pass
        assert process.wait(5) == 0
        print('H1 bindings, advice, slow receiver, 128 KiB sends, disconnect, owned worker cancellation and reuse passed')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

class H2Peer:
    def __init__(self, port, tls_context=None):
        transport = socket.create_connection(('127.0.0.1', port), timeout=4)
        self.socket = transport if tls_context is None else tls_context.wrap_socket(transport, server_hostname='localhost')
        self.scheme = 'http' if tls_context is None else 'https'
        self.engine = connection.H2Connection(config=config.H2Configuration(header_encoding='utf-8'))
        self.engine.initiate_connection()
        self.engine.update_settings({settings.SettingCodes.INITIAL_WINDOW_SIZE: 0})
        self.flush()
        self.messages = {}
        self.errors = {}
        self.ended = set()
        self.goaway = None

    def flush(self):
        output = self.engine.data_to_send()
        if output:
            self.socket.sendall(output)

    def take(self):
        received = self.socket.recv(65536)
        if not received:
            raise ConnectionError('HTTP/2 socket reached EOF')
        for event in self.engine.receive_data(received):
            if isinstance(event, events.ResponseReceived):
                self.messages[event.stream_id][0] = int(dict(event.headers)[':status'])
            if isinstance(event, events.DataReceived):
                self.messages[event.stream_id][1].extend(event.data)
            if isinstance(event, events.StreamEnded):
                self.ended.add(event.stream_id)
            if isinstance(event, events.StreamReset):
                self.errors[event.stream_id] = int(event.error_code)
                self.ended.add(event.stream_id)
            if isinstance(event, events.ConnectionTerminated):
                self.goaway = int(event.error_code)
        self.flush()

    def through(self, predicate):
        while not predicate():
            self.take()

    def get(self, path, credit=0):
        stream = self.engine.get_next_available_stream_id()
        self.messages[stream] = [0, bytearray()]
        self.engine.send_headers(stream, [(':method', 'GET'), (':scheme', self.scheme),
                                         (':authority', 'localhost'), (':path', path)], end_stream=True)
        if credit:
            self.engine.increment_flow_control_window(credit, stream_id=stream)
        self.flush()
        return stream

    def result(self, stream):
        self.through(lambda: stream in self.ended)
        status, body = self.messages[stream]
        return status, bytes(body)

def h2(binary):
    process, port = listener(binary, 'h2')
    try:
        peer = H2Peer(port)
        with peer.socket:
            large = peer.get('/large')
            held = peer.get('/hold')
            peer.through(lambda: peer.messages[large][0] == 200)
            assert len(peer.messages[large][1]) == 0
            assert peer.result(peer.get(TARGET, credit=1000)) == (200, JSON)
            assert peer.result(peer.get('/conflict', credit=1000)) == (409, b'{"error":"already exists"}')

            seen = peer.get('/observations', credit=1000)
            assert json.loads(peer.result(seen)[1])['admitted'] >= 1
            peer.engine.reset_stream(held)
            peer.flush()
            wait_until(lambda: json.loads(peer.result(peer.get('/observations', credit=1000))[1])['canceled'] >= 1)

            peer.engine.increment_flow_control_window(4096, stream_id=large)
            peer.flush()
            peer.through(lambda: len(peer.messages[large][1]) >= 4096)
            assert len(peer.messages[large][1]) == 4096
            assert peer.result(peer.get(TARGET, credit=1000)) == (200, JSON)
            assert len(peer.messages[large][1]) == 4096

            peer.engine.increment_flow_control_window(160000)
            peer.engine.increment_flow_control_window(160000, stream_id=large)
            peer.flush()
            assert peer.result(large) == (200, PAYLOAD)
            saturated = H2Peer(port)
            with saturated.socket:
                active = [saturated.get('/hold') for _ in range(4)]
                excessive = saturated.get('/hold')
                saturated.through(lambda: excessive in saturated.errors)
                assert saturated.errors[excessive] == 7, saturated.errors
                for stream in active:
                    saturated.engine.reset_stream(stream)
                saturated.flush()

            overflow = peer.get('/hold', credit=64)
            sibling = peer.get(TARGET, credit=1000)
            assert peer.result(sibling) == (200, JSON)
            frame = WindowUpdateFrame(overflow)
            frame.window_increment = 0x7fffffff
            wire = frame.serialize()
            for segment in (wire[:3], wire[3:10], wire[10:]):
                peer.socket.sendall(segment)
            peer.through(lambda: overflow in peer.errors)
            assert peer.errors[overflow] == 3
            assert peer.result(peer.get(TARGET, credit=1000)) == (200, JSON)

            retiring = H2Peer(port)
            with retiring.socket:
                assert retiring.result(retiring.get(TARGET, credit=1000)) == (200, JSON)
                retiring.engine.close_connection()
                retiring.flush()
                retiring.through(lambda: retiring.goaway is not None)
                assert retiring.goaway == 0
                retiring.socket.shutdown(socket.SHUT_WR)
                assert retiring.socket.recv(1) == b''

            peer.get('/shutdown')
            peer.through(lambda: peer.goaway is not None)
            assert peer.goaway == 0
        assert process.wait(5) == 0
        print('H2 multiplexing, flow credit, stream-local overflow, reciprocal GOAWAY and 128 KiB drainage passed')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

def shutdown_stress(binary):
    process, port = listener(binary, 'stress')
    try:
        with ExitStack() as resources:
            pending = []
            for _ in range(1024):
                peer = resources.enter_context(socket.create_connection(('127.0.0.1', port), timeout=4))
                peer.sendall(b'GET /hold HTTP/1.1\r\nHost: localhost\r\n\r\n')
                pending.append(peer)
            client = resources.enter_context(closing(http.client.HTTPConnection('127.0.0.1', port, timeout=4)))
            wait_observation(client, 'admitted', 1024)
            try:
                request(client, 'GET', '/shutdown')
            except (ConnectionError, http.client.RemoteDisconnected):
                pass
            assert process.wait(8) == 0
            assert all(peer.recv(1) == b'' for peer in pending)
        print('shutdown joined 1,024 admitted fibers and closed every connection without a response')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

def tls(binary, certificate, key, unrelated_key):
    rejected = subprocess.run([binary, '0', 'tls', certificate, unrelated_key], timeout=3)
    assert rejected.returncode == 3, rejected.returncode
    process, port = listener(binary, 'tls', certificate, key)
    try:
        h1_context = ssl.create_default_context(cafile=certificate)
        h1_context.set_alpn_protocols(['http/1.1'])
        with closing(http.client.HTTPSConnection('localhost', port, timeout=4, context=h1_context)) as client:
            assert request(client, 'GET', TARGET) == (200, JSON)
            original = client.sock
            assert original.selected_alpn_protocol() == 'http/1.1'
            assert request(client, 'GET', '/large') == (200, PAYLOAD)
            assert client.sock is original

            unsupported = ssl.create_default_context(cafile=certificate)
            unsupported.set_alpn_protocols(['example.unsupported'])
            with socket.create_connection(('127.0.0.1', port), timeout=3) as wire:
                try:
                    unsupported.wrap_socket(wire, server_hostname='localhost')
                except ssl.SSLError:
                    pass
                else:
                    raise AssertionError('server accepted unsupported ALPN')

            h2_context = ssl.create_default_context(cafile=certificate)
            h2_context.set_alpn_protocols(['http/1.1', 'h2'])
            peer = H2Peer(port, h2_context)
            with peer.socket:
                assert peer.socket.selected_alpn_protocol() == 'h2'
                assert peer.result(peer.get(TARGET, credit=1000)) == (200, JSON)
                try:
                    request(client, 'GET', '/shutdown')
                except (ConnectionError, http.client.RemoteDisconnected):
                    pass
                peer.through(lambda: peer.goaway is not None)
                assert peer.goaway == 0
        assert process.wait(5) == 0
        print('TLS trusted PEM certificate, matching key validation, dual ALPN, 128 KiB drainage and ALPN rejection passed')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

if __name__ == '__main__':
    h1(sys.argv[1])
    h2(sys.argv[1])
    shutdown_stress(sys.argv[1])
    if len(sys.argv) == 5:
        tls(*sys.argv[1:5])
