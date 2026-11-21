#!/usr/bin/env python3
"""Check real cell snapshots through the shared Linux TUI runtime."""
import argparse
import contextlib
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tui/fixtures"))
from test_pty import Terminal


def screen(data):
    cells = [[" "] * 80 for _ in range(24)]
    row = column = 0
    fragments = re.split(rb"(\x1b\[[\x20-\x3f]*[\x40-\x7e])", bytes(data))
    for fragment in fragments:
        cursor = re.fullmatch(rb"\x1b\[(\d+);(\d+)H", fragment)
        if cursor:
            row, column = (int(value) - 1 for value in cursor.groups())
        elif fragment.startswith(b"\x1b["):
            continue
        else:
            for value in fragment:
                if 32 <= value < 127 and row < 24 and column < 80:
                    cells[row][column] = chr(value)
                    column += 1
    return ["".join(line).rstrip() for line in cells]


def verify(binary):
    with contextlib.closing(Terminal(binary)) as terminal:
        terminal.read(b"\x1b[24;1H" + b" " * 80)
        observed = screen(terminal.bytes)
        expected = {
            0: "WIDGET GRID",
            1: "*****",
            3: "FirLast",
            4: "",
            5: "q",
            6: "012Z",
            8: "-----",
            9: "=====",
            10: "",
            11: "",
            12: "4/4",
            13: "|",
        }
        assert {index: observed[index] for index in expected} == expected, observed
        assert b"sensitive" not in terminal.bytes
        os.write(terminal.master, b"t")
        terminal.read(b"\x1b[14;1H/")
        os.write(terminal.master, b"\x1b")
        terminal.read(b"\x1b[?1049l")
        assert terminal.child.wait(timeout=4) == 0
        terminal.restored()
    print("widget PTY snapshot: masked glyphs, short rows, clipping, indicators and terminal restoration")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    verify(str(parser.parse_args().binary.resolve()))
