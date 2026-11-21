#!/usr/bin/env python3
"""Observe child CPU time when the real renderer is waiting on an idle PTY."""
import argparse
import contextlib
import resource
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fixtures"))
from test_pty import Terminal


def cpu():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def idle(binary):
    start_cpu = cpu()
    start = time.monotonic()
    with contextlib.closing(Terminal(binary, "--idle")) as terminal:
        terminal.read(b"IDLE")
        terminal.read(b"\x1b[?1049l")
        assert terminal.child.wait(timeout=4) == 0
        assert termios_restored(terminal)
    elapsed = time.monotonic() - start
    used = cpu() - start_cpu
    assert elapsed >= 0.95 and elapsed <= 2.0
    print(f"idle elapsed_sec={elapsed:.6f} cpu_sec={used:.6f} cpu_pct={100 * used / elapsed:.4f}")


def termios_restored(terminal):
    import termios

    return termios.tcgetattr(terminal.slave) == terminal.original


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    idle(str(parser.parse_args().binary.resolve()))
