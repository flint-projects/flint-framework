#!/usr/bin/env python3
"""Build, execute and record the Redis feature and direct hiredis release probes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parents[1] / "tests" / "redis_fixture"
sys.dont_write_bytecode = True
sys.path.insert(0, str(FIXTURE))
from native import verified_archives


def capture(command, logfile, env=None):
    with logfile.open("wb") as log:
        log.write((shlex.join(map(str, command)) + "\n").encode())
        log.flush()
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env, check=True)


def build_reference(args, output):
    archive = output / "libredis_probe_reference.a"
    obj = output / "redis_probe_reference.o"
    capture([args.cc, "-O2", "-fPIC", "-std=c11", "-Wall", "-Wextra", "-Werror",
             f"-I{args.prefix / 'include'}", "-c", HERE / "baseline/c/reference.c",
             "-o", obj], output / "reference-build.log")
    subprocess.run(["ar", "-rcs", archive, obj], check=True)
    return archive


def run_case(args, output, profile, baseline):
    variant = "baseline" if baseline else "feature"
    source = HERE / "baseline" if baseline else HERE
    binary = "probe-cache-redis" + ("-baseline" if baseline else "")
    target = output / f"{profile}-{variant}"
    flags = ["-preview=dip1000", "-release", "-boundscheck=safeonly", f"-{profile}",
             "--flto=thin", "-link-defaultlib-shared=false", f"-linker={args.linker}"]
    env = dict(os.environ, DFLAGS=shlex.join(flags))
    capture(["dub", "build", f"--root={source}", f"--compiler={args.compiler}", "--build=plain",
             "--force", "--skip-registry=all"], target.with_suffix(".build"), env)
    shutil.copy2(source / "build" / binary, target)
    subprocess.run(["strip", "--strip-all", target], check=True)
    measured = target.with_suffix(".run")
    capture([sys.executable, FIXTURE / "run.py", "--server", args.server, "--valkey", args.valkey,
             "--", target], measured)
    capture(["readelf", "--wide", "--dynamic", target], target.with_suffix(".dynamic"))
    checksum, = re.findall(r"^redis-round-trips (\d+)$", measured.read_text(), flags=re.M)
    with target.open("rb") as executable:
        digest = hashlib.file_digest(executable, "sha256").hexdigest()
    return {"bytes": target.stat().st_size, "sha256": digest, "checksum": int(checksum)}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    for name in ("prefix", "server", "valkey", "output"):
        cli.add_argument(f"--{name}", type=Path, required=True)
    cli.add_argument("--compiler", default="ldc2")
    cli.add_argument("--cc", default="cc")
    cli.add_argument("--linker", default="gold")
    args = cli.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = build_reference(args, output)
    flags = [archive, *verified_archives(args.prefix), "-lpthread", "-ldl", "-lm"]
    recipe = HERE / "baseline/dub.sdl"
    original = recipe.read_bytes()
    block = "".join(f"lflags {json.dumps(str(flag))}\n" for flag in flags)
    sizes = {}
    try:
        recipe.write_bytes(original + b"\n" + block.encode())
        for profile in ("O3", "Oz"):
            feature = run_case(args, output, profile, False)
            baseline = run_case(args, output, profile, True)
            if feature["checksum"] != baseline["checksum"]:
                raise SystemExit("provider checksum differs from feature checksum")
            sizes[profile] = {"feature": feature, "baseline": baseline,
                              "signed_delta_bytes": feature["bytes"] - baseline["bytes"]}
    finally:
        recipe.write_bytes(original)
    (output / "size-evidence.json").write_text(json.dumps(sizes, indent=2) + "\n")


if __name__ == "__main__":
    main()
