"""Milestone 10 (ADR-028 section 10): SIGTERM and SIGINT shut a flint:engine-web application down gracefully.

The fixture in tests/integration/graceful-shutdown composes flint:os's watchShutdownSignals with flint:engine-web's
runApplication. It links the pinned native providers, so build them first (tools/native_build.py --emit-dub).
FLINT_TEST_COMPILER picks the compiler (dmd by default)."""
import http.client
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
import unittest
from pathlib import Path

import os
import sys
sys.path.insert(0, str(Path(os.environ.get('FLINT_ROOT') or Path(__file__).resolve().parents[2]) / 'tests'))
from flint_testing import FLINT_ROOT, package_dir, repo_dir  # noqa: E402,F401
ROOT = FLINT_ROOT
FIXTURE = repo_dir('framework', 'tests/framework/integration/graceful-shutdown')
BINARY = FIXTURE / 'build' / 'flint-graceful-shutdown-fixture'


def setUpModule():
    global BINARY
    if shutil.which('dub') is None:
        raise unittest.SkipTest('dub is not on PATH')
    compiler = os.environ.get('FLINT_TEST_COMPILER', 'dmd')
    if (FIXTURE.parents[3] / 'packages' / 'arena').is_dir():
        # The monorepo: the fixture's flint:* paths reach this checkout's root recipe.
        built = subprocess.run(['dub', 'build', '--root', str(FIXTURE), '--compiler=' + compiler],
                               cwd=ROOT, capture_output=True, text=True, timeout=900)
        if built.returncode != 0:
            raise RuntimeError('fixture build failed:\n' + built.stdout + built.stderr)
        return
    # flint-framework: build a copy against the workspace's joined recipe (tools/workspace.py build-example).
    import tempfile
    import workspace
    from flint_testing import WORKSPACE
    output = Path(tempfile.mkdtemp(prefix='flint-graceful-'))
    if workspace.build_example(FIXTURE, WORKSPACE, output, compiler, FLINT_ROOT) != 0:
        raise RuntimeError('fixture build failed against the workspace')
    BINARY = output / 'example' / 'build' / 'flint-graceful-shutdown-fixture'


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def refused(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=0.2):
            return False
    except ConnectionRefusedError:
        return True


class Request(threading.Thread):
    """One GET on its own connection, recording the status or the failure."""

    def __init__(self, port, target):
        super().__init__(daemon=True)
        self.port, self.target = port, target
        self.status, self.failure = None, None
        self.sent = threading.Event()

    def run(self):
        client = http.client.HTTPConnection('127.0.0.1', self.port, timeout=40)
        try:
            client.request('GET', self.target)
            self.sent.set()
            self.status = client.getresponse().status
        except (OSError, http.client.HTTPException) as error:
            self.failure = error
        finally:
            self.sent.set()
            client.close()


class GracefulShutdownTests(unittest.TestCase):
    def start(self, grace_ms):
        port = free_port()
        process = subprocess.Popen([str(BINARY), str(port), str(grace_ms)], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        self.addCleanup(self.reap, process)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            self.assertIsNone(process.poll(), 'the fixture exited while starting')
            if not refused(port):
                return process, port
            time.sleep(0.02)
        self.fail('the fixture never listened')

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.wait()
        if not process.stdout.closed:
            process.stdout.close()

    def in_flight(self, port, target):
        request = Request(port, target)
        request.start()
        request.sent.wait(5)
        time.sleep(0.3)  # The handler is running before the signal arrives.
        return request

    def wait_refused(self, port):
        deadline = time.monotonic() + 3
        while not refused(port):
            self.assertLess(time.monotonic(), deadline, 'new connections were still admitted while draining')
            time.sleep(0.01)

    def drains(self, number):
        process, port = self.start(10_000)
        request = self.in_flight(port, '/slow?ms=1500')
        os.kill(process.pid, number)
        self.wait_refused(port)
        self.assertIsNone(process.poll(), 'the application stopped before its request finished')
        request.join(10)
        self.assertEqual(request.status, 200, request.failure)
        self.assertEqual(process.wait(10), 0)
        self.assertIn('exit 0 after 1 signal(s)', process.communicate()[0])

    def test_sigterm_finishes_the_in_flight_request_refuses_new_connections_and_exits_0(self):
        self.drains(signal.SIGTERM)

    def test_sigint_behaves_the_same(self):
        self.drains(signal.SIGINT)

    def test_an_idle_application_exits_0_at_once(self):
        process, port = self.start(10_000)
        began = time.monotonic()
        os.kill(process.pid, signal.SIGTERM)
        self.assertEqual(process.wait(5), 0)
        self.assertLess(time.monotonic() - began, 2)

    def test_the_grace_period_expiring_cancels_the_request_and_exits_124(self):
        process, port = self.start(300)
        request = self.in_flight(port, '/slow?ms=20000')
        began = time.monotonic()
        os.kill(process.pid, signal.SIGTERM)
        self.assertEqual(process.wait(5), 124)
        self.assertGreaterEqual(time.monotonic() - began, 0.3)
        request.join(5)
        self.assertIsNone(request.status)

    def test_a_second_signal_forces_the_exit_with_130(self):
        process, port = self.start(30_000)
        request = self.in_flight(port, '/slow?ms=20000')
        os.kill(process.pid, signal.SIGTERM)
        self.wait_refused(port)
        time.sleep(0.2)
        self.assertIsNone(process.poll(), 'one signal did not leave the drain running')
        os.kill(process.pid, signal.SIGINT)
        self.assertEqual(process.wait(5), 130)
        self.assertIn('exit 130 after 2 signal(s)', process.communicate()[0])
        request.join(5)
        self.assertIsNone(request.status)

    def test_a_handler_that_ignores_cancellation_does_not_hold_the_process(self):
        process, port = self.start(300)
        self.in_flight(port, '/worker/stuck')
        began = time.monotonic()
        os.kill(process.pid, signal.SIGTERM)
        self.assertEqual(process.wait(10), 124)
        self.assertLess(time.monotonic() - began, 8)


if __name__ == '__main__':
    unittest.main()
