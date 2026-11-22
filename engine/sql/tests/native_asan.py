#!/usr/bin/env python3
"""Build the SQL C shim boundary corpus (native/ffi/sql_native_test.c) with ASan and UBSan and run it.

The corpus covers the 16-lease/256-waiter queue cap, waiter withdrawal, stale lease generations,
invalid UTF-8 and NUL inputs, value lengths 0..256 and around 1 KiB/1 MiB, and retirement of an
operation that is cancelled while in flight. The shims are compiled from source with
instrumentation and linked against the pinned SQLite and libpq archives.
"""

import argparse
import os
from pathlib import Path
import subprocess

SHIMS = ("flint_sql_core.c", "flint_sql_pg.c", "flint_sqlite.c", "flint_sql_script.c")
ARCHIVES = ("lib/libsqlite3.a", "lib/libpq.a", "lib/libpgcommon_shlib.a", "lib/libpgport_shlib.a",
            "lib/libssl.a", "lib/libcrypto.a", "lib64/libz.a")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--prefix", type=Path, required=True,
                        help="native install prefix, e.g. <native>/install/linux-x86_64-glibc")
    parser.add_argument("--output", type=Path, required=True, help="scratch directory for the binary")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[3] / "native" / "ffi"
    args.output.mkdir(parents=True, exist_ok=True)
    binary = args.output / "sql_native_test_asan"
    command = [args.cc, "-std=c11", "-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
               "-DFLINT_HAS_SQLITE=1", "-DFLINT_HAS_LIBPQ=1", f"-I{source}", f"-I{args.prefix / 'include'}",
               str(source / "sql_native_test.c"), *(str(source / name) for name in SHIMS),
               *(str(args.prefix / name) for name in ARCHIVES), "-lpthread", "-ldl", "-lm", "-o", str(binary)]
    subprocess.run(command, check=True)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1:abort_on_error=1:detect_stack_use_after_return=1",
               UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    result = subprocess.run([str(binary)], env=env, timeout=300, check=False)
    if result.returncode != 0:
        raise SystemExit(f"sql_native_test under ASan/UBSan exited {result.returncode}")
    print("sql_native_test: ASan/UBSan clean")


if __name__ == "__main__":
    main()
