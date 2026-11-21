#!/usr/bin/env python3
"""Compile codec boundary misuse fixtures with DMD or LDC."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
CASES = [
    (
        "source borrow",
        """import flint.arena : Result;
ubyte[] retained;
Result!size_t invalid(scope ubyte[] bytes) @safe nothrow @nogc {
    retained = bytes;
    return Result!size_t.init;
}
""",
        "scope",
    ),
    (
        "sink borrow",
        """import flint.arena : Error;
const(ubyte)[] retained;
Error invalid(scope const(ubyte)[] bytes) @safe nothrow @nogc {
    retained = bytes;
    return Error.init;
}
""",
        "scope",
    ),
    (
        "opaque identity",
        """import flint.codec : Encoder;
void invalid(ref Encoder encoder) @safe { encoder.owner = typeof(encoder.owner).init; }
""",
        "no property",
    ),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler")
    args = parser.parse_args()
    paths = ["-I" + str(ROOT / "packages" / p / "source") for p in ("arena", "codec")]
    with tempfile.TemporaryDirectory(prefix="flint-codec-negative-") as temp:
        fixture = Path(temp) / "fixture.d"
        for name, source, diagnostic in CASES:
            fixture.write_text("module fixture;\n" + source)
            command = [args.compiler, "-c", "-o-", "-preview=dip1000", *paths, fixture]
            result = subprocess.run(command, text=True, capture_output=True, timeout=15)
            assert result.returncode and diagnostic in result.stderr, (name, result.stderr)
            print(name + " rejected")


if __name__ == "__main__":
    main()
