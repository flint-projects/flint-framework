#!/usr/bin/env python3
"""Check that forged upload handles and package-private credential access fail to compile on both compilers."""

import argparse
from pathlib import Path
import subprocess

CASES = {
    "forge_upload": "no property `generation`",
    "signing_internal": "is not visible from module",
}

IMPORTS = ("arena", "conc", "http", "log", "reactor", "security", "serde", "storage", "validate")


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
