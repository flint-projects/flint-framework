#!/usr/bin/env python3
"""Check exact embedded bytes and rejected templates with a pinned D compiler."""
import argparse
import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]
FIXTURE = "V000001__bootstrap.sql"


def generate(directory):
    subprocess.run(
        [
            sys.executable, ROOT / "tools/migration_manifest.py", "--input", directory,
            "--output", directory / "embedded.d", "--module", "embedded",
        ],
        check=True,
        capture_output=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler")
    args = parser.parse_args()
    source_dirs = [
        ROOT / "packages" / name / "source"
        for name in ("arena", "conc", "reactor", "sql", "migrate")
    ]
    options = [args.compiler, "-preview=dip1000", *("-I" + str(folder) for folder in source_dirs)]
    implementation = [path for folder in source_dirs for path in sorted(folder.rglob("*.d"))]
    source = PACKAGE / "fixtures/embed.d"
    original = (PACKAGE / "tests/migrations" / FIXTURE).read_bytes()
    with tempfile.TemporaryDirectory(prefix="flint-migrate-embed-") as temp:
        directory = Path(temp)
        resource = directory / FIXTURE
        target = directory / "embed"
        includes = [*options, "-J" + temp]
        for data in (original, original, original.replace(b"\n", b"\r\n")):
            resource.write_bytes(data)
            generate(directory)
            subprocess.run([*includes, "-of=" + str(target), source, *implementation], check=True)
            observed = subprocess.check_output([target])
            assert observed == hashlib.sha256(data).hexdigest().encode() + b"\n" + data
        assert hashlib.sha256(original).digest() != hashlib.sha256(resource.read_bytes()).digest()

        sidecar = directory / (FIXTURE + ".sha256")
        valid = sidecar.read_bytes()
        sidecar.write_bytes(valid[:64].upper() + valid[64:])
        for name, diagnostic in (
            ("path_escape", "invalid embedded migration filename or version"),
            ("version_mismatch", "invalid embedded migration filename or version"),
            ("invalid_sidecar", "invalid migration SHA-256 sidecar"),
        ):
            result = subprocess.run(
                [*includes, "-c", "-o-", PACKAGE / "negative" / (name + ".d")],
                capture_output=True,
                text=True,
                timeout=10,
            )
            assert result.returncode and diagnostic in result.stderr, result
        for broken in (b"", b"SELECT '\xc2'", b"SELECT 1" + b" " * 1_048_569):
            resource.write_bytes(broken)
            sidecar.write_bytes(valid)
            result = subprocess.run([*includes, "-c", "-o-", source], capture_output=True, text=True, timeout=10)
            assert result.returncode and "invalid UTF-8 or size in migration SQL" in result.stderr, result
    print(args.compiler + ": repeated bytes, CRLF digest, path/version/sidecar negatives, and size/encoding passed")


if __name__ == "__main__":
    main()
