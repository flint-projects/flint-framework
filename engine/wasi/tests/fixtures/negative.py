#!/usr/bin/env python3
"""Verify that both native owners reject copies at compile time."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    packages = Path(__file__).resolve().parents[3]
    includes = [f"-I={packages / name / 'source'}" for name in ("wasi", "arena", "conc")]
    with tempfile.TemporaryDirectory(prefix="flint-wasi-negative-") as directory:
        for name in ("copy_plugin", "copy_compiled"):
            source = Path(directory) / (name + ".d")
            source.write_bytes((packages / "wasi" / "negative" / (name + ".d.fail")).read_bytes())
            result = subprocess.run([args.compiler, "-o-", "-c", "-preview=dip1000", *includes, str(source)],
                                    check=False, capture_output=True, text=True)
            report = result.stdout + result.stderr
            print(f"{name} exit={result.returncode}\n{report}", end="")
            if result.returncode == 0 or not any(text in report for text in ("not copyable", "cannot be copied", "disabled")):
                raise SystemExit(f"unexpected compile result for {name}")


if __name__ == "__main__":
    main()
