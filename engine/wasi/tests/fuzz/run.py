#!/usr/bin/env python3
"""Compile and run the native WASI boundary corpus against the pinned static provider."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=60)
    args = parser.parse_args()
    if args.seconds < 0:
        parser.error("--seconds must be nonnegative")
    root = Path(__file__).resolve().parents[4]
    package = Path(__file__).resolve().parents[2]
    shim = package / "native" / "ffi"
    shared = next(p for p in (package.parents[1] / "native" / "framework" / "include", package.parents[1] / "native" / "include") if p.is_dir())
    archive = args.prefix / "lib" / "libwasmtime.a"
    command = [
        os.environ.get("CC", "cc"), "-std=c11", "-g", "-O1", "-Wall", "-Wextra", "-Werror",
        "-fno-omit-frame-pointer", "-fsanitize=address,undefined", "-no-pie",
        "-DFLINT_HAS_WASMTIME=1", "-DFLINT_HAS_WASMTIME_EXTENSIONS=1",
        "-I" + str(args.prefix / "include"), "-I" + str(shim), "-I" + str(shared), str(shim / "flint_wasi.c"),
        str(Path(__file__).with_name("native.c")), str(archive), "-lpthread", "-ldl", "-lm", "-lrt",
        "-lutil", "-o", str(args.output),
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(command, check=True)
    options = dict(os.environ, ASAN_OPTIONS="detect_leaks=1:detect_stack_use_after_return=1",
                   UBSAN_OPTIONS="halt_on_error=1")
    subprocess.run([str(args.output.resolve()), str(args.seconds)], check=True, env=options, timeout=args.seconds+20)


if __name__ == "__main__":
    main()
