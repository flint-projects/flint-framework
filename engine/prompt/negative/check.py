#!/usr/bin/env python3
"""Compile the prompt secret misuse fixtures and require each specific rejection."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PACKAGES = ("arena", "conc", "style", "term", "tui", "validate", "widgets", "prompt")
CASES = (
    ("borrow_escape.d", "assigning scope variable `bytes` to `stored`", (("stored = bytes;", "stored = bytes.dup;"),)),
    ("copy_secret.d", "is not copyable because it has a disabled postblit",
     (("import flint.prompt : Secret;", "import core.lifetime : move;\nimport flint.prompt : Secret;"),
      ("Secret other = owner;", "Secret other = move(owner);"))),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler")
    args = parser.parse_args()
    imports = ["-I" + str(ROOT / "packages" / name / "source") for name in PACKAGES]
    compile_only = [args.compiler, "-c", "-o-", "-preview=dip1000", *imports]
    for filename, diagnostic, repairs in CASES:
        result = subprocess.run([*compile_only, str(HERE / filename)], capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        assert 0 < result.returncode < 128 and diagnostic in output, (filename, result.returncode, output)
        assert "internal compiler error" not in output.lower(), (filename, output)
        print(f"{filename} rejected: {diagnostic}")
        if not repairs:
            continue
        # Positive control: the minimally repaired fixture must compile, so the rejection is the misuse itself.
        source = (HERE / filename).read_text()
        for old, new in repairs:
            assert old in source, (filename, old)
            source = source.replace(old, new)
        with tempfile.TemporaryDirectory(prefix="flint-negative-control-") as temp:
            control = Path(temp) / filename
            control.write_text(source)
            accepted = subprocess.run([*compile_only, str(control)], capture_output=True, text=True, timeout=60)
            assert accepted.returncode == 0, (filename, accepted.stdout + accepted.stderr)
        print(f"{filename} repaired control compiles")


if __name__ == "__main__":
    main()
