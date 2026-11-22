#!/usr/bin/env python3
"""Check that forged SQL lease and row handles fail to compile on both pinned D compilers."""

import argparse
from pathlib import Path
import subprocess

CASES = {
    "forge_lease": "no property `generation`",
    "forge_row": "is not accessible from module",
}

IMPORTS = ("arena", "conc", "log", "reactor", "sql")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixtures = Path(__file__).resolve().parent
    root = fixtures.parents[3]
    for compiler in ("dmd", "ldc2"):
        for name, diagnostic in CASES.items():
            command = [compiler, "-preview=dip1000", "-c", "-o-",
                       *("-Ipackages/" + dep + "/source" for dep in IMPORTS), str(fixtures / (name + ".d"))]
            result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            (args.output / f"{compiler}-{name}.log").write_text(output)
            if result.returncode != 1 or diagnostic not in output:
                raise SystemExit(f"{compiler} {name} did not fail with {diagnostic!r}\n{output}")
            print(f"{compiler} {name}: {diagnostic}")


if __name__ == "__main__":
    main()
