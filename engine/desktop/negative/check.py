#!/usr/bin/env python3
"""Compile fail cases for desktop generation and event-arena scope."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
CASES = [
    (
        "opaque identity",
        """import flint.engine.desktop : Window;
void misuse(ref Window window) @safe { window.identity = typeof(window.identity).init; }
""",
        "no property",
    ),
    (
        "event arena escape",
        """import flint.arena : Error, RequestArena;
import flint.engine.desktop : DesktopEvent;
RequestArena escaped;
Error misuse(ref DesktopEvent event, ref scope RequestArena arena) @safe nothrow @nogc {
    escaped = arena;
    return Error.init;
}
""",
        "scope",
    ),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler")
    args = parser.parse_args()
    paths = ["-I" + str(ROOT / "packages" / name / "source")
             for name in ("arena", "conc", "os", "wasm-bridge", "desktop")]
    with tempfile.TemporaryDirectory(prefix="flint-desktop-negative-") as temp:
        fixture = Path(temp) / "fixture.d"
        for name, text, category in CASES:
            fixture.write_text("module fixture;\n" + text)
            result = subprocess.run([args.compiler, "-c", "-o-", "-preview=dip1000", *paths, fixture],
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode and category in result.stderr, (name, result.stderr)
            print(name + " rejected")


if __name__ == "__main__":
    main()
