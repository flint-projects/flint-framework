#!/usr/bin/env python3
"""Check a desktop ELF against the ADR-017 licensing profile.

The system webview (GTK, WebKitGTK, JavaScriptCore, libsoup) is LGPL and may only be
linked dynamically, like glibc. A binary that defines any of their symbols itself has
linked them statically and fails. `--no-system-webview` additionally refuses any dynamic
dependency on them, for SDL canvas-only artifacts.
"""
import argparse
from pathlib import Path
import re
import subprocess

TOOLKIT = re.compile(r"webkit|javascriptcore|gtk|gdk|soup", re.I)
SYMBOL = re.compile(r"^(webkit_|jsc_|gtk_|gdk_|soup_)")


def needed(binary):
    text = subprocess.check_output(["readelf", "-d", "--wide", binary], text=True)
    return re.findall(r"\(NEEDED\).*?\[([^]]+)\]", text)


def defined_toolkit_symbols(binary):
    text = subprocess.check_output(["readelf", "--syms", "--wide", binary], text=True)
    found = set()
    for line in text.splitlines():
        fields = line.split()
        # Num: Value Size Type Bind Vis Ndx Name
        if len(fields) >= 8 and fields[6] != "UND" and fields[3] in ("FUNC", "OBJECT"):
            name = fields[7].split("@", 1)[0]
            if SYMBOL.match(name):
                found.add(name)
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--no-system-webview", action="store_true",
                        help="refuse any GTK/WebKitGTK dependency (SDL canvas-only artifacts)")
    args = parser.parse_args()
    static = defined_toolkit_symbols(args.binary)
    if static:
        parser.exit(1, "LGPL webview code is linked statically: " + ", ".join(static[:8]) + "\n")
    libraries = needed(args.binary)
    system = [name for name in libraries if TOOLKIT.search(name)]
    if system and args.no_system_webview:
        parser.exit(1, "system WebView dependencies are outside this profile: " + ", ".join(system) + "\n")
    print("desktop ELF dependencies: " + ", ".join(libraries))
    print("dynamic system webview (LGPL, not redistributed): " + (", ".join(system) or "none"))


if __name__ == "__main__":
    main()
