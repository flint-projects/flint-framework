#!/usr/bin/env python3
"""Build the HTTP boundary corpus against a verified native receipt and run it on loopback."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def archives(prefix):
    receipt = json.loads((prefix / "flint-native-install.json").read_text())
    result = []
    for name in ("curl", "zlib", "nghttp2", "openssl"):
        for entry in receipt["libraries"][name]["archives"]:
            path = Path(entry["path"])
            with path.open("rb") as source:
                actual = hashlib.file_digest(source, "sha256").hexdigest()
            if actual != entry["sha256"]:
                raise SystemExit(f"native archive digest changed for {name}")
            result.append(path)
    return result


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--prefix", type=Path, required=True)
    cli.add_argument("--server", type=Path, required=True)
    cli.add_argument("--output", type=Path, required=True)
    cli.add_argument("--cc", default="cc")
    cli.add_argument("--sanitize", choices=("address,undefined", "none"), default="address,undefined")
    args = cli.parse_args()
    fixture = Path(__file__).resolve().parent
    ffi = fixture.parents[3] / "native" / "ffi"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sanitizer = [] if args.sanitize == "none" else [
        f"-fsanitize={args.sanitize}", "-fno-omit-frame-pointer",
    ]
    command = [
        args.cc, "-O1", "-g", "-no-pie", "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-DFLINT_HAS_CURL=1", "-DFLINT_HTTP_TEST_OWNER=1", *sanitizer,
        f"-I{ffi}", f"-I{args.prefix / 'include'}", ffi / "flint_http.c", fixture / "native.c",
        *archives(args.prefix), "-Wl,--wrap=getaddrinfo,--wrap=malloc,--wrap=calloc,--wrap=realloc",
        "-pthread", "-ldl", "-lm", "-o", args.output,
    ]
    print(shlex.join(map(str, command)), flush=True)
    subprocess.run(command, check=True)
    env = os.environ.copy()
    env.setdefault("ASAN_OPTIONS", "detect_leaks=1:detect_stack_use_after_return=1")
    return subprocess.run(
        [sys.executable, fixture / "run.py", "--server", args.server, "--", args.output.resolve()],
        env=env, check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
