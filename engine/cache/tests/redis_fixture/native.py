#!/usr/bin/env python3
"""Compile the Redis boundary corpus against the verified native receipt."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def verified_archives(prefix):
    received = json.loads((prefix / "flint-native-install.json").read_text())
    archives = []
    for provider in ("hiredis", "openssl"):
        for entry in received["libraries"][provider]["archives"]:
            target = Path(entry["path"])
            with target.open("rb") as package:
                digest = hashlib.file_digest(package, "sha256").hexdigest()
            if digest != entry["sha256"]:
                raise SystemExit(f"native archive digest changed for {provider}")
            archives.append(target)
    return archives


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    for name in ("prefix", "server", "valkey", "output"):
        cli.add_argument(f"--{name}", type=Path, required=True)
    cli.add_argument("--cc", default="cc")
    args = cli.parse_args()
    fixture = Path(__file__).resolve().parent
    ffi = fixture.parents[3] / "native" / "ffi"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        args.cc, "-O1", "-g", "-no-pie", "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-DFLINT_HAS_HIREDIS=1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
        f"-I{ffi}", f"-I{args.prefix / 'include'}", ffi / "flint_cache.c", fixture / "native.c",
        *verified_archives(args.prefix), "-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc", "-pthread", "-ldl", "-lm", "-o", args.output,
    ]
    print(shlex.join(map(str, command)), flush=True)
    subprocess.run(command, check=True)
    env = os.environ.copy()
    env.setdefault("ASAN_OPTIONS", "detect_leaks=1:detect_stack_use_after_return=1")
    return subprocess.run([
        sys.executable, fixture / "run.py", "--server", args.server, "--valkey", args.valkey,
        "--", args.output.resolve(),
    ], check=False, env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
