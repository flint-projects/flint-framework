#!/usr/bin/env python3
"""Assert both configured compilers reject a retained scoped MIME chunk."""
import argparse
from pathlib import Path
import re
import subprocess


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compilers", nargs="+")
    options = cli.parse_args()
    root = Path(__file__).resolve().parents[4]
    packages = ["mail", "arena", "conc", "http", "reactor", "serde"]
    inputs = [f"-I{root / 'packages' / name / 'source'}" for name in packages]
    source = root / "packages/engine-mail/negative/escape_mime_chunk.d"
    for compiler in options.compilers:
        result = subprocess.run([compiler, "-c", "-o-", "-preview=dip1000", *inputs, str(source)],
                                capture_output=True, text=True, check=False)
        diagnostic = result.stdout + result.stderr
        if result.returncode == 0 or not re.search(r"scope variable.*chunk.*(longer lifetime|global variable)", diagnostic):
            raise SystemExit(f"{compiler} failed negative contract verification\n{diagnostic}")
        print(f"{compiler} rejected retaining the scoped MIME callback slice")


if __name__ == "__main__":
    main()
