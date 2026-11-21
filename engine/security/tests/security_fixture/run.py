#!/usr/bin/env python3
"""Run a security test against an ephemeral HTTPS JWKS fixture."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--server", type=Path, required=True)
    cli.add_argument("command", nargs=argparse.REMAINDER)
    args = cli.parse_args()
    if not args.command or args.command == ["--"]:
        cli.error("a test command is required")
    command = args.command[1:] if args.command[0] == "--" else args.command
    with tempfile.TemporaryDirectory(prefix="flint-security-") as directory:
        with subprocess.Popen([args.server.resolve(), directory], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True) as child:
            try:
                # Token strings stay on the fixture pipe and in the test process environment.
                values = json.loads(child.stdout.readline())
                env = dict(os.environ, **{f"FLINT_SECURITY_{key}": value for key, value in values.items()})
                return subprocess.run(command, env=env, check=False, timeout=180).returncode
            finally:
                child.stdin.close()


if __name__ == "__main__":
    raise SystemExit(main())
