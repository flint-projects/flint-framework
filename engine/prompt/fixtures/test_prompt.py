#!/usr/bin/env python3
"""Verify prompt ownership and secret redaction with a Linux terminal or pipe."""
import argparse
import contextlib
import select
import os
import subprocess
import sys
import termios
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tui/fixtures"))
from test_pty import Terminal


def send(terminal, text):
    os.write(terminal.master, text)


def paste(terminal, text):
    send(terminal, b"\x1b[200~" + text + b"\x1b[201~")


def finished(terminal, marker):
    terminal.read(marker)
    assert terminal.child.wait(timeout=4) == 0
    terminal.restored()
    assert terminal.bytes.count(b"\x1b[?1049h") == 1
    assert terminal.bytes.count(b"\x1b[?1049l") == 1


def password(binary):
    supplied = "starter-é👩‍🔬".encode()
    with contextlib.closing(Terminal(binary, "password")) as terminal:
        terminal.read(b"Password")
        paste(terminal, supplied)
        terminal.read(b"***")
        send(terminal, b"\x7f!\r")
        finished(terminal, b"RESULT=ok SECRET")
        assert supplied not in terminal.bytes
        assert "starter-é!".encode() not in terminal.bytes

    redirected = subprocess.run([binary, "password"], input=supplied, capture_output=True, timeout=4)
    assert redirected.returncode == 0 and redirected.stdout.strip() == b"RESULT=unsupported", redirected
    assert supplied not in redirected.stderr and b"\x1b" not in redirected.stdout
    # PROMPT-03 with a terminal on stdout: piped stdin still refuses before any terminal control or mode change.
    master, slave = os.openpty()
    try:
        original = termios.tcgetattr(slave)
        piped = subprocess.run([binary, "password"], input=supplied, stdout=slave, stderr=subprocess.PIPE,
                               timeout=4)
        assert piped.returncode == 0 and supplied not in piped.stderr, piped
        assert termios.tcgetattr(slave) == original
        shown = bytearray()
        while select.select([master], [], [], 0.2)[0]:
            part = os.read(master, 4096)
            if not part:
                break
            shown += part
        assert shown.strip() == b"RESULT=unsupported" and b"\x1b" not in shown, bytes(shown)
    finally:
        os.close(master)
        os.close(slave)
    readable = subprocess.run([binary, "stream"], input=b"stream\n", capture_output=True, timeout=4)
    assert readable.returncode == 0 and readable.stdout.strip() == b"RESULT=ok STREAM", readable
    print("password: edit and paste redacted, redirected secret refused, public stream explicitly enabled")


def form(binary):
    for page in (1, 2, 3, 4):
        with contextlib.closing(Terminal(binary, "form")) as terminal:
            terminal.read(b"PUBLIC ENTRY")
            if page > 1:
                send(terminal, b"\r")
                terminal.read(b"\x1b[3;26Hpublic")
                send(terminal, b"public\r")
                terminal.read(b"\x1b[4;1H2")
            if page > 2:
                paste(terminal, b"qwerty-secret")
                terminal.read(b"***")
                send(terminal, b"\r")
                terminal.read(b"\x1b[4;1H3")
            if page == 4:
                send(terminal, b"final\r")
                finished(terminal, b"RESULT=ok GROUP")
            else:
                send(terminal, b"\x03")
                finished(terminal, b"RESULT=cancelled")
            assert b"qwerty-secret" not in terminal.bytes
    print("form: required field retry, cancellation on every page, mixed owned answers")


def pick(binary):
    with contextlib.closing(Terminal(binary, "select")) as terminal:
        terminal.read(b"Choose an item")
        send(terminal, b"STRASSE\r")
        finished(terminal, b"RESULT=ok PICK")
    with contextlib.closing(Terminal(binary, "multi")) as terminal:
        terminal.read(b"Choose several")
        send(terminal, b"\t\x1b[B\t\r")
        finished(terminal, b"RESULT=ok PICK")
    for command, result in ((b"\r", b"RESULT=ok"), (b"\x03", b"RESULT=cancelled")):
        with contextlib.closing(Terminal(binary, "confirm")) as terminal:
            terminal.read(b"Proceed?")
            send(terminal, command)
            finished(terminal, result)
    with contextlib.closing(Terminal(binary, "nested")) as terminal:
        terminal.read(b"RESULT=ok CONFLICT")
        assert terminal.child.wait(timeout=4) == 0
        assert termios.tcgetattr(terminal.slave) == terminal.original
    print("selection: Unicode filtering, disabled choices, default and cancellation, nested session conflict")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    path = str(parser.parse_args().binary.resolve())
    password(path)
    form(path)
    pick(path)
