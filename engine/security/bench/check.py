#!/usr/bin/env python3
"""Compare the exercised wrapper and direct EVP probe outputs."""
import argparse
import hashlib
from pathlib import Path
import subprocess


def checked(binary):
    result = subprocess.run([binary.resolve()], capture_output=True, text=True, timeout=30, check=False)
    print(result.stderr, end="")
    if result.returncode != 0 or result.stdout != "cached-jws 30660000\n":
        raise SystemExit(f"verification workload failed for {binary.name}")
    print(f"{binary.name} bytes={binary.stat().st_size} sha256={hashlib.sha256(binary.read_bytes()).hexdigest()}")
    return result.stdout


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("feature", type=Path)
    cli.add_argument("baseline", type=Path)
    args = cli.parse_args()
    feature = checked(args.feature)
    baseline = checked(args.baseline)
    if feature != baseline:
        raise SystemExit("feature and baseline results differ")
    print(feature, end="")
    print(f"signed_delta_bytes={args.feature.stat().st_size - args.baseline.stat().st_size}")


if __name__ == "__main__":
    main()
