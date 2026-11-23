#!/usr/bin/env python3
"""Build the linked startup worker (fixtures/startup.d) and run the independent-process conformance.

The build closure (import paths, native versions and link flags) comes from `dub describe :migrate`
in the given repository root, so the worker links the same pinned SQLite/libpq profile as the
package suite. concurrency.py then covers transaction_rollback and concurrent_start/lock_timeout on
SQLite and, with --postgres, concurrent_start, lock_timeout and nontransactional_recovery on
PostgreSQL. The PostgreSQL database must be disposable and empty: the crash case leaves a
started-but-unsuccessful marker that blocks it permanently.
"""

import argparse
from pathlib import Path
import subprocess
import sys

FIXTURES = Path(__file__).resolve().parent
PACKAGE = FIXTURES.parent


def describe(compiler, root, field):
    result = subprocess.run(["dub", "describe", ":migrate", "--compiler=" + compiler, "--skip-registry=all",
                             "--data=" + field, "--data-list"], cwd=root, capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("compiler", choices=("dmd", "ldc2"))
    parser.add_argument("output", type=Path)
    parser.add_argument("--root", type=Path, default=PACKAGE.parents[1],
                        help="repository root whose recipes carry the native block")
    parser.add_argument("--postgres", help="DSN for a disposable, empty PostgreSQL database")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = args.root.resolve()
    version = "-version=" if args.compiler == "dmd" else "-d-version="
    versions = [version + name for name in describe(args.compiler, root, "versions") if not name.startswith("Have_")]
    folders = describe(args.compiler, root, "import-paths")
    imports = ["-I" + path for path in folders]
    # Each dependency's import path is also its library source tree.
    sources = sorted(str(path) for folder in folders for path in Path(folder).rglob("*.d"))
    flags = ["-L" + flag for flag in describe(args.compiler, root, "lflags")]
    worker = args.output / ("migrate-startup-" + args.compiler)
    migrations = root / "packages/engine-migrate/tests/migrations"
    subprocess.run([args.compiler, "-preview=dip1000", "-of=" + str(worker), *versions, *imports, "-J" + str(migrations),
                    str(FIXTURES / "startup.d"), str(FIXTURES / "generated_plan.d"), *sources, *flags], check=True)
    command = [sys.executable, str(FIXTURES / "concurrency.py"), str(worker)]
    if args.postgres:
        command += ["--postgres", args.postgres]
    subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
