#!/usr/bin/env python3
"""migration_bench: validate 1000 embedded migrations and bound the provider query count.

Builds bench/source/app.d with the shared harness and links trace/provider.c through `--wrap`, so
the provider's own statement callbacks (SQLite trace, libpq prepare/execute) count the work that one
validateOnly startup performs. The count must not grow with the 1000-entry history. Compiler template
counts for the canonical fixture are measured by tools/measure_builds.py against the manifest cap.
"""

import argparse
import json
from pathlib import Path
import subprocess

TRACE = Path(__file__).resolve().parent
BENCH = TRACE.parent
WRAPS = ("sqlite3_open_v2", "PQsendPrepare", "PQsendQueryPrepared")
# One validateOnly startup: lock, history/metadata existence and metadata checks, one ordered history
# read, unlock or rollback. A per-migration query would add about 1000.
MAX_QUERIES = 12


def describe(compiler, root, field):
    result = subprocess.run(["dub", "describe", ":migrate", "--compiler=" + compiler, "--skip-registry=all",
                             "--data=" + field, "--data-list"], cwd=root, capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("compiler", choices=("dmd", "ldc2"))
    parser.add_argument("output", type=Path)
    parser.add_argument("--root", type=Path, default=BENCH.parents[2])
    parser.add_argument("--postgres", help="DSN of a database without a flint_schema_history table")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = args.root.resolve()
    prefix = Path(next(flag for flag in describe(args.compiler, root, "lflags") if flag.endswith("libpq.a"))).parents[1]
    provider = args.output / "provider.o"
    subprocess.run(["cc", "-c", "-O2", "-I" + str(prefix / "include"), str(TRACE / "provider.c"), "-o", str(provider)],
                   check=True)
    version = "-version=" if args.compiler == "dmd" else "-d-version="
    versions = [version + name for name in describe(args.compiler, root, "versions") if not name.startswith("Have_")]
    folders = describe(args.compiler, root, "import-paths")
    sources = sorted(str(path) for folder in folders for path in Path(folder).rglob("*.d"))
    flags = ["-L" + flag for flag in describe(args.compiler, root, "lflags")]
    binary = args.output / ("probe-migrate-traced-" + args.compiler)
    build = [args.compiler, "-preview=dip1000", "-O", "-of=" + str(binary), *versions,
             *("-I" + path for path in folders), "-I" + str(BENCH / "harness"), "-J" + str(BENCH / "harness"),
             str(BENCH / "source/app.d"), str(BENCH / "harness/probe.d"), *sources, str(provider),
             *("-L--wrap=" + name for name in WRAPS), *flags]
    subprocess.run(build, check=True)
    targets = [("sqlite", [])] + ([("postgres", [args.postgres])] if args.postgres else [])
    report = {"compiler": args.compiler}
    for name, extra in targets:
        run = subprocess.run([str(binary), *extra], capture_output=True, text=True, timeout=120)
        if run.returncode != 0 or "migration checksum 500500" not in run.stdout:
            raise SystemExit(f"{name} probe failed\n{run.stdout}\n{run.stderr}")
        queries = [line for line in run.stderr.splitlines()
                   if line.startswith("sqlite ") or line.startswith("postgres execute")]
        report[name + "_queries"] = len(queries)
        if not 0 < len(queries) <= MAX_QUERIES:
            raise SystemExit(f"{name}: {len(queries)} provider queries for one 1000-entry validation\n" +
                             "\n".join(queries))
    print(json.dumps(report))


if __name__ == "__main__":
    main()
