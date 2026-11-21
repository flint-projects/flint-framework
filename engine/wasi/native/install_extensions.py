#!/usr/bin/env python3
"""Configure Flint's extension inside the verified Wasmtime 51 C ABI workspace."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


REVISION = "32656dc4873fcec5c8662aa937bd01acda3b2e85"
HERE = Path(__file__).resolve().parent
FEATURE = "flint-wasi-extensions"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def upstream(source, path):
    return subprocess.check_output(["git", "show", f"{REVISION}:{path}"], cwd=source, text=True)


def modify(source, relative, addition):
    original = source / relative
    original.write_text(upstream(source, relative) + addition)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("source", type=Path)
    cli.add_argument("--install-prefix", type=Path)
    args = cli.parse_args()
    source = args.source.resolve()
    current = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if current != REVISION:
        raise SystemExit("WASI extensions require exact Wasmtime 51.0.0 source")

    files = [
        "crates/c-api/Cargo.toml",
        "crates/c-api/artifact/Cargo.toml",
        "crates/c-api/src/wasi.rs",
    ]
    modify(source, files[0], f'\n{FEATURE} = ["wasi", "component-model-async", "wasmtime-wasi/p3"]\n')
    modify(source, files[1], f'\n{FEATURE} = ["wasmtime-c-api/{FEATURE}"]\n')
    modify(source, files[2], f'\n#[cfg(feature = "{FEATURE}")]\nmod flint_wasmtime_extensions;\n')
    rust_file = HERE / "flint_wasmtime_extensions.rs"
    adapter = source / "crates/c-api/src/wasi/flint_wasmtime_extensions.rs"
    adapter.parent.mkdir(exist_ok=True)
    shutil.copyfile(rust_file, adapter)

    if args.install_prefix:
        header = HERE / "flint_wasmtime_extensions.h"
        include = args.install_prefix.resolve() / "include"
        include.mkdir(exist_ok=True, parents=True)
        shutil.copyfile(header, include / header.name)
        print(json.dumps({
            "wasmtime_revision": REVISION,
            "cargo_feature": FEATURE,
            "extensions_abi": 1,
            "script_sha256": digest(Path(__file__)),
            "rust_shim_sha256": digest(rust_file),
            "header_sha256": digest(header),
            "upstream_overlay": {name: digest(source / name) for name in files},
        }, sort_keys=True))


if __name__ == "__main__":
    main()
