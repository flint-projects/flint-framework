"""Run the golden desktop app's scripted session on the current display."""

import argparse
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    args = parser.parse_args()
    result = subprocess.run([args.executable, "--self-test"], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr[-2000:])
    assert "golden-desktop self-test: passed (count=2, greeting=Hello, Ada!)" in result.stdout, result.stdout
    print(result.stdout.strip())


if __name__ == "__main__":
    main()
