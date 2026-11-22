#!/usr/bin/env python3
"""Check the rpc compile-fail fixtures and, optionally, the rejected Protobuf schemas."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

COMPILE_CASES = {
    "escaped_peer": r"scope variable .*(global|non-scope)",
    "escaped_stream": r"scope variable .*(global|non-scope)",
}

SCHEMA_CASES = {
    "recursive": "recursive message graph cannot be bounded",
    "required": "only proto3 syntax is supported",
    "editions": "only proto3 syntax is supported",
    "optional": "cannot emit proto3 optional scalars",
}


def compile_negatives(root, compiler):
    imports = [f"-I{root / 'packages' / name / 'source'}"
               for name in ("arena", "conc", "di", "http", "log", "reactor", "rpc", "serde", "validate", "web")]
    for mode, flags in (("debug", ["-boundscheck=on"]), ("release", ["-release", "-boundscheck=safeonly"])):
        for fixture, pattern in COMPILE_CASES.items():
            source = root / "packages" / "rpc" / "negative" / f"{fixture}.d"
            command = [compiler, "-preview=dip1000", *flags, "-c", "-o-", *imports, str(source)]
            result = subprocess.run(command, check=False, capture_output=True, text=True)
            output = result.stdout + result.stderr
            print(f"{fixture} {Path(compiler).name} {mode} exit={result.returncode}", flush=True)
            if result.returncode == 0 or not re.search(pattern, output):
                print(output, end="")
                raise SystemExit(f"unexpected result for {fixture} ({mode})")


def schema_negatives(root, prefix, scratch):
    generator = root / "packages" / "rpc" / "tools" / "protoc-gen-flint"
    for fixture, marker in SCHEMA_CASES.items():
        command = [sys.executable, str(generator), "--module", "flint.rpc.rejected",
                   "--protoc", str(prefix / "bin" / "protoc"), "--plugin", str(prefix / "bin" / "protoc-gen-c"),
                   "--runtime-header", str(prefix / "include" / "protobuf-c" / "protobuf-c.h"),
                   "--schema", str(root / "packages" / "rpc" / "tests" / "proto" / f"{fixture}.proto"),
                   "--output", str(scratch / f"rejected-{fixture}")]
        result = subprocess.run(command, check=False, capture_output=True, text=True, env=os.environ)
        output = result.stdout + result.stderr
        print(f"schema {fixture} exit={result.returncode}", flush=True)
        if result.returncode == 0 or marker not in output:
            print(output, end="")
            raise SystemExit(f"unexpected generator result for {fixture}")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler", nargs="+", help="pinned dmd and/or ldc2")
    cli.add_argument("--protobuf-prefix", type=Path, help="install prefix with protoc and protoc-gen-c")
    cli.add_argument("--scratch", type=Path, help="directory for rejected generator output")
    args = cli.parse_args()
    root = Path(__file__).resolve().parents[3]
    for compiler in args.compiler:
        compile_negatives(root, compiler)
    if args.protobuf_prefix:
        if not args.scratch:
            cli.error("--scratch is required with --protobuf-prefix")
        schema_negatives(root, args.protobuf_prefix, args.scratch)


if __name__ == "__main__":
    main()
