#!/usr/bin/env python3
"""Compile style boundary misuse fixtures with DMD or LDC and require the specific rejection."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
CASES = (
    ("package grapheme walker",
     "import flint.style : visitGraphemes;\n"
     "void f() @safe { visitGraphemes(\"a\", (scope const(char)[] t, uint c, bool b) @safe => true); }",
     "visitGraphemes"),
    ("package case folding",
     "import flint.style : foldGraphemes;\nvoid f() @safe { string s; cast(void) foldGraphemes(\"a\", s); }",
     "foldGraphemes"),
    ("private Unicode provider",
     "import flint.style.ffi.unicode : properties;\nvoid f() @safe { cast(void) properties('a'); }",
     "properties"),
    ("trusted fold outside the boundary",
     "import flint.style.ffi.unicode : caseFold;\nvoid f() @safe { string s; cast(void) caseFold(\"a\", s); }",
     "caseFold"),
    ("internal output buffer",
     "import flint.style.internal.text : Output;\nvoid f() @safe { Output o; o.add(\"x\"); }",
     "Output"),
)
REJECTION = re.compile(r"is not (visible|accessible) from module `fixture`")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler")
    args = parser.parse_args()
    include = "-I" + str(ROOT / "packages" / "style" / "source")
    with tempfile.TemporaryDirectory(prefix="flint-style-negative-") as temp:
        fixture = Path(temp) / "fixture.d"
        for name, source, symbol in CASES:
            fixture.write_text("module fixture;\n" + source + "\n")
            result = subprocess.run([args.compiler, "-c", "-o-", "-preview=dip1000", include, str(fixture)],
                                    text=True, capture_output=True, timeout=60)
            output = result.stdout + result.stderr
            assert 0 < result.returncode < 128, (name, result.returncode, output)
            assert symbol in output and REJECTION.search(output), (name, output)
            assert not re.search(r"(?i)internal compiler error|segmentation fault", output), (name, output)
            print(name + " rejected")
        fixture.write_text("module fixture;\nimport flint.style : Style, render, truncateCells;\n"
                           "string f() @safe { return render(truncateCells(\"abc\", 2), Style.init, 2); }\n")
        result = subprocess.run([args.compiler, "-c", "-o-", "-preview=dip1000", include, str(fixture)],
                                text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, ("positive control", result.stdout + result.stderr)
        print("positive control compiled")


if __name__ == "__main__":
    main()
