#!/usr/bin/env python3
"""Build the explicit Linux WebKitGTK adapter with an isolated dependency receipt."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = ROOT / "packages/desktop"
SDK = ("webkit2gtk-4.1", "gtk+-3.0", "glib-2.0", "libsoup-3.0", "javascriptcoregtk-4.1")
MARKED = re.compile(r"\n// BEGIN FLINT WEBKITGTK\n.*?// END FLINT WEBKITGTK\n", re.S)


def query(program, *args):
    return subprocess.check_output([program, *args], text=True).strip()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def linker_flags(arguments):
    flags = []
    for flag in arguments:
        if flag == "-pthread":
            flags.append("-lpthread")
        elif flag.startswith("-Wl,"):
            flags.extend(flag[4:].split(","))
        else:
            flags.append(flag)
    return flags


def emit(recipe, archive, flags):
    existing = recipe.read_text()
    body = MARKED.sub("\n", existing).rstrip()
    provider = "\nversions \"FlintDesktopWebkitGtk\" platform=\"linux\""
    libraries = "".join("\nlflags " + json.dumps(str(flag)) + " platform=\"linux\"" for flag in [archive, *flags])
    recipe.write_text(body + "\n\n// BEGIN FLINT WEBKITGTK" + provider + libraries + "\n// END FLINT WEBKITGTK\n")


def main():
    argument = argparse.ArgumentParser(description=__doc__)
    argument.add_argument("--output", required=True, type=Path)
    argument.add_argument("--cc", default=os.environ.get("CC", "cc"))
    argument.add_argument("--pkg-config", default="pkg-config")
    argument.add_argument("--emit-dub", action="store_true")
    argument.add_argument("--permissive-only", action="store_true")
    inputs = argument.parse_args()
    if inputs.permissive_only:
        argument.error("the Linux WebKitGTK system profile is outside permissive-only packaging")
    if sys.platform != "linux":
        argument.error("the WebKitGTK adapter requires Linux and a matching system SDK")
    output = inputs.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    flags = shlex.split(query(inputs.pkg_config, "--cflags", SDK[0]))
    native = shlex.split(query(inputs.pkg_config, "--libs", SDK[0]))
    linked = linker_flags(native)
    source = PACKAGE / "native/webkitgtk.c"
    header = ROOT / "native/ffi/flint_desktop.h"
    obj = output / "flint_desktop_webkitgtk.o"
    archive = output / "libflint_desktop_webkitgtk.a"
    command = [inputs.cc, "-std=c11", "-O2", "-fPIC", "-Wall", "-Wextra", "-Werror",
               "-Wno-deprecated-declarations", "-I", str(header.parent), *flags, "-c", source, "-o", obj]
    subprocess.run(command, check=True)
    subprocess.run(["ar", "rcs", archive, obj], check=True)
    versions = {name: query(inputs.pkg_config, "--modversion", name) for name in SDK}
    receipt = {
        "schema": 1,
        "profile": "linux-system-webkitgtk",
        "permissive": False,
        "system_dependencies": versions,
        "native_source_sha256": sha256(source),
        "common_header_sha256": sha256(header),
        "archive": {"path": str(archive), "sha256": sha256(archive)},
        "cflags": flags,
        "linker_flags": linked,
    }
    (output / "flint-webkitgtk-system.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if inputs.emit_dub:
        emit(PACKAGE / "dub.sdl", archive, linked)
    print(json.dumps({"profile": receipt["profile"], "system_dependencies": versions, "archive": str(archive)}))


if __name__ == "__main__":
    main()
