#!/usr/bin/env python3
"""Run a client command against the local, ephemeral-CA protocol peers."""
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
        cli.error("a client command is required")
    command = args.command[1:] if args.command[0] == "--" else args.command

    with tempfile.TemporaryDirectory(prefix="flint-http-fixture-") as directory:
        with subprocess.Popen(
            [args.server.resolve(), directory],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        ) as server:
            try:
                origin_env = json.loads(server.stdout.readline())
                env = dict(os.environ, **{f"FLINT_HTTP_{name}": value for name, value in origin_env.items()})
                result = subprocess.run(command, env=env, check=False, timeout=180)
                return result.returncode
            finally:
                server.stdin.close()


if __name__ == "__main__":
    raise SystemExit(main())
