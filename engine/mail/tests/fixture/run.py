#!/usr/bin/env python3
"""Run tests against disposable SMTP listeners on loopback."""
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
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        cli.error("a test command is required")
    with tempfile.TemporaryDirectory(prefix="flint-smtp-") as directory:
        with subprocess.Popen([args.server.resolve(), directory], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True) as child:
            try:
                values = json.loads(child.stdout.readline())
                env = dict(os.environ, **{f"FLINT_MAIL_{name}": value for name, value in values.items()})
                return subprocess.run(command, env=env, check=False, timeout=100).returncode
            finally:
                child.stdin.close()


if __name__ == "__main__":
    raise SystemExit(main())
