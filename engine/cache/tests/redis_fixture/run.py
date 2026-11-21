#!/usr/bin/env python3
"""Run a client against ephemeral loopback Valkey and scripted RESP3 peers."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def valkey_command(binary, directory):
    with socket.socket() as reserved:
        reserved.bind(("127.0.0.1", 0))
        port = reserved.getsockname()[1]
    password = "flint-cache-fixture"
    command = [
        binary, "--bind", "127.0.0.1", "--port", str(port), "--dir", directory,
        "--save", "", "--appendonly", "no", "--requirepass", password,
    ]
    return command, port, f"redis://:{password}@127.0.0.1:{port}"


def wait_listening(child, port):
    for _ in range(400):
        if child.poll() is not None:
            raise SystemExit("local Valkey stopped before it accepted connections")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.05):
                return
        except OSError:
            time.sleep(0.01)
    raise SystemExit("local Valkey did not open its socket")


def stop(child):
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--server", type=Path, required=True)
    cli.add_argument("--valkey", type=Path, required=True)
    cli.add_argument("command", nargs=argparse.REMAINDER)
    args = cli.parse_args()
    if not args.command or args.command == ["--"]:
        cli.error("a client command is required")
    command = args.command[1:] if args.command[0] == "--" else args.command
    with tempfile.TemporaryDirectory(prefix="flint-cache-redis-") as directory, contextlib.ExitStack() as cleanup:
        run, port, url = valkey_command(args.valkey.resolve(), directory)
        actual = subprocess.Popen(run, stdout=subprocess.DEVNULL)
        cleanup.callback(stop, actual)
        wait_listening(actual, port)
        peer = cleanup.enter_context(subprocess.Popen(
            [args.server.resolve(), directory, f"127.0.0.1:{port}"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        ))
        cleanup.callback(peer.stdin.close)
        routes = json.loads(peer.stdout.readline())
        routes["REAL"] = url
        env = dict(os.environ, **{f"FLINT_CACHE_REDIS_{name}": value for name, value in routes.items()})
        return subprocess.run(command, env=env, check=False, timeout=180).returncode


if __name__ == "__main__":
    raise SystemExit(main())
