#!/usr/bin/env python3
"""Verify display, resize, async completion and exact terminal restoration on a Linux PTY."""
import argparse
import contextlib
import errno
import fcntl
import os
import pty
import selectors
import signal
import struct
import subprocess
import termios
import time
from pathlib import Path


class Terminal:
    def __init__(self, binary, *args):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.resize(80, 24)
        self.bytes = bytearray()
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.master, selectors.EVENT_READ)
        self.child = subprocess.Popen(
            [binary, *args], stdin=self.slave, stdout=self.slave, stderr=self.slave,
            env={**os.environ, "TERM": "xterm-256color"},
        )

    def resize(self, columns, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        if hasattr(self, "child"):
            self.child.send_signal(signal.SIGWINCH)

    def read(self, token, seconds=4):
        deadline = time.monotonic() + seconds
        while token not in self.bytes:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and self.selector.select(remaining), (token, self.bytes[-2000:])
            try:
                data = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            assert data, (token, self.bytes[-2000:])
            self.bytes.extend(data)

    def restored(self):
        assert termios.tcgetattr(self.slave) == self.original
        assert b"\x1b[?1049h" in self.bytes
        assert b"\x1b[?1049l" in self.bytes
        assert b"\x1b[?25h" in self.bytes
        assert b"\x1b[?2004l" in self.bytes

    def close(self):
        if self.child.poll() is None:
            self.child.kill()
            self.child.wait(timeout=4)
        self.selector.close()
        os.close(self.master)
        os.close(self.slave)


def exercise(path):
    with contextlib.closing(Terminal(path)) as terminal:
        terminal.read(b"\x1b[?25l")
        assert termios.tcgetattr(terminal.slave) != terminal.original
        time.sleep(0.003)
        terminal.resize(94, 29)
        terminal.resize(100, 31)
        terminal.read(b"READY 80x24")
        terminal.read(b"READY 100x31")
        os.write(terminal.master, b"\t\x1b[200~private paste contents\x1b[201~")
        terminal.read(b"\x1b[2;7H2")
        terminal.read(b"\x1b[3;8H1")
        terminal.read(b"\x1b[4;11H1")
        os.write(terminal.master, b"q")
        terminal.read(b"RETURN=0")
        assert terminal.child.wait(timeout=4) == 0
        terminal.restored()
        assert terminal.bytes.count(b"\x1b[2J") == 2
        assert b"private paste contents" not in terminal.bytes
    print("pty: resized once, applied Tab focus and paste, received serial completion")

    with contextlib.closing(Terminal(path, "auto")) as terminal:
        terminal.read(b"READY 80x24")
        terminal.read(b"RETURN=7")
        assert terminal.child.wait(timeout=4) == 7
        terminal.restored()
    print("pty: completion exited while input was idle and restored the terminal")

    with contextlib.closing(Terminal(path, "saturated")) as terminal:
        terminal.read(b"QUEUE=256")
        os.write(terminal.master, b"\t")
        terminal.read(b"\x1b[2;7H2")
        os.write(terminal.master, b"q")
        terminal.read(b"RETURN=0")
        assert terminal.child.wait(timeout=4) == 0
        terminal.restored()
    print("pty: full command queue preserved Tab input and shutdown")

    with contextlib.closing(Terminal(path, "late")) as terminal:
        terminal.read(b"READY 80x24")
        start = time.monotonic()
        terminal.read(b"RETURN=9", 2.8)
        assert time.monotonic() - start < 2.7
        assert b"WORKER COMPLETE" not in terminal.bytes
        terminal.restored()
        terminal.read(b"WORKER COMPLETE")
        assert terminal.child.wait(timeout=4) == 9
    print("pty: timer exited with a late worker, restored the terminal, and retired its completion")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    exercise(str(parser.parse_args().binary.resolve()))
