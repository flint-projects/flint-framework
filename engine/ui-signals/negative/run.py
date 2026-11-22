#!/usr/bin/env python3
"""Verify that each ui-signals compile-negative fixture is rejected for its intended reason.

Uses the tools/ci.py negative-test conventions: `-c -o- -preview=dip1000`, an exit status in 1..127,
a fixture-specific diagnostic pattern and no compiler crash. Fixtures carry a `.d.fail` suffix so
package builds and linters never treat them as sources.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

FIXTURES = {
    "copy_graph": r"(?i)disabled|not copyable|cannot be copied",
    "capturing_compute": r"(?i)delegate|function",
    "escaped_storage": r"(?i)scope|escap|local",
}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    here = Path(__file__).resolve().parent
    packages = here.parents[1]
    includes = [f"-I{packages / name / 'source'}" for name in ("ui-signals", "wasm-bridge", "arena")]
    with tempfile.TemporaryDirectory(prefix="flint-ui-signals-negative-") as directory:
        for name, pattern in FIXTURES.items():
            source = Path(directory) / (name + ".d")
            source.write_bytes((here / (name + ".d.fail")).read_bytes())
            result = subprocess.run([args.compiler, "-c", "-o-", "-preview=dip1000", *includes, str(source)],
                                    check=False, capture_output=True, text=True)
            report = result.stdout + result.stderr
            print(f"{name} exit={result.returncode}\n{report}", end="")
            if not 0 < result.returncode < 128 or not re.search(pattern, report):
                raise SystemExit(f"{name}: expected a specific compiler rejection")
            if re.search(r"(?i)internal compiler error|segmentation fault|access violation", report):
                raise SystemExit(f"{name}: compiler crash is not a safety pass")


if __name__ == "__main__":
    main()
