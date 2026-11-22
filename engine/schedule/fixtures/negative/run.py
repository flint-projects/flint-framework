#!/usr/bin/env python3
"""Check that invalid @Scheduled metadata is rejected by the pinned D compiler with a stable diagnostic."""
import argparse
from pathlib import Path
import subprocess
import tempfile

CASES = {
    "multiple_modes": "scheduled method requires exactly one scheduling mode",
    "zero_mode": "scheduled method requires exactly one scheduling mode",
    "negative_period": "scheduled method requires exactly one scheduling mode",
    "invalid_cron": "invalid scheduled cron expression",
}
POSITIVE = """module valid_component;
import flint.arena : Error;
import flint.conc : Context;
import flint.schedule : Retryable, Scheduled, Scheduler, registerScheduled;
@safe:
final class Valid
{
    @Scheduled("0 */5 * * * 1-5") @Retryable(2) Error invoke(ref Context context) nothrow @nogc
    {
        return context.check();
    }
}
void accept(ref Scheduler scheduler, Valid component)
{
    registerScheduled(scheduler, component);
}
"""


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("compiler")
    args = cli.parse_args()
    here = Path(__file__).resolve().parent
    packages = here.parents[2]
    flags = [f"-I={source}" for source in sorted(packages.glob("*/source"))]
    base = [args.compiler, "-preview=dip1000", "-o-", "-c", *flags]
    with tempfile.TemporaryDirectory(prefix="flint-schedule-negative-") as directory:
        positive = Path(directory) / "valid_component.d"
        positive.write_text(POSITIVE)
        result = subprocess.run([*base, str(positive)], capture_output=True, text=True, check=False)
    print(f"valid_component exit={result.returncode}\n{result.stdout}{result.stderr}", end="")
    if result.returncode != 0:
        raise SystemExit("positive control failed to compile")
    for name, required in CASES.items():
        result = subprocess.run([*base, str(here / (name + ".d"))], capture_output=True, text=True, check=False)
        output = result.stdout + result.stderr
        print(f"{name} exit={result.returncode}\n{output}", end="")
        crashed = "internal compiler error" in output.lower() or "segmentation fault" in output.lower()
        if not 0 < result.returncode < 128 or required not in output or crashed:
            raise SystemExit(f"unexpected compile result for {name}")


if __name__ == "__main__":
    main()
