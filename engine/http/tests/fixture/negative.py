#!/usr/bin/env python3
"""Check compile-fail diagnostics using either pinned D compiler."""
import argparse
from pathlib import Path
import subprocess


CASES = {
    "escape_chunk": ("scope", "leaked"),
    "escape_destination": ("scope", "leaked"),
    "bad_return": ("scalarResponse", "requires Result!HttpResponse"),
    "two_bodies": ("duplicateBodies", "multiple body arguments"),
    "unknown_uda": ("unknownParameter", "unknown parameter UDA"),
    "ambiguous_header": ("conflictingHeaders", "ambiguous HTTP header names"),
    "unannotated": ("missingAnnotation", "requires exactly one GetExchange or PostExchange"),
}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    root = Path(__file__).resolve().parents[4]
    imports = [f"-I={root / 'packages' / name / 'source'}"
               for name in ("http", "arena", "conc", "reactor", "serde")]
    for fixture, markers in CASES.items():
        source = root / "packages" / "http" / "negative" / f"{fixture}.d"
        command = [args.compiler, "-o-", "-preview=dip1000", *imports, str(source)]
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        print(f"{fixture} exit={result.returncode}", flush=True)
        output = result.stdout + result.stderr
        print(output, end="")
        if result.returncode == 0 or not all(marker in output for marker in markers):
            raise SystemExit(f"unexpected result for {fixture}")


if __name__ == "__main__":
    main()
