#!/usr/bin/env python3
"""Check authorization metadata and scoped JSON callbacks in the pinned D compiler."""
import argparse
from pathlib import Path
import subprocess
import tempfile


CASES = {
    "escaped_name": ("scope", "member", "escaped"),
    "escaped_value": ("scope", "member", "escaped"),
    "unknown_policy": ("authorization policy is missing or ambiguous", "missing"),
    "invalid_roles": ("invalid RolesAllowed metadata",),
}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    root = Path(__file__).resolve().parents[4]
    packages = root / "packages"
    flags = [f"-I={packages / name / 'source'}"
             for name in ("security", "http", "arena", "conc", "reactor", "serde")]
    with tempfile.TemporaryDirectory(prefix="flint-security-negative-") as directory:
        for name, required in CASES.items():
            source = Path(directory) / (name + ".d")
            fixture = packages / "security" / "negative" / (name + ".d.fail")
            source.write_bytes(fixture.read_bytes())
            command = [args.compiler, "-preview=dip1000", "-o-", "-c", *flags, str(source)]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            output = result.stdout + result.stderr
            print(f"{name} exit={result.returncode}\n{output}", end="")
            if result.returncode == 0 or not all(pattern in output for pattern in required):
                raise SystemExit(f"unexpected compile result for {name}")


if __name__ == "__main__":
    main()
