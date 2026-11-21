#!/usr/bin/env python3
"""Verify Redis reply scopes, worker transfer, and private bridge access."""
import argparse
from pathlib import Path
import subprocess


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    root = Path(__file__).resolve().parents[4]
    includes = [f"-I={root / 'packages' / name / 'source'}"
                for name in ("arena", "conc", "reactor", "serde", "cache")]
    probes = {
        "redis_reply_escape": ("scope", "leaked"),
        "redis_worker_escape": ("scope", "borrowed"),
        "redis_private_bridge": ("Bridge", "visible"),
    }
    for fixture, markers in probes.items():
        path = root / "packages/cache/negative" / f"{fixture}.d"
        command = [args.compiler, "-preview=dip1000", "-o-", *includes, path]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        output = result.stdout + result.stderr
        print(f"{fixture} exit={result.returncode}\n{output}", flush=True)
        if result.returncode == 0 or not all(marker in output for marker in markers):
            raise SystemExit(f"unexpected result for {fixture}")


if __name__ == "__main__":
    main()
