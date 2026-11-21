#!/usr/bin/env python3
"""Check the strict SDL artifact for forbidden GUI toolkit dependencies."""
import argparse
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    text = subprocess.check_output(["readelf", "-d", args.binary], text=True)
    libraries = re.findall(r"\(NEEDED\).*?\[([^]]+)\]", text)
    blocked = [name for name in libraries if re.search(r"webkit|javascriptcore|gtk|gdk|soup", name, re.I)]
    if blocked:
        parser.exit(1, "system WebView dependencies are outside permissive packaging: " + ", ".join(blocked) + "\n")
    print("permissive desktop ELF dependencies: " + ", ".join(libraries))


if __name__ == "__main__":
    main()
