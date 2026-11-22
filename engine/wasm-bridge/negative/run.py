#!/usr/bin/env python3
"""Verify that each wasm-bridge compile-negative fixture is rejected for its intended reason.

Uses the tools/ci.py negative-test conventions: `-c -o- -preview=dip1000`, an exit status in 1..127,
a fixture-specific diagnostic pattern and no compiler crash.
"""
import argparse
from pathlib import Path
import re
import subprocess

FIXTURES = {
    "copy_frame.d": r"(?i)disabled|not copyable|cannot be copied",
    "escaped_frame.d": r"(?i)scope|escap",
}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    here = Path(__file__).resolve().parent
    packages = here.parents[1]
    includes = [f"-I{packages / name / 'source'}" for name in ("wasm-bridge", "arena")]
    for name, pattern in FIXTURES.items():
        result = subprocess.run([args.compiler, "-c", "-o-", "-preview=dip1000", *includes, str(here / name)],
                                check=False, capture_output=True, text=True)
        report = result.stdout + result.stderr
        print(f"{name} exit={result.returncode}\n{report}", end="")
        if not 0 < result.returncode < 128 or not re.search(pattern, report):
            raise SystemExit(f"{name}: expected a specific compiler rejection")
        if re.search(r"(?i)internal compiler error|segmentation fault|access violation", report):
            raise SystemExit(f"{name}: compiler crash is not a safety pass")


if __name__ == "__main__":
    main()
