#!/usr/bin/env python3
"""Build and exercise the pinned security ABI under native sanitizers."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--prefix", required=True, type=Path)
    cli.add_argument("--server", required=True, type=Path)
    cli.add_argument("--output", required=True, type=Path)
    args = cli.parse_args()
    library_path = args.prefix.resolve() / "lib"
    root = Path(__file__).resolve().parents[4]
    test = Path(__file__).resolve().parent
    ffi = Path(__file__).resolve().parents[2] / "native" / "ffi"
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        os.environ.get("CC", "cc"), "-std=c11", "-g", "-O1", "-Wall", "-Wextra", "-Werror",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-no-pie",
        "-DFLINT_HAS_OPENSSL=1", "-DFLINT_HAS_LIBSODIUM=1", "-DFLINT_SECURITY_TEST=1",
        "-I", str(args.prefix.resolve() / "include"), "-I", str(ffi),
        str(ffi / "flint_security.c"), str(test / "native.c"),
        str(library_path / "libcrypto.a"), str(library_path / "libsodium.a"),
        "-pthread", "-ldl", "-o", str(output),
    ]
    subprocess.run(command, check=True)
    environment = dict(os.environ, ASAN_OPTIONS="detect_leaks=1:detect_stack_use_after_return=1",
                       UBSAN_OPTIONS="halt_on_error=1")
    subprocess.run([sys.executable, str(test / "run.py"), "--server", str(args.server.resolve()),
                    "--", str(output)], check=True, env=environment)


if __name__ == "__main__":
    main()
